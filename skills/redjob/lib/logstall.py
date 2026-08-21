"""logstall.py — рантайм-проверка тихих отказов launchd-джоб.

ЗАЧЕМ. Все прочие проверки доктора статические: читают plist, реестр, наличие бинарей.
Класс отказа, который они увидеть НЕ МОГУТ: джоба исправно стартует по расписанию, падает,
пишет ошибку в лог и ретраится — вечно, молча, без единого алерта.

Три реальных случая:
  · джоба-мост падала с FileNotFoundError: 'op' — launchd не даёт homebrew-путь в PATH.
    Элемент очереди провисел 3.5 НЕДЕЛИ, ~600 повторов, каждый аккуратно записан в лог
    строкой «остаётся в pending, повтор через час». Никто не смотрел;
  · до этого та же джоба ловила 403/401 от headless-агента;
  · архив съедал заметку в момент успешной обработки (retention по дате создания).
Общее у всех: отказ ТИХИЙ и с бесконечным ретраем. Логи писались исправно — их не читали.

ПРИНЦИП. «Ошибка была» — не повод для тревоги: разовый сбой сети нормален. Тревога — когда
одна и та же ошибка повторяется И последнее слово в логе за ней, то есть джоба не выкарабкалась.
"""
import os, re, time

TAIL_BYTES = 256 * 1024
TAIL_LINES = 300
MIN_REPEATS = 3          # разовый сбой — не повод; три подряд — уже система
TAIL_WINDOW = 6          # сколько последних строк считаем «последним словом» лога

ERR = re.compile(
    r"Traceback|No such file or directory|command not found|not found\b"
    r"|FAILED|Failed to authenticate|API Error|401|403"
    r"|permission denied|Errno|повтор через|остаётся в pending|exit code [1-9]",
    re.I)

# Нормализация строки в «подпись ошибки»: убираем то, что меняется от прогона к прогону
# (даты, времена, пути, pid, хэши), чтобы одинаковые по сути ошибки схлопывались в одну.
_SUB = [
    (re.compile(r"\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}(:\d{2})?"), "<ts>"),
    # ⚑ Слэш-формат (Go-логи вида «2026/07/15 07:00:04»). Без него каждая строка
    # уникальна, одинаковые ошибки не схлопываются и НАСТОЯЩИЙ тихий отказ такой формы
    # проходит мимо ×3-порога — промах в опасную сторону (пойман на живом парке).
    (re.compile(r"\d{4}/\d{2}/\d{2}[ T]\d{2}:\d{2}(:\d{2})?"), "<ts>"),
    (re.compile(r"/[\w./~-]{6,}"), "<path>"),
    (re.compile(r"\b\d{3,}\b"), "<n>"),
    (re.compile(r"\b[0-9a-f]{8,}\b", re.I), "<hex>"),
]

# Извлечение времени из строки лога. Нужно, чтобы отличить «повторяется прямо сейчас»
# от «случалось пять раз за пять недель»: без окна ×3 набираются за месяцы, и редкие
# транзиентные сбои сети выглядят как система (пойман на живом парке: 15.07/18.07/04.08/19.08).
_TSPATS = [
    (re.compile(r"(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?"), None),
    (re.compile(r"(\d{4})/(\d{2})/(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?"), None),
]


def _ts(line):
    """epoch-секунды из строки лога, либо None если времени в ней нет."""
    for rx, _ in _TSPATS:
        m = rx.search(line)
        if m:
            y, mo, d, h, mi = (int(m.group(i)) for i in range(1, 6))
            sec = int(m.group(6) or 0)
            try:
                return time.mktime((y, mo, d, h, mi, sec, 0, 0, -1))
            except Exception:
                return None
    return None


def _sig(line):
    s = line.strip()
    for rx, rep in _SUB:
        s = rx.sub(rep, s)
    return s[:160]

def _tail(path):
    try:
        sz = os.path.getsize(path)
        with open(path, "rb") as f:
            if sz > TAIL_BYTES:
                f.seek(sz - TAIL_BYTES)
            data = f.read().decode("utf-8", "replace")
        return [l for l in data.split("\n")[-TAIL_LINES:] if l.strip()]
    except Exception:
        return []

def _period_sec(job):
    """Ожидаемый период джобы. None — если посчитать нельзя (не тревожим наугад)."""
    sch = job.get("schedule") or {}
    if sch.get("interval_sec"):
        try: return int(sch["interval_sec"])
        except Exception: return None
    cal = sch.get("calendar")
    if cal:
        # ⚑ Масштаб задаётся самой редкой осью, а не количеством записей. Раньше период
        # считался как «сутки / число записей», и обе календарные джобы с редким циклом
        # объявлялись замолчавшими сразу после НОРМАЛЬНОГО прогона: джоба «1-е и 15-е
        # число» получала 12 ч вместо ~15 суток, недельная (по понедельникам) — 24 ч
        # вместо недели. Ложная тревога на здоровой джобе обесценивает сторож быстрее,
        # чем пропущенная поломка, поэтому берём консервативную (бо́льшую) оценку.
        try:
            if any(e.get("day") is not None for e in cal):
                base = 30 * 86400
            elif any(e.get("weekday") is not None for e in cal):
                base = 7 * 86400
            else:
                base = 86400
            return max(3600, base // max(1, len(cal)))
        except Exception:
            return 86400
    return None

def _muted(job):
    """Курируемые исключения из jobs.yaml: logstall_ignore: [<regex>, ...].

    ⚑ Подавление НЕ делает находку невидимой — она понижается до INFO с пометкой
    «заглушено», потому что вся эта подсистема написана против молчаливого
    проглатывания. Заводить запись только с причиной в поле logstall_ignore_why.
    """
    pats = job.get("logstall_ignore") or []
    outp = []
    for p in pats:
        try:
            outp.append(re.compile(p))
        except re.error:
            continue
    return outp


def scan(job, now=None):
    """[(severity, message, fix)] — пусто, если всё в порядке."""
    now = now or time.time()
    out = []
    mutes = _muted(job)
    logs = job.get("logs") or {}
    for kind in ("err", "out"):
        path = logs.get(kind)
        if not path or not os.path.exists(path):
            continue
        lines = _tail(path)
        if not lines:
            continue
        errs = [l for l in lines if ERR.search(l)]
        if not errs:
            continue
        counts = {}
        for l in errs:
            k = _sig(l)
            counts[k] = counts.get(k, 0) + 1
        # ⚑ Подпись и признак «стоит в хвосте» ОБЯЗАНЫ относиться к одной строке.
        # Первая версия брала самую частую подпись по всему логу, а в хвосте искала
        # ЛЮБУЮ ошибку — и выдавала «последнее слово лога» про строку из середины
        # файла (пойман на живом парке: подпись из строк 62–64 из 174). Это тот же
        # класс, против которого детектор и написан: отчёт не о том, что измерено.
        tail_sigs = {_sig(l) for l in lines[-TAIL_WINDOW:] if ERR.search(l)}
        stalled = [kv for kv in counts.items()
                   if kv[1] >= MIN_REPEATS and kv[0] in tail_sigs]
        age_h = (now - os.path.getmtime(path)) / 3600.0

        if stalled:
            # ⚑ Раньше брали ТОЛЬКО самую частую подпись, и второй независимый затык в том
            # же логе оставался невидим — детектор сообщал бы «одна ошибка», умалчивая о
            # других. Сообщаем о самой частой, но если заклинивших подписей несколько —
            # говорим об этом вслух (no silent cap), а не прячем за max().
            stalled.sort(key=lambda kv: kv[1], reverse=True)
            sig, n = stalled[0]
            extra = ""
            if len(stalled) > 1:
                extra = (f" [ещё заклинивших подписей: {len(stalled) - 1}, суммарно "
                         f"×{sum(v for _k, v in stalled[1:])}]")
            # ⚑ Окно времени. Берём последние MIN_REPEATS датированных вхождений этой
            # подписи: если они размазаны шире пяти периодов джобы — это редкие
            # транзиенты, а не заклинивший ретрай. Строки без даты окно не судят
            # (возвращаемся к прежнему поведению, чтобы не ослепнуть на таких логах).
            occ = [t for t in (_ts(l) for l in errs if _sig(l) == sig) if t]
            per = _period_sec(job) or 86400
            if occ:
                # ⚑ Плотность ≠ свежесть. Пойман на живом парке: доминировала
                # пачка ошибок двухдневной давности — три последних вхождения
                # стояли подряд, окно считало «заклинило», а джоба с тех пор успешно
                # отработала десятки раз. Ложный CRITICAL ушёл в Telegram. Поэтому:
                # (а) само вхождение должно быть свежим, (б) джоба не должна успешно
                # писать в соседний поток ПОСЛЕ последнего появления этой подписи.
                if now - occ[-1] > 5 * per:
                    out.append(("INFO",
                                f"в {kind}-логе ошибка ×{n}, но последнее её появление "
                                f"{(now - occ[-1]) / 86400:.1f} сут назад при периоде "
                                f"{per / 3600:.1f} ч — старая пачка, не заклинило. "
                                f"Подпись: {sig[:90]}{extra}", None))
                    continue
                other_p = logs.get("out" if kind == "err" else "err")
                if (other_p and os.path.exists(other_p) and os.path.getsize(other_p) > 0
                        and os.path.getmtime(other_p) > occ[-1] + 60):
                    out.append(("INFO",
                                f"в {kind}-логе ошибка ×{n}, но соседний лог пополнялся "
                                f"ПОСЛЕ последнего её появления — выкарабкалась. "
                                f"Подпись: {sig[:90]}{extra}", None))
                    continue
            if len(occ) >= MIN_REPEATS:
                span = occ[-1] - occ[-MIN_REPEATS]
                if span > 5 * per:
                    out.append(("INFO",
                                f"в {kind}-логе ошибка ×{n}, но {MIN_REPEATS} последних "
                                f"растянуты на {span/86400:.1f} сут при периоде "
                                f"{per/3600:.1f} ч — редкие транзиенты, не заклинило. "
                                f"Подпись: {sig[:90]}", None))
                    continue
            # ⚑ Кросс-проверка соседнего потока. Ошибки в err ещё не значат отказ:
            # джоба сыпала сетевыми ошибками в err, а в out в это же время шли
            # свежие строки успеха — она выкарабкалась. Тревога только
            # если ПОСЛЕ последней ошибки джоба ничего успешного не написала.
            other = logs.get("out" if kind == "err" else "err")
            recovered = (other and os.path.exists(other)
                         and os.path.getsize(other) > 0
                         and os.path.getmtime(other) > os.path.getmtime(path) + 60)
            if recovered:
                out.append(("INFO",
                            f"в {kind}-логе повторяющаяся ошибка ×{n}, но соседний лог "
                            f"пополнялся позже — джоба выкарабкалась. Подпись: {sig[:90]}{extra}",
                            None))
            elif any(m.search(sig) for m in mutes):
                out.append(("INFO",
                            f"в {kind}-логе повторяющаяся ошибка ×{n} — ЗАГЛУШЕНО по "
                            f"logstall_ignore ({job.get('logstall_ignore_why') or 'причина не указана'}). "
                            f"Подпись: {sig[:90]}{extra}", None))
            else:
                out.append(("CRITICAL",
                            f"тихий отказ с ретраем в {kind}-логе: одна и та же ошибка ×{n}, "
                            f"и последнее слово лога — она же (запись {age_h:.0f} ч назад). "
                            f"Подпись: {sig[:90]}{extra}",
                            f"прочитай {path}; джоба крутится вхолостую и никого не зовёт"))
        else:
            sig, n = max(counts.items(), key=lambda kv: kv[1])
            if n >= MIN_REPEATS:
                out.append(("INFO",
                            f"в {kind}-логе повторяющаяся ошибка ×{n}, но после неё есть записи — "
                            f"похоже, выкарабкалась. Подпись: {sig[:90]}", None))

    # Тишина: лог раньше ПИСАЛСЯ и перестал.
    # ⚠ Пустой лог сигналом НЕ является. Первая версия правила брала mtime любого лога и
    # обвинила четыре здоровые джобы разом, включая ночной синк («молчит 909 ч»).
    # Проверка показала обратное: база обновлена по расписанию, launchctl отдаёт exit 0, а логи
    # нулевые с июля просто потому, что при успехе джоба ничего не печатает. У 0-байтового
    # файла mtime — момент создания, а не прогона. Поэтому смотрим только НЕПУСТЫЕ логи.
    per = _period_sec(job)
    if per:
        # ⚑ Только out-лог. Err пишется ТОЛЬКО при ошибках, поэтому его молчание —
        # хорошая новость, а не подозрение; беря максимум по обоим, правило судило
        # джобы по err-файлу многомесячной давности и обвиняло здоровых. Живой случай: у джобы
        # бэкапа в plist нет StandardOutPath (скрипт ведёт свой лог сам), доктор видел
        # только err многомесячной давности и писал «молчит 1094 ч», тогда как в
        # собственном логе скрипта успех датирован вчерашним днём.
        # Нет out-лога или он пуст — судить не по чему, молчим (лучше промолчать,
        # чем обвинить: ложная тревога обесценивает весь сторож).
        po = logs.get("out")
        newest = (os.path.getmtime(po)
                  if po and os.path.exists(po) and os.path.getsize(po) > 0 else None)
        if newest is not None:
            silent_h = (now - newest) / 3600.0
            if silent_h > 3 * per / 3600.0:
                out.append(("WARNING",
                            f"непустой лог не пополнялся {silent_h:.0f} ч при периоде {per/3600:.1f} ч "
                            f"(три цикла) — раньше писал, перестал",
                            "сверься с `launchctl list | grep <label>`: exit 0 при пустоте — норма, "
                            "ненулевой код или отсутствие в списке — разбирайся"))
    return out

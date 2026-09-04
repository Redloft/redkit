#!/usr/bin/env python3
"""dashboard.py — карточка прогона redloop для показа в чате (mcp__visualize__show_widget).

Читает ТОЛЬКО факты прогона: contract.json, events.jsonl, вывод detect.sh scan.
Принцип: не досочинять. Нет данных — в карточке «—» с причиной, а не правдоподобная цифра
(память: «нет событий ≠ успех»). Знаменатель обязателен везде, где есть счётчик.

Usage: dashboard.py <run_dir> [--stage S3] > widget.html
"""
import json, os, subprocess, sys, html, datetime

STAGES = [("S1", "разведка"), ("S2", "контракт"), ("S3", "промпт"),
          ("S4", "запуск"), ("S5", "прогон"), ("S6", "разбор")]

def read_events(rd):
    p = os.path.join(rd, "events.jsonl"); out = []
    if os.path.exists(p):
        for ln in open(p):
            ln = ln.strip()
            if ln:
                try: out.append(json.loads(ln))
                except json.JSONDecodeError: pass
    return out

def detectors(rd):
    here = os.path.dirname(os.path.abspath(__file__))
    try:
        r = subprocess.run(["bash", os.path.join(here, "detect.sh"), "scan", rd],
                           capture_output=True, text=True, timeout=20)
        return json.loads(r.stdout or "[]")
    except Exception:
        return []

def esc(s): return html.escape(str(s), quote=True)

def build(rd, stage):
    contract = {}
    cp = os.path.join(rd, "contract.json")
    if os.path.exists(cp):
        try: contract = json.load(open(cp))
        except json.JSONDecodeError: pass
    ev = read_events(rd); det = detectors(rd)

    # Список зелёных вердиктов — из ОБЩЕГО файла: он один на гейт, детектор и карточку.
    # Дубль уже дал дефект (карточка считала зелёным fresh_check с NEEDS-WORK).
    # ⚠ fail-closed: молчаливый фолбэк на зашитый дефолт — это ровно тот тихий дрейф,
    # ради устранения которого словарь и заведён. Нет словаря → карточка говорит об этом.
    const, const_err = {}, None
    try:
        const = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "constants.json")))
        if not const.get("fresh_ok_verdicts"): const_err = "словарь неполон"
    except Exception as e:
        const_err = f"словарь недоступен: {type(e).__name__}"
    FRESH_ID = const.get("fresh_check_id", "fresh_check")
    FRESH_OK = set(const.get("fresh_ok_verdicts") or [])

    # ⚠ Требования читаем из СНАПШОТА run_start, а не из живого contract.json: правка контракта
    # после старта уменьшала знаменатель карточки и переводила её в «прогон завершён», пока
    # гейт продолжал требовать подпись. Один источник правды на всех потребителей.
    snap = next((e["payload"] for e in ev if e.get("event_type") == "run_start"), {})
    fresh_req = snap.get("fresh_check") if "fresh_check" in snap else contract.get("fresh_check")
    budget = snap.get("budget") if snap.get("budget") else contract.get("budget")

    dod = list(contract.get("dod") or [])
    # Свежий чекер — такая же строка готовности, как и остальные, просто живёт отдельным полем
    # контракта. Без него он попадал в числитель (он же check_result), но не в знаменатель,
    # и карточка выдавала «2 из 1 проверок зелёные» — ровно то досочинение, которое запрещено.
    # ⚠ И не дублируем: контракт вправе объявить fresh_check и строкой DoD.
    if (fresh_req or {}).get("required") is True and not any(d.get("id") == FRESH_ID for d in dod):
        kind = (fresh_req or {}).get("kind") or "finalize"
        dod.append({"id": FRESH_ID, "cmd": f"свежий контекст ({kind}) → SHIP"})
    dod_total = len(dod)
    dod_ids = {d.get("id") for d in dod}
    # ⚠ статус проверки = ПОСЛЕДНЕЕ её событие, а не «когда-либо была зелёной».
    # Иначе проверка, позеленевшая на 3-й итерации и упавшая на 15-й, навсегда остаётся
    # зелёной, и карточка рапортует «прогон завершён» поверх красного прогона.
    # Та же семантика, что у PREMATURE-EXIT в detect.sh — один смысл на двух потребителей.
    last_by_check = {}
    for e in sorted((x for x in ev if x.get("event_type") == "check_result"),
                    key=lambda x: x.get("seq", 0)):
        last_by_check[e["payload"].get("check_id")] = e
    # ⚠ Считаем ТОЛЬКО строки контракта: числитель по всем check_id журнала позволял
    # посторонней зелёной проверке заткнуть слот недоделанной строки DoD.
    def _is_green(cid, e):
        if e.get("kind") == "blocked" or e["payload"].get("exit_code") != 0:
            return False
        # для свежего чекера exit 0 НЕ равно «зелено»: решает вердикт (тот же смысл,
        # что в гейте events.sh и детекторе detect.sh — один список на троих)
        if cid == FRESH_ID:
            return e["payload"].get("verdict") in FRESH_OK
        return True
    scoped = {c: e for c, e in last_by_check.items() if c in dod_ids}
    green = {c for c, e in scoped.items() if _is_green(c, e)}
    blocked = {c for c, e in scoped.items() if e.get("kind") == "blocked"}
    red = {c for c, e in scoped.items()
           if e.get("kind") != "blocked" and not _is_green(c, e)}
    # ⚠ Сужение к строкам контракта касается ЧИСЛИТЕЛЯ, но не тревоги: проверка с чужим
    # check_id и exit≠0 иначе исчезала из карточки совсем, и «прогон завершён · 1 из 1»
    # печаталось поверх упавшего build. Считаем и показываем отдельной строкой.
    outside = {c: e for c, e in last_by_check.items() if c not in dod_ids}
    outside_red = {c for c, e in outside.items()
                   if e.get("kind") != "blocked" and e["payload"].get("exit_code") != 0}
    iters = [e for e in ev if e.get("event_type") == "iter_done"]
    iter_n = len(iters)
    iter_of = (budget or {}).get("max_iters")
    assumptions = len([e for e in ev if e.get("event_type") == "assumption"])
    interventions = len([e for e in ev if e.get("event_type") == "question"
                         and e["payload"].get("allowed") is False]) \
                  + len([e for e in ev if e.get("event_type") == "escalation"])
    infra = len([e for e in ev if e.get("kind") == "infra_failure"])
    neg = len([e for e in ev if e.get("kind") == "negative_verdict"])
    done_ev = [e for e in ev if e.get("event_type") == "run_done"]

    # ── приёмка человеком: «названо в финале N из M» ────────────────────
    # ⚠ Читаем СНАПШОТ run_start, а не живой contract.json: правка контракта задним числом
    # уменьшала бы знаменатель. Ключа в снапшоте нет → прогон стартовал до выката v3.3.3,
    # и карточка обязана сказать это, а не показать бодрое «0 из 0».
    acc_declared = "human_acceptance" in snap
    acc_snap = snap.get("human_acceptance") if acc_declared else None
    acc_items = acc_snap if isinstance(acc_snap, list) else []
    acc_manual = [a for a in acc_items if a.get("manual_only") is True]
    presented = []
    if done_ev:
        _p = done_ev[-1]["payload"].get("acceptance_presented")
        if isinstance(_p, list): presented = [x for x in _p if isinstance(x, str)]
    acc_m = len(acc_manual)
    acc_n = len([a for a in acc_manual if a.get("id") in presented])

    hard = [d for d in det if not d.get("shadow")]
    # ⚠ Не-тихий детектор ГЛАВНЕЕ «прогон завершён»: иначе прогон, закрытый в обход гейта,
    # показывался владельцу зелёным, а сигнал о том, что его обошли, — ниже по карточке.
    _outcome = (done_ev[-1]["payload"].get("outcome") or "success") if done_ev else "success"
    if hard:
        status, tone = "нужен человек", "danger"
    elif outside_red and _outcome == "success":
        # красное вне контракта не закрывает прогон: контракт мог просто не знать про эту проверку
        status, tone = "красные проверки вне контракта", "danger"
    elif _outcome != "success":
        # прогон честно объявил, что не сделал: показывать это исходом, а не «завершён»
        # и не «красные проверки» — незакрытая работа у сдавшегося прогона это норма, а не болезнь
        status, tone = {"failed": "прогон не сделал задачу",
                        "blocked": "прогон упёрся во внешнее",
                        "abandoned": "прогон прекращён"}.get(_outcome, f"исход: {_outcome}"), "warning"
    elif done_ev and dod_total and len(green) == dod_total:
        status, tone = "прогон завершён", "success"
    elif done_ev and blocked and not red and (len(green) + len(blocked)) == dod_total:
        # «ждёт владельца» только когда ВСЕ строки DoD разобраны: иначе недоделанная работа
        # маскируется под внешнюю блокировку
        status, tone = "закрыт частично · ждёт владельца", "warning"
    elif det:
        status, tone = "идёт, есть сигналы", "warning"
    elif ev:
        status, tone = "идёт", "accent"
    else:
        status, tone = "не начат", "muted"

    order = [s[0] for s in STAGES]
    cur = stage if stage in order else ("S5" if ev else "S2")
    ci = order.index(cur)

    def pill(i, code, name):
        if i < ci: bg, fg, bd, ico = "var(--bg-success)", "var(--text-success)", "var(--border-success)", "ti-check"
        elif i == ci: bg, fg, bd, ico = "var(--bg-accent)", "var(--text-accent)", "var(--border-accent)", "ti-player-play"
        else: bg, fg, bd, ico = "transparent", "var(--text-muted)", "var(--border)", "ti-point"
        return (f'<div style="flex:1;min-width:96px;background:{bg};border:1px solid {bd};border-radius:var(--radius);'
                f'padding:8px 10px"><div style="font-family:var(--font-mono);font-size:11px;color:{fg}">'
                f'<i class="ti {ico}" aria-hidden="true"></i> {code}</div>'
                f'<div style="font-size:13px;color:{fg};margin-top:2px">{name}</div></div>')

    def kpi(label, value, sub=""):
        return (f'<div style="background:var(--surface-1);border:1px solid var(--border);border-radius:12px;padding:12px 14px">'
                f'<div style="font-size:11px;color:var(--text-muted)">{label}</div>'
                f'<div style="font-size:20px;font-weight:500;color:var(--text-primary);'
                f'font-family:var(--font-mono);margin-top:2px">{value}</div>'
                f'<div style="font-size:12px;color:var(--text-secondary)">{sub}</div></div>')

    pct = int(100 * len(green) / dod_total) if dod_total else 0
    tone_fg = {"success": "var(--text-success)", "danger": "var(--text-danger)",
               "warning": "var(--text-warning)", "accent": "var(--text-accent)",
               "muted": "var(--text-muted)"}[tone]
    tone_bg = {"success": "var(--bg-success)", "danger": "var(--bg-danger)",
               "warning": "var(--bg-warning)", "accent": "var(--bg-accent)",
               "muted": "var(--surface-1)"}[tone]

    checks = []
    for d in dod:
        cid = d.get("id", "?")
        ev_last = last_by_check.get(cid)
        vd = (ev_last or {}).get("payload", {}).get("verdict") if ev_last else None
        if cid == FRESH_ID and vd and cid not in green:
            ico, col, note = "ti-circle-x", "var(--text-danger)", f"вердикт {vd} — не зелёный"
        elif cid in green: ico, col, note = "ti-circle-check", "var(--text-success)", "зелёная"
        elif cid in blocked: ico, col, note = "ti-lock", "var(--text-warning)", "заблокирована внешним"
        elif cid in red: ico, col, note = "ti-circle-x", "var(--text-danger)", "красная"
        elif not d.get("cmd"): ico, col, note = "ti-user", "var(--text-secondary)", "приёмка человеком"
        else: ico, col, note = "ti-circle-dashed", "var(--text-muted)", "не запускалась"
        cmd = d.get("cmd") or d.get("desc", "")
        checks.append(
            f'<div style="display:flex;gap:8px;align-items:baseline;padding:6px 0;border-bottom:1px solid var(--border)">'
            f'<i class="ti {ico}" style="color:{col};font-size:16px" aria-hidden="true"></i>'
            f'<code style="font-family:var(--font-mono);font-size:12px;color:var(--text-primary)">{esc(cmd)}</code>'
            f'<span style="margin-left:auto;font-size:12px;color:{col}">{note}</span></div>')
    # строка про проверки вне контракта — со знаменателем, как и всё в карточке
    if const_err:
        checks.append('<div style="font-size:12px;color:var(--text-danger);margin-top:6px">'
                      f'{esc(const_err)} — статус проверок показан НЕ по общему словарю</div>')
    if outside:
        _names = ", ".join(sorted(esc(c) for c in outside_red)) or "—"
        checks.append(
            f'<div style="font-size:12px;color:{"var(--text-danger)" if outside_red else "var(--text-muted)"};'
            f'margin-top:6px">проверки вне контракта: {len(outside)}, из них красных '
            f'{len(outside_red)} ({_names})</div>')
    checks_html = "".join(checks) or '<div style="color:var(--text-muted);font-size:13px">контракт ещё не собран</div>'

    if det:
        chips = "".join(
            f'<span style="display:inline-block;padding:3px 9px;border-radius:999px;font-size:12px;'
            f'background:{"var(--bg-warning)" if d.get("shadow") else "var(--bg-danger)"};'
            f'color:{"var(--text-warning)" if d.get("shadow") else "var(--text-danger)"};'
            f'border:1px solid {"var(--border-warning)" if d.get("shadow") else "var(--border-danger)"};'
            f'margin:0 6px 6px 0">{esc(d["detector"])}'
            f'{" · тихий режим" if d.get("shadow") else " · эскалация"}</span>' for d in det)
        det_html = chips + (f'<div style="font-size:12px;color:var(--text-secondary);margin-top:2px">'
                            f'{esc(det[0]["evidence"])}</div>' if det else "")
    else:
        det_html = ('<div style="font-size:13px;color:var(--text-muted)">тихо — ни один детектор не сработал'
                    f' на {iter_n} итерациях</div>')

    # HTML блока приёмки — по тем же правилам, что и всё в карточке: не досочинять,
    # знаменатель обязателен, «—» с причиной вместо правдоподобного нуля.
    if not acc_declared:
        acc_head = "— приёмка не снята в снапшоте run_start (прогон стартовал до выката v3.3.3)"
        acc_col, acc_rows = "var(--text-muted)", ""
    elif acc_snap is None:
        acc_head = "контракт приёмку не объявлял — предъявлять нечего и проверить нечем"
        acc_col, acc_rows = "var(--text-danger)", ""
    elif not acc_items:
        acc_head = "кадров приёмки нет — осознанный отказ владельца (0 из 0)"
        acc_col, acc_rows = "var(--text-muted)", ""
    else:
        # красным только на ЗАКРЫТОМ прогоне: пока прогон идёт, непредъявленный кадр —
        # это ещё не потеря, а ложная тревога обесценивает сигнал быстрее пропуска
        acc_col = ("var(--text-danger)" if (done_ev and acc_n < acc_m)
                   else "var(--text-success)" if acc_m and acc_n == acc_m
                   else "var(--text-secondary)")
        acc_head = f"названо в финале {acc_n} из {acc_m}"
        if acc_m == 0:
            acc_head += " · машинно непроверяемых кадров нет, все закрыты пробами"
        rows = []
        for a in acc_items:
            aid = a.get("id") or "—"
            if a.get("manual_only") is True:
                if aid in presented:
                    ico, col, note = "ti-user-check", "var(--text-success)", "названо в финале"
                else:
                    ico, col, note = "ti-user-exclamation", "var(--text-danger)", "НЕ названо"
                what = "машинно непроверяемо"
            else:
                pr = a.get("probe")
                what = f"проба {pr}" if pr else "проба не названа"
                if pr in green: ico, col, note = "ti-circle-check", "var(--text-success)", "проба зелёная"
                elif pr in blocked: ico, col, note = "ti-lock", "var(--text-warning)", "проба заблокирована"
                elif pr in red: ico, col, note = "ti-circle-x", "var(--text-danger)", "проба красная"
                elif pr is None: ico, col, note = "ti-help", "var(--text-danger)", "адреса проверки нет"
                else: ico, col, note = "ti-circle-dashed", "var(--text-muted)", "проба не запускалась"
            rows.append(
                f'<div style="display:flex;gap:8px;align-items:baseline;padding:5px 0;border-bottom:1px solid var(--border)">'
                f'<i class="ti {ico}" style="color:{col};font-size:15px" aria-hidden="true"></i>'
                f'<code style="font-family:var(--font-mono);font-size:12px;color:var(--text-primary)">{esc(aid)}</code>'
                f'<span style="font-size:12px;color:var(--text-secondary)">{esc(what)}</span>'
                f'<span style="margin-left:auto;font-size:12px;color:{col}">{note}</span></div>')
        acc_rows = "".join(rows)
    # ⚠ Граница честности, как у fresh_check: журнал проверяет, что кадр НАЗВАН в финале,
    # а не что владелец его посмотрел и принял. Карточка не вправе утверждать больше журнала —
    # «предъявлено владельцу» было утверждением о человеческом взаимодействии без единого
    # подтверждения под ним.
    acc_note = ('<div style="font-size:11px;color:var(--text-muted);margin-top:6px">'
                'журнал сверяет, что кадр НАЗВАН в финале, а не что владелец его принял</div>'
                ) if acc_items else ""
    acc_html = (f'<div style="display:flex;justify-content:space-between;font-size:13px;'
                f'color:var(--text-secondary);margin-bottom:6px"><span>приёмка человеком</span>'
                f'<span style="font-family:var(--font-mono);color:{acc_col}">{esc(acc_head)}</span></div>'
                + acc_rows + acc_note)

    task = contract.get("task") or "задача не задана"
    runner = contract.get("runner") or "—"
    psha = (contract.get("patterns_sha") or "—")[:8]
    upd = datetime.datetime.now().strftime("%H:%M")

    return f"""<h2 class="sr-only">Карточка автономного прогона redloop: стадия {cur}, {len(green)} из {dod_total} проверок зелёные, приёмка — {esc(acc_head)}, статус — {status}</h2>
<div style="padding:2px 0 4px;display:flex;align-items:baseline;gap:10px;flex-wrap:wrap">
  <span style="font-family:var(--font-mono);font-size:12px;color:var(--text-accent)">REDLOOP</span>
  <span style="font-size:16px;color:var(--text-primary)">{esc(task)}</span>
  <span style="margin-left:auto;padding:3px 10px;border-radius:999px;font-size:12px;background:{tone_bg};color:{tone_fg}">{status}</span>
</div>
<div style="display:flex;gap:6px;flex-wrap:wrap;margin:10px 0 14px">{"".join(pill(i, c, n) for i, (c, n) in enumerate(STAGES))}</div>
<div style="background:var(--surface-1);border:1px solid var(--border);border-radius:12px;padding:14px;margin-bottom:12px">
  <div style="display:flex;justify-content:space-between;font-size:13px;color:var(--text-secondary)">
    <span>контракт готовности</span><span style="font-family:var(--font-mono)">{len(green)} / {dod_total}</span></div>
  <div style="height:6px;border-radius:999px;background:var(--surface-0);margin:8px 0 12px;overflow:hidden">
    <div style="height:6px;width:{pct}%;background:var(--text-success)"></div></div>
  {checks_html}
</div>
<div style="background:var(--surface-1);border:1px solid var(--border);border-radius:12px;padding:14px;margin-bottom:12px">
  {acc_html}
</div>
<div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:10px;margin-bottom:12px">
  {kpi("итерация", f"{iter_n} / {iter_of if iter_of else '—'}", "из бюджета")}
  {kpi("вмешательств", interventions, "человек трогал прогон")}
  {kpi("допущений", assumptions, "решил сам, записал")}
  {kpi("сбои / красные", f"{infra} / {neg}", "инфра · вердикт")}
</div>
<div style="background:var(--surface-1);border:1px solid var(--border);border-radius:12px;padding:14px">
  <div style="font-size:13px;color:var(--text-secondary);margin-bottom:8px">детекторы</div>
  {det_html}
</div>
<div style="display:flex;gap:14px;flex-wrap:wrap;font-size:12px;color:var(--text-muted);margin-top:10px">
  <span>раннер: {esc(runner)}</span><span>приёмы: {esc(psha)}</span>
  <span>обновлено {upd}</span>
</div>"""

def _self_test():
    """Минимальная проверка ветки статусов: зелёная→красная и зелёная→blocked."""
    import tempfile, subprocess, shutil
    here = os.path.dirname(os.path.abspath(__file__)); fails = []
    def run(rd, *args):
        subprocess.run(["bash", os.path.join(here, "events.sh"), "append", rd] + list(args),
                       capture_output=True)
    def fixture(tmp, name, seq, extra=None, presented=None):
        rd = os.path.join(tmp, name); os.makedirs(rd, exist_ok=True)
        # ⚠ human_acceptance обязателен и в фикстурах: без него run_start отвергается гейтом И9,
        # то есть фикстура шла бы НЕ тем путём, что боевой прогон.
        c = {"task": "t", "budget": {"max_iters": 5}, "state_files": [],
             "human_acceptance": [],
             "dod": [{"id": "a", "cmd": "x", "expect_exit": 0},
                     {"id": "b", "cmd": "y", "expect_exit": 0}]}
        c.update(extra or {})
        json.dump(c, open(os.path.join(rd, "contract.json"), "w"))
        run(rd, "run_start", '{"runner":"session","contract_sha":"a"}')
        run(rd, "iter_done", '{"task_id":"t","files_changed":1,"checkboxes_done":1}', "--iter", "1", "--of", "2")
        for payload in seq:
            # отчёт чекера обязан лежать ПОД каталогом прогона, содержать свой вердикт и быть
            # новее последней итерации — как в жизни, где чекер зовут ПОСЛЕ работы
            if "__RD__" in payload:
                rep = os.path.join(rd, "judge.md")
                vd = json.loads(payload.replace("__RD__", rd)).get("verdict", "")
                open(rep, "w").write(f"# Finalize\nverdict: **{vd}**\n")
                payload = payload.replace("__RD__", rd)
            run(rd, "check_result", payload, "--iter", "1")
        done = {"verdict": "partial", "iters": 1, "interventions": 0}
        if presented is not None: done["acceptance_presented"] = presented
        run(rd, "run_done", json.dumps(done, ensure_ascii=False))
        return rd
    tmp = tempfile.mkdtemp()
    os.environ["REDLOOP_INDEX"] = os.path.join(tmp, "index.jsonl")   # боевой реестр не трогаем
    # событие свежего чекера обязано указывать на существующий непустой отчёт (самоаттестация
    # запрещена) — фикстуры играют по тем же правилам, что боевой прогон
    def fresh_ev(verdict):
        # __RD__ подставит fixture: путь известен только внутри неё
        return json.dumps({"check_id": "fresh_check", "cmd_hash": "f",
                           "exit_code": 0, "verdict": verdict, "report": "__RD__/judge.md"},
                          ensure_ascii=False)
    try:
        # была зелёной, стала красной — карточка обязана показать красную, а не «завершён»
        rd = fixture(tmp, "regress", ['{"check_id":"a","cmd_hash":"h","exit_code":0}',
                                      '{"check_id":"b","cmd_hash":"h","exit_code":0}',
                                      '{"check_id":"a","cmd_hash":"h","exit_code":1}'])
        html = build(rd, "S6")
        if "прогон завершён" in html: fails.append("регрессия зелёной проверки выдана за успех")
        if "красная" not in html: fails.append("красная проверка не показана")
        # зелёная + заблокированная внешним = «ждёт владельца»
        rd = fixture(tmp, "blocked", ['{"check_id":"a","cmd_hash":"h","exit_code":0}',
                                      '{"check_id":"b","cmd_hash":"h","exit_code":1,"result":"blocked_owner_action"}'])
        html = build(rd, "S6")
        if "ждёт владельца" not in html: fails.append("blocked-прогон не помечен как ждущий владельца")
        if "заблокирована внешним" not in html: fails.append("blocked-строка не подписана")
        # частичное покрытие DoD не должно выдаваться за «ждёт владельца»
        # свежий чекер обязан попасть и в числитель, и в ЗНАМЕНАТЕЛЬ: иначе карточка
        # рапортует «2 из 1 проверок зелёные» — досочинение, запрещённое её же правилами
        rd = fixture(tmp, "fresh", ['{"check_id":"a","cmd_hash":"h","exit_code":0}',
                                    '{"check_id":"b","cmd_hash":"h","exit_code":0}',
                                    fresh_ev("SHIP")],
                     extra={"fresh_check": {"kind": "finalize", "required": True}})
        html = build(rd, "S6")
        if "3 из 3" not in html: fails.append("знаменатель карточки не учёл fresh_check")
        if "свежий контекст" not in html: fails.append("строка свежего чекера не показана в карточке")

        # exit 0 при NEEDS-WORK — НЕ зелёная строка: тот же смысл, что в гейте и детекторе
        rd = fixture(tmp, "fresh-nowork", ['{"check_id":"a","cmd_hash":"h","exit_code":0}',
                                           '{"check_id":"b","cmd_hash":"h","exit_code":0}',
                                           fresh_ev("NEEDS-WORK")],
                     extra={"fresh_check": {"kind": "finalize", "required": True}})
        html = build(rd, "S6")
        if "3 из 3" in html: fails.append("карточка зачла fresh_check с NEEDS-WORK как зелёный")
        if "вердикт NEEDS-WORK" not in html: fails.append("карточка не назвала незелёный вердикт чекера")
        if "прогон завершён" in html: fails.append("прогон с незелёным чекером показан завершённым")

        # посторонняя зелёная проверка не затыкает слот строки DoD
        rd = fixture(tmp, "stranger", ['{"check_id":"a","cmd_hash":"h","exit_code":0}',
                                       '{"check_id":"посторонняя","cmd_hash":"h","exit_code":0}'])
        html = build(rd, "S6")
        if "2 из 2" in html: fails.append("чужой check_id зачтён в числитель DoD")
        if "проверки вне контракта: 1" not in html: fails.append("проверка вне контракта не показана")

        # КРАСНАЯ проверка вне контракта не должна исчезать: «завершён» поверх упавшего build
        rd = fixture(tmp, "outside-red", ['{"check_id":"a","cmd_hash":"h","exit_code":0}',
                                          '{"check_id":"b","cmd_hash":"h","exit_code":0}',
                                          '{"check_id":"build","cmd_hash":"h","exit_code":1}'])
        html = build(rd, "S6")
        if "прогон завершён" in html: fails.append("красная проверка вне контракта выдана за успех")
        if "build" not in html: fails.append("красная проверка вне контракта не названа в карточке")

        # fresh_check, объявленный И строкой DoD, не задваивается в знаменателе
        rd = fixture(tmp, "nodup", ['{"check_id":"a","cmd_hash":"h","exit_code":0}'],
                     extra={"fresh_check": {"kind": "finalize", "required": True},
                            "dod": [{"id": "a", "cmd": "x", "expect_exit": 0},
                                    {"id": "fresh_check", "cmd": "своя строка", "expect_exit": 0}]})
        html = build(rd, "S6")
        if "из 2" not in html: fails.append("fresh_check задвоился в знаменателе карточки")

        rd = fixture(tmp, "partial", ['{"check_id":"a","cmd_hash":"h","exit_code":1,"result":"blocked_by_env"}'])
        html = build(rd, "S6")
        if "ждёт владельца" in html: fails.append("недоделанный DoD замаскирован под внешнюю блокировку")

        # ── блок приёмки: у human_acceptance появился читатель в карточке ──────
        ha = [{"id": "52", "what": "карточка", "probe": "a"},
              {"id": "53", "what": "сочетаемость", "manual_only": True, "why": "вкусовой кадр"},
              {"id": "57", "what": "конструктор", "manual_only": True, "why": "вкусовой кадр"}]
        rd = fixture(tmp, "acc-full", ['{"check_id":"a","cmd_hash":"h","exit_code":0}',
                                       '{"check_id":"b","cmd_hash":"h","exit_code":0}'],
                     extra={"human_acceptance": ha}, presented=["53", "57"])
        html = build(rd, "S6")
        # ⚠ Заголовок sr-only несёт ту же строку, поэтому отдельно проверяем ВИДИМЫЙ блок:
        # без этой проверки контроль зеленел бы на одной только строке для скринридера.
        if ">приёмка человеком<" not in html:
            fails.append("видимого блока приёмки в карточке нет")
        if "названо в финале 2 из 2" not in html:
            fails.append("карточка не показала знаменатель предъявленных кадров приёмки")
        if "названо в финале" not in html or "НЕ названо" in html:
            fails.append("предъявленные кадры показаны неверно")
        if "проба a" not in html: fails.append("кадр с пробой не связан со строкой DoD")

        # прогон со strict=0 гейт не держит — и именно тут карточка обязана быть читателем
        rd = os.path.join(tmp, "acc-gap"); os.makedirs(rd, exist_ok=True)
        json.dump({"task": "t", "budget": {"max_iters": 5}, "state_files": [],
                   "human_acceptance": ha, "dod": [{"id": "a", "cmd": "x", "expect_exit": 0}]},
                  open(os.path.join(rd, "contract.json"), "w"))
        env = dict(os.environ, REDLOOP_STRICT_JOURNAL="0")
        for args in (["run_start", '{"runner":"session","contract_sha":"a"}'],
                     ["iter_done", '{"task_id":"t","files_changed":1,"checkboxes_done":1}', "--iter", "1"],
                     ["run_done", '{"verdict":"green","iters":1,"interventions":0}']):
            subprocess.run(["bash", os.path.join(here, "events.sh"), "append", rd] + args,
                           capture_output=True, env=env)
        html = build(rd, "S6")
        if ">приёмка человеком<" not in html:
            fails.append("видимого блока приёмки нет на прогоне со strict=0")
        if "названо в финале 0 из 2" not in html:
            fails.append("непредъявленные кадры не показаны знаменателем на прогоне со strict=0")
        if "НЕ названо" not in html:
            fails.append("непредъявленный кадр не назван в карточке")

        # прогон, стартовавший до выката: «—» с причиной, а не бодрое «0 из 0»
        rd = os.path.join(tmp, "acc-legacy"); os.makedirs(rd, exist_ok=True)
        open(os.path.join(rd, "events.jsonl"), "w").write(json.dumps({
            "schema_version": 1, "ts": "2026-09-01T10:00:00Z", "run_id": "l", "seq": 1,
            "event_type": "run_start", "kind": "progress", "severity": "info",
            "denominator": {"iter": None, "of": None},
            "payload": {"runner": "session", "contract_sha": "o"}}) + "\n")
        html = build(rd, "S6")
        if "не снята в снапшоте run_start" not in html:
            fails.append("карточка выдумала приёмку для прогона, стартовавшего до выката")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    for f in fails: print("  ✗", f)
    print("✓ dashboard self-test passed" if not fails else "✗ dashboard self-test FAILED")
    return 1 if fails else 0


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        sys.exit(_self_test())
    if len(sys.argv) < 2:
        print("usage: dashboard.py <run_dir> [--stage S3]", file=sys.stderr); sys.exit(1)
    rd = sys.argv[1]
    st = sys.argv[sys.argv.index("--stage") + 1] if "--stage" in sys.argv else ""
    sys.stdout.write(build(rd, st))

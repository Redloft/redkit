#!/usr/bin/env python3
"""redjob doctor — read-only аудит парка джоб.

СТРОГО read-only: никаких launchctl load/unload, никаких правок plist.
Ловит ровно класс тихих поломок из ТЗ (health.sh 127, ночное TCC-окно,
missing gtimeout, VACUUM, коллизии). Проверяет ИСХОД, а не паттерн:
PATH — реальным резолвом бинарей в эффективном окружении джобы.

Severity: CRITICAL (exit≠0), WARNING, INFO.
"""
import os
import re
import sys
import glob
import shutil
import subprocess

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common
import plistparse
import registry
import scrub


# ---------- модель находки ----------
class Finding:
    __slots__ = ("sev", "rule", "label", "msg", "fix")

    def __init__(self, sev, rule, label, msg, fix=None):
        self.sev, self.rule, self.label, self.msg, self.fix = sev, rule, label, msg, fix


# ---------- сбор контекста скрипта (depth-1) ----------
def _resolve_source(token, script):
    """Разрешить путь из `source X`/`. X` (best-effort: $DIR/$HOME/кавычки)."""
    t = token.strip().strip('"').strip("'")
    d = os.path.dirname(os.path.abspath(script)) if script else ""
    t = (t.replace("$DIR", d).replace("${DIR}", d)
           .replace("$HOME", common.HOME).replace("${HOME}", common.HOME))
    if not t.startswith("/"):
        t = os.path.join(d, t)
    return t if os.path.exists(t) else None


def gather_context(script, depth=1):
    """Вернуть (combined_text, sourced_files, unresolved_sources).

    combined = текст скрипта + текст depth-1 sourced-файлов. unresolved>0 =
    есть source, который мы не смогли разрешить → op-эвристика помечается
    'глубже эвристики'.
    """
    if not script or not os.path.exists(script):
        return "", [], 0
    try:
        txt = open(script, encoding="utf-8", errors="replace").read()
    except Exception:
        return "", [], 0
    combined = [txt]
    sourced, unresolved = [], 0
    if depth >= 1:
        for m in re.finditer(r"(?m)^\s*(?:source|\.)\s+([^\s;#]+)", txt):
            tok = m.group(1)
            # пропускаем очевидно не-файловые (одиночная точка и пр. попадёт в None)
            r = _resolve_source(tok, script)
            if r:
                sourced.append(r)
                try:
                    combined.append(open(r, encoding="utf-8", errors="replace").read())
                except Exception:
                    pass
            elif "/" in tok or "$" in tok:
                unresolved += 1
    return "\n".join(combined), sourced, unresolved


# ---------- эффективное окружение (для PATH-резолва) ----------
def build_env_path(model, ctx_text):
    """Эффективный PATH джобы: plist EnvironmentVariables.PATH ИЛИ launchd-дефолт,
    плюс все реальные PATH=… присвоения из скрипта/source (разбор, не тумблер)."""
    base = model.get("env_path") or common.LAUNCHD_DEFAULT_PATH
    return common.parse_path_assignments(ctx_text, base)


# ---------- правила ----------
def check_job(job, live, findings):
    label = job["label"]
    if job.get("status") == "external":
        return
    if job.get("status") == "retired":
        return

    script = job.get("script")
    ctx, sourced, unresolved = gather_context(script)
    # реальный env из plist (для точного PATH-резолва + not-strict-XML сигнал)
    plist_env_path = None
    pm = {}
    try:
        pm = plistparse.parse(job["plist"]) if job.get("plist") and os.path.exists(job["plist"]) else {}
        plist_env_path = pm.get("env_path")
        if pm.get("lenient_parse"):
            findings.append(Finding("WARNING", "plist-xml", label,
                                     "plist не строгий XML (сырой control-байт?) — читается только "
                                     "через plutil; launchd терпит, но почини комментарий"))
    except Exception:
        pass

    # --- 0. no-trigger: plist без единого триггера — джоба сама не стартует ---
    # По РАСПАРСЕННОМУ plist, не по реестру: seed отмывает kind=unknown в
    # keepalive (реальный инцидент 2026-07 — plist без SCI/StartInterval/
    # KeepAlive, RunAtLoad=false, джоба месяц молчала).
    if pm and not pm.get("_error") and pm.get("kind") == "unknown":
        if pm.get("run_at_load"):
            findings.append(Finding("WARNING", "no-trigger", label,
                                     "в plist нет StartCalendarInterval/StartInterval/KeepAlive — "
                                     "запуск только RunAtLoad (раз на login/load); для периодической "
                                     "джобы это тихая смерть",
                                     fix="перегенери через `redjob add --generate` с kind "
                                         "calendar|interval|keepalive"))
        else:
            findings.append(Finding("CRITICAL", "no-trigger", label,
                                     "в plist нет ни одного триггера (StartCalendarInterval/"
                                     "StartInterval/KeepAlive) и RunAtLoad=false — джоба НИКОГДА "
                                     "не запустится",
                                     fix="перегенери через `redjob add --generate` с kind "
                                         "calendar|interval|keepalive"))

    # --- 5. Файловая гигиена ---
    interp = job.get("interpreter")
    if interp and interp.startswith("/") and not os.path.exists(interp):
        findings.append(Finding("CRITICAL", "file-hygiene", label,
                                 f"интерпретатор не найден: {interp}"))
    # путь-подобный script = содержит '/' (и абсолютный, и относительный);
    # НЕ путь (напр. uvicorn-модуль 'pkg.main:app') — не проверяем на файл.
    looks_path = bool(script) and "/" in script
    if looks_path and not os.path.exists(script):
        findings.append(Finding("CRITICAL", "file-hygiene", label,
                                 f"script не найден: {script}"))
    elif script and os.path.exists(script) and not os.access(script, os.X_OK):
        # не всегда критично (bash script arg), но отметим
        findings.append(Finding("INFO", "file-hygiene", label,
                                 f"script не исполняемый (ок если запускается как арг bash): {script}"))
    logs = job.get("logs") or {}
    for kind, lp in (("err", logs.get("err")), ("out", logs.get("out"))):
        if lp and os.path.dirname(lp) and not os.path.isdir(os.path.dirname(lp)):
            findings.append(Finding("WARNING", "file-hygiene", label,
                                     f"каталог {kind}-лога не существует: {os.path.dirname(lp)}"))
        elif lp and os.path.exists(lp):
            sz = os.path.getsize(lp)
            if sz > 10 * 1024 * 1024:
                findings.append(Finding("WARNING", "file-hygiene", label,
                                         f"{kind}-лог раздут: {sz // 1024 // 1024} МБ ({lp})"))

    # --- 2/4. PATH + missing bins через реальный резолв ---
    eff_path = build_env_path({"env_path": plist_env_path}, ctx)
    login = common.uses_login_shell(ctx)
    for b in (job.get("deps_bins") or []):
        if shutil.which(b, path=eff_path):
            continue
        if login:
            # бинарь резолвится через login-shell (~/.zshenv PATH) — статикой не подтвердить
            findings.append(Finding("INFO", "path-resolve", label,
                                     f"бинарь '{b}' не в статическом PATH, но скрипт делегирует в "
                                     f"login-shell (zsh -lc) — резолв в рантайме, проверь при сбое"))
        else:
            findings.append(Finding("CRITICAL", "path-resolve", label,
                                     f"бинарь '{b}' не резолвится в PATH джобы "
                                     f"(eff PATH={_short(eff_path)})",
                                     fix=f"добавь EnvironmentVariables.PATH с {common.HOMEBREW_BIN} "
                                         f"в plist или `export PATH` в скрипте"))

    # --- 3. op-safety (honest heuristic, source-depth=1) ---
    op_in_script = common.invokes(ctx, "op")
    if job.get("auth") == "op-sa" or op_in_script:
        verified = job.get("op_safety") == "manually-verified"
        # SA-токен один уже уводит op в service-account режим (десктоп-1Password не
        # трогается → нет TCC-окна); op_env.sh делает то же. biometric=false — бонус.
        # ВАЖНО: по comment-stripped тексту — упоминание гварда в КОММЕНТАРИИ ≠ safe
        # (иначе ложно-safe пропускал бы TCC-класс; симметрично с invokes()).
        code_ctx = common.strip_comments(ctx)
        safe = ("op_env.sh" in code_ctx) or ("OP_SERVICE_ACCOUNT_TOKEN" in code_ctx)
        if verified:
            findings.append(Finding("INFO", "op-safety", label,
                                     "op-цепочка помечена manually-verified в реестре"))
        elif safe:
            # SA-токен/op_env.sh на месте → TCC-окно не грозит. Молчим сознательно:
            # многие джобы (inbox/sleep) сорсят op_env.sh, а сам `op` зовёт claude-
            # обёртка вне depth-1 — op_in_script=False здесь НОРМА, не дрифт. Шумим
            # только если эвристика частична (неразрешённый source) — честность глубины.
            if unresolved:
                findings.append(Finding("INFO", "op-safety", label,
                                         "op-safety PASS (SA/op_env), но есть неразрешённый source "
                                         "(depth=1) — эвристика частична"))
        elif not op_in_script and job.get("auth") == "op-sa":
            # auth=op-sa заявлен, но ни `op`, ни SA/op_env не видны — реестр мог отстать
            findings.append(Finding("WARNING", "op-safety", label,
                                     "auth=op-sa, но вызов `op` не виден в скрипте/source (depth=1) и нет "
                                     "SA-токена/op_env.sh — op-цепочка глубже эвристики, проверь руками",
                                     fix="подтверди тегом `op_safety: manually-verified` в jobs.yaml"))
        else:
            # сюда попадаем только при not safe И (op_in_script ИЛИ auth!=op-sa):
            # `op` реально зовётся без SA/op_env → риск ночного TCC-окна.
            extra = " [есть неразрешённый source — эвристика могла не дойти]" if unresolved else ""
            findings.append(Finding("CRITICAL", "op-safety", label,
                                     f"вызывает `op`, но не сорсит op_env.sh и не ставит "
                                     f"OP_SERVICE_ACCOUNT_TOKEN+OP_BIOMETRIC_UNLOCK_ENABLED "
                                     f"→ риск ночного TCC-окна{extra}",
                                     fix="source op_env.sh ИЛИ export OP_BIOMETRIC_UNLOCK_ENABLED=false "
                                         "+ SA-токен из Keychain"))

    # --- 1. Drift: реестр отстал от кода (код — источник фактов) ---
    if op_in_script and job.get("auth") == "none":
        findings.append(Finding("WARNING", "drift-code", label,
                                 "скрипт вызывает `op`, но в реестре auth=none — реестр отстал от кода"))
    known = set(job.get("deps_bins") or [])
    for b in ("gtimeout", "jq", "sqlite3"):
        if common.invokes(ctx, b) and b not in known:
            findings.append(Finding("INFO", "drift-code", label,
                                     f"скрипт использует '{b}', которого нет в deps_bins реестра"))


def _short(path, n=60):
    return path if len(path) <= n else path[:n] + "…"


# ---------- парковые правила (drift, коллизии, herd, cron) ----------
def check_park(data, live, findings, la_dir=None, reg_path=None):
    la_dir = la_dir or common.LAUNCH_AGENTS
    reg_path = reg_path or registry.JOBS_YAML
    reg_labels = {j["label"] for j in data.get("jobs", [])}
    disk_plists = {}
    for p in glob.glob(os.path.join(la_dir, "*.plist")):
        lbl = os.path.basename(p).replace(".plist", "")
        disk_plists[lbl] = p

    # 1. Drift: на диске есть, в реестре нет (и наоборот)
    for lbl, p in disk_plists.items():
        if lbl not in reg_labels and not common.is_external_label(lbl):
            findings.append(Finding("WARNING", "drift", lbl,
                                     f"plist есть в LaunchAgents, но НЕ в jobs.yaml: {p}",
                                     fix="прогони `redjob seed --write` или добавь вручную"))
    for j in data.get("jobs", []):
        # external исключён симметрично check_job («без проверок»): вендорский plist
        # (GoogleUpdater/homebrew.mxcl) может исчезнуть при апдейте — это не наш дефект.
        if j.get("status") in ("retired", "external"):
            continue
        lbl = j["label"]
        pl = j.get("plist")
        if pl and not os.path.exists(pl):
            findings.append(Finding("CRITICAL", "drift", lbl,
                                     f"в реестре есть, но plist на диске отсутствует: {pl}"))

    # 8. Exit-code + загружена ли (из launchctl)
    for j in data.get("jobs", []):
        if j.get("status") not in ("active",):
            continue
        lbl = j["label"]
        st = live.get(lbl)
        if st is None:
            findings.append(Finding("WARNING", "not-loaded", lbl,
                                     "active в реестре, но НЕ загружена в launchctl (выгружена?)"))
        elif st.get("last_exit") not in (None, 0):
            code = st["last_exit"]
            # 126/127 = exec/не-найден (наш целевой класс) → CRITICAL.
            # Прочий положительный код = отработала, но упала → WARNING (не «не найден»).
            # Отрицательный (сигнал): для keepalive SIGTERM/SIGKILL — норма рестарта → INFO.
            if code in (126, 127):
                sev, tail = "CRITICAL", " (бинарь/скрипт не найден — класс health.sh)"
            elif code > 0:
                sev, tail = "WARNING", " (отработала с ошибкой — не «не найден»)"
            elif j.get("kind") == "keepalive":
                sev, tail = "INFO", " (сигнал; для keepalive рестарт — норма)"
            else:
                sev, tail = "WARNING", " (завершена сигналом)"
            findings.append(Finding(sev, "exit-code", lbl,
                                     f"последний выход launchctl = {code}{tail}"))

    # 6. Коллизии расписаний (СТАТИЧЕСКИ из jobs.yaml)
    _collision_rules(data, findings)
    _lock_groups(data, findings)

    # 7. Thundering-herd после сна (отдельный источник, всегда INFO)
    wakes = common.pmset_last_wakes(3)
    if wakes:
        findings.append(Finding("INFO", "herd", "*",
                                 f"последние wake: {', '.join(wakes)} — launchd мог схлопнуть "
                                 f"пропущенные во сне calendar-джобы в пачку (не коллизия)"))

    # cron: скилл называется launchd/cron — проверяем и crontab
    try:
        r = subprocess.run(["crontab", "-l"], capture_output=True, text=True, timeout=10)
        lines = [l for l in r.stdout.splitlines() if l.strip() and not l.strip().startswith("#")]
        if lines:
            findings.append(Finding("WARNING", "cron", "*",
                                     f"в crontab {len(lines)} записей — они НЕ в jobs.yaml "
                                     f"(реестр покрывает только launchd)"))
        else:
            findings.append(Finding("INFO", "cron", "*", "crontab пуст (парк = только launchd)"))
    except Exception:
        pass

    # 9. Secrets-lint реестра
    hits = scrub.lint_registry_file(reg_path)
    for lbl_reason, masked in hits:
        findings.append(Finding("CRITICAL", "secrets", "jobs.yaml",
                                 f"секрет в реестре: {lbl_reason} (~{masked}) — "
                                 f"реестр хранит только имена env, не значения"))


def _cal_minutes(job):
    """Список (weekday|None, minute-of-day) для calendar-джобы; иначе []."""
    sched = job.get("schedule") or {}
    cal = sched.get("calendar") or []
    out = []
    for e in cal:
        h = e.get("hour")
        mn = e.get("minute") or 0
        if h is None:
            continue
        out.append((e.get("weekday"), h * 60 + mn))
    return out


def _wd_overlap(a, b):
    """Пересекаются ли дни недели (None = каждый день)."""
    return a is None or b is None or a == b


def _lock_groups(data, findings):
    """Advisory: какие джобы делят lock (карта контеншена для секвенирования).

    Пара calendar-джоб в ±10мин уже ловится _collision_rules как WARNING;
    здесь — общая картина + подсветка ежечасных interval-джоб, которые могут
    совпасть на :00 (напр. две ежечасные джобы одного проекта, делящие БД)."""
    by_lock = {}
    for j in data.get("jobs", []):
        if j.get("status") != "active":
            continue
        for lk in (j.get("locks") or []):
            by_lock.setdefault(lk, []).append(j)
    for lk, jobs in sorted(by_lock.items()):
        if len(jobs) < 2:
            continue
        names = ", ".join(sorted(j["label"] for j in jobs))
        hourly = [j["label"] for j in jobs
                  if j.get("kind") == "interval" and (j.get("schedule") or {}).get("interval_sec") == 3600]
        extra = (f" ⚠ ежечасные могут совпасть на :00 — {', '.join(sorted(hourly))}"
                 if len(hourly) >= 2 else "")
        findings.append(Finding("INFO", "lock-group", lk,
                                 f"{len(jobs)} джоб делят lock '{lk}': {names} — секвенируй, "
                                 f"чтобы не гонялись за ресурсом{extra}"))


def _collision_rules(data, findings):
    active = [j for j in data.get("jobs", []) if j.get("status") == "active"]
    slots = []   # (job, weekday, minute)
    for j in active:
        for wd, mn in _cal_minutes(j):
            slots.append((j, wd, mn))
    seen_pairs = set()
    for i in range(len(slots)):
        for k in range(i + 1, len(slots)):
            (ja, wda, ma), (jb, wdb, mb) = slots[i], slots[k]
            if ja["label"] == jb["label"]:
                continue
            if not _wd_overlap(wda, wdb):
                continue
            d = abs(ma - mb)
            gap = min(d, 1440 - d)   # круговой: 23:55 и 00:05 = 10мин, не 1430
            pair = tuple(sorted((ja["label"], jb["label"])))
            # общий lock в ±10мин
            shared = set(ja.get("locks") or []) & set(jb.get("locks") or [])
            if shared and gap <= 10 and (pair, "lock") not in seen_pairs:
                seen_pairs.add((pair, "lock"))
                findings.append(Finding("WARNING", "collision-lock", f"{ja['label']} ↔ {jb['label']}",
                                         f"делят lock {sorted(shared)} и стартуют в {gap}мин друг от друга "
                                         f"— секвенируй (риск гонки за {sorted(shared)[0]})"))
            # два heavy-claude в ±30мин
            if (ja.get("weight") == "heavy-claude" and jb.get("weight") == "heavy-claude"
                    and gap <= 30 and (pair, "heavy") not in seen_pairs):
                seen_pairs.add((pair, "heavy"))
                findings.append(Finding("WARNING", "collision-heavy", f"{ja['label']} ↔ {jb['label']}",
                                         f"оба heavy-claude и стартуют в {gap}мин — не сажай два "
                                         f"headless-claude в одно окно (стекуются по CPU/подписке)"))


# ---------- прогон + рендер ----------
def run(reg_path=None, la_dir=None):
    data = registry.load(reg_path) if reg_path else registry.load()
    live = common.launchctl_list()
    findings = []
    for j in data.get("jobs", []):
        check_job(j, live, findings)
    check_park(data, live, findings, la_dir=la_dir, reg_path=reg_path)
    # op-safety-2: слепые зоны depth-1 op-safety — MCP-серверы в ~/.claude.json
    # с голым `command: op` (+ op в args обёртки) И headless launchd-цепочки
    # глубже depth-1. Отдельный rule-id, не дублирует launchd-op-safety depth-1
    # (scan_launchd_chains исключает сам script джобы). Сбой скана НЕ глушим тихо
    # — иначе регрессия даёт ложно-чистый doctor (false-clean в security-инструменте).
    try:
        import vault_audit
        for vf in vault_audit.scan():
            findings.append(Finding(vf.sev, "op-safety-2", vf.target, vf.msg, vf.fix))
    except Exception as e:
        findings.append(Finding("WARNING", "op-safety-2", "vault-audit",
                                f"op-safety-2 не смог выполниться ({type(e).__name__}) — "
                                f"MCP/launchd-развёртка НЕ проверена этим прогоном",
                                fix="прогони `redjob vault-audit` вручную и почини импорт/скан"))
    return data, findings


def render(findings, quiet=False):
    findings.sort(key=lambda f: (common.SEV_ORDER.get(f.sev, 9), f.rule, f.label))
    n_crit = sum(1 for f in findings if f.sev == "CRITICAL")
    n_warn = sum(1 for f in findings if f.sev == "WARNING")
    n_info = sum(1 for f in findings if f.sev == "INFO")
    lines = []
    lines.append(common.c("redjob doctor", "1") +
                 f" — CRITICAL={n_crit} WARNING={n_warn} INFO={n_info}")
    lines.append("")
    for f in findings:
        if quiet and f.sev == "INFO":
            continue
        head = common.c(f"[{f.sev}]", common.sev_color(f.sev))
        lines.append(f"{head} {common.c(f.rule, '1')} · {f.label}")
        lines.append(f"    {f.msg}")
        if f.fix:
            lines.append(common.c(f"    fix: {f.fix}", "2"))
    if not findings:
        lines.append(common.c("✓ находок нет", "1;32"))
    # scrub-on-render: единая точка — весь блок (вкл. label) через скраб, как list_cmd
    return scrub.scrub_text("\n".join(lines)), n_crit


def main(argv):
    quiet = "--quiet" in argv
    data, findings = run()
    text, n_crit = render(findings, quiet=quiet)
    print(text)
    return 1 if n_crit else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""redjob plistgen — Фаза 2: генератор plist из канон-шаблона + self-doctor гейт.

В шаблон ВШИТЫ выученные Ф1 грабли: PATH с /opt/homebrew/bin и ~/.local/bin,
Standard{Out,Err}Path в ~/.cache/<proj>/, шапка-комментарий с install/uninstall,
напоминание source op_env.sh при auth=op-sa.

ГЕЙТ (plan v2 шаг 9): сгенерированный plist ОБЯЗАН пройти собственный doctor
(правила Ф1) ДО того, как install-команды показаны — doctor-FAIL = plist не
показываем, чиним вход. install/uninstall печатаются командами; НЕ выполняем.
"""
import os
import re
import sys
import shlex
import plistlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common
import doctor
import registry
import scrub

# Label — только reverse-DNS-безопасные символы. Закрывает path-traversal в
# staging-пути (F3), shell-инъекцию в печатаемых install-командах (F4) и порчу
# XML-шапки через '-->' (F5). Без '/', '..', пробелов, control-байт.
LABEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")

STAGING = os.path.join(common.HOME, ".cache", "redjob", "staging")
SNAPSHOTS = os.path.join(common.HOME, ".cache", "redjob", "snapshots")
CANON_PATH = f"{common.HOMEBREW_BIN}:{common.HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"


def _header(spec):
    """XML-комментарий-шапка с install/uninstall в шапке."""
    label = spec["label"]
    pl = _plist_target(label)
    return (f"<!-- redjob-generated. Проект: {spec.get('project','?')}.\n"
            f"     install:   cp {_staging_path(label)} {pl} && launchctl load {pl}\n"
            f"     uninstall: launchctl unload {pl} && rm {pl}\n"
            + ("     ВНИМАНИЕ auth=op-sa: скрипт ДОЛЖЕН source op_env.sh (SA-токен) —\n"
               "     иначе ночное TCC-окно (doctor это проверит).\n" if spec.get("auth") == "op-sa" else "")
            + "-->")


def _plist_target(label):
    return os.path.join(common.LAUNCH_AGENTS, f"{label}.plist")


def _staging_path(label):
    return os.path.join(STAGING, f"{label}.plist")


def build_plist_dict(spec):
    """spec → dict для plistlib. Вшивает PATH, логи, RunAtLoad."""
    proj = spec.get("project", "misc")
    label = spec["label"]
    log_dir = os.path.join(common.HOME, ".cache", proj)
    d = {
        "Label": label,
        "ProgramArguments": [spec.get("interpreter", "/bin/bash"), spec["script"]]
                            + list(spec.get("args") or []),
        "EnvironmentVariables": {"PATH": CANON_PATH,
                                 **(spec.get("env") or {})},
        "RunAtLoad": bool(spec.get("run_at_load", False)),
        "StandardOutPath": os.path.join(log_dir, f"{label}.out.log"),
        "StandardErrorPath": os.path.join(log_dir, f"{label}.err.log"),
    }
    kind = spec.get("kind")
    if kind == "calendar":
        cal = spec.get("calendar")
        if cal:
            d["StartCalendarInterval"] = cal if isinstance(cal, list) else [cal]
    elif kind == "interval":
        d["StartInterval"] = int(spec["interval_sec"])
    elif kind == "keepalive":
        d["KeepAlive"] = True
        d["RunAtLoad"] = True
    return d


def render_plist(spec):
    """Вернуть строку plist (шапка-комментарий + XML)."""
    body = plistlib.dumps(build_plist_dict(spec)).decode("utf-8")
    # вставить шапку-комментарий после <?xml ...?> строки
    lines = body.splitlines()
    if lines and lines[0].startswith("<?xml"):
        return lines[0] + "\n" + _header(spec) + "\n" + "\n".join(lines[1:])
    return _header(spec) + "\n" + body


def _spec_schedule(spec):
    """schedule в форме, которую читают park-правила (_cal_minutes/_lock_groups)."""
    kind = spec.get("kind")
    if kind == "calendar":
        cal = spec.get("calendar")
        norm = [{"hour": e.get("Hour"), "minute": e.get("Minute"),
                 "weekday": (0 if e.get("Weekday") == 7 else e.get("Weekday"))}
                for e in ((cal if isinstance(cal, list) else [cal]) if cal else [])]
        return {"calendar": norm}
    if kind == "interval":
        try:
            return {"interval_sec": int(spec.get("interval_sec"))}
        except (TypeError, ValueError):
            return {}
    return {}


def _synthetic_job(spec, path):
    """Запись реестра для нового plist — с полем schedule (иначе park-коллизии слепы)."""
    d = build_plist_dict(spec)
    return {
        "label": spec["label"], "project": spec.get("project", "misc"),
        "kind": spec.get("kind"), "plist": path, "script": spec["script"],
        "interpreter": spec.get("interpreter", "/bin/bash"),
        "deps_bins": spec.get("deps_bins") or [], "auth": spec.get("auth", "none"),
        "locks": spec.get("locks") or [], "weight": spec.get("weight", "light"),
        "status": "active", "schedule": _spec_schedule(spec),
        "logs": {"out": d["StandardOutPath"], "err": d["StandardErrorPath"]},
    }


def _scan_spec_secrets(spec, findings):
    """Секрет-значение в spec.env/args → CRITICAL (env хранит ИМЕНА, не значения)."""
    blobs = []
    for k, v in (spec.get("env") or {}).items():
        blobs.append(f"{k}={v}")
    blobs += [str(a) for a in (spec.get("args") or [])]
    # script/interpreter тоже идут в ProgramArguments → в plist; сканируем и их
    blobs += [str(spec.get("script") or ""), str(spec.get("interpreter") or "")]
    for b in blobs:
        for reason, masked in scrub.find_secrets(b):
            findings.append(doctor.Finding(
                "CRITICAL", "secrets", spec["label"],
                f"секрет-значение в spec.env/args ({reason}, ~{masked}) — env хранит "
                f"ИМЕНА переменных, значение живёт в 1Password",
                fix="убери значение из spec; инъектируй через op run/op_env.sh в рантайме"))
        if "op://" in b:
            findings.append(doctor.Finding(
                "CRITICAL", "secrets", spec["label"],
                "op://-ссылка как literal-значение env — launchd её не развернёт "
                "(джоба получит строку) + утечка модели доступа"))


def stage_and_check(spec, park_data=None):
    """Валидировать вход, сгенерить plist в staging, прогнать ПОЛНЫЙ гейт
    (check_job + park-коллизии + secrets spec). Возвращает (path|None, findings, n_crit).
    n_crit>0 = НЕ показывать install. park_data — впрыснуть реестр (тесты); иначе живой."""
    findings = []
    label = spec.get("label", "")
    # F3/F4/F5: невалидный label = стоп ДО записи файла (path-traversal/shell-инъекция)
    if not LABEL_RE.match(label or ""):
        findings.append(doctor.Finding(
            "CRITICAL", "label", str(label)[:40],
            "label не reverse-DNS-безопасен (только [A-Za-z0-9][A-Za-z0-9._-]*): "
            "риск path-traversal в staging и инъекции в install-командах"))
        return None, findings, 1

    _scan_spec_secrets(spec, findings)   # F2

    os.makedirs(STAGING, exist_ok=True)
    path = _staging_path(label)
    with open(path, "w", encoding="utf-8") as f:
        f.write(render_plist(spec))

    job = _synthetic_job(spec, path)
    live = {}   # staging plist не загружен — exit-code/not-loaded не применяем
    doctor.check_job(job, live, findings)

    # F1: park-правила (коллизии/локи) на реальном парке + новая джоба
    try:
        data = park_data if park_data is not None else registry.load()
        merged = {"schema_version": data.get("schema_version"),
                  "jobs": list(data.get("jobs", [])) + [job]}
        park = []
        doctor._collision_rules(merged, park)
        doctor._lock_groups(merged, park)
        # только находки, где НОВАЯ джоба — реальный участник (точный матч по
        # сторонам пары «A ↔ B», не подстрока — иначе короткий label вытягивает чужое)
        for f in park:
            if "↔" in f.label:
                if label in [s.strip() for s in f.label.split("↔")]:
                    findings.append(f)
            elif label in (f.msg or ""):   # lock-group (INFO): участие по списку в msg
                findings.append(f)
    except Exception:
        pass

    n_crit = sum(1 for f in findings if f.sev == "CRITICAL")
    return path, findings, n_crit


def pre_install_snapshot():
    """Снимок launchctl-стейта + копия jobs.yaml ПЕРЕД любой установкой.
    Возвращает путь к каталогу снапшота (в реальном шелле; date доступен)."""
    import subprocess, shutil, datetime
    ts = datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    d = os.path.join(SNAPSHOTS, ts)
    os.makedirs(d, exist_ok=True)
    try:
        with open(os.path.join(d, "launchctl.list.txt"), "w") as f:
            subprocess.run(["launchctl", "list"], stdout=f, timeout=15)
    except Exception:
        pass
    from registry import JOBS_YAML
    if os.path.exists(JOBS_YAML):
        shutil.copy2(JOBS_YAML, os.path.join(d, "jobs.yaml"))
    return d


def install_commands(spec, staging_path):
    label = spec["label"]
    target = _plist_target(label)
    q = shlex.quote   # defense-in-depth поверх label-валидатора (F4)
    install = [f"cp {q(staging_path)} {q(target)}", f"launchctl load {q(target)}"]
    # rollback: unload + rm + retired в реестре. ВНИМАНИЕ: откат plist ≠ откат данных.
    rollback = [f"launchctl unload {q(target)}", f"rm {q(target)}"]
    warn = None
    if spec.get("locks"):
        warn = (f"⚠ rollback plist ≠ rollback данных: джоба трогает lock "
                f"{spec['locks']} — после отката проверь состояние ресурса вручную.")
    return install, rollback, warn

#!/usr/bin/env python3
"""redjob seed — построить первичный jobs.yaml из живого парка LaunchAgents.

Факты берём из КОДА (скрипты), не из головы: deps_bins/op/weight/db-локи
детектятся сканом entrypoint'а. Доменный overlay (ANNOTATIONS) добавляет то,
что из скрипта не вывести машинно (locks через depth>1, weight, notes).
Сторонние агенты (com.google/homebrew.mxcl/com.apple) → status: external без проверок.
"""
import os
import re
import sys
import glob

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common
import plistparse
import registry

KNOWN_BINS = ["op", "claude", "gtimeout", "jq", "sqlite3", "python3", "node",
              "uvicorn", "curl", "git", "rsync", "osascript", "pmset", "launchctl"]

# Overlay поверх авто-детекта: только то, что из скрипта не вывести машинно
# (локи через depth>1, weight скрытый в под-скрипте, auth-нюансы, заметки).
# Заполни своими джобами. Пример формата:
#
#   ANNOTATIONS = {
#     "com.example.nightly": {
#         "auth": "op-sa",                  # если op-цепочка глубже depth-1
#         "weight": "heavy-claude",          # если тяжёлый claude в под-скрипте
#         "locks": ["mydb"],                 # разделяемый ресурс, невидимый в entrypoint
#         "env_required": ["PATH"],
#         "notes": "человекочитаемое описание",
#     },
#   }
ANNOTATIONS = {}


def detect_from_script(script):
    """Скан entrypoint: deps_bins, uses_op, heavy-claude, db-lock, self-PATH, op-safety."""
    d = {"deps_bins": [], "uses_op": False, "heavy_claude": False,
         "db_lock": False, "self_path": False, "op_env_sourced": False,
         "sa_fallback": False, "biometric_off": False}
    if not script or not os.path.exists(script):
        return d
    try:
        txt = open(script, encoding="utf-8", errors="replace").read()
    except Exception:
        return d
    for b in KNOWN_BINS:
        if common.invokes(txt, b):
            d["deps_bins"].append(b)
    d["op_env_sourced"] = bool(re.search(r"(?:source|\.)\s+[^\n]*op_env\.sh", txt))
    d["uses_op"] = common.invokes(txt, "op") or d["op_env_sourced"]
    # heavy-claude: реальный запуск агента, не просто упоминание слова
    code = common.strip_comments(txt)
    d["heavy_claude"] = bool(re.search(r"claude\s+(?:-p|--print)|gtimeout\b[^\n]*claude|run_headless", code))
    # db-контеншн: скрипт трогает sqlite/файл-БД → джобы одного проекта делят lock
    d["db_lock"] = bool(re.search(r"\bsqlite3?\b|\.db\b|\.sqlite\b", txt, re.I))
    d["self_path"] = bool(re.search(r"(?m)^\s*(?:export\s+)?PATH=", txt)) \
        or "/opt/homebrew/bin" in txt
    d["op_env_sourced"] = bool(re.search(r"(?:source|\.)\s+[^\n]*op_env\.sh", txt))
    d["sa_fallback"] = "OP_SERVICE_ACCOUNT_TOKEN" in txt
    d["biometric_off"] = "OP_BIOMETRIC_UNLOCK_ENABLED" in txt
    return d


def build():
    jobs = []
    for p in sorted(glob.glob(os.path.join(common.LAUNCH_AGENTS, "*.plist"))):
        m = plistparse.parse(p)
        label = m["label"]
        external = common.is_external_label(label)
        if external:
            jobs.append({
                "label": label, "project": "external", "kind": "keepalive",
                "plist": p, "status": "external",
                "notes": "Сторонний агент — наблюдается в drift-отчёте, без проверок.",
            })
            continue

        proj = common.project_from_label(label)
        det = detect_from_script(m.get("script"))
        kind = m.get("kind") if m.get("kind") in registry.VALID_KIND else "keepalive"

        # schedule (машинно + человекочитаемо)
        sched = {"human": plistparse.schedule_human(m)}
        if kind == "calendar":
            sched["calendar"] = m.get("schedule")
        elif kind == "interval":
            sched["interval_sec"] = m.get("interval_sec")

        auth = "op-sa" if det["uses_op"] else "none"
        weight = "heavy-claude" if det["heavy_claude"] else "light"
        locks = [f"{proj}-db"] if det["db_lock"] else []

        job = {
            "label": label,
            "project": proj,
            "kind": kind,
            "schedule": sched,
            "plist": p,
            "script": m.get("script"),
            "interpreter": m.get("interpreter"),
            "deps_bins": det["deps_bins"],
            "auth": auth,
            "locks": locks,
            "weight": weight,
            "env_required": ["PATH"] if m.get("env_path") else [],
            "logs": {"out": m.get("stdout"), "err": m.get("stderr")},
            "status": "active",
        }
        # overlay
        ann = ANNOTATIONS.get(label, {})
        for k, v in ann.items():
            job[k] = v
        jobs.append(job)

    return {"schema_version": registry.SCHEMA_VERSION, "jobs": jobs}


if __name__ == "__main__":
    data = build()
    dry = "--write" not in sys.argv
    errs = registry.validate(data)
    if errs:
        print("SEED INVALID:\n  " + "\n  ".join(errs), file=sys.stderr)
        sys.exit(1)
    if dry:
        print(registry.dump_str(data))
        print(f"\n# --- dry-run: {len(data['jobs'])} джоб. Запусти с --write чтобы записать jobs.yaml ---",
              file=sys.stderr)
    else:
        registry.atomic_write(data)
        print(f"✓ jobs.yaml записан: {len(data['jobs'])} джоб → {registry.JOBS_YAML}")

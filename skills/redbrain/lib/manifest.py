#!/usr/bin/env python3
"""redbrain scan-manifest + резолвер source_id→файл (STEP-0 F1/F2 для «Сна»).

ПРОБЛЕМА (обнаружено STEP-0): 120 источников work.db собраны ad-hoc из РАЗНЫХ корней;
абсолютный путь нигде не хранится, а префикс `memory/` схлопывает 13 разных
`~/.claude/projects/*/memory/` в одно пространство → неоднозначность и tombstone-коллизии.

РЕШЕНИЕ: единый декларативный манифест {prefix → dir(s), scope, flags}. Резолвер
source_id→abspath: 1 совпадение → OK; 0 → NOT_FOUND/GHOST; >1 → AMBIGUOUS (REFUSE,
никогда не гадаем какой файл править). sleep_apply трогает ТОЛЬКО OK-резолвы.

CLI:
  manifest.py show                 — печать активного манифеста
  manifest.py resolve <source_id>  — резолв одного (scope из REDBRAIN_SCOPE)
  manifest.py audit                — резолюция ВСЕХ источников текущего scope: сколько правимо
"""
import sys, os, json, glob, sqlite3

HOME = os.path.expanduser("~")
CC = os.environ.get("CLAUDECORE_PATH", "")
CLAUDE_PROJECTS = os.path.join(HOME, ".claude", "projects")
AUTOMEM = os.environ.get("REDBRAIN_AUTOMEM") or os.path.join(CLAUDE_PROJECTS,
    "-Users-igorkonovalcik-Yandex-Disk-localized------------------ClaudeCore", "memory")

SCOPE = os.environ.get("REDBRAIN_SCOPE", "work")
_DIR = os.path.expanduser(os.environ.get("REDBRAIN_DB_DIR",
                          "~/Library/Application Support/graph-memory"))
DB = os.path.join(_DIR, f"{SCOPE}.db")


def memory_roots():
    """Все ~/.claude/projects/*/memory (легаси-префикс memory/ ищем во всех)."""
    return sorted(glob.glob(os.path.join(CLAUDE_PROJECTS, "*", "memory")))


def roots():
    """Декларативный манифест. dirs=[] + флаг → префикс без файловой подложки."""
    return [
        {"prefix": "self/",        "dirs": [os.path.join(CC, "личные данные ", "self")], "scope": "private"},
        {"prefix": "servers/",     "dirs": [os.path.join(CC, "servers")],  "scope": "private"},
        {"prefix": "projects/",    "dirs": [os.path.join(CC, "projects")], "scope": "work"},
        {"prefix": "apis/",        "dirs": [os.path.join(CC, "apis")],     "scope": "work"},
        {"prefix": "core/",        "dirs": [CC],                            "scope": "work", "recursive": False},
        {"prefix": "rc-projects/", "dirs": [],                              "scope": "private", "ghost": True},
        {"prefix": "inbox/",       "dirs": [],                              "scope": "work", "ephemeral": True},
        {"prefix": "memory/",      "dirs": memory_roots(),                  "scope": "work", "legacy_multiroot": True},
        {"prefix": "",             "dirs": [AUTOMEM],                        "scope": "work"},  # no-prefix — последним
    ]


def match_root(source_id):
    """Самый длинный подходящий префикс (пустой '' — в конце как fallback)."""
    for r in roots():
        if r["prefix"] and source_id.startswith(r["prefix"]):
            return r
    for r in roots():
        if r["prefix"] == "":
            return r
    return None


def resolve(source_id):
    """→ dict{status, path?, candidates?}. status ∈ OK|AMBIGUOUS|GHOST|NOT_FOUND."""
    r = match_root(source_id)
    if r is None:
        return {"status": "NOT_FOUND", "reason": "no root"}
    if r.get("ephemeral"):
        return {"status": "GHOST", "reason": "ephemeral namespace (not file-backed)"}
    if r.get("ghost") or not r["dirs"]:
        return {"status": "GHOST", "reason": "no backing dir declared"}
    base = source_id[len(r["prefix"]):]
    hits = [os.path.join(d, base) for d in r["dirs"] if os.path.isfile(os.path.join(d, base))]
    if len(hits) == 1:
        return {"status": "OK", "path": hits[0], "scope": r["scope"]}
    if len(hits) > 1:
        return {"status": "AMBIGUOUS", "candidates": hits, "scope": r["scope"]}
    return {"status": "NOT_FOUND", "reason": f"not in {len(r['dirs'])} root(s) of prefix '{r['prefix']}'"}


def audit():
    if not os.path.exists(DB):
        sys.exit(f"{DB} not found")
    c = sqlite3.connect(DB)
    rows = [r[0] for r in c.execute("SELECT source_id FROM sources")]
    tally = {"OK": [], "AMBIGUOUS": [], "GHOST": [], "NOT_FOUND": []}
    for sid in rows:
        tally[resolve(sid)["status"]].append(sid)
    total = len(rows)
    print(json.dumps({
        "scope": SCOPE, "total_sources": total,
        "resolvable_OK": len(tally["OK"]),
        "pct_editable": round(100 * len(tally["OK"]) / total, 1) if total else 0,
        "AMBIGUOUS": len(tally["AMBIGUOUS"]),
        "GHOST": len(tally["GHOST"]),
        "NOT_FOUND": len(tally["NOT_FOUND"]),
    }, ensure_ascii=False, indent=1))
    for st in ("AMBIGUOUS", "GHOST", "NOT_FOUND"):
        if tally[st]:
            print(f"  {st}: {tally[st][:12]}{' …' if len(tally[st])>12 else ''}")


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "audit"
    if cmd == "show":
        print(json.dumps({"scope_active": SCOPE, "CLAUDECORE_PATH": CC,
                          "roots": [{**r} for r in roots()]}, ensure_ascii=False, indent=1))
    elif cmd == "resolve":
        print(json.dumps(resolve(sys.argv[2]), ensure_ascii=False))
    elif cmd == "audit":
        audit()
    else:
        sys.exit(f"unknown cmd {cmd}")


if __name__ == "__main__":
    main()

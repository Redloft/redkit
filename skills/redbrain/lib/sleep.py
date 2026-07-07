#!/usr/bin/env python3
"""redbrain sleep — «Сон» графа памяти. M1a: TRIAGE (read-only, без LLM).

Детерминированный диагност: гоняет дешёвые SQL/строковые эвристики по графу и
собирает «список подозреваемых» — кандидатов на консолидацию. НИЧЕГО не пишет.
Платная адъюдикация (consolidate) и правка файлов (sleep_apply) — отдельные фазы.

Scope как в graphdb.py/query.py: REDBRAIN_SCOPE=work(default)|private → work/private.db.

Детекторы M1a (только те, что НЕ требуют резолва source_id→файл; stale-fact и
index-drift ждут scan-манифеста F1, помечены как deferred):
  1 ephemeral-leak    — inbox/*, hex-имена, event-подобные источники в постоянном графе
  2 near-dup-node     — узлы одного типа с близкими именами (difflib) → ALIAS/MERGE
  3 func-contradiction— ТОЛЬКО функц. (одно-значные) отношения: 1 src → >1 dst → SUPERSEDE
  4 doc-overlap       — пары source_doc с высоким Jaccard соседств → MERGE файлов
  5 reverted-orphan   — sources.status='reverted' без ре-ingest
  6 orphan-node       — узлы без рёбер

Usage: sleep.py triage [--json] [--min-sim 0.86] [--min-jaccard 0.5] [--limit 40]
Exit: 0 всегда (диагност). severity=high печатается в stderr как «побудка».
"""
import sys, os, re, json, sqlite3
from difflib import SequenceMatcher

SCOPE = os.environ.get("REDBRAIN_SCOPE", "work")
if SCOPE not in ("work", "private"):
    sys.exit(f"invalid REDBRAIN_SCOPE={SCOPE} (work|private)")
_DIR = os.path.expanduser(os.environ.get("REDBRAIN_DB_DIR",
                          "~/Library/Application Support/graph-memory"))
DB = os.path.join(_DIR, f"{SCOPE}.db")

# Функциональные (одно-значные на субъекта) отношения: >1 distinct dst = вероятное
# противоречие/устаревание. НЕ включать многозначные (uses/contains/links_to/prefers/
# practices/sport/core_value/health_flag/related_to/integrates_with) — они шумят
# (проверено: «termoport uses 10», «игорь prefers 9» — норма, не противоречие).
FUNCTIONAL_RELS = {
    "deployed_on", "hosted_on", "has_type", "replaces", "owned_by", "born_in",
    "former_spouse", "located_in", "runs_on", "primary_domain", "current_status",
}
HEX_RE = re.compile(r"^[0-9a-f]{12,}$")
EPHEMERAL_PREFIXES = ("inbox/",)


def connect():
    if not os.path.exists(DB):
        sys.exit(f"{DB} not found — run bootstrap first")
    c = sqlite3.connect(DB)
    c.row_factory = sqlite3.Row
    return c


def d_ephemeral_leak(c):
    """Эфемерные источники (голосовые захваты и т.п.) в ПОСТОЯННОМ графе — нарушение
    write-policy. Ghost = рёбра есть, но источник помечает транзиентный namespace."""
    rows = c.execute("SELECT source_id, status FROM sources").fetchall()
    hits = []
    for r in rows:
        sid = r["source_id"]
        base = sid.split("/", 1)[1] if "/" in sid else sid
        base = base.removesuffix(".md")
        if sid.startswith(EPHEMERAL_PREFIXES) or HEX_RE.match(base):
            ne = c.execute("SELECT COUNT(*) FROM edges WHERE source_doc=?", (sid,)).fetchone()[0]
            hits.append({"source_id": sid, "edges": ne, "hint": "ARCHIVE + чинить фильтр моста"})
    sev = "high" if len(hits) >= 5 else ("warn" if hits else "ok")
    return {"detector": "ephemeral-leak", "severity": sev, "count": len(hits), "items": hits}


def d_near_dup_node(c, min_sim):
    """Похожие имена внутри одного типа (опечатки / несведённые варианты / ru↔en без
    алиаса). Сравнение только within-type (режет O(n²))."""
    by_type = {}
    for r in c.execute("SELECT id, type, name FROM nodes"):
        by_type.setdefault(r["type"], []).append((r["id"], r["name"]))
    pairs = []
    aliased = {row[0] for row in c.execute("SELECT node_id FROM aliases")}
    for typ, items in by_type.items():
        for i in range(len(items)):
            for j in range(i + 1, len(items)):
                n1, n2 = items[i][1], items[j][1]
                if abs(len(n1) - len(n2)) > 6:
                    continue
                sim = SequenceMatcher(None, n1, n2).ratio()
                if sim >= min_sim and n1 != n2:
                    pairs.append({"type": typ, "a": n1, "b": n2, "sim": round(sim, 2),
                                  "a_aliased": items[i][0] in aliased,
                                  "hint": "ALIAS если ru↔en/опечатка, иначе MERGE"})
    pairs.sort(key=lambda p: -p["sim"])
    return {"detector": "near-dup-node", "severity": "warn" if pairs else "ok",
            "count": len(pairs), "items": pairs}


def _dismissed_pairs():
    """(src,relation) пары, помеченные NOOP при адъюдикации → триаж их не флажит
    (система учится: что уже признано легитимным сосуществованием — не шум)."""
    path = os.path.join(os.path.dirname(DB), "sleep", "dismissed.jsonl")
    pairs = set()
    if os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            try:
                d = json.loads(line); pairs.add((d["src"], d["relation"]))
            except Exception:
                pass
    return pairs


def d_func_contradiction(c):
    """Функц. отношение с >1 distinct dst у одного субъекта = кандидат в противоречие/
    устаревание (напр. X deployed_on A И B — миграция?). Только whitelist отношений.
    Пропускает dismissed (NOOP-вердикты прошлых прогонов)."""
    hits = []
    dismissed = _dismissed_pairs()
    q = """SELECT n.name AS src, e.relation AS rel,
                  COUNT(DISTINCT e.dst_id) AS c,
                  GROUP_CONCAT(DISTINCT n2.name) AS dsts
           FROM edges e JOIN nodes n ON n.id=e.src_id JOIN nodes n2 ON n2.id=e.dst_id
           GROUP BY e.src_id, e.relation HAVING c > 1"""
    for r in c.execute(q):
        if r["rel"] in FUNCTIONAL_RELS and (r["src"], r["rel"]) not in dismissed:
            hits.append({"src": r["src"], "relation": r["rel"], "distinct_dst": r["c"],
                         "values": r["dsts"], "hint": "SUPERSEDE (свежесть детерминированно)"})
    return {"detector": "func-contradiction", "severity": "high" if hits else "ok",
            "count": len(hits), "items": hits}


def d_doc_overlap(c, min_jaccard):
    """Пары документов с сильно пересекающимися соседствами узлов → возможно об одном
    и том же, кандидат на MERGE файлов."""
    doc_nodes = {}
    for r in c.execute("""SELECT source_doc AS d, src_id AS s, dst_id AS t FROM edges"""):
        doc_nodes.setdefault(r["d"], set()).update((r["s"], r["t"]))
    docs = [(d, ns) for d, ns in doc_nodes.items() if len(ns) >= 3]
    pairs = []
    for i in range(len(docs)):
        for j in range(i + 1, len(docs)):
            a, na = docs[i]; b, nb = docs[j]
            inter = len(na & nb)
            if not inter:
                continue
            jac = inter / len(na | nb)
            if jac >= min_jaccard:
                pairs.append({"a": a, "b": b, "shared": inter, "jaccard": round(jac, 2),
                              "hint": "MERGE файлов (проверить дубль)"})
    pairs.sort(key=lambda p: -p["jaccard"])
    return {"detector": "doc-overlap", "severity": "warn" if pairs else "ok",
            "count": len(pairs), "items": pairs}


def d_reverted_orphan(c):
    rows = [dict(source_id=r["source_id"]) for r in
            c.execute("SELECT source_id FROM sources WHERE status='reverted'")]
    return {"detector": "reverted-orphan", "severity": "warn" if rows else "ok",
            "count": len(rows), "items": rows}


def d_orphan_node(c):
    n = c.execute("""SELECT COUNT(*) FROM nodes WHERE id NOT IN
                     (SELECT src_id FROM edges UNION SELECT dst_id FROM edges)""").fetchone()[0]
    return {"detector": "orphan-node", "severity": "warn" if n else "ok", "count": n, "items": []}


def triage(argv):
    min_sim = float(argv[argv.index("--min-sim") + 1]) if "--min-sim" in argv else 0.86
    min_jac = float(argv[argv.index("--min-jaccard") + 1]) if "--min-jaccard" in argv else 0.5
    limit = int(argv[argv.index("--limit") + 1]) if "--limit" in argv else 40
    c = connect()
    results = [
        d_ephemeral_leak(c),
        d_func_contradiction(c),
        d_near_dup_node(c, min_sim),
        d_doc_overlap(c, min_jac),
        d_reverted_orphan(c),
        d_orphan_node(c),
    ]
    for r in results:  # кап вывода
        r["items"] = r["items"][:limit]
    high = [r["detector"] for r in results if r["severity"] == "high" and r["count"]]
    report = {"scope": SCOPE, "db": DB, "high_severity": high,
              "deferred": ["stale-fact", "index-drift"],  # ждут scan-манифеста F1
              "detectors": results}

    if "--json" in argv:
        print(json.dumps(report, ensure_ascii=False, indent=1))
    else:
        print(f"🌙 triage · scope={SCOPE}")
        for r in results:
            mark = {"high": "🔴", "warn": "🟡", "ok": "🟢"}[r["severity"]]
            print(f"  {mark} {r['detector']}: {r['count']}")
            for it in r["items"][:8]:
                print(f"       {json.dumps(it, ensure_ascii=False)}")
        if high:
            print(f"\n⚠️  HIGH severity: {', '.join(high)} — ночью это будит.", file=sys.stderr)
        print(f"  (deferred до scan-манифеста F1: stale-fact, index-drift)")
    return 0


def full(argv):
    """Недельный полный сон. Пока = триаж; consolidate(M2 Haiku) + dream(M4 REM)
    — в разработке. Notice в stderr, чтобы stdout оставался чистым JSON при --json."""
    rc = triage(argv)
    print("▸ full: consolidate (M2 Haiku) + dream (M4 REM) ещё не построены — pending",
          file=sys.stderr)
    return rc


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "triage"
    if cmd == "triage":
        sys.exit(triage(sys.argv[2:]))
    elif cmd == "full":
        sys.exit(full(sys.argv[2:]))
    sys.exit(f"unknown cmd {cmd} (есть: triage | full)")


if __name__ == "__main__":
    main()

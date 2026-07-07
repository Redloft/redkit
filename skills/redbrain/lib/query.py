#!/usr/bin/env python3
"""redbrain query — retrieval поверх графа. Бесплатный SQLite, без LLM.

Phase 1 = плоский lookup-by-entity + recursive CTE до глубины N.
Personalized PageRank НЕ реализуем, пока golden-запросы не покажут
недостаточный recall (решение панели: premature abstraction).

Commands:
  search <substr>              — найти узлы по подстроке имени (или алиасу)
  entity <name>                — прямые связи узла (in+out), source_doc у каждого ребра
  context <name> [--depth 2]   — окрестность через recursive CTE (default depth 2)
  docs <name>                  — какие документы упоминают сущность
  asof <ISO-дата> [name]       — что было истинно на дату (интервальные факты);
                                 без name — только «презентные» relation из allowlist
Флаги (entity/context/docs/asof): --include-candidates — показать и кандидатов;
  --asof <ISO> — темпоральный срез любого чтения.
Дефолт БЕЗ флагов = как до v3: только status='confirmed' (кандидаты/инвалидированные/
истёкшие не видны — контракт S3, поведение старых сценариев байт-в-байт).
Output: компактный JSON — построчно, готов к чтению агентом.
"""
import sys, json, sqlite3, os

# scope как в graphdb.py: work (default) | private — два физических файла,
# личный ассистент может опросить оба (два вызова с разным REDBRAIN_SCOPE),
# рабочий контур private не видит вовсе
SCOPE = os.environ.get("REDBRAIN_SCOPE", "work")
if SCOPE not in ("work", "private"):
    sys.exit(f"invalid REDBRAIN_SCOPE={SCOPE} (work|private)")
_DIR = os.path.expanduser(os.environ.get("REDBRAIN_DB_DIR",
                          "~/Library/Application Support/graph-memory"))
DB = os.path.join(_DIR, f"{SCOPE}.db")

def norm(s): return " ".join(s.lower().strip().split())

def _iso(s):
    from datetime import datetime
    try:
        datetime.fromisoformat(str(s).replace("Z", "+00:00")); return str(s)
    except ValueError:
        sys.exit(f"not an ISO-8601 date: {s}")

INC_CAND = "--include-candidates" in sys.argv
ASOF = _iso(sys.argv[sys.argv.index("--asof") + 1]) if "--asof" in sys.argv else None

def efilter(alias="e"):
    """Темпоральный фильтр чтения (S3). Fail-open на до-v3 базе: нет колонки
    status → пустой фильтр (поведение как раньше)."""
    if not _HAS_TEMPORAL:
        return ""
    sts = "('confirmed','candidate')" if INC_CAND else "('confirmed')"
    f = f" AND {alias}.status IN {sts}"
    if ASOF:
        # closed-open: valid_at <= D < invalid_at (NULL = открытый интервал)
        f += (f" AND {alias}.valid_at <= '{ASOF}'"
              f" AND ({alias}.invalid_at IS NULL OR '{ASOF}' < {alias}.invalid_at)")
    return f

_HAS_TEMPORAL = False

def connect():
    global _HAS_TEMPORAL
    if not os.path.exists(DB):
        sys.exit("graph.db not found — run bootstrap first (scan.py + extraction)")
    c = sqlite3.connect(DB)
    _HAS_TEMPORAL = any(r[1] == "status" for r in c.execute("PRAGMA table_info(edges)"))
    return c

def resolve(c, name):
    """→ (canonical_name, [node_ids]). Один name может жить в нескольких типах
    (redcontrol как memory-doc И как project) — объединяем все, иначе связи
    фрагментируются по типу."""
    n = norm(name)
    rows = c.execute("SELECT id,name FROM nodes WHERE name=?", (n,)).fetchall()
    if rows: return rows[0][1], [r[0] for r in rows]
    al = c.execute("SELECT node_id FROM aliases WHERE alias=?", (n,)).fetchone()
    if al:
        hit = c.execute("SELECT name FROM nodes WHERE id=?", (al[0],)).fetchone()
        if hit:  # stale-алиас (узел удалён gc) → падаем в LIKE, не в exception
            rows = c.execute("SELECT id FROM nodes WHERE name=?", (hit[0],)).fetchall()
            return hit[0], [r[0] for r in rows]
    like = c.execute("SELECT DISTINCT name FROM nodes WHERE name LIKE ? LIMIT 5", (f"%{n}%",)).fetchall()
    if len(like) == 1:
        canon = like[0][0]
        rows = c.execute("SELECT id FROM nodes WHERE name=?", (canon,)).fetchall()
        return canon, [r[0] for r in rows]
    if like:
        print(json.dumps({"ambiguous": [r[0] for r in like]}, ensure_ascii=False)); sys.exit(0)
    return None, []

def edges_of(c, nids):
    ph = ",".join("?" * len(nids))
    return c.execute(f"""
      SELECT DISTINCT n1.name, e.relation, n2.name, e.source_doc, e.weight FROM edges e
      JOIN nodes n1 ON n1.id=e.src_id JOIN nodes n2 ON n2.id=e.dst_id
      WHERE (e.src_id IN ({ph}) OR e.dst_id IN ({ph})){efilter()} ORDER BY e.weight DESC""",
      nids + nids).fetchall()

def presence_relations():
    p = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "golden", "relations-allow.txt")
    try:
        return sorted(ln.strip() for ln in open(p, encoding="utf-8")
                      if ln.strip() and not ln.startswith("#"))
    except OSError:
        return []

def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "search"
    c = connect()
    if cmd == "search":
        t = f"%{norm(sys.argv[2])}%"
        # union с алиасами — паритет с entity/docs (кириллица находит латиницу)
        for r in c.execute("""
            SELECT DISTINCT name, type FROM (
              SELECT n.name, n.type FROM nodes n WHERE n.name LIKE ?
              UNION
              SELECT n.name, n.type FROM aliases a
                JOIN nodes n ON n.id = a.node_id WHERE a.alias LIKE ?)
            ORDER BY name LIMIT 25""", (t, t)):
            print(json.dumps({"name": r[0], "type": r[1]}, ensure_ascii=False))
    elif cmd in ("entity", "docs"):
        canon, nids = resolve(c, sys.argv[2])
        if not nids: sys.exit(f"not found: {sys.argv[2]}")
        if cmd == "docs":
            ph = ",".join("?" * len(nids))
            for (d,) in c.execute(f"""SELECT DISTINCT source_doc FROM edges e
                                      WHERE (src_id IN ({ph}) OR dst_id IN ({ph})){efilter()}""",
                                  nids + nids):
                print(d)
        else:
            print(json.dumps({"entity": canon, "node_count": len(nids)}, ensure_ascii=False))
            for s, rel, d, doc, w in edges_of(c, nids):
                print(json.dumps({"src": s, "rel": rel, "dst": d, "doc": doc}, ensure_ascii=False))
    elif cmd == "context":
        canon, nids = resolve(c, sys.argv[2])
        if not nids: sys.exit(f"not found: {sys.argv[2]}")
        depth = int(sys.argv[sys.argv.index("--depth") + 1]) if "--depth" in sys.argv else 2
        ph = ",".join("?" * len(nids))
        rows = c.execute(f"""
          WITH RECURSIVE hood(id, d) AS (
            SELECT id, 0 FROM nodes WHERE id IN ({ph})
            UNION
            SELECT CASE WHEN e.src_id=h.id THEN e.dst_id ELSE e.src_id END, h.d+1
            FROM edges e JOIN hood h ON h.id IN (e.src_id, e.dst_id)
            WHERE h.d < ?{efilter()})
          SELECT DISTINCT n1.name, e.relation, n2.name, e.source_doc, MIN(h.d)
          FROM hood h JOIN edges e ON h.id IN (e.src_id, e.dst_id)
          JOIN nodes n1 ON n1.id=e.src_id JOIN nodes n2 ON n2.id=e.dst_id
          WHERE 1=1{efilter()}
          GROUP BY e.id ORDER BY MIN(h.d), e.relation""", nids + [depth]).fetchall()
        print(json.dumps({"entity": canon, "depth": depth, "edges": len(rows)}, ensure_ascii=False))
        for s, rel, d, doc, dd in rows:
            print(json.dumps({"hop": dd, "src": s, "rel": rel, "dst": d, "doc": doc}, ensure_ascii=False))
    elif cmd == "asof":
        # «что было истинно на дату D»: срез интервальных фактов. Без entity —
        # только «презентные» relation (allowlist), иначе backfill-рёбра (valid_at=
        # created_at, NULL invalid_at) зальют выдачу всем графом.
        global ASOF
        ASOF = _iso(sys.argv[2])
        limit = int(sys.argv[sys.argv.index("--limit") + 1]) if "--limit" in sys.argv else 50
        ent, rest, i = None, sys.argv[3:], 0
        while i < len(rest):
            if rest[i] in ("--limit", "--asof"): i += 2; continue
            if rest[i].startswith("--"): i += 1; continue
            ent = rest[i]; break
        if ent:
            canon, nids = resolve(c, ent)
            if not nids: sys.exit(f"not found: {ent}")   # not-found ≠ пустой срез
            rows = edges_of(c, nids)[:limit]
            print(json.dumps({"asof": ASOF, "entity": canon, "facts": len(rows)}, ensure_ascii=False))
        else:
            pres = presence_relations()
            if not pres: sys.exit("relations-allow.txt пуст/недоступен — нечем фильтровать презентный срез")
            ph = ",".join("?" * len(pres))
            rows = c.execute(f"""
              SELECT DISTINCT n1.name, e.relation, n2.name, e.source_doc, e.weight FROM edges e
              JOIN nodes n1 ON n1.id=e.src_id JOIN nodes n2 ON n2.id=e.dst_id
              WHERE e.relation IN ({ph}){efilter()} ORDER BY e.valid_at DESC LIMIT ?""",
              pres + [limit]).fetchall()
            print(json.dumps({"asof": ASOF, "entity": None, "facts": len(rows)}, ensure_ascii=False))
        for s, rel, d, doc, _w in rows:
            print(json.dumps({"src": s, "rel": rel, "dst": d, "doc": doc}, ensure_ascii=False))
    else:
        sys.exit(f"unknown cmd {cmd}")

if __name__ == "__main__":
    main()

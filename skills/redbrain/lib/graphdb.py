#!/usr/bin/env python3
"""redbrain graph store — SQLite, WAL, idempotent ingest.

Хранилище НЕ на Yandex.Disk (правило C1): облачный sync конфликтует с
WAL-записью (гонка/конфликтные копии). Граф — производный индекс; истина
остаётся в memory/*.md, потеря graph.db лечится ре-bootstrap'ом.

Commands:
  init                          — create schema (idempotent)
  insert                        — stdin JSON {source_id, content_hash, run_id, triples:[...]}
                                  tombstone: старые DOC-рёбра этого source_id удаляются перед append
                                  (episode-рёбра tombstone НЕ трогает — живут по lineage, контракт v2)
  insert-episode                — stdin JSON {episode:{ts,channel,content}, run_id, triples:[...]}
                                  hot path Слоя 2: PII-скраб → episodes + candidate-рёбра + lineage,
                                  одна транзакция; идемпотентно (повтор payload = нулевой дифф)
  invalidate <edge_id> <iso>    — темпоральная инвалидация episode-ребра (не DELETE); doc-рёбра refuse
  mark-source <id> <hash> <st>  — upsert sources row without triples (e.g. skipped/failed)
  check <source_id> <hash>      — exit 0 + "skip" если hash уже ingested ok, иначе "pending"
  revert <run_id>               — удалить DOC-рёбра прогона + осиротевшие узлы
  status                        — counts + last ingests
  export                        — nodes+edges JSONL в stdout (reversibility при смене backend)
Doc triple:     {"src", "src_type", "relation", "dst", "dst_type", "weight"}
Episode triple: + {"valid_at"?, "invalid_at"?, "attribution": user_statement|model_inference}
"""
import sys, json, sqlite3, hashlib, os
from contextlib import contextmanager
from datetime import datetime, timezone

# Два мозга = два физических файла. Граница на уровне ФС, не гарда в промпте:
# будущая рабочая LLM просто не получает путь к private.db (fail-closed).
# ЧТЕНИЕ (status/check/export/search) — default work: запросы без трения.
# ЗАПИСЬ (insert/mark-source/revert/alias) — REDBRAIN_SCOPE ОБЯЗАТЕЛЕН явно:
# забытый env не должен молча уронить приватные данные в разделяемый work.db
# (fail-open именно в опасную сторону — finding панели finalize-02).
DB_DIR = os.path.expanduser(os.environ.get("REDBRAIN_DB_DIR",
                            "~/Library/Application Support/graph-memory"))
SCOPE_EXPLICIT = "REDBRAIN_SCOPE" in os.environ
SCOPE = os.environ.get("REDBRAIN_SCOPE", "work")
if SCOPE not in ("work", "private"):
    sys.exit(f"invalid REDBRAIN_SCOPE={SCOPE} (work|private)")
DB = os.path.join(DB_DIR, f"{SCOPE}.db")
WRITE_CMDS = {"insert", "insert-episode", "invalidate", "mark-source", "revert", "alias", "rekey"}

DDL = """
CREATE TABLE IF NOT EXISTS sources (
  source_id      TEXT PRIMARY KEY,
  content_hash   TEXT NOT NULL,
  last_ingest_at TEXT NOT NULL,
  status         TEXT NOT NULL CHECK (status IN ('ok','failed','skipped','reverted'))
);
CREATE TABLE IF NOT EXISTS nodes (
  id TEXT PRIMARY KEY, type TEXT NOT NULL, name TEXT NOT NULL,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS edges (
  id TEXT PRIMARY KEY,
  src_id TEXT NOT NULL REFERENCES nodes(id),
  dst_id TEXT NOT NULL REFERENCES nodes(id),
  relation TEXT NOT NULL, weight REAL DEFAULT 1.0,
  source_doc TEXT NOT NULL REFERENCES sources(source_id),
  run_id TEXT NOT NULL, created_at TEXT NOT NULL,
  valid_at    TEXT,   -- event time: факт истинен с (closed-open: valid_at <= t < invalid_at)
  invalid_at  TEXT,   -- event time: NULL = истинен сейчас
  expired_at  TEXT,   -- ingestion time: когда система аннулировала ребро
  status      TEXT NOT NULL DEFAULT 'confirmed'
              CHECK (status IN ('candidate','confirmed','expired','invalidated')),
  attribution TEXT NOT NULL DEFAULT 'doc'
              CHECK (attribution IN ('doc','user_statement','model_inference'))
);
CREATE TABLE IF NOT EXISTS aliases (
  alias TEXT PRIMARY KEY, node_id TEXT NOT NULL REFERENCES nodes(id)
);
CREATE INDEX IF NOT EXISTS idx_edges_src ON edges(src_id);
CREATE INDEX IF NOT EXISTS idx_edges_dst ON edges(dst_id);
CREATE INDEX IF NOT EXISTS idx_edges_doc ON edges(source_doc);
CREATE INDEX IF NOT EXISTS idx_nodes_name ON nodes(name);
"""

# v3-объекты отдельным скриптом: индексы по темпоральным колонкам нельзя класть
# в основной DDL — на v2-базе он выполняется ДО ALTER'ов и упал бы на missing
# column. Выполняется в init() ПОСЛЕ миграции (idempotent).
DDL_V3 = """
CREATE TABLE IF NOT EXISTS episodes (
  id TEXT PRIMARY KEY,             -- hash(channel|ts|content до скраба)
  ts TEXT NOT NULL,                -- event time эпизода
  channel TEXT NOT NULL,           -- plaud | chat | telegram | calendar | doc
  content TEXT NOT NULL,           -- ПОСЛЕ PII-скраба
  redacted INTEGER NOT NULL DEFAULT 0,
  ingested_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS edge_episodes (
  edge_id TEXT NOT NULL REFERENCES edges(id),
  episode_id TEXT NOT NULL REFERENCES episodes(id),
  PRIMARY KEY (edge_id, episode_id)
);
CREATE INDEX IF NOT EXISTS idx_episodes_ts ON episodes(ts);
CREATE INDEX IF NOT EXISTS idx_edges_temporal ON edges(src_id, relation, valid_at);
CREATE INDEX IF NOT EXISTS idx_edges_status ON edges(status);
"""

def now(): return datetime.now(timezone.utc).isoformat(timespec="seconds")
def norm(name): return " ".join(name.lower().strip().split())
def node_id(name, typ): return hashlib.sha256(f"{typ}|{norm(name)}".encode()).hexdigest()[:16]

def connect():
    os.makedirs(DB_DIR, exist_ok=True)
    # autocommit + явные tx(): неявный BEGIN DEFERRED питона апгрейдит shared→write
    # лок посреди операции (TOCTOU-окно между guard-чтением и tombstone-DELETE,
    # finding панели rank 2). BEGIN IMMEDIATE берёт write-лок сразу.
    c = sqlite3.connect(DB, isolation_level=None)
    c.execute("PRAGMA journal_mode=WAL")
    c.execute("PRAGMA foreign_keys=ON")
    c.execute("PRAGMA busy_timeout=3000")
    return c

@contextmanager
def tx(c):
    c.execute("BEGIN IMMEDIATE")
    try:
        yield
        c.execute("COMMIT")
    except BaseException:
        c.execute("ROLLBACK")
        raise

def init(c):
    c.executescript(DDL)
    # v1→v2: CHECK на sources не знал 'reverted' — SQLite не умеет ALTER CHECK,
    # пересобираем таблицу один раз (данные сохраняются)
    if c.execute("PRAGMA user_version").fetchone()[0] < 2:
        sql = c.execute("SELECT sql FROM sqlite_master WHERE name='sources'").fetchone()
        if sql and "'reverted'" not in sql[0]:
            # FK off + legacy_alter_table on: без legacy RENAME молча переписывает
            # REFERENCES в edges на sources_v1, и после DROP edges ссылается в
            # никуда (все инсерты падают FK). Оба PRAGMA обязательны.
            c.execute("PRAGMA foreign_keys=OFF")
            c.execute("PRAGMA legacy_alter_table=ON")
            c.executescript("""
              ALTER TABLE sources RENAME TO sources_v1;
              CREATE TABLE sources (
                source_id TEXT PRIMARY KEY, content_hash TEXT NOT NULL,
                last_ingest_at TEXT NOT NULL,
                status TEXT NOT NULL CHECK (status IN ('ok','failed','skipped','reverted')));
              INSERT INTO sources SELECT * FROM sources_v1;
              DROP TABLE sources_v1;""")
            c.execute("PRAGMA legacy_alter_table=OFF")
            c.execute("PRAGMA foreign_keys=ON")
        c.execute("PRAGMA user_version=2")
    # v2→v3: би-темпоральные колонки edges (roadmap/DESIGN-temporal-layers-v2.md).
    # Существующие рёбра = confirmed/doc, valid_at бэкфиллится из created_at —
    # поведение query/recall без темпоральных флагов не меняется.
    if c.execute("PRAGMA user_version").fetchone()[0] < 3:
        cols = {r[1] for r in c.execute("PRAGMA table_info(edges)")}
        if "valid_at" not in cols:
            c.executescript("""
              BEGIN IMMEDIATE;
              ALTER TABLE edges ADD COLUMN valid_at TEXT;
              ALTER TABLE edges ADD COLUMN invalid_at TEXT;
              ALTER TABLE edges ADD COLUMN expired_at TEXT;
              ALTER TABLE edges ADD COLUMN status TEXT NOT NULL DEFAULT 'confirmed'
                CHECK (status IN ('candidate','confirmed','expired','invalidated'));
              ALTER TABLE edges ADD COLUMN attribution TEXT NOT NULL DEFAULT 'doc'
                CHECK (attribution IN ('doc','user_statement','model_inference'));
              UPDATE edges SET valid_at = created_at WHERE valid_at IS NULL;
              COMMIT;""")
        c.execute("PRAGMA user_version=3")
    c.executescript(DDL_V3)
    c.commit()

def upsert_node(c, name, typ, ts):
    nid = node_id(name, typ)
    c.execute("""INSERT INTO nodes(id,type,name,created_at,updated_at) VALUES(?,?,?,?,?)
                 ON CONFLICT(id) DO UPDATE SET updated_at=excluded.updated_at""",
              (nid, typ, norm(name), ts, ts))
    return nid

def insert(c, payload):
    ts = now()
    sid, chash, run = payload["source_id"], payload["content_hash"], payload["run_id"]
    with tx(c):
        # guard: пустой triples при существующих DOC-рёбрах = вероятный сбой extraction
        # выше по конвейеру (агент упал/вернул мусор) — молчаливый tombstone потерял
        # бы все рёбра документа. Явный override: payload.allow_empty=true.
        if not payload.get("triples") and not payload.get("allow_empty"):
            existing = c.execute("SELECT COUNT(*) FROM edges WHERE source_doc=? AND attribution='doc'",
                                 (sid,)).fetchone()[0]
            if existing:
                sys.exit(f"refusing empty-triples insert for {sid}: {existing} edges exist "
                         f"(extraction failure upstream?); pass allow_empty:true to override")
        # tombstone: изменённый документ полностью переопределяет СВОИ doc-рёбра.
        # Контракт v2 (panel rank 1): episode-рождённые рёбра (attribution != 'doc')
        # tombstone НЕ трогает — они живут по episode-lineage и умирают только
        # инвалидацией. Инвариант «один док = один insert» действует в границах doc-слоя.
        c.execute("DELETE FROM edges WHERE source_doc=? AND attribution='doc'", (sid,))
        c.execute("""INSERT INTO sources(source_id,content_hash,last_ingest_at,status)
                     VALUES(?,?,?,'ok') ON CONFLICT(source_id) DO UPDATE SET
                     content_hash=excluded.content_hash,last_ingest_at=excluded.last_ingest_at,status='ok'""",
                  (sid, chash, ts))
        n = 0
        for t in payload.get("triples", []):
            if not (t.get("src") and t.get("dst") and t.get("relation")): continue
            s = upsert_node(c, t["src"], t.get("src_type", "entity"), ts)
            d = upsert_node(c, t["dst"], t.get("dst_type", "entity"), ts)
            eid = hashlib.sha256(f"{s}|{t['relation']}|{d}|{sid}".encode()).hexdigest()[:16]
            c.execute("""INSERT OR REPLACE INTO edges(id,src_id,dst_id,relation,weight,source_doc,run_id,created_at,
                         valid_at,status,attribution)
                         VALUES(?,?,?,?,?,?,?,?,?,'confirmed','doc')""",
                      (eid, s, d, t["relation"], t.get("weight", 1.0), sid, run, ts, ts))
            n += 1
    return n


def iso_or_none(s):
    if not s: return None
    try:
        datetime.fromisoformat(str(s).replace("Z", "+00:00"))
        return str(s)
    except ValueError:
        return None


def allowed_relations(c):
    # gate качества экстракции (panel rank 10): relation — закрытый словарь
    # (существующие в графе + явный allowlist), не свободный текст Haiku.
    allow = {r[0] for r in c.execute("SELECT DISTINCT relation FROM edges")}
    f = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "golden", "relations-allow.txt")
    if os.path.exists(f):
        with open(f, encoding="utf-8") as fh:
            allow |= {ln.strip() for ln in fh if ln.strip() and not ln.startswith("#")}
    return allow


def insert_episode(c, payload):
    """Hot path Слоя 2: эпизод + candidate-рёбра + lineage, одна транзакция.

    Идемпотентно: episode id и edge id детерминированы → повторный payload = нулевой
    дифф; НОВЫЙ эпизод с той же тройкой = +1 строка lineage (корроборация), не дубль.
    Кандидаты не видны recall'у (фильтр status='confirmed' на чтении).
    """
    from pii import scrub
    ep, run = payload["episode"], payload["run_id"]
    if ep["channel"] not in ("plaud", "chat", "telegram", "calendar", "doc"):
        sys.exit(f"unknown episode channel: {ep['channel']}")
    ep_ts = iso_or_none(ep["ts"]) or sys.exit(f"episode.ts not ISO-8601: {ep['ts']}")
    eid = hashlib.sha256(f"{ep['channel']}|{ep_ts}|{ep['content']}".encode()).hexdigest()[:16]
    content, redacted = scrub(ep["content"])
    src_doc = f"episode:{eid}"
    ts = now()
    inserted, corroborated, rejected = [], [], []
    with tx(c):
        allow = allowed_relations(c)
        c.execute("""INSERT OR IGNORE INTO episodes(id,ts,channel,content,redacted,ingested_at)
                     VALUES(?,?,?,?,?,?)""", (eid, ep_ts, ep["channel"], content, int(redacted), ts))
        c.execute("""INSERT INTO sources(source_id,content_hash,last_ingest_at,status)
                     VALUES(?,?,?,'ok') ON CONFLICT(source_id) DO UPDATE SET last_ingest_at=excluded.last_ingest_at""",
                  (src_doc, eid, ts))
        for t in payload.get("triples", []):
            if not (t.get("src") and t.get("dst") and t.get("relation")):
                rejected.append({"triple": t, "reason": "missing src/dst/relation"}); continue
            attr = t.get("attribution", "model_inference")
            if attr not in ("user_statement", "model_inference"):
                rejected.append({"triple": t, "reason": f"bad attribution {attr}"}); continue
            if t["relation"] not in allow:
                rejected.append({"triple": t, "reason": f"relation not in dictionary: {t['relation']}"}); continue
            # valid_at: ISO-или-fallback на время эпизода (мусорная дата не пишется);
            # invalid_at: ISO-или-None (открытый интервал)
            valid_at = iso_or_none(t.get("valid_at")) or ep_ts
            invalid_at = iso_or_none(t.get("invalid_at"))
            s = upsert_node(c, t["src"], t.get("src_type", "entity"), ts)
            d = upsert_node(c, t["dst"], t.get("dst_type", "entity"), ts)
            if invalid_at and invalid_at <= valid_at:
                rejected.append({"triple": t, "reason": "invalid_at <= valid_at"}); continue
            # id БЕЗ source_doc: та же тройка+интервал из другого эпизода мапится в то же
            # ребро → INSERT OR IGNORE + lineage-строка = корроборация без дублей
            edge_id = hashlib.sha256(f"{s}|{t['relation']}|{d}|{valid_at}".encode()).hexdigest()[:16]
            cur = c.execute("""INSERT OR IGNORE INTO edges(id,src_id,dst_id,relation,weight,source_doc,run_id,
                               created_at,valid_at,invalid_at,status,attribution)
                               VALUES(?,?,?,?,?,?,?,?,?,?,'candidate',?)""",
                            (edge_id, s, d, t["relation"], t.get("weight", 1.0), src_doc, run,
                             ts, valid_at, invalid_at, attr))
            c.execute("INSERT OR IGNORE INTO edge_episodes(edge_id,episode_id) VALUES(?,?)", (edge_id, eid))
            n_ep = c.execute("SELECT COUNT(*) FROM edge_episodes WHERE edge_id=?", (edge_id,)).fetchone()[0]
            (inserted if cur.rowcount else corroborated).append({"edge": edge_id, "episodes": n_ep})
    return {"episode": eid, "redacted": redacted, "inserted": inserted,
            "corroborated": corroborated, "rejected": rejected}


def invalidate(c, edge_id, invalid_at):
    """Темпоральная инвалидация (контракт v2): никогда DELETE, только закрытие окна.
    Doc-рёбра — refuse: их жизненный цикл управляется tombstone'ом документа."""
    iv = iso_or_none(invalid_at) or sys.exit(f"invalid_at not ISO-8601: {invalid_at}")
    with tx(c):
        row = c.execute("SELECT attribution,status FROM edges WHERE id=?", (edge_id,)).fetchone()
        if not row: sys.exit(f"edge not found: {edge_id}")
        if row[0] == "doc": sys.exit(f"refuse: {edge_id} is doc-attributed (tombstone lifecycle, not invalidation)")
        c.execute("UPDATE edges SET invalid_at=?, expired_at=?, status='invalidated' WHERE id=?",
                  (iv, now(), edge_id))
    return {"invalidated": edge_id, "invalid_at": iv}

def gc_orphans(c):
    # порядок важен: сначала алиасы осиротевших узлов (FK aliases.node_id без
    # CASCADE — иначе DELETE nodes падает constraint'ом), потом сами узлы
    with tx(c):
        c.execute("""DELETE FROM aliases WHERE node_id IN
                     (SELECT id FROM nodes WHERE id NOT IN
                      (SELECT src_id FROM edges UNION SELECT dst_id FROM edges))""")
        c.execute("""DELETE FROM nodes WHERE id NOT IN
                     (SELECT src_id FROM edges UNION SELECT dst_id FROM edges)""")

def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    if cmd in WRITE_CMDS and not SCOPE_EXPLICIT:
        sys.exit(f"'{cmd}' is a write op — set REDBRAIN_SCOPE=work|private explicitly "
                 f"(no silent default: forgotten env must not leak private data into work.db)")
    c = connect(); init(c)
    if cmd == "init":
        print(f"ok {DB}")
    elif cmd == "insert":
        payload = json.load(sys.stdin)
        print(json.dumps({"inserted_edges": insert(c, payload), "source": payload["source_id"]}))
    elif cmd == "insert-episode":
        print(json.dumps(insert_episode(c, json.load(sys.stdin)), ensure_ascii=False))
    elif cmd == "invalidate":
        print(json.dumps(invalidate(c, sys.argv[2], sys.argv[3])))
    elif cmd == "mark-source":
        sid, chash, st = sys.argv[2], sys.argv[3], sys.argv[4]
        c.execute("""INSERT INTO sources VALUES(?,?,?,?) ON CONFLICT(source_id) DO UPDATE SET
                     content_hash=excluded.content_hash,last_ingest_at=excluded.last_ingest_at,status=excluded.status""",
                  (sid, chash, now(), st)); c.commit(); print("ok")
    elif cmd == "check":
        row = c.execute("SELECT content_hash,status FROM sources WHERE source_id=?", (sys.argv[2],)).fetchone()
        print("skip" if row and row[0] == sys.argv[3] and row[1] == "ok" else "pending")
    elif cmd == "alias":
        # alias <алиас> <канон-имя> [тип] — ru↔en мост: extraction канонизирует
        # в латиницу, кириллический запрос без алиаса не найдёт узел
        al, canon = norm(sys.argv[2]), norm(sys.argv[3])
        typ = sys.argv[4] if len(sys.argv) > 4 else None
        q = "SELECT id,name FROM nodes WHERE name=?" + (" AND type=?" if typ else "")
        row = c.execute(q, (canon, typ) if typ else (canon,)).fetchone()
        if not row:
            # ambiguity-guard, симметрично query.py resolve(): >1 distinct-имени
            # по LIKE → отказ с кандидатами, а не молчаливая привязка к первому.
            # typ-фильтр протаскивается и в fallback — явная подсказка вызывающего
            # не должна теряться на полпути (finding ops finalize-02)
            lq = "SELECT DISTINCT name FROM nodes WHERE name LIKE ?" + (" AND type=?" if typ else "") + " LIMIT 5"
            like = c.execute(lq, (f"%{canon}%", typ) if typ else (f"%{canon}%",)).fetchall()
            if len(like) > 1:
                sys.exit(f"ambiguous canon '{canon}': {[r[0] for r in like]} — уточни имя/тип")
            if like:
                rq = "SELECT id,name FROM nodes WHERE name=?" + (" AND type=?" if typ else "")
                row = c.execute(rq, (like[0][0], typ) if typ else (like[0][0],)).fetchone()
        if not row: sys.exit(f"canon node not found: {canon}")
        c.execute("INSERT OR REPLACE INTO aliases VALUES(?,?)", (al, row[0])); c.commit()
        print(f"alias {al} -> {row[1]}")
    elif cmd == "revert":
        run = sys.argv[2]
        # revert живёт в doc-слое (контракт v2): episode-рёбра не удаляются
        # (их держит FK lineage; жизненный цикл — invalidate/TTL, не revert)
        if "--dry-run" in sys.argv:
            ne = c.execute("SELECT COUNT(*) FROM edges WHERE run_id=? AND attribution='doc'", (run,)).fetchone()[0]
            docs = [r[0] for r in c.execute(
                "SELECT DISTINCT source_doc FROM edges WHERE run_id=? AND attribution='doc'", (run,))]
            print(json.dumps({"would_delete_edges": ne, "affected_docs": docs}, ensure_ascii=False))
            return
        with tx(c):
            # запоминаем затронутые документы ДО удаления
            docs = [r[0] for r in c.execute(
                "SELECT DISTINCT source_doc FROM edges WHERE run_id=? AND attribution='doc'", (run,))]
            c.execute("DELETE FROM edges WHERE run_id=? AND attribution='doc'", (run,))
            # sources-desync guard: сбросить status затронутых доков, иначе следующий
            # scan увидит совпадающий hash → skip → откаченные рёбра потеряны навсегда.
            # 'reverted', НЕ 'failed': janitor различает «ждёт ре-ingest после отката»
            # и «реально сломанная экстракция»
            for sid in docs:
                c.execute("UPDATE sources SET status='reverted' WHERE source_id=?", (sid,))
        gc_orphans(c)
        print(f"reverted {run}: {len(docs)} docs marked for re-ingest")
    elif cmd == "rekey":
        # rekey <old_sid> <new_sid> — миграция source_id при внедрении --prefix
        # на уже проиндексированной директории (rename, НЕ re-insert: без повторной
        # платной экстракции и без вечных дублей под двумя id)
        old_sid, new_sid = sys.argv[2], sys.argv[3]
        if c.execute("SELECT 1 FROM sources WHERE source_id=?", (new_sid,)).fetchone():
            sys.exit(f"target source_id already exists: {new_sid}")
        # rename родителя+детей атомарно; FK временно off (иначе любое из двух
        # промежуточных состояний нарушает constraint). PRAGMA — вне tx (внутри no-op).
        c.execute("PRAGMA foreign_keys=OFF")
        with tx(c):
            n = c.execute("UPDATE sources SET source_id=? WHERE source_id=?",
                          (new_sid, old_sid)).rowcount
            c.execute("UPDATE edges SET source_doc=? WHERE source_doc=?", (new_sid, old_sid))
        c.execute("PRAGMA foreign_keys=ON")
        print(f"rekeyed {old_sid} -> {new_sid}" if n else f"not found: {old_sid}")
    elif cmd == "status":
        q = lambda s: c.execute(s).fetchone()[0]
        print(json.dumps({"db": DB, "nodes": q("SELECT COUNT(*) FROM nodes"),
                          "edges": q("SELECT COUNT(*) FROM edges"),
                          "sources": q("SELECT COUNT(*) FROM sources"),
                          "episodes": q("SELECT COUNT(*) FROM episodes"),
                          "candidates": q("SELECT COUNT(*) FROM edges WHERE status='candidate'"),
                          "last_ingest": c.execute("SELECT MAX(last_ingest_at) FROM sources").fetchone()[0]}))
    elif cmd == "export":
        for r in c.execute("SELECT id,type,name FROM nodes"):
            print(json.dumps({"kind": "node", "id": r[0], "type": r[1], "name": r[2]}, ensure_ascii=False))
        for r in c.execute("""SELECT src_id,relation,dst_id,source_doc,weight,
                              valid_at,invalid_at,status,attribution FROM edges"""):
            print(json.dumps({"kind": "edge", "src": r[0], "relation": r[1], "dst": r[2],
                              "source_doc": r[3], "weight": r[4], "valid_at": r[5],
                              "invalid_at": r[6], "status": r[7], "attribution": r[8]}, ensure_ascii=False))
        for r in c.execute("SELECT id,ts,channel,redacted FROM episodes"):
            print(json.dumps({"kind": "episode", "id": r[0], "ts": r[1],
                              "channel": r[2], "redacted": r[3]}, ensure_ascii=False))
    else:
        sys.exit(f"unknown cmd {cmd}")

if __name__ == "__main__":
    main()

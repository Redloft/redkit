#!/usr/bin/env python3
"""redbrain backlog — оперативная память (слой 2 поверх графа).

Staging-очередь действий из разговоров (ChatGPT inbox / Claude / voice):
задачи, идеи, напоминания, дневник. НЕ граф: элементы стареют и роутятся
в Трекер / календарь / rc-private / повышаются в граф.

Живёт в ТЕХ ЖЕ файлах work.db/private.db → граница двух мозгов и
REDBRAIN_SCOPE-гейт на запись наследуются бесплатно (см. graphdb.py).

Statuses (CAS-переходы, никаких слепых UPDATE):
  raw             — свежее, ещё не разобрано
  clarify         — нужно уточнение у Игоря (Мия спросит)
  pending_confirm — превью отправлено в TG, ждём кнопку
  confirmed       — Игорь подтвердил, действие выполняется
  routed          — действие ПОДТВЕРЖДЁННО выполнено (read-back), routed_to заполнен
  promoted        — повышено в долгосрочный граф
  expired|rejected|archived — конец жизни

Commands:
  add --text .. --source inbox|claude|voice --kind task|idea|reminder|diary|calendar
      [--project X] [--confidence 0.0] [--meta JSON] [--ttl-days N]
  list [--status S] [--kind K]        — JSON построчно
  get <id>
  cas <id> --from S1 --to S2 [--routed-to X]   — атомарный переход; exit 3 при conflict
  expire                               — raw/clarify старше expires_at → expired
"""
import sys, json, os, sqlite3, uuid
from datetime import datetime, timezone, timedelta

# тот же резолвинг, что graphdb.py: REDBRAIN_DB_DIR + REDBRAIN_SCOPE
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import graphdb as g

WRITE_CMDS = {"add", "cas", "expire"}
KINDS = ("task", "idea", "reminder", "diary", "calendar")
STATUSES = ("raw", "clarify", "pending_confirm", "confirmed", "routed",
            "promoted", "expired", "rejected", "archived")

DDL = """
CREATE TABLE IF NOT EXISTS backlog (
  id          TEXT PRIMARY KEY,
  text        TEXT NOT NULL,
  source      TEXT NOT NULL,
  kind        TEXT NOT NULL,
  status      TEXT NOT NULL DEFAULT 'raw',
  project     TEXT,
  confidence  REAL DEFAULT 0,
  routed_to   TEXT,
  meta        TEXT DEFAULT '{}',
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL,
  expires_at  TEXT
);
CREATE INDEX IF NOT EXISTS idx_backlog_status ON backlog(status);
"""
# enum'ы НЕ в CHECK-constraint сознательно (finding панели: rebuild-миграция
# CHECK на живой таблице = риск data-loss) — валидация в коде ниже.

def now(): return datetime.now(timezone.utc).isoformat(timespec="seconds")

def connect():
    c = g.connect()
    c.executescript(DDL)
    c.commit()
    return c

def arg(name, default=None):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default

def row_dict(r):
    keys = ("id","text","source","kind","status","project","confidence",
            "routed_to","meta","created_at","updated_at","expires_at")
    return dict(zip(keys, r))

def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "list"
    if cmd in WRITE_CMDS and "REDBRAIN_SCOPE" not in os.environ:
        sys.exit(f"'{cmd}' is a write op — set REDBRAIN_SCOPE=work|private explicitly")
    c = connect()
    if cmd == "add":
        kind = arg("--kind", "idea")
        if kind not in KINDS: sys.exit(f"bad kind {kind} ({'|'.join(KINDS)})")
        ttl = int(arg("--ttl-days", "30"))
        bid = uuid.uuid4().hex[:12]
        ts = now()
        exp = (datetime.now(timezone.utc) + timedelta(days=ttl)).isoformat(timespec="seconds")
        c.execute("INSERT INTO backlog(id,text,source,kind,status,project,confidence,meta,created_at,updated_at,expires_at) "
                  "VALUES(?,?,?, ?,'raw',?,?,?,?,?,?)",
                  (bid, arg("--text", ""), arg("--source", "claude"), kind,
                   arg("--project"), float(arg("--confidence", "0")),
                   arg("--meta", "{}"), ts, ts, exp))
        c.commit()
        print(json.dumps({"id": bid, "status": "raw"}))
    elif cmd == "list":
        q, p = "SELECT * FROM backlog WHERE 1=1", []
        if arg("--status"): q += " AND status=?"; p.append(arg("--status"))
        if arg("--kind"):   q += " AND kind=?";   p.append(arg("--kind"))
        for r in c.execute(q + " ORDER BY created_at", p):
            print(json.dumps(row_dict(r), ensure_ascii=False))
    elif cmd == "get":
        r = c.execute("SELECT * FROM backlog WHERE id=?", (sys.argv[2],)).fetchone()
        if not r: sys.exit(f"not found: {sys.argv[2]}")
        print(json.dumps(row_dict(r), ensure_ascii=False))
    elif cmd == "cas":
        bid, s_from, s_to = sys.argv[2], arg("--from"), arg("--to")
        if s_to not in STATUSES: sys.exit(f"bad status {s_to}")
        cur = c.execute(
            "UPDATE backlog SET status=?, updated_at=?, routed_to=COALESCE(?,routed_to) "
            "WHERE id=? AND status=?", (s_to, now(), arg("--routed-to"), bid, s_from))
        c.commit()
        if cur.rowcount != 1:
            print(json.dumps({"ok": False, "reason": "conflict_or_missing"})); sys.exit(3)
        print(json.dumps({"ok": True, "id": bid, "status": s_to}))
    elif cmd == "expire":
        cur = c.execute("UPDATE backlog SET status='expired', updated_at=? "
                        "WHERE status IN ('raw','clarify') AND expires_at < ?", (now(), now()))
        # застрявшие ПРЕВЬЮ (карточка ушла, Игорь не нажал кнопку >48ч) → назад в raw,
        # dispatch перешлёт заново. ТОЛЬКО pending_confirm: 'confirmed' НЕ реквеуим — там create
        # уже мог сработать server-side, а реквеу → второй тап → ДУБЛЬ-задача в Трекере (finding
        # finalize). Застрявший confirmed (крэш до routed) остаётся confirmed → recovery вручную/адоптом.
        stale = (datetime.now(timezone.utc) - timedelta(hours=48)).isoformat(timespec="seconds")
        cur2 = c.execute("UPDATE backlog SET status='raw', updated_at=? "
                         "WHERE status = 'pending_confirm' AND updated_at < ?",
                         (now(), stale))
        c.commit()
        print(json.dumps({"expired": cur.rowcount, "requeued_stale": cur2.rowcount}))
    else:
        sys.exit(f"unknown cmd {cmd}")

if __name__ == "__main__":
    main()

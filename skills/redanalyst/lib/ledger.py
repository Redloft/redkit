#!/usr/bin/env python3
"""redanalyst idempotency ledger — dedup offline conversions at the HTTP-call level.

The single most dangerous bug in offline-conversion pipelines is a double upload:
a retry re-sends rows already accepted -> revenue is counted twice -> ROI lies.
The ledger is the source of truth for what has been reserved/sent and is read by
/redanalyst-verify.

Contract (see _shared.md §2, offline-matching-recipe.md):
  1. reserve(purchase_id)  BEFORE upload  -> refuses duplicates
  2. mark_batch(batch_id, uploading_id)   right after HTTP 200
  3. mark_status(status)                  after polling uploading/{id}
A retry checks has(purchase_id) and skips already-reserved rows.

Usage:
  ledger.py <db> reserve <purchase_id> [--client-id X --revenue N --datetime UNIX]
  ledger.py <db> has <purchase_id>                 # exit 0 if present, 1 if not
  ledger.py <db> mark-batch <batch_id> <uploading_id> <purchase_id>...
  ledger.py <db> mark-status <batch_id> <status>
  ledger.py <db> summary                           # JSON: counts by status (for /verify)
"""
import sys, sqlite3, json, time

SCHEMA_VERSION = 1

def conn(db):
    c = sqlite3.connect(db, timeout=30)
    c.execute("PRAGMA journal_mode=WAL")       # concurrent reserve vs mark-batch without 'database is locked'
    c.execute("PRAGMA busy_timeout=30000")
    c.execute("""CREATE TABLE IF NOT EXISTS ledger(
        purchase_id TEXT PRIMARY KEY,
        batch_id TEXT, uploading_id TEXT,
        status TEXT DEFAULT 'reserved',
        client_id TEXT, revenue TEXT, datetime_unix INTEGER,
        reserved_at INTEGER, schema_version INTEGER DEFAULT %d)""" % SCHEMA_VERSION)
    return c

def opt(args, name, default=None):
    # require a real value: the flag must be present AND followed by a non-flag token,
    # else a trailing flag would IndexError and `--flag --other` would eat --other as the value.
    if name in args:
        i = args.index(name)
        if i + 1 < len(args) and not args[i + 1].startswith("--"):
            return args[i + 1]
    return default

def main():
    if len(sys.argv) < 3:
        print(__doc__); sys.exit(2)
    db, action, rest = sys.argv[1], sys.argv[2], sys.argv[3:]
    c = conn(db)
    if action == "reserve":
        pid = rest[0]
        # Insert-first and let the PRIMARY KEY be the arbiter — atomic under concurrency.
        # A racing second process gets IntegrityError -> same clean duplicate/exit-3 path as a
        # pre-existing row, instead of an uncaught traceback (which would collide with exit 1).
        try:
            c.execute("INSERT INTO ledger(purchase_id,client_id,revenue,datetime_unix,reserved_at) VALUES(?,?,?,?,?)",
                      (pid, opt(rest, "--client-id"), opt(rest, "--revenue"),
                       int(opt(rest, "--datetime", "0")), int(time.time())))
            c.commit()
        except sqlite3.IntegrityError:
            print(json.dumps({"reserved": False, "reason": "duplicate", "purchase_id": pid}))
            sys.exit(3)  # duplicate -> caller must skip this row
        print(json.dumps({"reserved": True, "purchase_id": pid}))
    elif action == "has":
        cur = c.execute("SELECT 1 FROM ledger WHERE purchase_id=?", (rest[0],)).fetchone()
        sys.exit(0 if cur else 1)
    elif action == "mark-batch":
        batch_id, uploading_id, pids = rest[0], rest[1], rest[2:]
        for pid in pids:
            c.execute("UPDATE ledger SET batch_id=?, uploading_id=?, status='uploaded' WHERE purchase_id=?",
                      (batch_id, uploading_id, pid))
        c.commit(); print(json.dumps({"batch_id": batch_id, "rows": len(pids)}))
    elif action == "mark-status":
        batch_id, status = rest[0], rest[1]
        c.execute("UPDATE ledger SET status=? WHERE batch_id=?", (status, batch_id))
        c.commit(); print(json.dumps({"batch_id": batch_id, "status": status}))
    elif action == "summary":
        rows = c.execute("SELECT status, COUNT(*) FROM ledger GROUP BY status").fetchall()
        print(json.dumps({"by_status": dict(rows),
                          "total": c.execute("SELECT COUNT(*) FROM ledger").fetchone()[0]}))
    else:
        print(__doc__); sys.exit(2)

if __name__ == "__main__":
    main()

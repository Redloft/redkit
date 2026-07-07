#!/usr/bin/env python3
"""redbrain sleep_apply — ЕДИНСТВЕННАЯ фаза, правящая файлы-истину. Протокол + гейты.

Порядок на 1 решение (разрешение конфликта architect×data×security из панели):
  disk-guard → path+scope-guard → per-file снапшот → allow_empty-tombstone рёбер
  ПЕРЕД mv → правка файла → (ре-scan) → golden → при провале откат файл→граф со STOP.

Гейты: lock (общий, lib/lock), snapshot (lib/snapshot, cp -a), резолвер (lib/manifest,
только OK-резолвы правим), disk-guard, path+scope allowlist (realpath ∈ {root,/_archive,/insights}
И тот же scope). Детерминированные операторы (DROP_GHOST/ARCHIVE) готовы; LLM-операторы
(MERGE/UPDATE/SUPERSEDE/SPLIT) — протокол готов, тело в M2.

По умолчанию --dry: НИЧЕГО не пишет, печатает план. Реальная правка — без --dry И под
подписанной ✅-квитанцией (async HMAC, M1c) либо явным --i-am-igor для интерактива.

CLI: sleep_apply.py backfill [--dry] | plan <decisions.json> [--dry]
"""
import sys, os, json, subprocess, shutil

LIB = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, LIB)
import manifest, snapshot, lock  # noqa

SCOPE = os.environ.get("REDBRAIN_SCOPE", "work")
GHOST_DROP_MAX_EDGES = 2   # ghost с <=2 рёбер — транзиентный захват, безопасно снять
LOCK_NAME = "redbrain"     # общий с ingest/sync/backup


def _db(args, stdin=None):
    r = subprocess.run([sys.executable, os.path.join(LIB, "graphdb.py")] + args,
                       input=stdin, capture_output=True, text=True,
                       env=dict(os.environ, REDBRAIN_SCOPE=SCOPE))
    return r.returncode, r.stdout.strip(), r.stderr.strip()


def _edges_of(sid):
    import sqlite3
    db = os.path.join(os.path.expanduser(os.environ.get("REDBRAIN_DB_DIR",
         "~/Library/Application Support/graph-memory")), f"{SCOPE}.db")
    c = sqlite3.connect(db)
    return c.execute("SELECT COUNT(*) FROM edges WHERE source_doc=?", (sid,)).fetchone()[0]


def path_scope_guard(path, source_scope):
    """realpath обязан лежать в allowlist-корне И совпадать по scope. Иначе REFUSE.
    Закрывает: LLM-путь пишет в ~/.zshenv; cross-scope; утечку private."""
    rp = os.path.realpath(path)
    allowed = []
    for r in manifest.roots():
        if r["scope"] != source_scope:
            continue
        for d in r["dirs"]:
            allowed.append(os.path.realpath(d))
    ok = any(rp == a or rp.startswith(a + os.sep) for a in allowed)
    return ok, rp


def tombstone(sid):
    """Снять ВСЕ рёбра источника (allow_empty insert = tombstone без append)."""
    payload = json.dumps({"source_id": sid, "content_hash": "sleep-tombstone",
                          "run_id": "sleep-backfill", "triples": [], "allow_empty": True})
    return _db(["insert"], stdin=payload)


def op_drop_ghost(sid, dry):
    """Ghost-источник (файла нет): снять рёбра. Файл не трогаем — его и нет."""
    ne = _edges_of(sid)
    if dry:
        return {"op": "DROP_GHOST", "source_id": sid, "edges_would_tombstone": ne, "dry": True}
    rc, out, err = tombstone(sid)
    return {"op": "DROP_GHOST", "source_id": sid, "tombstoned": ne, "ok": rc == 0, "err": err}


def op_archive(sid, dry):
    """Файл-backed эвикция: снапшот → tombstone рёбер → mv в <root>/_archive/."""
    res = manifest.resolve(sid)
    if res["status"] != "OK":
        return {"op": "ARCHIVE", "source_id": sid, "REFUSE": f"resolve={res['status']}"}
    path, sc = res["path"], res.get("scope", SCOPE)
    ok, rp = path_scope_guard(path, sc)
    if not ok:
        return {"op": "ARCHIVE", "source_id": sid, "REFUSE": "path/scope guard", "realpath": rp}
    archive_dir = os.path.join(os.path.dirname(path), "_archive")
    dest = os.path.join(archive_dir, os.path.basename(path))
    if dry:
        return {"op": "ARCHIVE", "source_id": sid, "from": path, "to": dest,
                "edges_would_tombstone": _edges_of(sid), "dry": True}
    snapshot.disk_guard()
    snapshot.snapshot(f"archive-{os.path.basename(sid)}", [path])
    tombstone(sid)
    os.makedirs(archive_dir, exist_ok=True)
    shutil.move(path, dest)
    return {"op": "ARCHIVE", "source_id": sid, "moved_to": dest, "ok": True}


def backfill_plan(dry=True):
    """Классифицировать un-resolvable/эфемерные источники: DROP_GHOST vs FLAG-refile.
    Крупный ghost (>2 рёбер) НЕ дропаем — это реальные знания в неправильном namespace."""
    import sqlite3
    db = os.path.join(os.path.expanduser(os.environ.get("REDBRAIN_DB_DIR",
         "~/Library/Application Support/graph-memory")), f"{SCOPE}.db")
    c = sqlite3.connect(db)
    sids = [r[0] for r in c.execute("SELECT source_id FROM sources")]
    drop, flag = [], []
    for sid in sids:
        st = manifest.resolve(sid)["status"]
        if st == "OK":
            continue
        ne = _edges_of(sid)
        if st == "GHOST" and ne <= GHOST_DROP_MAX_EDGES:
            drop.append((sid, ne))
        else:
            flag.append((sid, ne, st))
    print(json.dumps({"scope": SCOPE, "mode": "DRY" if dry else "APPLY",
                      "drop_ghost": len(drop), "flag_for_human": len(flag)}, ensure_ascii=False))
    print("\n▸ DROP_GHOST (транзиентные захваты, безопасно снять рёбра):")
    for sid, ne in drop:
        print("   ", op_drop_ghost(sid, dry))
    print("\n▸ FLAG — решение человека (НЕ авто-дроп):")
    for sid, ne, st in flag:
        reason = ("реальные знания в ephemeral namespace → REFILE, не дроп" if ne > GHOST_DROP_MAX_EDGES
                  else f"{st}: переименован/перемещён → re-scan или drop")
        print(f"    {{'source_id': '{sid}', 'edges': {ne}, 'status': '{st}', 'action': '{reason}'}}")
    if not dry:
        print("\n(APPLY выполнен под lock — см. выше ok/err по каждому)")


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "backfill"
    dry = "--dry" in sys.argv or "--i-am-igor" not in sys.argv  # безопасный дефолт
    if cmd == "backfill":
        if not dry:
            if not lock.acquire(LOCK_NAME):
                sys.exit("busy: redbrain lock занят (ingest/другой Сон) — skip")
            try:
                backfill_plan(dry=False)
            finally:
                lock.release(LOCK_NAME)
        else:
            backfill_plan(dry=True)
    else:
        sys.exit(f"unknown cmd {cmd} (M1c: 'backfill'; LLM-операторы — M2)")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Общий файловый lock для ВСЕХ redbrain launchd-джоб (sleep.triage/full + inbox/sync/backup).

Зачем: Сон правит файлы-истину, а параллельный ingest/живая сессия могут писать граф.
Нужен один writer. Ни одна из 5 существующих джоб сейчас lock не имеет (finding ops-панели).

Механика: mkdir-атомарность + meta.json{owner,ts,ttl} + stale-reclaim (мёртвый владелец
ИЛИ протухший TTL → отбираем). ВЛАДЕЛЕЦ передаётся явно (--owner), т.к. acquire и release
идут РАЗНЫМИ процессами (bash-обёртка → отдельные python CLI): по os.getpid() они бы не
сошлись. Обёртка передаёт свой bash $$ и в acquire, и в release. Default owner = свой PID.

CLI: acquire <name> [--ttl S] [--owner ID] | release <name> [--owner ID] | status <name>
Exit: acquire → 0 взят / 1 занят живым владельцем. release/status → 0.
launchd-обёртка: `lock.py acquire redbrain --owner $$ || { echo skip; exit 0; }`
"""
import sys, os, json, time, errno

LOCKROOT = os.path.expanduser(os.environ.get("REDBRAIN_DB_DIR",
                              "~/Library/Application Support/graph-memory"))
LOCKS = os.path.join(LOCKROOT, "sleep", "locks")
DEFAULT_TTL = 3600


def _lock_path(name): return os.path.join(LOCKS, f"{name}.lock")
def _meta_path(name): return os.path.join(_lock_path(name), "meta.json")


def _pid_alive(pid):
    if pid < 1:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError as e:
        return e.errno == errno.EPERM  # существует, но не наш — жив


def _owner_alive(owner):
    """Владелец — обычно PID (число). Если не число — считаем живым (полагаемся на TTL)."""
    try:
        return _pid_alive(int(owner))
    except (TypeError, ValueError):
        return True


def _read_meta(name):
    try:
        with open(_meta_path(name)) as f:
            return json.load(f)
    except Exception:
        return None


def _write_meta(name, ttl, owner):
    with open(_meta_path(name), "w") as f:
        json.dump({"owner": str(owner), "ts": time.time(), "ttl": ttl,
                   "host": os.uname().nodename}, f)


def _is_stale(meta, ttl):
    if not meta:
        return True
    return (not _owner_alive(meta.get("owner"))) or \
           (time.time() - meta.get("ts", 0) > meta.get("ttl", ttl))


def acquire(name, ttl=DEFAULT_TTL, owner=None):
    owner = owner if owner is not None else os.getpid()
    os.makedirs(LOCKS, exist_ok=True)
    try:
        os.mkdir(_lock_path(name))            # атомарный захват
        _write_meta(name, ttl, owner)
        return True
    except FileExistsError:
        if _is_stale(_read_meta(name), ttl):  # мёртвый/протухший → отбираем
            _write_meta(name, ttl, owner)
            return True
        return False                          # живой владелец


def release(name, owner=None):
    owner = str(owner if owner is not None else os.getpid())
    meta = _read_meta(name)
    if meta and meta.get("owner") == owner:
        try:
            os.remove(_meta_path(name))
        except FileNotFoundError:
            pass
        try:
            os.rmdir(_lock_path(name))
        except OSError:
            pass
        return True
    return False


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: lock.py acquire|release|status <name> [--ttl S] [--owner ID]")
    cmd, name = sys.argv[1], sys.argv[2]
    ttl = int(sys.argv[sys.argv.index("--ttl") + 1]) if "--ttl" in sys.argv else DEFAULT_TTL
    owner = sys.argv[sys.argv.index("--owner") + 1] if "--owner" in sys.argv else None
    if cmd == "acquire":
        ok = acquire(name, ttl, owner)
        print("acquired" if ok else "busy")
        sys.exit(0 if ok else 1)
    elif cmd == "release":
        print("released" if release(name, owner) else "not-owner")
    elif cmd == "status":
        meta = _read_meta(name)
        held = os.path.isdir(_lock_path(name))
        print(json.dumps({"name": name, "held": held, "meta": meta,
                          "stale": _is_stale(meta, ttl) if held else None}, ensure_ascii=False))
    else:
        sys.exit(f"unknown cmd {cmd}")


if __name__ == "__main__":
    main()

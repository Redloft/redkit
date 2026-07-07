#!/usr/bin/env python3
"""cp -a снапшоты файлов-истины для отката «Сна». Git НИГДЕ нет (ни ~/.claude, ни
$CLAUDECORE_PATH — проверено STEP-0), поэтому откат — копия в локальный не-Я.Диск
каталог (рядом с БД). + disk-guard (не писать на переполненном диске) + retention.

API (и CLI): snapshot <label> <file>... | restore <snapdir> | gc [--keep N] | diskguard [--min-gb N]
Снапшот хранит orig↔snap в manifest.json → restore кладёт файлы обратно точно на место.
"""
import sys, os, json, time, shutil

SNAPROOT = os.path.join(os.path.expanduser(os.environ.get("REDBRAIN_DB_DIR",
           "~/Library/Application Support/graph-memory")), "snapshots")
MIN_FREE_GB = 2.0
KEEP = 14


def free_gb(path=SNAPROOT):
    p = path if os.path.exists(path) else os.path.dirname(os.path.dirname(path))
    st = os.statvfs(p)
    return st.f_bavail * st.f_frsize / 1e9


def disk_guard(min_gb=MIN_FREE_GB):
    """Аварийный стоп до любой записи (rank-8 панели). True=ок, иначе sys.exit."""
    f = free_gb(os.path.expanduser("~"))
    if f < min_gb:
        sys.exit(f"DISK-GUARD: свободно {f:.1f}GB < {min_gb}GB — Сон не пишет (abort+alert)")
    return f


def snapshot(label, files):
    disk_guard()
    ts = time.strftime("%Y%m%d-%H%M%S")
    snapdir = os.path.join(SNAPROOT, f"{ts}-{label}")
    os.makedirs(snapdir, exist_ok=True)
    manifest = []
    for i, orig in enumerate(files):
        if not os.path.isfile(orig):
            manifest.append({"orig": orig, "snap": None, "missing": True})
            continue
        snap = os.path.join(snapdir, f"{i:03d}-{os.path.basename(orig)}")
        shutil.copy2(orig, snap)              # cp -a: сохраняет mtime/mode
        manifest.append({"orig": orig, "snap": snap})
    with open(os.path.join(snapdir, "manifest.json"), "w") as f:
        json.dump({"label": label, "ts": ts, "files": manifest}, f, ensure_ascii=False, indent=1)
    return snapdir


def restore(snapdir):
    with open(os.path.join(snapdir, "manifest.json")) as f:
        m = json.load(f)
    restored = 0
    for e in m["files"]:
        if e.get("snap") and os.path.isfile(e["snap"]):
            os.makedirs(os.path.dirname(e["orig"]), exist_ok=True)
            shutil.copy2(e["snap"], e["orig"])
            restored += 1
        elif e.get("missing"):
            # файла не было на момент снапшота → откат = удалить, если создан
            if os.path.isfile(e["orig"]):
                os.remove(e["orig"])
    return restored


def gc(keep=KEEP):
    if not os.path.isdir(SNAPROOT):
        return 0
    snaps = sorted(d for d in os.listdir(SNAPROOT) if os.path.isdir(os.path.join(SNAPROOT, d)))
    removed = 0
    for d in snaps[:-keep] if len(snaps) > keep else []:
        shutil.rmtree(os.path.join(SNAPROOT, d)); removed += 1
    return removed


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: snapshot.py snapshot|restore|gc|diskguard ...")
    cmd = sys.argv[1]
    if cmd == "snapshot":
        print(snapshot(sys.argv[2], sys.argv[3:]))
    elif cmd == "restore":
        print(f"restored {restore(sys.argv[2])} files")
    elif cmd == "gc":
        keep = int(sys.argv[sys.argv.index("--keep") + 1]) if "--keep" in sys.argv else KEEP
        print(f"gc removed {gc(keep)} snapshots")
    elif cmd == "diskguard":
        mg = float(sys.argv[sys.argv.index("--min-gb") + 1]) if "--min-gb" in sys.argv else MIN_FREE_GB
        print(f"free {disk_guard(mg):.1f}GB (min {mg})")
    else:
        sys.exit(f"unknown cmd {cmd}")


if __name__ == "__main__":
    main()

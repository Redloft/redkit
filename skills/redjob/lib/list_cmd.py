#!/usr/bin/env python3
"""redjob list — карта парка джоб (timeline + persistent + сводка + exit).

Читает jobs.yaml + живой launchctl. Вывод — терминальная таблица либо `--md`
(markdown для вставки в доки). Всё, что печатается, проходит scrub (инвариант).
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common
import registry
import scrub

_WD = {0: "вс", 1: "пн", 2: "вт", 3: "ср", 4: "чт", 5: "пт", 6: "сб", 7: "вс"}


def _exit_badge(live, label):
    st = live.get(label)
    if st is None:
        return "—"
    le = st.get("last_exit")
    if le in (None, 0):
        return "ok"
    return f"exit={le}"


def _cal_slots(job):
    out = []
    for e in (job.get("schedule") or {}).get("calendar") or []:
        if e.get("hour") is None:
            continue
        wd = _WD.get(e.get("weekday"), "*") if e.get("weekday") is not None else "*"
        out.append((e["hour"], e.get("minute") or 0, wd))
    return out


def build_view(md=False):
    data = registry.load()
    live = common.launchctl_list()
    active = [j for j in data["jobs"] if j.get("status") == "active"]
    external = [j for j in data["jobs"] if j.get("status") == "external"]

    lines = []
    H = (lambda s: f"## {s}") if md else (lambda s: common.c(s, "1"))

    # --- Timeline (calendar-джобы по часам) ---
    lines.append(H("Timeline (calendar) — сутки"))
    timeline = {}
    for j in active:
        for h, m, wd in _cal_slots(j):
            timeline.setdefault(h, []).append((m, wd, j))
    if not timeline:
        lines.append("  (нет calendar-джоб)")
    for h in sorted(timeline):
        for m, wd, j in sorted(timeline[h], key=lambda x: x[0]):
            w = "🔴heavy" if j.get("weight") == "heavy-claude" else "light"
            lk = ("+lock:" + ",".join(j["locks"])) if j.get("locks") else ""
            badge = _exit_badge(live, j["label"])
            row = f"  {h:02d}:{m:02d} {wd:2} │ {j['label']:34} {w:8} {lk:16} [{badge}]"
            lines.append(row)

    # --- Interval-джобы ---
    intervals = [j for j in active if j.get("kind") == "interval"]
    if intervals:
        lines.append("")
        lines.append(H("Interval"))
        for j in sorted(intervals, key=lambda x: x["label"]):
            hu = (j.get("schedule") or {}).get("human", "?")
            lk = ("lock:" + ",".join(j["locks"])) if j.get("locks") else ""
            lines.append(f"  {j['label']:36} {hu:12} {lk:16} [{_exit_badge(live, j['label'])}]")

    # --- Persistent (keepalive) ---
    persist = [j for j in active if j.get("kind") == "keepalive"]
    if persist:
        lines.append("")
        lines.append(H("Persistent (KeepAlive)"))
        for j in sorted(persist, key=lambda x: x["label"]):
            st = live.get(j["label"]) or {}
            pid = st.get("pid")
            run = f"pid={pid}" if pid else "НЕ загружена"
            lines.append(f"  {j['label']:36} {run:14} [{_exit_badge(live, j['label'])}]")

    # --- Сводка по проектам ---
    lines.append("")
    lines.append(H("По проектам"))
    byproj = {}
    for j in active:
        byproj.setdefault(j.get("project", "?"), []).append(j)
    for p in sorted(byproj):
        heavy = sum(1 for j in byproj[p] if j.get("weight") == "heavy-claude")
        lines.append(f"  {p:12} {len(byproj[p])} джоб (heavy-claude: {heavy})")
    if external:
        lines.append(f"  {'external':12} {len(external)} (сторонние, без проверок)")

    body = "\n".join(lines)
    return scrub.scrub_text(body)


def main(argv):
    md = "--md" in argv
    print(build_view(md=md))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""redbrain promote — конвейер candidate→confirmed (S2a temporal-layers).

Собственный минимальный batch-раннер: НЕ зависит от redbrain-sleep (upstream
у того свои critical). Детерминированные правила, не LLM-усмотрение:
  • ≥2 независимых эпизодов (разные дни ИЛИ разные каналы) → в пачку на confirmed
  • attribution='user_statement' → в пачку с 1 эпизода
  • model_inference с 1 эпизодом → остаётся candidate
  • candidate старше TTL без корроборации → expired автоматически (строка остаётся)
Противоречие с активным confirmed той же тройки (пересечение valid-окон) —
в conflicts на ручной разбор, НЕ авто-промоушен и НЕ молчаливая перезапись.

Промоушен-пачка применяется только по ✅ Игоря: scan строит proposal-карточку
(идемпотентно: тот же набор рёбер → тот же id и байт-в-байт контент),
apply переводит статусы. Оба прохода идемпотентны и под общим lock'ом
'redbrain' (один writer, panel rank 9). Переходы статусов — append-only
JSONL ~/.cache/redbrain/promote/events.log (panel rank 7).

CLI:
  scan [--ttl-days N] [--min-episodes N] [--notify]  — TTL-проход + proposal
  apply <proposal-id|path>                           — перевести пачку (после ✅)
  status                                             — счётчики конвейера
Запись требует явный REDBRAIN_SCOPE (наследуем правило graphdb).
"""
import sys, os, json, time, hashlib, subprocess

LIB = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, LIB)
import graphdb as g  # noqa: E402

CACHE = os.path.expanduser(os.environ.get("REDBRAIN_PROMOTE_CACHE", "~/.cache/redbrain/promote"))
EVENTS = os.path.join(CACHE, "events.log")
LOG_MAX = 512 * 1024
TTL_DAYS = 30
MIN_EPISODES = 2
LOCK_NAME = "redbrain"   # общий writer-lock со sleep/ingest/sync


def _cache_ready():
    os.makedirs(CACHE, exist_ok=True)
    os.chmod(CACHE, 0o700)


def log_event(rec):
    try:
        _cache_ready()
        if os.path.exists(EVENTS) and os.path.getsize(EVENTS) > LOG_MAX:
            os.replace(EVENTS, EVENTS + ".1")
        rec = {"ts": int(time.time()), "scope": g.SCOPE, **rec}
        with open(EVENTS, "a") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        os.chmod(EVENTS, 0o600)
    except Exception:
        pass   # observability не должна ронять конвейер


def lock_acquire():
    # capture: stdout lock.py не должен мешаться в наш JSON-вывод
    r = subprocess.run([sys.executable, os.path.join(LIB, "lock.py"),
                        "acquire", LOCK_NAME, "--owner", f"promote-{os.getpid()}"],
                       capture_output=True, text=True)
    return r.returncode == 0


def lock_release():
    subprocess.run([sys.executable, os.path.join(LIB, "lock.py"),
                    "release", LOCK_NAME, "--owner", f"promote-{os.getpid()}"],
                   capture_output=True, text=True)


def _name(c, nid):
    r = c.execute("SELECT name FROM nodes WHERE id=?", (nid,)).fetchone()
    return r[0] if r else nid


def _lineage(c, edge_id):
    return c.execute("""SELECT e.id, e.ts, e.channel FROM episodes e
                        JOIN edge_episodes ee ON ee.episode_id=e.id
                        WHERE ee.edge_id=? ORDER BY e.ts""", (edge_id,)).fetchall()


def _overlaps(v1, i1, v2, i2):
    # closed-open; NULL invalid_at = открытый интервал
    return v1 < (i2 or "9999") and v2 < (i1 or "9999")


def scan(ttl_days=TTL_DAYS, min_episodes=MIN_EPISODES, notify=False):
    c = g.connect(); g.init(c)
    cutoff = time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(time.time() - ttl_days * 86400))
    expired, promote, conflicts = [], [], []
    with g.tx(c):
        cands = c.execute("""SELECT id, src_id, relation, dst_id, valid_at, invalid_at,
                             attribution, created_at FROM edges WHERE status='candidate'
                             ORDER BY id""").fetchall()
        for (eid, src, rel, dst, va, ia, attr, created) in cands:
            eps = _lineage(c, eid)
            days = {e[1][:10] for e in eps}
            chans = {e[2] for e in eps}
            corroborated = len(days) >= min_episodes or len(chans) >= min_episodes
            triple = f"{_name(c, src)} —{rel}→ {_name(c, dst)}"
            # TTL: одинокий model_inference старше cutoff — гасим (строка остаётся)
            if not corroborated and attr != "user_statement" and created < cutoff:
                c.execute("UPDATE edges SET status='expired', expired_at=? WHERE id=?", (g.now(), eid))
                expired.append({"edge": eid, "triple": triple})
                log_event({"op": "ttl-expire", "edge": eid, "old": "candidate", "new": "expired",
                           "reason": f"no corroboration in {ttl_days}d", "episodes": len(eps)})
                continue
            if not (corroborated or attr == "user_statement"):
                continue   # ждёт корроборации
            # конфликт: активный confirmed той же тройки с пересечением окон
            clash = [r[0] for r in c.execute(
                """SELECT id, valid_at, invalid_at FROM edges WHERE status='confirmed'
                   AND src_id=? AND relation=? AND dst_id=? AND id!=?""", (src, rel, dst, eid))
                if _overlaps(va or "0000", ia, r[1] or "0000", r[2])]
            item = {"edge": eid, "triple": triple, "interval": [va, ia],
                    "attribution": attr, "episodes": len(eps),
                    "days": sorted(days), "channels": sorted(chans)}
            if clash:
                conflicts.append({**item, "confirmed_clash": clash})
                log_event({"op": "conflict", "edge": eid, "clash": clash, "triple": triple})
            else:
                promote.append(item)
    proposal = None
    if promote or conflicts:
        pid = hashlib.sha256(json.dumps(
            [x["edge"] for x in promote + conflicts], sort_keys=True).encode()).hexdigest()[:12]
        proposal = {"id": pid, "scope": g.SCOPE, "promote": promote, "conflicts": conflicts}
        _cache_ready()
        path = os.path.join(CACHE, f"proposal-{pid}.json")
        blob = json.dumps(proposal, ensure_ascii=False, indent=1)
        if not (os.path.exists(path) and open(path).read() == blob):
            with open(path, "w") as f:
                f.write(blob)
            os.chmod(path, 0o600)
        log_event({"op": "scan", "proposal": pid, "promote": len(promote),
                   "conflicts": len(conflicts), "expired": len(expired)})
        if notify:
            _send_card(proposal, path)
    else:
        log_event({"op": "scan", "proposal": None, "promote": 0,
                   "conflicts": 0, "expired": len(expired)})
    return {"expired": expired, "proposal": proposal}


def _send_card(proposal, path):
    """TG-карточка Игорю через существующий redcontrol-sender (@Attunedbot, op run)."""
    lines = [f"🧠 RedBrain: {len(proposal['promote'])} факт(ов) на подтверждение"
             f" ({proposal['scope']})", ""]
    for x in proposal["promote"][:15]:
        iv = f" [{x['interval'][0] or '…'} → {x['interval'][1] or 'сейчас'}]"
        lines.append(f"• {x['triple']}{iv} — {x['episodes']} эп., {'/'.join(x['channels'])}")
    if proposal["conflicts"]:
        lines.append("")
        lines.append(f"⚠️ конфликтов с confirmed: {len(proposal['conflicts'])} (ручной разбор)")
    lines += ["", f"✅ apply: promote.py apply {proposal['id']}"]
    card = os.path.join(CACHE, f"card-{proposal['id']}.txt")
    with open(card, "w") as f:
        f.write("\n".join(lines))
    sender = os.path.expanduser("~/.claude/skills/redcontrol/scripts/rc_digest_send.sh")
    if os.path.exists(sender):
        subprocess.run(["bash", sender, card])


def apply_proposal(ref):
    path = ref if os.path.exists(ref) else os.path.join(CACHE, f"proposal-{ref}.json")
    if not os.path.exists(path):
        sys.exit(f"proposal not found: {ref}")
    p = json.load(open(path))
    if p.get("scope") != g.SCOPE:
        sys.exit(f"proposal scope={p.get('scope')} != REDBRAIN_SCOPE={g.SCOPE} — не смешиваем мозги")
    c = g.connect(); g.init(c)
    done, skipped = [], []
    with g.tx(c):
        for x in p.get("promote", []):
            row = c.execute("SELECT status FROM edges WHERE id=?", (x["edge"],)).fetchone()
            if not row or row[0] != "candidate":      # уже применён / истёк / нет — идемпотентно
                skipped.append({"edge": x["edge"], "status": row[0] if row else "missing"})
                continue
            c.execute("UPDATE edges SET status='confirmed' WHERE id=?", (x["edge"],))
            done.append(x["edge"])
            log_event({"op": "promote", "edge": x["edge"], "old": "candidate",
                       "new": "confirmed", "reason": "tg-approved", "episodes": x["episodes"]})
    return {"applied": done, "skipped": skipped, "proposal": p["id"]}


def status():
    c = g.connect(); g.init(c)
    by = dict(c.execute("SELECT status, COUNT(*) FROM edges GROUP BY status").fetchall())
    props = sorted(f for f in os.listdir(CACHE) if f.startswith("proposal-")) if os.path.isdir(CACHE) else []
    return {"db": g.DB, "by_status": by,
            "episodes": c.execute("SELECT COUNT(*) FROM episodes").fetchone()[0],
            "pending_proposals": props}


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    if cmd in ("scan", "apply") and not g.SCOPE_EXPLICIT:
        sys.exit(f"'{cmd}' пишет в граф — set REDBRAIN_SCOPE=work|private явно")
    if cmd == "status":
        print(json.dumps(status(), ensure_ascii=False)); return
    if not lock_acquire():
        sys.exit("lock 'redbrain' занят живым writer'ом — skip (не сериализуемся силой)")
    try:
        if cmd == "scan":
            args = sys.argv[2:]
            ttl = int(args[args.index("--ttl-days") + 1]) if "--ttl-days" in args else TTL_DAYS
            mn = int(args[args.index("--min-episodes") + 1]) if "--min-episodes" in args else MIN_EPISODES
            print(json.dumps(scan(ttl, mn, "--notify" in args), ensure_ascii=False))
        elif cmd == "apply":
            print(json.dumps(apply_proposal(sys.argv[2]), ensure_ascii=False))
        else:
            sys.exit(f"unknown cmd {cmd}")
    finally:
        lock_release()


if __name__ == "__main__":
    main()

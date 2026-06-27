#!/usr/bin/env python3
"""dedup-cards.py — round.sh helper. Reads raw adapter cards (one JSON per line)
on stdin, drops any already in the WAL captures-index OR duplicated within the
batch, then picks up to CAP_N cards ROUND-ROBIN across sources (so the first
adapter in the fetch pipe can't crowd out the others), assigns fresh global ids
(MAXID+1..) and stamps the round.
Env: IDX (captures-index.json path), MAXID, CAP_N, RN. Prints kept cards."""
import sys, os, json

idx = {}
try:
    with open(os.environ["IDX"]) as f:
        idx = json.load(f)
except Exception:
    idx = {}

maxid = int(os.environ.get("MAXID", "0") or 0)
cap = int(os.environ.get("CAP_N", "12") or 12)
rn = int(os.environ.get("RN", "1") or 1)

seen = set()
by_source = {}          # source → fresh cards in arrival order
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        c = json.loads(line)
    except Exception:
        continue
    key = "%s|%s" % (c.get("source"), c.get("ref_url"))
    if key in idx or key in seen:
        continue
    seen.add(key)
    by_source.setdefault(c.get("source") or "?", []).append(c)

# round-robin across sources up to the cap → balanced mix per round
queues = list(by_source.values())
out = []
while queues and len(out) < cap:
    nxt = []
    for q in queues:
        if len(out) >= cap:
            break
        out.append(q.pop(0))
        if q:
            nxt.append(q)
    queues = nxt

nid = maxid
for c in out:
    nid += 1
    c["id"] = nid
    c["round"] = rn
    print(json.dumps(c, ensure_ascii=False))

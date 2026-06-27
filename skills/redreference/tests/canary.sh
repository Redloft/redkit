#!/usr/bin/env bash
# canary.sh — LIVE probes (network). NOT a gate: may fail on network issues or
# upstream API changes. Run on a schedule, not in the MVP DoD gate (that's
# tests/smoke.sh, which is hermetic). Surfaces FIXTURE_SCHEMA_DRIFT and dead
# adapters before a real run does.
#
# Usage: bash tests/canary.sh
set -uo pipefail
SK="${CLAUDE_SKILLS:-$HOME/.claude/skills}"
LIB="$SK/redreference/lib"
WARN=0; OK=0
ok()  { echo "  ✅ $1"; OK=$((OK+1)); }
warn(){ echo "  ⚠️  $1"; WARN=$((WARN+1)); }

echo "── Are.na live adapter ──"
LC=$(bash "$LIB/adapters/arena.sh" search "swiss typography" 1 2 1 2>/dev/null | head -8)
N=$(printf '%s\n' "$LC" | grep -c . || true)
if [ "${N:-0}" -ge 1 ]; then
  V=0; while IFS= read -r c; do [ -n "$c" ] || continue; node "$LIB/validate-card.js" "$c" >/dev/null 2>&1 && V=$((V+1)); done <<< "$LC"
  # live-probe must yield non-empty title+ref_url, not a silent 2xx-empty
  NONEMPTY=$(printf '%s\n' "$LC" | jq -r 'select((.title|length)>0 and (.ref_url|length)>0)|1' 2>/dev/null | grep -c 1 || true)
  [ "$V" = "$N" ] && [ "${NONEMPTY:-0}" -ge 1 ] && ok "arena live → $N cards, all valid, non-empty" || warn "arena live degraded ($V/$N valid, $NONEMPTY non-empty)"
else
  warn "arena live returned 0 cards (network/rate-limit?)"
fi

echo "── Awwwards / Behance live adapters ──"
for src in awwwards behance; do
  LC=$(bash "$LIB/adapters/${src}.sh" search "restaurant" 1 4 1 2>/dev/null | head -4)
  N=$(printf '%s\n' "$LC" | grep -c . || true)
  if [ "${N:-0}" -ge 1 ]; then
    V=0; while IFS= read -r c; do [ -n "$c" ] || continue; node "$LIB/validate-card.js" "$c" >/dev/null 2>&1 && V=$((V+1)); done <<< "$LC"
    [ "$V" = "$N" ] && ok "$src live → $N cards, all valid" || warn "$src live degraded ($V/$N valid)"
  else
    warn "$src live returned 0 cards (network/anti-bot/markup change?)"
  fi
  sleep 1
done

echo "── fixture schema drift (verify-fixtures) ──"
for src in arena; do
  if ls "$SK/redreference/fixtures/${src}."*.json >/dev/null 2>&1; then
    if bash "$LIB/verify-fixtures.sh" "$src" "https://api.are.na/v2/channels/brutal-web-phgxbsaht6m/contents?per=24&direction=desc" 2>/dev/null; then
      ok "$src fixture schema in sync"
    else warn "$src FIXTURE_SCHEMA_DRIFT or live fetch failed"; fi
  else warn "$src: no fixture recorded (run record-fixture.sh)"; fi
done

echo "── robots.txt reachability (scraper hosts) ──"
for host in onepagelove.com www.awwwards.com www.behance.net; do
  rc=0; bash "$LIB/robots.sh" "https://$host/" redreference >/dev/null 2>&1 || rc=$?
  case "$rc" in 0) ok "robots $host → allowed";; 3) ok "robots $host → Disallow (link-only respected)";; *) warn "robots $host probe rc=$rc";; esac
done

echo
echo "──────── canary: $OK ok, $WARN warn (non-gating) ────────"
exit 0

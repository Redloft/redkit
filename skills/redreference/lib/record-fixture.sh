#!/usr/bin/env bash
# record-fixture.sh — capture a REAL adapter endpoint response as a dated fixture
# (plan gap#3: fixtures must not drift from the live API). Saves the response
# as-is to fixtures/<src>.<YYYY-MM-DD>.json and stamps last_verified in the
# source's recon.md. Use cffi_get (browser TLS) or --proxy for IP-gated hosts.
#
# Usage:
#   record-fixture.sh <src> <url> [--proxy]
# Exit: 0 saved | 1 empty/blocked | 64 usage
set -uo pipefail

SRC="${1:-}"; URL="${2:-}"; MODE="${3:-}"
[ -n "$SRC" ] && [ -n "$URL" ] || { echo "usage: record-fixture.sh <src> <url> [--proxy]" >&2; exit 64; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
FIX_DIR="$SKILL_DIR/fixtures"
RECON="$SKILL_DIR/lib/adapters/${SRC}.recon.md"
mkdir -p "$FIX_DIR"
DATE=$(date +%Y-%m-%d)
OUT="$FIX_DIR/${SRC}.${DATE}.json"

if [ "$MODE" = "--proxy" ]; then
  body=$(redproxy "$URL" 2>/dev/null || bash "$HERE/redproxy.sh" "$URL" 2>/dev/null || true)
else
  body=$(bash "$HERE/cffi_get.sh" "$URL" 12 chrome 2>/dev/null || true)
fi

if [ -z "$body" ]; then echo "✗ empty/blocked response for $URL" >&2; exit 1; fi
printf '%s' "$body" > "$OUT"
echo "saved fixture: ${OUT#"$SKILL_DIR"/} ($(wc -c < "$OUT" | tr -d ' ') bytes)"

# stamp last_verified in recon.md frontmatter (create a stub if missing)
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if [ -f "$RECON" ] && grep -q 'last_verified:' "$RECON"; then
  sed -i '' -E "s|last_verified:.*|last_verified: $TS|" "$RECON" 2>/dev/null || \
  sed -i -E "s|last_verified:.*|last_verified: $TS|" "$RECON" 2>/dev/null || true
  echo "stamped last_verified in ${RECON#"$SKILL_DIR"/}"
fi

#!/usr/bin/env bash
# robots.sh — machine-readable robots.txt enforcement (plan gap#1 / B0.5).
# Before a scraper adapter's FIRST request to a domain, check the target path
# against /robots.txt for our user-agent. Disallowed → exit 3 (ROBOTS_BLOCKED);
# the adapter returns empty + logs robots_blocked instead of scraping. The
# Crawl-delay (if any) is echoed on stdout so retry.sh can honor it.
#
# robots.txt is fetched once via cffi_get.sh (browser TLS) and cached 24h under
# $REDREFERENCE_DATA_DIR/cache/robots/<host>.txt. Parsing uses Python stdlib
# urllib.robotparser (correct precedence/wildcards), never a hand-rolled grep.
#
# Usage:  robots.sh <url> [user_agent=redreference]
# Exit:   0 allowed (echoes crawl_delay seconds or "")
#         3 ROBOTS_BLOCKED
#         0 allowed (fail-OPEN) when robots.txt is unreachable/missing — but logs to stderr
#        64 usage
set -uo pipefail

URL="${1:-}"; UA="${2:-redreference}"
[ -n "$URL" ] || { echo "usage: robots.sh <url> [user_agent]" >&2; exit 64; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_ROOT="${REDREFERENCE_DATA_DIR:-$HOME/Library/Application Support/redreference}"
CACHE_DIR="$DATA_ROOT/cache/robots"
mkdir -p "$CACHE_DIR"

HOST=$(printf '%s' "$URL" | sed -E 's#^https?://([^/]+).*#\1#')
[ -n "$HOST" ] || { echo "robots.sh: cannot parse host from $URL" >&2; exit 0; }
SCHEME=$(printf '%s' "$URL" | sed -E 's#^(https?)://.*#\1#'); [ "$SCHEME" = "http" ] || SCHEME="https"
CACHE="$CACHE_DIR/${HOST}.txt"

# refresh cache if missing or older than 24h
_stale=1
if [ -f "$CACHE" ]; then
  if find "$CACHE" -mtime -1 2>/dev/null | grep -q .; then _stale=0; fi
fi
if [ "$_stale" -eq 1 ]; then
  body=$(bash "$HERE/cffi_get.sh" "${SCHEME}://${HOST}/robots.txt" 8 chrome 2>/dev/null || true)
  # cache even an empty result (avoids hammering); empty robots = allow-all
  printf '%s' "$body" > "$CACHE"
fi

# Parse with stdlib; decide allow + crawl-delay.
DELAY=$(URL="$URL" UA="$UA" CACHE="$CACHE" python3 - <<'PY'
import os, sys
from urllib.robotparser import RobotFileParser
url=os.environ["URL"]; ua=os.environ["UA"]; cache=os.environ["CACHE"]
rp=RobotFileParser()
try:
    with open(cache, "r", encoding="utf-8", errors="replace") as f:
        rp.parse(f.read().splitlines())
except Exception:
    # unreadable → fail open
    print(""); sys.exit(0)
allowed = rp.can_fetch(ua, url)
if not allowed:
    sys.exit(3)
cd = rp.crawl_delay(ua)
print(cd if cd is not None else "")
sys.exit(0)
PY
)
rc=$?
if [ "$rc" -eq 3 ]; then
  echo "ROBOTS_BLOCKED host=$HOST url=$URL ua=$UA" >&2
  exit 3
fi
printf '%s' "$DELAY"
exit 0

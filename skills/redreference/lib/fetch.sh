# VENDORED from ~/.claude/skills/redresearch/lib/fetch.sh — DO NOT edit here; re-vendor via lib/update-vendor.sh
#!/usr/bin/env bash
# fetch.sh — free self-hosted bypass tier for the skill fetch ladder.
# CANONICAL SOURCE (vendor copies note their origin, like url-guard.sh).
#
# Full ladder (orchestrated by role docs / the agent):
#   1. WebFetch        (Claude tool, free, no JS)      — try FIRST
#   2. fetch.sh        (THIS — curl_cffi -> cloakbrowser, free, self-hosted)
#   3. firecrawl       (Claude tool, PAID)             — last resort
#
# This wrapper:
#   • validates the URL through url-guard.sh (SSRF defense) BEFORE any request
#   • runs the dedicated parsing venv python on fetch_tiered.py
#   • returns extracted markdown on stdout; with --json, meta line on stderr
#
# Usage:
#   bash lib/fetch.sh "<url>"                # light(curl_cffi) -> deep(browser)
#   bash lib/fetch.sh --json "<url>"         # + meta JSON on stderr
#   bash lib/fetch.sh --no-deep "<url>"      # curl_cffi only, never launch browser
#   bash lib/fetch.sh --deep "<url>"         # straight to stealth browser
#   PROXY via 1Password only:
#     op run --env-file=<(echo 'PROXY=op://AI-Tokens/<Item>/credential') -- \
#       bash lib/fetch.sh --proxy "$PROXY" "<url>"
#
# Exit: 0 ok | 1 blocked/empty | 2 SSRF/url-guard block | 3 deps missing
#       | 4 hard error | 64 usage error
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_PY="${PARSING_VENV:-$HOME/.claude/parsing-venv}/bin/python"
GUARD="$HERE/url-guard.sh"
PYSCRIPT="$HERE/fetch_tiered.py"

# last arg is the URL; everything before is passthrough flags
if [ "$#" -lt 1 ]; then
  echo "usage: fetch.sh [--deep|--no-deep|--json|--debug|--impersonate X|--timeout N|--proxy URL|--humanize] <url>" >&2
  exit 64
fi
URL="${!#}"

# SSRF guard (vendored url-guard.sh). Forward its stderr (the block reason) so
# legitimate-URL rejections are debuggable; only stdout (OK line) is dropped.
if [ -f "$GUARD" ]; then
  if ! bash "$GUARD" "$URL" >/dev/null; then
    echo "BLOCKED by url-guard: $URL" >&2
    exit 2
  fi
elif [ "${FETCH_ALLOW_NO_GUARD:-0}" = "1" ]; then
  echo "WARN: url-guard.sh not found — SSRF check SKIPPED (FETCH_ALLOW_NO_GUARD=1)" >&2
else
  # FAIL CLOSED: no guard beside fetch.sh and override not set.
  echo "BLOCKED: url-guard.sh not found next to fetch.sh — refusing to fetch unguarded" >&2
  echo "  (set FETCH_ALLOW_NO_GUARD=1 to override; the python layer still re-checks)" >&2
  exit 2
fi

if [ ! -x "$VENV_PY" ]; then
  echo "deps missing: parsing venv not found at $VENV_PY" >&2
  echo "  python3 -m venv ~/.claude/parsing-venv && ~/.claude/parsing-venv/bin/pip install curl_cffi trafilatura" >&2
  echo "  (optional deep tier: pip install cloakbrowser — see lib/FETCH.md)" >&2
  exit 3
fi

exec "$VENV_PY" "$PYSCRIPT" "$@"

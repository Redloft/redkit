#!/usr/bin/env bash
# fetch-doctor.sh — health-check the whole fetch stack so silent rot is caught
# before it bites (provider port change, broken dep, drifted vendor copy, dead
# proxy, missing secret). Run periodically or after an upstream update.
#
# Usage: fetch-doctor.sh [--offline]   (--offline skips network/proxy checks)
# Exit:  0 healthy (no ❌) | 1 problems found.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="${PARSING_VENV:-$HOME/.claude/parsing-venv}"
PY="$VENV/bin/python"; CFFI="$VENV/bin/curl-cffi"
OFFLINE=0; [ "${1:-}" = "--offline" ] && OFFLINE=1
FAIL=0; WARN=0
ok(){ echo "  ✅ $1"; }
warn(){ echo "  ⚠️  $1"; WARN=$((WARN+1)); }
bad(){ echo "  ❌ $1"; FAIL=$((FAIL+1)); }

echo "== deps =="
[ -x "$PY" ] && ok "venv python ($VENV)" || bad "venv python missing — python3 -m venv $VENV"
"$PY" -c 'import curl_cffi' 2>/dev/null && ok "curl_cffi: $("$PY" -c 'import curl_cffi;print(curl_cffi.__version__)' 2>/dev/null)" || bad "curl_cffi not importable (pip install curl_cffi)"
"$PY" -c 'import trafilatura' 2>/dev/null && ok "trafilatura present" || warn "trafilatura missing (extraction degrades to tag-strip)"
[ -x "$CFFI" ] && ok "curl-cffi CLI present" || warn "curl-cffi CLI missing (cffi_get falls back to plain curl)"
"$PY" -c 'import cloakbrowser' 2>/dev/null && ok "cloakbrowser (deep tier) installed" || warn "cloakbrowser not installed (deep tier degrades gracefully)"

echo "== security guards =="
if [ -f "$HERE/url-guard.sh" ]; then
  bash "$HERE/url-guard.sh" "http://localhost/" >/dev/null 2>&1 && bad "url-guard FAILED to block localhost (SSRF!)" || ok "url-guard blocks localhost"
  bash "$HERE/url-guard.sh" "https://example.com" >/dev/null 2>&1 && ok "url-guard allows public host" || warn "url-guard rejected a public host (too strict?)"
else
  bad "url-guard.sh missing next to fetch.sh (fetch.sh fails closed)"
fi

echo "== vendor sync =="
if [ -x "$HERE/check-vendor-drift.sh" ]; then
  if bash "$HERE/check-vendor-drift.sh" >/dev/null 2>&1; then ok "vendored copies in sync"; else warn "vendor DRIFT — run lib/check-vendor-drift.sh"; fi
else warn "check-vendor-drift.sh missing"; fi

echo "== secrets / proxy config =="
if command -v op >/dev/null 2>&1; then
  ok "op CLI present"
  if op item get "Evomi Residential Proxy" --vault AI-Tokens >/dev/null 2>&1; then
    ok "1Password item 'Evomi Residential Proxy' reachable"
  else warn "Evomi item not found in AI-Tokens (auto-proxy will no-op)"; fi
else warn "op CLI missing — auto-proxy can't resolve credential"; fi

echo "== playbook / telemetry =="
STATE="${REDFETCH_STATE:-$HOME/.cache/redfetch}"
if [ -f "$STATE/playbook.json" ]; then
  n=$("$PY" -c "import json;print(len(json.load(open('$STATE/playbook.json'))))" 2>/dev/null || echo '?')
  ok "playbook: $n host(s) learned ($STATE)"
else echo "  · playbook empty (no fetches recorded yet)"; fi

if [ "$OFFLINE" -eq 0 ]; then
  echo "== live network =="
  direct=$(curl -s --max-time 12 https://api.ipify.org 2>/dev/null)
  [ -n "$direct" ] && ok "direct egress OK ($direct)" || warn "no direct egress (sandboxed?)"
  if command -v op >/dev/null 2>&1 && [ -x "$CFFI" ]; then
    pip=$(op run --env-file=<(echo 'CFFI_PROXY=op://AI-Tokens/Evomi Residential Proxy/credential') -- \
      bash -c 'all_proxy="$CFFI_PROXY" "'"$CFFI"'" get https://api.ipify.org --impersonate chrome --timeout 25 2>/dev/null' 2>/dev/null)
    if [ -n "$pip" ] && [ "$pip" != "$direct" ]; then ok "residential proxy live (exit IP $pip)"
    elif [ -n "$pip" ]; then warn "proxy returned same IP as direct ($pip) — not proxying?"
    else bad "proxy not responding (check Evomi balance / endpoint / SOCKS port 1002)"; fi
  fi
else echo "== live network == (skipped: --offline)"; fi

echo
if [ "$FAIL" -gt 0 ]; then echo "DOCTOR: ❌ $FAIL problem(s), $WARN warning(s)"; exit 1
elif [ "$WARN" -gt 0 ]; then echo "DOCTOR: ⚠️  healthy with $WARN warning(s)"; exit 0
else echo "DOCTOR: ✅ all green"; exit 0; fi

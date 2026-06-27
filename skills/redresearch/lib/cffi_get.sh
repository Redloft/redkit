#!/usr/bin/env bash
# cffi_get.sh — raw HTTP GET with browser TLS/JA3 impersonation via the
# curl_cffi CLI; falls back to plain `curl` when the parsing venv is absent.
# CANONICAL SOURCE — edit HERE; vendor copies carry a VENDORED header and must
# NOT be edited in place (re-vendor from this file instead).
#
# Returns the RAW response body on stdout (NO content extraction) — use for
# JSON / autocomplete / API endpoints that TLS-fingerprint the handshake and
# block non-browser clients (e.g. Yandex/Google suggest). For arbitrary or
# user-supplied PAGE urls that need the SSRF guard + markdown extraction, use
# fetch.sh instead. Hosts passed here are expected to be FIXED constants.
#
# Usage: cffi_get.sh <url> [timeout_sec=10] [impersonate=chrome]
#        cffi_get.sh --self-test
# Exit:  0 non-empty body | 64 usage/bad-arg | else curl's rc.
set -uo pipefail

if [ "${1:-}" = "--self-test" ]; then
  out=$("$0" "https://suggest.yandex.ru/suggest-ya.cgi?v=4&part=test" 8 chrome 2>/dev/null || true)
  if printf '%s' "$out" | grep -q '^\['; then echo "✅ cffi_get self-test OK (TLS-impersonation reachable)"; exit 0
  else echo "✗ cffi_get self-test failed (no JSON body — venv/curl_cffi or network?)"; exit 1; fi
fi

URL="${1:-}"; TIMEOUT="${2:-10}"; IMP="${3:-chrome}"
[ -n "$URL" ] || { echo "usage: cffi_get.sh <url> [timeout] [impersonate] | --self-test" >&2; exit 64; }
# Validate caller-controlled args before they reach the curl-cffi CLI — keeps
# the "fixed constants" invariant and prevents CLI-arg injection via IMP/TIMEOUT.
case "$IMP" in chrome|chrome124|firefox|safari|safari_ios|edge|edge99|edge101) ;;
  *) echo "cffi_get: invalid --impersonate value: $IMP" >&2; exit 64 ;; esac
case "$TIMEOUT" in ''|*[!0-9]*) echo "cffi_get: timeout must be a positive integer: $TIMEOUT" >&2; exit 64 ;; esac

# Residential proxy:
#   • explicit: env CFFI_PROXY (inject via `op run`, NEVER hardcode), or
#   • AUTO: on a detected block (empty / anti-bot challenge) the request is
#     retried ONCE through the residential proxy — fetched on demand from
#     1Password (op read of $CFFI_PROXY_REF). Disable with CFFI_AUTOPROXY=0.
#     The secret stays in-process; it is never printed.
PROXY="${CFFI_PROXY:-}"
AUTOPROXY="${CFFI_AUTOPROXY:-1}"
PROXY_REF="${CFFI_PROXY_REF:-op://AI-Tokens/Evomi Residential Proxy/credential}"
CFFI="${PARSING_VENV:-$HOME/.claude/parsing-venv}/bin/curl-cffi"

# _is_block <body> → rc 0 if the body is empty or an anti-bot/challenge page.
_is_block() {
  [ -z "$1" ] && return 0
  printf '%s' "$1" | head -c 4000 | grep -qiE \
    'just a moment|attention required|enable javascript and cookies|cf-browser-verification|access denied|please verify you are a human|<title>sorry' && return 0
  return 1
}
# _fetch <proxyOrEmpty> → echoes body (curl_cffi, falls back to plain curl).
# The proxy is passed via ENV (all_proxy/https_proxy/http_proxy), NEVER as a
# CLI arg — so the secret never lands in argv / ps / procfs. curl_cffi (libcurl)
# and curl both honor these env vars.
_fetch() {
  local pxy="$1"
  if [ -x "$CFFI" ]; then
    if [ -n "$pxy" ]; then all_proxy="$pxy" https_proxy="$pxy" http_proxy="$pxy" "$CFFI" get "$URL" --impersonate "$IMP" --timeout "$TIMEOUT" 2>/dev/null
    else "$CFFI" get "$URL" --impersonate "$IMP" --timeout "$TIMEOUT" 2>/dev/null; fi
  elif [ -n "$pxy" ]; then all_proxy="$pxy" https_proxy="$pxy" http_proxy="$pxy" curl -s --max-time "$TIMEOUT" "$URL"
  else curl -s --max-time "$TIMEOUT" "$URL"; fi
}

# 1) primary attempt (explicit proxy if set, else direct)
out=$(_fetch "$PROXY" || true)
if ! _is_block "$out"; then printf '%s' "$out"; exit 0; fi

# 2) AUTO-PROXY: blocked & no explicit proxy & enabled → retry once via proxy.
# Use `op run` (env injection) not `op read` into a var — the latter would
# surface the secret under `bash -x`. Proxy stays in the child env, not argv.
if [ -z "$PROXY" ] && [ "$AUTOPROXY" != "0" ] && [ -n "$PROXY_REF" ] && [ -x "$CFFI" ] && command -v op >/dev/null 2>&1; then
  echo "cffi_get: blocked — auto-retry via residential proxy" >&2
  out2=$(op run --env-file=<(printf 'all_proxy=%s\nhttps_proxy=%s\nhttp_proxy=%s\n' "$PROXY_REF" "$PROXY_REF" "$PROXY_REF") -- \
    "$CFFI" get "$URL" --impersonate "$IMP" --timeout "$TIMEOUT" 2>/dev/null || true)
  if ! _is_block "$out2"; then printf '%s' "$out2"; exit 0; fi
  out="$out2"
fi

# 3) nothing clean — emit what we have (may be a challenge page) but signal failure
printf '%s' "$out"
exit 1

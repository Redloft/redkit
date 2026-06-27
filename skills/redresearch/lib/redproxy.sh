#!/usr/bin/env bash
# redproxy — run anything through the Evomi residential proxy.
# The proxy URL is injected from 1Password into the child process ENVIRONMENT
# only (CFFI_PROXY + all_proxy/https_proxy/http_proxy) — never as a CLI arg, so
# it stays out of argv/ps/procfs. Secret is never printed or written to disk.
#
# Usage:
#   redproxy                       # self-test: direct vs proxied IP + geo
#   redproxy <url>                 # fetch ONE url through the proxy (via cffi_get.sh)
#   redproxy <command> [args...]   # run ANY command proxied (curl/python/etc. auto-use all_proxy)
#
# Examples:
#   redproxy "https://suggestqueries.google.com/complete/search?client=chrome&q=test"
#   redproxy bash ~/.claude/skills/redresearch/lib/fetch.sh --json https://land-book.com/
#   redproxy curl -s https://api.ipify.org      # curl picks up all_proxy from env automatically
set -uo pipefail

# Same op:// ref bound to every proxy env var libcurl/requests/curl_cffi honor.
REF=$'CFFI_PROXY=op://AI-Tokens/Evomi Residential Proxy/credential
all_proxy=op://AI-Tokens/Evomi Residential Proxy/credential
https_proxy=op://AI-Tokens/Evomi Residential Proxy/credential
http_proxy=op://AI-Tokens/Evomi Residential Proxy/credential'
CFFI_GET="$HOME/.claude/skills/redresearch/lib/cffi_get.sh"

if [ "$#" -eq 0 ]; then
  echo "direct  IP : $(curl -s --max-time 12 https://api.ipify.org 2>/dev/null || echo '?')"
  # all_proxy is already in the child env (from op run) — no CLI proxy arg needed.
  op run --env-file=<(printf '%s' "$REF") -- bash -c '
    CFFI="${PARSING_VENV:-$HOME/.claude/parsing-venv}/bin/curl-cffi"
    ip=$("$CFFI" get https://api.ipify.org --impersonate chrome --timeout 25 2>/dev/null)
    geo=$("$CFFI" get http://ip-api.com/json --impersonate chrome --timeout 25 2>/dev/null)
    echo "proxied IP : ${ip:-<нет ответа — прокси не отдал>}"
    [ -n "$geo" ] && echo "geo        : $(printf "%s" "$geo" | jq -r "\"\(.city), \(.regionName), \(.country)\"" 2>/dev/null)"
  '
  exit 0
fi

# single bare URL → convenience: raw GET through proxy via cffi_get.sh
if [ "$#" -eq 1 ] && printf '%s' "$1" | grep -qiE '^https?://'; then
  exec op run --env-file=<(printf '%s' "$REF") -- bash "$CFFI_GET" "$1"
fi

# generic: run whatever command was given, proxied via env
exec op run --env-file=<(printf '%s' "$REF") -- "$@"

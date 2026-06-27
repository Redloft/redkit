#!/usr/bin/env bash
# Suggest adapter — Yandex + Google autocomplete. БЕЗ ключа (публичные эндпоинты).
# Даёт «хвост» и реальные формулировки запросов вокруг seed-фраз.
#
# Usage:
#   suggest.sh <seed-phrase> [--engine yandex|google|both] [--lang ru] [--expand]
#   suggest.sh --self-test
#
# Output (stdout): JSON { source:"suggest", engine, seed, keywords:[{phrase, source}] }
# --expand: рекурсивно добавляет seed + " a".." я"/"a".."z" (a-z широкий хвост).
set -euo pipefail

# Raw GET with browser TLS/JA3 impersonation (curl_cffi CLI) — Yandex/Google
# suggest fingerprint the TLS handshake and throttle/empty non-browser clients.
# Falls back to plain curl if the parsing venv is absent. (vendored helper)
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFFI_GET="$HERE/cffi_get.sh"
_get() { if [ -x "$CFFI_GET" ]; then bash "$CFFI_GET" "$1" 10 chrome 2>/dev/null; else curl -s --max-time 10 "$1"; fi; }

ENGINE="both"; LANG_="ru"; EXPAND=0
SEED="${1:-}"

if [ "$SEED" = "--self-test" ]; then
  q=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "баня москва")
  out=$(_get "https://suggest.yandex.ru/suggest-ya.cgi?v=4&part=$q" || true)
  n=$(printf '%s' "$out" | jq -r '(.[1] // [])|length' 2>/dev/null || echo 0)
  if [ "${n:-0}" -gt 0 ] 2>/dev/null; then
    echo "✅ suggest self-test OK (yandex: $n suggestions)"; exit 0
  else
    echo "✗ suggest self-test failed (no suggestions from yandex)"; exit 1
  fi
fi

[ -n "$SEED" ] || { echo "usage: suggest.sh <seed> [--engine both] [--lang ru] [--expand]" >&2; exit 64; }
shift || true
while [ "$#" -gt 0 ]; do
  case "$1" in
    --engine) ENGINE="$2"; shift 2 ;;
    --lang) LANG_="$2"; shift 2 ;;
    --expand) EXPAND=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done

# Validate caller-controlled values (else unknown engine = silent keyword_count:0,
# indistinguishable from "found nothing"; lang goes into a URL → URL-encode it).
case "$ENGINE" in yandex|google|both) ;; *) echo "unknown engine: $ENGINE (yandex|google|both)" >&2; exit 64 ;; esac

_urlenc() { python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$1"; }

_yandex() { # <phrase> → newline phrases (v=4 — чистый JSON ["q",[suggestions]])
  local q; q=$(_urlenc "$1")
  _get "https://suggest.yandex.ru/suggest-ya.cgi?v=4&part=$q" 2>/dev/null \
    | jq -r '(.[1] // [])[]?' 2>/dev/null || true
}

_google() { # <phrase> → newline phrases (client=chrome + UTF-8, иначе cp1251)
  local q; q=$(_urlenc "$1")
  local hl; hl=$(_urlenc "$LANG_")
  _get "https://suggestqueries.google.com/complete/search?client=chrome&ie=UTF-8&oe=UTF-8&hl=${hl}&q=$q" 2>/dev/null \
    | jq -r '(.[1] // [])[]?' 2>/dev/null || true
}

# Build seed list (+ a-z expansion)
seeds=("$SEED")
if [ "$EXPAND" -eq 1 ]; then
  # й included; щ/ъ/ы/ь/ё/ё omitted — words don't start with them, so suggest
  # returns nothing for "<seed> щ" etc. (wasted requests).
  for c in а б в г д е ж з и й к л м н о п р с т у ф х ц ч ш э ю я a b c d e f g h i j k l m n o p q r s t u v w x y z 0 1 2 3 4 5 6 7 8 9; do
    seeds+=("$SEED $c")
  done
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
# Throttle when expanding (up to ~128 sequential requests): a small inter-request
# pause keeps us under suggest rate-limits, and an empty-response counter warns
# (to stderr) if a large fraction came back empty — likely throttling/IP block.
THROTTLE=0; [ "$EXPAND" -eq 1 ] && THROTTLE="0.3"
req=0; empty=0
for s in "${seeds[@]}"; do
  if [ "$ENGINE" = "yandex" ] || [ "$ENGINE" = "both" ]; then
    n0=$(wc -l < "$tmp")
    _yandex "$s" | while IFS= read -r p; do [ -n "$p" ] && printf '%s\tyandex\n' "$p"; done >> "$tmp"
    req=$((req+1)); [ "$(wc -l < "$tmp")" -eq "$n0" ] && empty=$((empty+1))
  fi
  if [ "$ENGINE" = "google" ] || [ "$ENGINE" = "both" ]; then
    n0=$(wc -l < "$tmp")
    _google "$s" | while IFS= read -r p; do [ -n "$p" ] && printf '%s\tgoogle\n' "$p"; done >> "$tmp"
    req=$((req+1)); [ "$(wc -l < "$tmp")" -eq "$n0" ] && empty=$((empty+1))
  fi
  [ "$THROTTLE" != "0" ] && sleep "$THROTTLE"
done
if [ "$req" -gt 10 ] && [ "$((empty*100/req))" -gt 30 ]; then
  echo "WARN: suggest — ${empty}/${req} requests returned empty (>30%); likely rate-limited/IP-blocked" >&2
fi

# Dedup by normalized phrase, emit JSON
jq -R -s --arg seed "$SEED" --arg engine "$ENGINE" '
  split("\n") | map(select(length>0) | split("\t") | {phrase:.[0], source:("suggest:"+.[1])})
  | unique_by(.phrase|ascii_downcase|gsub("\\s+";" "))
  | {source:"suggest", engine:$engine, seed:$seed, keyword_count:length, keywords:.}
' "$tmp"

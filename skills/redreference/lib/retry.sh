#!/usr/bin/env bash
# retry.sh — bounded retry with exponential backoff + jitter, honoring a
# server Retry-After (plan judge#7). The circuit-breaker is the caller's job:
# retry.sh exits 1 after max_attempts so an adapter can count consecutive
# failures and stop itself for the round.
#
# Contract with the wrapped command:
#   • exit 0            → success; its stdout is forwarded, retry.sh exits 0.
#   • exit non-zero     → failure; retry with backoff.
#   • on HTTP 429 / rate-limit the command SHOULD print "RETRY_AFTER=<seconds>"
#     to stderr — retry.sh then sleeps exactly that long instead of backoff.
#
# Usage:
#   retry.sh [--max N=3] [--base SECS=1] [--cap SECS=30] -- <cmd> [args...]
# Exit: 0 success | 1 exhausted (circuit-breaker) | 64 usage
set -uo pipefail

MAX=3; BASE=1; CAP=30
while [ "$#" -gt 0 ]; do
  case "$1" in
    --max) MAX="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --cap) CAP="$2"; shift 2 ;;
    --) shift; break ;;
    *) echo "retry.sh: unknown arg $1" >&2; exit 64 ;;
  esac
done
[ "$#" -ge 1 ] || { echo "usage: retry.sh [--max N] [--base S] [--cap S] -- <cmd...>" >&2; exit 64; }

OUT_TMP="$(mktemp "${TMPDIR:-/tmp}/redref-retry.XXXXXX")"
ERR_TMP="$(mktemp "${TMPDIR:-/tmp}/redref-retry.XXXXXX")"
trap 'rm -f "$OUT_TMP" "$ERR_TMP"' EXIT

attempt=1
while :; do
  if "$@" >"$OUT_TMP" 2>"$ERR_TMP"; then
    cat "$OUT_TMP"
    exit 0
  fi
  # forward the command's stderr (already secret-free per its own scrubbing)
  cat "$ERR_TMP" >&2
  if [ "$attempt" -ge "$MAX" ]; then
    echo "retry.sh: exhausted after $MAX attempts (circuit-breaker)" >&2
    exit 1
  fi
  # honor Retry-After if the command surfaced it
  ra=$(grep -oE 'RETRY_AFTER=[0-9]+' "$ERR_TMP" | head -1 | cut -d= -f2 || true)
  if [ -n "$ra" ]; then
    [ "$ra" -gt "$CAP" ] && ra="$CAP"
    echo "retry.sh: honoring Retry-After=${ra}s (attempt $attempt/$MAX)" >&2
    sleep "$ra"
  else
    # exp backoff = base * 2^(attempt-1), capped, + jitter [0,base)
    delay=$(( BASE * (1 << (attempt - 1)) ))
    [ "$delay" -gt "$CAP" ] && delay="$CAP"
    jitter=$(( RANDOM % (BASE > 0 ? BASE : 1) ))
    delay=$(( delay + jitter ))
    echo "retry.sh: backoff ${delay}s (attempt $attempt/$MAX)" >&2
    sleep "$delay"
  fi
  attempt=$(( attempt + 1 ))
done

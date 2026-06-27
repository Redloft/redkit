#!/usr/bin/env bash
# with-lock.sh — run a command holding an advisory lock on a shared file
# (plan D5 / concurrency-invariant). Used for read-modify-write on shared,
# cross-run files: captures-index.json, visual-taste-profile.json.
#
# Prefers flock(1) when present (Linux / brew); falls back to a portable
# mkdir-lock (macOS ships no flock). Acquire timeout 10s → fail-loud
# LOCK_TIMEOUT (exit 75 EX_TEMPFAIL), so the caller can queue (e.g. the
# *.index-pending merge path) instead of corrupting state.
#
# Usage:
#   with-lock.sh <target_file> -- <cmd> [args...]
#   (lock object is <target_file>.lock)
# Exit: <cmd>'s exit code | 64 usage | 75 lock timeout
set -uo pipefail

TARGET="${1:-}"
if [ -z "$TARGET" ] || [ "${2:-}" != "--" ]; then
  echo "usage: with-lock.sh <target_file> -- <cmd> [args...]" >&2
  exit 64
fi
shift 2   # drop target + '--'
if [ "$#" -lt 1 ]; then echo "with-lock.sh: no command given" >&2; exit 64; fi

LOCK="${TARGET}.lock"
TIMEOUT="${REDREFERENCE_LOCK_TIMEOUT:-10}"

if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK"
  if ! flock -w "$TIMEOUT" 9; then
    echo "LOCK_TIMEOUT target=$TARGET timeout=${TIMEOUT}s" >&2
    exit 75
  fi
  "$@"; rc=$?
  flock -u 9 2>/dev/null || true
  exit "$rc"
else
  # Portable mkdir-lock fallback (no flock on macOS).
  lock_dir="${LOCK}.d"
  waited=0
  while ! mkdir "$lock_dir" 2>/dev/null; do
    # stale-lock break: if holder pid recorded and dead, reclaim
    if [ -f "$lock_dir/pid" ]; then
      hp=$(cat "$lock_dir/pid" 2>/dev/null || echo "")
      if [ -n "$hp" ] && ! kill -0 "$hp" 2>/dev/null; then rm -rf "$lock_dir" 2>/dev/null; continue; fi
    fi
    waited=$((waited + 1))
    if [ "$waited" -gt $((TIMEOUT * 10)) ]; then
      echo "LOCK_TIMEOUT target=$TARGET timeout=${TIMEOUT}s" >&2
      exit 75
    fi
    sleep 0.1
  done
  echo "$$" > "$lock_dir/pid" 2>/dev/null || true
  "$@"; rc=$?
  rm -rf "$lock_dir" 2>/dev/null || true
  exit "$rc"
fi

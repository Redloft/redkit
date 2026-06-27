#!/usr/bin/env bash
# export-redloft.sh — Stage E: hand a redreference run's taste to redloft Phase 6.
# Merges into visual-taste-profile.json + (re)writes reference-likes.md with
# backup-before-write, JSON validation, atomic swap, all under flock (plan §5).
#
# Graceful sentinel: 0 likes / no taste-profile → DO NOT touch the target
# (redloft Design proceeds on the Briefing profile). Broken merge →
# TASTE_MERGE_FAILED, target left intact.
#
# Usage: export-redloft.sh <redreference_run_dir> <visual-taste-profile.json> <reference-likes.md>
# Exit: 0 done|skipped | 1 merge failed | 64 usage
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# ── internal: the actual merge, runs UNDER the lock (re-invoked via with-lock) ──
if [ "${1:-}" = "__locked_merge" ]; then
  RUN_DIR="$2"; TARGET="$3"; MD="$4"
  tmp="$TARGET.tmp.$$"; mdtmp="$MD.tmp.$$"
  existing="-"; [ -f "$TARGET" ] && existing="$TARGET"
  if ! node "$HERE/export-redloft.js" "$RUN_DIR" "$existing" "$tmp" "$mdtmp" >/dev/null 2>&1; then
    rm -f "$tmp" "$mdtmp"; echo "TASTE_MERGE_FAILED: export-redloft.js error" >&2; exit 1
  fi
  if ! jq -e . "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp" "$mdtmp"; echo "TASTE_MERGE_FAILED: merged JSON invalid" >&2; exit 1
  fi
  [ -f "$TARGET" ] && cp "$TARGET" "$TARGET.bak"          # backup-before-write
  if ! mv -f "$tmp" "$TARGET"; then
    [ -f "$TARGET.bak" ] && cp "$TARGET.bak" "$TARGET"
    rm -f "$tmp" "$mdtmp"; echo "TASTE_MERGE_FAILED: swap failed (restored)" >&2; exit 1
  fi
  mv -f "$mdtmp" "$MD"
  exit 0
fi

RUN_DIR="${1:-}"; TARGET="${2:-}"; MD="${3:-}"
[ -n "$RUN_DIR" ] && [ -n "$TARGET" ] && [ -n "$MD" ] || { echo "usage: export-redloft.sh <run_dir> <visual-taste.json> <reference-likes.md>" >&2; exit 64; }
PROF="$RUN_DIR/captures/taste-profile.json"

LIKES=$( [ -f "$PROF" ] && jq -r '.likes // 0' "$PROF" 2>/dev/null || echo 0 )
if [ "${LIKES:-0}" -eq 0 ]; then
  echo "TASTE_EMPTY: 0 likes — visual-taste-profile left untouched (graceful)"
  exit 0
fi

mkdir -p "$(dirname "$TARGET")" "$(dirname "$MD")"
RC=0
bash "$HERE/with-lock.sh" "$TARGET" -- bash "$0" __locked_merge "$RUN_DIR" "$TARGET" "$MD" || RC=$?
[ "$RC" -eq 0 ] || exit "$RC"
SUMMARY=$(jq -c '{references:(.references|length),mood:(.mood|length),anti:(.anti_references|length)}' "$TARGET" 2>/dev/null)
echo "TASTE_MERGED: $SUMMARY → $(basename "$TARGET") + $(basename "$MD")"

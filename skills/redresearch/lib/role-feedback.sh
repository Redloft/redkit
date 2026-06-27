#!/usr/bin/env bash
# role-feedback.sh — capture structured feedback about a redresearch role's
# output, to later drive prompt solidification (see SOLIDIFY.md). Mirrors the
# established /panel-solidify · /redloft-solidify feedback→solidify loop.
#
# Usage:
#   role-feedback.sh <role> "<what went wrong / could be better>"   # issue
#   role-feedback.sh <role> "<what worked well>" --good             # positive
#   role-feedback.sh --list [role]                                  # show counts
#
# Roles: deep-reader | source-hunter | scoper | synth | judge (any name ok).
# Appends one JSON line per note to feedback/<role>.jsonl (under the skill root).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FBDIR="$HERE/../feedback"

if [ "${1:-}" = "--list" ]; then
  [ -d "$FBDIR" ] || { echo "no feedback yet"; exit 0; }
  for f in "$FBDIR"/*.jsonl; do
    [ -e "$f" ] || continue
    r=$(basename "$f" .jsonl)
    [ -n "${2:-}" ] && [ "$2" != "$r" ] && continue
    n=$(wc -l < "$f" | tr -d ' ')
    good=$(grep -c '"kind":"good"' "$f" 2>/dev/null || echo 0)
    echo "  $r: $n note(s) ($good good / $((n-good)) issue)"
  done
  exit 0
fi

role="${1:-}"; note="${2:-}"; kind="issue"
[ "${3:-}" = "--good" ] && kind="good"
[ -n "$role" ] && [ -n "$note" ] || { echo "usage: role-feedback.sh <role> \"<note>\" [--good] | --list [role]" >&2; exit 64; }

mkdir -p "$FBDIR"
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
jq -nc --arg r "$role" --arg n "$note" --arg k "$kind" --arg t "$ts" \
  '{ts:$t, role:$r, kind:$k, note:$n}' >> "$FBDIR/$role.jsonl"
echo "✅ logged $kind feedback for '$role' → feedback/$role.jsonl"
echo "   ($(wc -l < "$FBDIR/$role.jsonl" | tr -d ' ') total; run a solidify pass when ≥5 — see lib/SOLIDIFY.md)"

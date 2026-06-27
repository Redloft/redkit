#!/usr/bin/env bash
# panel-feedback — appends per-role feedback to feedback/<role>.jsonl
# (private, gitignored — never leaves user's machine unless they explicitly
# /panel-share-prompt).
#
# Usage:
#   feedback.sh <role> <useful> <reason> [run_id] [plan_hash]
#
# Args:
#   role        — one of: scoper architect qa security frontend backend data ops judge
#   useful      — true | false | noise (последнее = роль помечается как irrelevant)
#   reason      — short reason (max 500 chars) — sanitize: НЕ должно содержать секретов
#   run_id      — optional, correlates с конкретным run (из metadata.json)
#   plan_hash   — optional, sha256 первых 200 chars плана (для grouping similar plans)
set -euo pipefail

ROLE="${1:?usage: feedback.sh <role> <useful> <reason> [run_id] [plan_hash]}"
USEFUL="${2:?need useful=true|false|noise}"
REASON="${3:?need reason}"
RUN_ID="${4:-}"
PLAN_HASH="${5:-}"

VALID_ROLES="scoper architect qa security frontend backend data ops judge"
if ! echo "$VALID_ROLES" | grep -qw "$ROLE"; then
  echo "✗ invalid role: $ROLE" >&2
  echo "  valid: $VALID_ROLES" >&2
  exit 1
fi

case "$USEFUL" in
  true|false|noise) ;;
  *) echo "✗ useful must be true|false|noise (got: $USEFUL)" >&2; exit 1 ;;
esac

# Sanitize reason — strip newlines, cap length
REASON_CLEAN=$(printf '%s' "$REASON" | tr -d '\r' | tr '\n' ' ' | head -c 500)

# Determine skill root + ensure feedback dir
SKILL_ROOT="${PLAN_PANEL_SKILL_ROOT:-$HOME/.claude/skills/plan-panel}"
FEEDBACK_DIR="$SKILL_ROOT/feedback"
mkdir -p "$FEEDBACK_DIR"

# Append JSONL entry — atomic write через temp + cat append
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
LINE=$(jq -nc \
  --arg ts "$TS" \
  --arg role "$ROLE" \
  --arg useful "$USEFUL" \
  --arg reason "$REASON_CLEAN" \
  --arg run_id "$RUN_ID" \
  --arg plan_hash "$PLAN_HASH" \
  '{ts: $ts, role: $role, useful: ($useful == "true"), useful_raw: $useful, reason: $reason, run_id: ($run_id // null), plan_hash: ($plan_hash // null)}')

echo "$LINE" >> "$FEEDBACK_DIR/${ROLE}.jsonl"

# Count current feedback entries for this role
COUNT=$(wc -l < "$FEEDBACK_DIR/${ROLE}.jsonl" | tr -d ' ')
echo "✓ feedback recorded for role '$ROLE' ($USEFUL)"
echo "  Total entries for $ROLE: $COUNT"

# Solidify threshold check
THRESHOLD="${PLAN_PANEL_SOLIDIFY_THRESHOLD:-10}"
if [ "$COUNT" -ge "$THRESHOLD" ]; then
  echo ""
  echo "💡 Tip: $COUNT entries для $ROLE >= threshold ($THRESHOLD)."
  echo "   Run '/panel-solidify role:$ROLE' to propose role.md improvements"
  echo "   (Or set PLAN_PANEL_SOLIDIFY_THRESHOLD higher to suppress this hint)"
fi

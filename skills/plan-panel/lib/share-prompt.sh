#!/usr/bin/env bash
# panel-share-prompt — собирает PR-ready bundle для contribute улучшения роли upstream.
# Включает только: diff role.md + abstract metrics. НЕ включает raw feedback (которое
# может содержать sensitive plan content).
#
# Usage:
#   share-prompt.sh <role> [--dry-run]
#
# Creates: /tmp/redplan-share-<role>-<ts>/
#   ├── role-diff.patch       # git diff между upstream main и local roles/<role>.md
#   ├── abstract-metrics.json # без raw feedback: counters + categories
#   ├── PR-body.md            # готовый текст PR description
#   └── README.txt            # как запушить как PR
set -euo pipefail

ROLE="${1:?usage: share-prompt.sh <role> [--dry-run]}"
DRY_RUN=false
[ "${2:-}" = "--dry-run" ] && DRY_RUN=true

VALID_ROLES="scoper architect qa security frontend backend data ops judge"
if ! echo "$VALID_ROLES" | grep -qw "$ROLE"; then
  echo "✗ invalid role: $ROLE" >&2
  exit 1
fi

SKILL_ROOT="${PLAN_PANEL_SKILL_ROOT:-$HOME/.claude/skills/plan-panel}"
ROLE_FILE="$SKILL_ROOT/roles/${ROLE}.md"
PROCESSED_DIR="$SKILL_ROOT/feedback/_processed"
UPSTREAM_URL="${REDPLAN_REPO_URL:-https://github.com/Redloft/redplan.git}"

[ -f "$ROLE_FILE" ] || { echo "✗ role file missing: $ROLE_FILE" >&2; exit 1; }

# Need git in skill root для diff
if [ ! -d "$SKILL_ROOT/.git" ]; then
  echo "✗ $SKILL_ROOT is not a git repo. Install via install.sh to enable sharing." >&2
  exit 1
fi

TS=$(date +%Y-%m-%d_%H-%M-%S)
OUT_DIR="/tmp/redplan-share-${ROLE}-${TS}"
mkdir -p "$OUT_DIR"

# Fetch latest upstream main to diff against
echo "→ fetching latest upstream..."
git -C "$SKILL_ROOT" fetch origin main --quiet 2>/dev/null || {
  echo "⚠ couldn't fetch origin; diff будет против last-known main"
}

# Generate role.md diff
git -C "$SKILL_ROOT" diff origin/main -- "roles/${ROLE}.md" > "$OUT_DIR/role-diff.patch" 2>/dev/null || {
  # Fallback if no origin/main known
  git -C "$SKILL_ROOT" diff HEAD -- "roles/${ROLE}.md" > "$OUT_DIR/role-diff.patch"
}

if [ ! -s "$OUT_DIR/role-diff.patch" ]; then
  echo "⚠ no changes to roles/${ROLE}.md vs upstream. Nothing to share." >&2
  rm -rf "$OUT_DIR"
  exit 0
fi

# Abstract metrics — counters + categories, БЕЗ raw reason text
ABSTRACT='{"role":"'"$ROLE"'","processed_feedback_buckets":[]}'
if [ -d "$PROCESSED_DIR" ]; then
  for f in "$PROCESSED_DIR"/${ROLE}.*.jsonl; do
    [ -f "$f" ] || continue
    # Aggregate counts by useful (true/false/noise) — без raw reason
    BUCKET=$(jq -s '{batch: (input_filename | split("/") | last), total: length, useful_true: ([.[] | select(.useful == true)] | length), useful_false: ([.[] | select(.useful == false)] | length), noise: ([.[] | select(.useful_raw == "noise")] | length)}' "$f")
    ABSTRACT=$(echo "$ABSTRACT" | jq --argjson b "$BUCKET" '.processed_feedback_buckets += [$b]')
  done
fi
echo "$ABSTRACT" | jq '.' > "$OUT_DIR/abstract-metrics.json"

# PR body template
LINES_ADDED=$(grep -c '^+' "$OUT_DIR/role-diff.patch" 2>/dev/null || echo 0)
LINES_REMOVED=$(grep -c '^-' "$OUT_DIR/role-diff.patch" 2>/dev/null || echo 0)
TOTAL_FEEDBACK=$(jq '[.processed_feedback_buckets[].total] | add // 0' "$OUT_DIR/abstract-metrics.json")

cat > "$OUT_DIR/PR-body.md" <<EOF
## Role improvement: \`${ROLE}\`

Solidified role prompt based on accumulated local usage feedback.

### Stats
- Lines added: $LINES_ADDED
- Lines removed: $LINES_REMOVED
- Source feedback batches: $(jq '.processed_feedback_buckets | length' "$OUT_DIR/abstract-metrics.json")
- Total feedback events: $TOTAL_FEEDBACK

### What changed (please fill in)

<!--
Describe in 2-3 sentences:
- Какие findings часто помечались noise → удалены/смягчены?
- Какие edge cases часто пропускались → добавлены в checklist?
- Какие false positives часто били → калибровка severity?

⚠️ DO NOT paste raw plan content или конкретные finding bodies — это может содержать sensitive info.
-->

### Regression check

- [ ] Запустил \`lib/run-golden.sh ${ROLE}\` локально — все fixtures проходят
- [ ] Сравнил before/after на ≥3 реальных планах разной сложности

### Metrics (abstract)

\`\`\`json
$(cat "$OUT_DIR/abstract-metrics.json")
\`\`\`

EOF

# README for user
cat > "$OUT_DIR/README.txt" <<EOF
PR bundle для роли '$ROLE' готов в этой директории.

Что внутри:
  role-diff.patch       — git diff role.md от upstream main
  abstract-metrics.json — agregated metrics без raw feedback
  PR-body.md            — шаблон описания PR (заполни секцию "What changed")

Как запушить:

  cd ~/.claude/skills/plan-panel
  # Создай feature branch
  git checkout -b improve-${ROLE}-${TS}

  # Diff уже применён локально в твоём roles/${ROLE}.md
  git add roles/${ROLE}.md
  git commit -m "Improve ${ROLE} role checklist based on usage feedback"

  # Push в твой fork (нужен git remote 'fork')
  git push fork improve-${ROLE}-${TS}

  # Открой PR на GitHub:
  # Заполни PR-body.md содержимым (секция "What changed")
  gh pr create --repo Redloft/redplan --base main \\
    --title "Improve ${ROLE} role" \\
    --body-file "$OUT_DIR/PR-body.md"

⚠️ ВАЖНО:
  - НЕ включай raw feedback (feedback/${ROLE}.jsonl) — он gitignored по причине: может содержать sensitive plan content
  - НЕ копируй plain reason из feedback в PR description — обобщай паттерны абстрактно
EOF

if [ "$DRY_RUN" = true ]; then
  echo "✓ DRY RUN — bundle prepared в $OUT_DIR"
  echo "  Просмотри files; никакие git changes не сделаны"
else
  echo "✓ Bundle ready: $OUT_DIR"
  echo
  echo "Next steps:"
  echo "  1. Open $OUT_DIR/PR-body.md — заполни секцию 'What changed'"
  echo "  2. Прочти $OUT_DIR/README.txt — там инструкции по push + PR create"
  echo "  3. Если что-то ломаешь — \"rm -rf $OUT_DIR\" чтобы выбросить bundle"
fi

#!/usr/bin/env bash
# Создаёт dual persistence: project-local + central mirror в ClaudeCore.
# Usage: persist.sh <cwd> <plan_slug>
# Echoes: <project_dir>|<central_dir>|<timestamp>
#
# Hardened: set -euo pipefail, strict quoting, input validation, lock-free
# (concurrent calls с разным slug безопасны; одинаковый slug дискриминируется TS).
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: persist.sh <cwd> <plan_slug>" >&2
  exit 64  # EX_USAGE
fi

CWD="$1"
SLUG="$2"

# Validate cwd
if [ ! -d "$CWD" ]; then
  echo "✗ cwd not a directory: $CWD" >&2
  exit 1
fi

# Validate slug — only [a-z0-9-], length 1-60
if ! printf '%s' "$SLUG" | grep -qE '^[a-z0-9-]{1,60}$'; then
  echo "✗ invalid slug (must match ^[a-z0-9-]{1,60}$): $SLUG" >&2
  exit 1
fi

TS=$(date +%Y-%m-%d_%H-%M-%S)
DIRNAME="${TS}-${SLUG}"

# Project slug: basename cwd, sanitized
PROJECT=$(basename "$CWD" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g')
[ -z "$PROJECT" ] && PROJECT="unknown"

PROJECT_DIR="$CWD/.plan-panel/$DIRNAME"

# Central root: env override > $CLAUDECORE_PATH > ~/.plan-panel-central
if [ -n "${PLAN_PANEL_CENTRAL:-}" ]; then
  CENTRAL_ROOT="$PLAN_PANEL_CENTRAL/$PROJECT"
elif [ -n "${CLAUDECORE_PATH:-}" ]; then
  CENTRAL_ROOT="$CLAUDECORE_PATH/plan-panel/$PROJECT"
else
  CENTRAL_ROOT="$HOME/.plan-panel-central/$PROJECT"
fi
CENTRAL_DIR="$CENTRAL_ROOT/$DIRNAME"

# Create dirs (idempotent)
mkdir -p "$PROJECT_DIR" "$CENTRAL_DIR"

# Symlink central → project (best-effort — не блокируем если symlink fails, e.g. на cloud-synced FS)
# Single source of truth: PROJECT_DIR. CENTRAL — best-effort replica для cross-project аналитики.
ln -sfn "$PROJECT_DIR" "$CENTRAL_DIR/_project_link" 2>/dev/null || true

# Начальный checkpoint (DESIGN-foundation §2, DoD Stage 0). run_type — 3-й арг, default plan-review.
# Best-effort: если checkpoint.sh недоступен, persist всё равно успешен (не блокируем).
RUN_TYPE="${3:-plan-review}"
CKPT="$(dirname "$0")/checkpoint.sh"
if [ -f "$CKPT" ]; then
  bash "$CKPT" init "$PROJECT_DIR" "$RUN_TYPE" "$(bash "$CKPT" slug "$SLUG")" 2>/dev/null || true
fi

printf '%s|%s|%s\n' "$PROJECT_DIR" "$CENTRAL_DIR" "$TS"

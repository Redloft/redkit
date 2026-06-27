#!/usr/bin/env bash
# persist.sh (finalize) — dual persistence для /finalize (DESIGN §secrets, §ops).
# ОТЛИЧИЯ от plan-panel/persist.sh:
#   - dir: <cwd>/.finalize/<ts>-<slug>/
#   - central mirror = METADATA-ONLY (diff.patch/reviews с кодом туда НЕ копируются — sensitive)
#   - checkpoint run_type=finalize
#
# Usage: persist.sh <cwd> <slug>
# Echoes: <project_dir>|<central_dir>|<timestamp>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

if [ "$#" -lt 2 ]; then echo "usage: persist.sh <cwd> <slug>" >&2; exit 64; fi
CWD="$1"; SLUG="$2"
[ -d "$CWD" ] || { echo "✗ cwd not a directory: $CWD" >&2; exit 1; }
printf '%s' "$SLUG" | grep -qE '^[a-z0-9-]{1,60}$' || { echo "✗ invalid slug: $SLUG" >&2; exit 1; }

TS=$(date +%Y-%m-%d_%H-%M-%S)
DIRNAME="${TS}-${SLUG}"
PROJECT=$(basename "$CWD" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'); [ -z "$PROJECT" ] && PROJECT="unknown"

PROJECT_DIR="$CWD/.finalize/$DIRNAME"
if [ -n "${FINALIZE_CENTRAL:-}" ]; then CENTRAL_ROOT="$FINALIZE_CENTRAL/$PROJECT"
elif [ -n "${CLAUDECORE_PATH:-}" ]; then CENTRAL_ROOT="$CLAUDECORE_PATH/finalize/$PROJECT"
else CENTRAL_ROOT="$HOME/.finalize-central/$PROJECT"; fi
CENTRAL_DIR="$CENTRAL_ROOT/$DIRNAME"

mkdir -p "$PROJECT_DIR" "$CENTRAL_DIR"

# checkpoint (run_type=finalize) в canonical PROJECT_DIR
CKPT="$HERE/checkpoint.sh"
[ -f "$CKPT" ] && bash "$CKPT" init "$PROJECT_DIR" finalize "$(bash "$CKPT" slug "$SLUG")" 2>/dev/null || true

# .gitignore guard: .finalize/ не должна попадать в git (diff.patch sensitive)
GI="$CWD/.gitignore"
if [ -f "$GI" ] && ! grep -qxF '.finalize/' "$GI" 2>/dev/null; then
  printf '\n.finalize/\n' >> "$GI" 2>/dev/null || true
fi

# Central = METADATA-ONLY: маркер, что код сюда не реплицируется (§secrets §5)
printf '%s\n' "metadata-only mirror — diff.patch/reviews НЕ копируются (sensitive). Canonical: $PROJECT_DIR" \
  > "$CENTRAL_DIR/README.txt" 2>/dev/null || true

printf '%s|%s|%s\n' "$PROJECT_DIR" "$CENTRAL_DIR" "$TS"

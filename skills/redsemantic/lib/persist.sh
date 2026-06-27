#!/usr/bin/env bash
# redsemantic run dir provisioning. Local-first: канонический путь —
# ~/Library/Application Support/redsemantic/runs/<TS>-<slug>/, ВНЕ Yandex.Disk
# (C1 data residency: собранная семантика/частотности не синкаются в RU cloud).
#
# Usage: persist.sh <slug>
# Echoes: <run_dir>|<timestamp>
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: persist.sh <slug>" >&2
  exit 64
fi

SLUG="$1"

# Validate slug — only [a-z0-9-], length 1-60 (зеркало redresearch/redplan)
if ! printf '%s' "$SLUG" | grep -qE '^[a-z0-9-]{1,60}$'; then
  echo "✗ invalid slug (must match ^[a-z0-9-]{1,60}$): $SLUG" >&2
  exit 1
fi

# Canonical data root — env override > macOS App Support
if [ -n "${REDSEMANTIC_DATA_DIR:-}" ]; then
  DATA_ROOT="$REDSEMANTIC_DATA_DIR"
else
  DATA_ROOT="$HOME/Library/Application Support/redsemantic"
fi

# Sanity check: DATA_ROOT NOT inside CLAUDECORE_PATH (Yandex.Disk) — C1 guard
if [ -n "${CLAUDECORE_PATH:-}" ]; then
  case "$DATA_ROOT" in
    "$CLAUDECORE_PATH"*)
      echo "✗ REFUSED: REDSEMANTIC_DATA_DIR is inside Yandex.Disk ($CLAUDECORE_PATH)" >&2
      echo "  This would sync harvested semantics to RU cloud. Set REDSEMANTIC_DATA_DIR elsewhere." >&2
      exit 2
      ;;
  esac
fi

mkdir -p "$DATA_ROOT/runs" "$DATA_ROOT/cache" "$DATA_ROOT/inbox" "$DATA_ROOT/processed"

TS=$(date +%Y-%m-%d_%H-%M-%S)
RUN_DIR="$DATA_ROOT/runs/${TS}-${SLUG}"

if [ -e "$RUN_DIR" ]; then
  echo "✗ run dir already exists: $RUN_DIR" >&2
  exit 3
fi

# keywords/ — per-source harvested JSON; phases/ — per-phase outputs
mkdir -p "$RUN_DIR/keywords" "$RUN_DIR/phases"

printf '%s|%s\n' "$RUN_DIR" "$TS"

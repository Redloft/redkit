#!/usr/bin/env bash
# redresearch run dir provisioning. Local-first: канонический путь —
# ~/Library/Application Support/redresearch/runs/<TS>-<slug>/, ВНЕ Yandex.Disk
# (C1 data residency: scraped content не должен синкаться в RU cloud).
#
# Usage: persist.sh <slug>
# Echoes: <run_dir>|<timestamp>
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: persist.sh <slug>" >&2
  exit 64
fi

SLUG="$1"

# Validate slug — only [a-z0-9-], length 1-60 (same regex as redplan)
if ! printf '%s' "$SLUG" | grep -qE '^[a-z0-9-]{1,60}$'; then
  echo "✗ invalid slug (must match ^[a-z0-9-]{1,60}$): $SLUG" >&2
  exit 1
fi

# Canonical data root — env override > macOS App Support
if [ -n "${REDRESEARCH_DATA_DIR:-}" ]; then
  DATA_ROOT="$REDRESEARCH_DATA_DIR"
else
  DATA_ROOT="$HOME/Library/Application Support/redresearch"
fi

# Sanity check: DATA_ROOT NOT inside CLAUDECORE_PATH (Yandex.Disk) — C1 guard
if [ -n "${CLAUDECORE_PATH:-}" ]; then
  case "$DATA_ROOT" in
    "$CLAUDECORE_PATH"*)
      echo "✗ REFUSED: REDRESEARCH_DATA_DIR is inside Yandex.Disk ($CLAUDECORE_PATH)" >&2
      echo "  This would sync scraped content to RU cloud. Set REDRESEARCH_DATA_DIR elsewhere." >&2
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

mkdir -p "$RUN_DIR/sources" "$RUN_DIR/phases"

printf '%s|%s\n' "$RUN_DIR" "$TS"

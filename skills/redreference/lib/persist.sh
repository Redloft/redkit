#!/usr/bin/env bash
# redreference run dir provisioning. Local-first: канонический путь —
# ~/Library/Application Support/redreference/runs/<TS>-<slug>/, ВНЕ Yandex.Disk
# (C1 data residency: scraped design-references не должны синкаться в RU cloud).
#
# Mirrors redresearch/lib/persist.sh but with redreference-specific run layout
# (captures/screenshots/page/phases). NOT a vendored copy — skill-specific.
#
# Usage: persist.sh <slug>
# Echoes: <run_dir>|<timestamp>
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: persist.sh <slug>" >&2
  exit 64
fi

SLUG="$1"

# Validate slug — only [a-z0-9-], length 1-60 (same regex as redresearch/redplan)
if ! printf '%s' "$SLUG" | grep -qE '^[a-z0-9-]{1,60}$'; then
  echo "✗ invalid slug (must match ^[a-z0-9-]{1,60}$): $SLUG" >&2
  exit 1
fi

# Canonical data root — env override > macOS App Support
if [ -n "${REDREFERENCE_DATA_DIR:-}" ]; then
  DATA_ROOT="$REDREFERENCE_DATA_DIR"
else
  DATA_ROOT="$HOME/Library/Application Support/redreference"
fi

# Sanity check: DATA_ROOT NOT inside CLAUDECORE_PATH (Yandex.Disk) — C1 guard.
# Canonicalize both (resolve symlinks/relative) so a symlink or `..` path that
# resolves INTO Yandex.Disk is still caught (os.path.realpath handles non-existent tails).
if [ -n "${CLAUDECORE_PATH:-}" ]; then
  _canon() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null || printf '%s' "$1"; }
  DR_CANON=$(_canon "$DATA_ROOT"); CC_CANON=$(_canon "$CLAUDECORE_PATH")
  case "$DR_CANON/" in
    "$CC_CANON/"*)
      echo "✗ REFUSED: REDREFERENCE_DATA_DIR resolves inside Yandex.Disk ($CLAUDECORE_PATH)" >&2
      echo "  This would sync scraped design content to RU cloud. Set REDREFERENCE_DATA_DIR elsewhere." >&2
      exit 2
      ;;
  esac
fi

mkdir -p "$DATA_ROOT/runs" "$DATA_ROOT/cache"

TS=$(date +%Y-%m-%d_%H-%M-%S)
RUN_DIR="$DATA_ROOT/runs/${TS}-${SLUG}"

if [ -e "$RUN_DIR" ]; then
  echo "✗ run dir already exists: $RUN_DIR" >&2
  exit 3
fi

# redreference layout: captures (jsonl + committed rounds), screenshots,
# page (interactive HTML + state), phases (WAL pending/committed)
mkdir -p "$RUN_DIR/captures" "$RUN_DIR/screenshots" "$RUN_DIR/page" "$RUN_DIR/phases"

printf '%s|%s\n' "$RUN_DIR" "$TS"

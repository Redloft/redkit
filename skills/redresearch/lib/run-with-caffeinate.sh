#!/usr/bin/env bash
# W4 caffeinate wrapper: предотвращает sleep мака на время heavy/ultra runs.
# Динамический timeout из scoper.eta_seconds + 30% buffer.
# Flags: -d (display) -i (idle) -m (disk) -s (system)
#
# Usage: run-with-caffeinate.sh <run_dir>
set -euo pipefail

RUN_DIR="${1:-}"
[ -n "$RUN_DIR" ] && [ -d "$RUN_DIR" ] || { echo "usage: $0 <run_dir>"; exit 64; }

SPEC="$RUN_DIR/run-spec.json"
[ -r "$SPEC" ] || { echo "missing run-spec.json"; exit 3; }

MODE=$(jq -r '.mode' "$SPEC")
ETA=$(jq -r '.scoper.estimated_seconds // 0' "$SPEC")

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKER="$SCRIPT_DIR/../workflow/worker.sh"

case "$MODE" in
  lite)
    # Synchronous, no caffeinate (short job)
    exec "$WORKER" --run-dir "$RUN_DIR"
    ;;
  standard|heavy|ultra)
    # Add 30% buffer, clamp to mode defaults
    case "$MODE" in
      standard) DEFAULT=600 ;;
      heavy) DEFAULT=1800 ;;
      ultra) DEFAULT=3600 ;;
    esac
    if [ "$ETA" -gt 0 ]; then
      TIMEOUT=$(( ETA * 13 / 10 ))
    else
      TIMEOUT="$DEFAULT"
    fi
    # Cap at 90 min absolute max
    [ "$TIMEOUT" -gt 5400 ] && TIMEOUT=5400
    exec caffeinate -dims -t "$TIMEOUT" "$WORKER" --run-dir "$RUN_DIR"
    ;;
  *)
    echo "unknown mode: $MODE"
    exit 3
    ;;
esac

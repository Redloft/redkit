#!/usr/bin/env bash
# redloft Project Context provisioning. Local-first (DR-8): канонический путь —
# ~/Library/Application Support/redloft/projects/<slug>/, ВНЕ Yandex.Disk
# (data residency: client-материалы и контакты не синкаются в RU cloud).
#
# Ported from redresearch/lib/persist.sh. KEY DIFFERENCE: per-project и
# НАКАПЛИВАЮЩИЙ (зародыш Memory) — НЕ timestamped per-run. Идемпотентно:
# повторный запуск по тому же slug переиспользует каталог, а не падает.
#
# Usage: persist.sh <slug>
# Echoes: <project_dir>
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
if [ -n "${REDLOFT_DATA_DIR:-}" ]; then
  DATA_ROOT="$REDLOFT_DATA_DIR"
else
  DATA_ROOT="$HOME/Library/Application Support/redloft"
fi

# Sanity check: DATA_ROOT NOT inside CLAUDECORE_PATH (Yandex.Disk) — data residency guard.
# Resolve both to absolute (handle relative/symlink env overrides) before prefix-match.
if [ -n "${CLAUDECORE_PATH:-}" ]; then
  _abs() { # echo absolute path without requiring the dir to exist
    case "$1" in
      /*) printf '%s' "$1" ;;
      *)  printf '%s/%s' "$(pwd)" "$1" ;;
    esac
  }
  _dr_abs="$(_abs "$DATA_ROOT")"
  _cc_abs="$(_abs "$CLAUDECORE_PATH")"
  case "$_dr_abs/" in
    "$_cc_abs"/*)
      echo "✗ REFUSED: REDLOFT_DATA_DIR is inside Yandex.Disk ($CLAUDECORE_PATH)" >&2
      echo "  This would sync client materials/contacts to RU cloud. Set REDLOFT_DATA_DIR elsewhere." >&2
      exit 2
      ;;
  esac
fi

PROJECTS_ROOT="$DATA_ROOT/projects"
PROJECT_DIR="$PROJECTS_ROOT/$SLUG"

# Idempotent: create root + all Project Context subdirs (reused on re-run — Memory seed).
# Subdirs mirror _shared.md §1.
mkdir -p \
  "$PROJECT_DIR/inbox" \
  "$PROJECT_DIR/brief" \
  "$PROJECT_DIR/research" \
  "$PROJECT_DIR/planning" \
  "$PROJECT_DIR/sitemap" \
  "$PROJECT_DIR/seo" \
  "$PROJECT_DIR/content" \
  "$PROJECT_DIR/design" \
  "$PROJECT_DIR/reviews" \
  "$PROJECT_DIR/memory"

printf '%s\n' "$PROJECT_DIR"

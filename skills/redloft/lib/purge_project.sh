#!/usr/bin/env bash
# redloft PII-lifecycle / project purge (Phase F, DR-7). Deletes a Project Context
# (GDPR/multi-client obligation), or only its PII (contacts) with --purge-contacts.
# Local-first guarded: refuses anything outside the canonical projects root.
#
# Usage:
#   purge_project.sh <slug>                 # delete entire project dir
#   purge_project.sh <slug> --purge-contacts  # delete ONLY brief/contacts.md
set -euo pipefail

SLUG="${1:-}"
MODE="${2:-full}"
if [ -z "$SLUG" ]; then
  echo "usage: purge_project.sh <slug> [--purge-contacts]" >&2; exit 64
fi
if ! printf '%s' "$SLUG" | grep -qE '^[a-z0-9-]{1,60}$'; then
  echo "✗ invalid slug (must match ^[a-z0-9-]{1,60}$): $SLUG" >&2; exit 1
fi

# Canonical data root — env override > macOS App Support (same as persist.sh)
if [ -n "${REDLOFT_DATA_DIR:-}" ]; then DATA_ROOT="$REDLOFT_DATA_DIR"
else DATA_ROOT="$HOME/Library/Application Support/redloft"; fi
PROJECTS_ROOT="$DATA_ROOT/projects"
PROJECT_DIR="$PROJECTS_ROOT/$SLUG"

# Safety: PROJECT_DIR must live strictly UNDER projects root (no traversal / root wipe).
case "$PROJECT_DIR/" in
  "$PROJECTS_ROOT"/*/) ;;
  *) echo "✗ REFUSED: resolved path is not under projects root: $PROJECT_DIR" >&2; exit 2 ;;
esac
[ "$PROJECT_DIR" != "$PROJECTS_ROOT" ] || { echo "✗ REFUSED: would target the whole projects root" >&2; exit 2; }

if [ ! -d "$PROJECT_DIR" ]; then
  echo "✗ no project: $SLUG ($PROJECT_DIR)" >&2; exit 1
fi

case "$MODE" in
  --purge-contacts)
    CONTACTS="$PROJECT_DIR/brief/contacts.md"
    if [ -f "$CONTACTS" ]; then
      rm -f "$CONTACTS"
      echo "✓ purged PII: $CONTACTS (project kept)"
    else
      echo "• no contacts.md to purge in $SLUG (project kept)"
    fi
    ;;
  full)
    rm -rf "$PROJECT_DIR"
    echo "✓ purged project: $SLUG ($PROJECT_DIR)"
    ;;
  *)
    echo "✗ unknown mode: $MODE (use --purge-contacts or omit)" >&2; exit 64 ;;
esac

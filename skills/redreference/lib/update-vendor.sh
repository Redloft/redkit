#!/usr/bin/env bash
# update-vendor.sh — re-sync redreference's vendored fetch-toolkit copies from
# the CANONICAL redresearch/lib (prepends the VENDORED header). Run after the
# canonical files change (e.g. the Stage-A A.patch-canon redirect re-guard, D4),
# then re-run check-vendor-drift.sh to confirm exit 0.
set -euo pipefail
SK="${CLAUDE_SKILLS:-$HOME/.claude/skills}"
CANON="$SK/redresearch/lib"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

vendor() {
  local f="$1"
  [ -f "$CANON/$f" ] || { echo "✗ canonical missing: $CANON/$f" >&2; exit 1; }
  { printf '# VENDORED from ~/.claude/skills/redresearch/lib/%s — DO NOT edit here; re-vendor via lib/update-vendor.sh\n' "$f"
    cat "$CANON/$f"; } > "$HERE/$f"
  echo "re-vendored: $f"
}
vendor cffi_get.sh
vendor fetch.sh
vendor fetch_tiered.py
chmod +x "$HERE/cffi_get.sh" "$HERE/fetch.sh"
echo "done — run check-vendor-drift.sh to verify"

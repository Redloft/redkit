#!/usr/bin/env bash
# check-vendor-drift.sh — verify redreference's vendored fetch-toolkit copies
# still match their CANONICAL source in redresearch/lib. Only the BODY is
# compared (header/origin lines are normalized away). Hard-fail on drift so a
# silently-diverged copy can't ship (Stage A Done-when #3).
#
# Re-sync on drift:  bash lib/update-vendor.sh
# Exit: 0 in sync | 1 drift detected.
set -uo pipefail
SK="${CLAUDE_SKILLS:-$HOME/.claude/skills}"
CANON="$SK/redresearch/lib"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_norm() {
  grep -vE 'VENDORED from|CANONICAL SOURCE|DO NOT edit here|edit HERE|edited in place|re-sync|re-vendor' "$1" 2>/dev/null
}
_sha() { _norm "$1" | shasum | cut -d' ' -f1; }

DRIFT=0
_cmp() { # <canonical> <vendor> <label>
  local can="$1" ven="$2" lbl="$3"
  if [ ! -f "$can" ]; then echo "?? canonical missing: $can"; DRIFT=1; return; fi
  if [ ! -f "$ven" ]; then echo "?? vendor missing:    $ven  ($lbl)"; DRIFT=1; return; fi
  if [ "$(_sha "$can")" = "$(_sha "$ven")" ]; then
    echo "✅ in sync: $lbl"
  else
    echo "⚠️  DRIFT:  $lbl"
    DRIFT=1
  fi
}

# Vendored fetch engine (byte-identical body). url-guard.sh / redproxy.sh are
# SYMLINKS (no copy → no drift) and intentionally not checked here.
_cmp "$CANON/cffi_get.sh"      "$HERE/cffi_get.sh"      "cffi_get.sh"
_cmp "$CANON/fetch.sh"         "$HERE/fetch.sh"         "fetch.sh"
_cmp "$CANON/fetch_tiered.py"  "$HERE/fetch_tiered.py"  "fetch_tiered.py"

echo
if [ "$DRIFT" -eq 0 ]; then echo "all vendored copies in sync ✅"; else echo "drift — run lib/update-vendor.sh ⚠️"; fi
exit $DRIFT

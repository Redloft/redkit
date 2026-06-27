#!/usr/bin/env bash
# check-vendor-drift.sh — verify vendored copies of the fetch toolkit still
# match their CANONICAL source here in redresearch/lib. Header/origin lines
# (VENDORED / CANONICAL SOURCE / re-sync notes) are ignored — only the BODY
# is compared (sha of the normalized content).
#
# Run after editing any canonical file, or periodically. Re-vendor on drift:
#   cp redresearch/lib/<f> <dest>   (then restore the vendor header line)
#
# Exit: 0 all in sync | 1 drift detected.
set -uo pipefail
SK="${CLAUDE_SKILLS:-$HOME/.claude/skills}"

# strip the lines that legitimately differ between canonical and a vendor copy
_norm() {
  grep -vE 'VENDORED from|CANONICAL SOURCE|DO NOT edit here|edit HERE|edited in place|re-sync|re-vendor' "$1" 2>/dev/null
}
_sha() { _norm "$1" | shasum | cut -d' ' -f1; }

DRIFT=0
_cmp() { # <canonical> <vendor> <label>
  local can="$1" ven="$2" lbl="$3"
  if [ ! -f "$can" ]; then echo "?? canonical missing: $can"; DRIFT=1; return; fi
  if [ ! -f "$ven" ]; then echo "?? vendor missing:    $ven  ($lbl)"; return; fi
  if [ "$(_sha "$can")" = "$(_sha "$ven")" ]; then
    echo "✅ in sync: $lbl"
  else
    echo "⚠️  DRIFT:  $lbl"
    echo "      canonical: ${can/#$HOME/\~}"
    echo "      vendor:    ${ven/#$HOME/\~}"
    DRIFT=1
  fi
}

# canonical = redresearch/lib ; vendored copies elsewhere
_cmp "$SK/redresearch/lib/cffi_get.sh"     "$SK/redsemantic/lib/adapters/cffi_get.sh" "cffi_get.sh    → redsemantic"
_cmp "$SK/redresearch/lib/fetch.sh"        "$SK/redloft/lib/fetch.sh"                 "fetch.sh       → redloft"
_cmp "$SK/redresearch/lib/fetch_tiered.py" "$SK/redloft/lib/fetch_tiered.py"          "fetch_tiered.py → redloft"

echo
if [ "$DRIFT" -eq 0 ]; then echo "all vendored copies in sync ✅"; else echo "drift found — re-vendor from canonical ⚠️"; fi
exit $DRIFT

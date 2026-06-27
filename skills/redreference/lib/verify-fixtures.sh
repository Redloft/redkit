#!/usr/bin/env bash
# verify-fixtures.sh — canary check that recorded fixtures still match the live
# endpoint's SHAPE (plan gap#3). Compares the set of top-level JSON keys of the
# newest fixture for a source against a fresh live fetch. A mismatch prints
# FIXTURE_SCHEMA_DRIFT (warn, non-fatal) so a green hermetic smoke can't hide a
# prod-breaking API change. NOT part of the hermetic gate — run in tests/canary.
#
# Usage:  verify-fixtures.sh <src> <live_url> [--proxy]
# Exit:   0 in sync | 5 drift (warn) | 1 live fetch failed | 64 usage
set -uo pipefail
SRC="${1:-}"; URL="${2:-}"; MODE="${3:-}"
[ -n "$SRC" ] && [ -n "$URL" ] || { echo "usage: verify-fixtures.sh <src> <live_url> [--proxy]" >&2; exit 64; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
FIX=$(ls -1 "$SKILL_DIR/fixtures/${SRC}."*.json 2>/dev/null | sort | tail -1)
[ -n "$FIX" ] || { echo "verify-fixtures: no fixture for $SRC (run record-fixture.sh)" >&2; exit 1; }

if [ "$MODE" = "--proxy" ]; then
  live=$(bash "$HERE/redproxy.sh" "$URL" 2>/dev/null || true)
else
  live=$(bash "$HERE/cffi_get.sh" "$URL" 12 chrome 2>/dev/null || true)
fi
[ -n "$live" ] || { echo "verify-fixtures: live fetch failed for $URL" >&2; exit 1; }

_keys() { jq -r 'if type=="object" then (keys_unsorted|sort|join(",")) elif type=="array" then "[array]" else type end' 2>/dev/null; }
fk=$(printf '%s' "$(cat "$FIX")" | _keys)
lk=$(printf '%s' "$live" | _keys)
if [ -z "$lk" ]; then echo "verify-fixtures: live response not JSON for $SRC" >&2; exit 1; fi
if [ "$fk" = "$lk" ]; then
  echo "✅ $SRC fixture in sync (top-level keys match)"
  exit 0
else
  echo "FIXTURE_SCHEMA_DRIFT src=$SRC fixture_keys=[$fk] live_keys=[$lk]" >&2
  exit 5
fi

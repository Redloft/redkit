#!/usr/bin/env bash
# test-finalize.sh — self-test'ы Stage 2 (/finalize).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
declare -i FAIL=0
run() { printf '\n▶ %s\n' "$1"; shift; if "$@"; then :; else echo "  ↳ FAILED"; FAIL+=1; fi; }

run "detect-gates"      bash "$HERE/detect-gates.sh" --self-test
run "snapshot"          bash "$HERE/snapshot.sh" --self-test
run "run-gates"         bash "$HERE/run-gates.sh" --self-test
run "strip (shared)"    bash "$HERE/strip-secrets.sh" --self-test
run "finalize.js syntax" node --check "$HERE/../workflow/finalize.js"
run "stabilize.js syntax" node --check "$HERE/../workflow/stabilize.js"
run "chunk logic"        node "$HERE/chunk-test.js"
run "empirical logic"    node "$HERE/empirical-test.js"

echo
if [ "$FAIL" -eq 0 ]; then echo "✅ /finalize Stage 2: ALL self-tests passed"; exit 0
else echo "❌ /finalize Stage 2: $FAIL suite(s) failed"; exit 1; fi

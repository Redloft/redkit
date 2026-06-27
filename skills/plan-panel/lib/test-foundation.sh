#!/usr/bin/env bash
# test-foundation.sh — единый раннер всех self-test'ов Stage 0 (DESIGN-foundation DoD).
# Зелёный выход здесь = фундамент готов, можно браться за Stage 1 / Stage 2.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
declare -i FAIL=0
run() {
  local name="$1"; shift
  printf '\n▶ %s\n' "$name"
  if "$@"; then :; else echo "  ↳ FAILED"; FAIL+=1; fi
}

run "strip-secrets"   bash "$HERE/strip-secrets.sh" --self-test
run "checkpoint"      bash "$HERE/checkpoint.sh" --self-test
run "validators"      node "$HERE/validators.js" --self-test
run "crash-canary"    bash "$HERE/crash-canary-test.sh"
run "persist-plan"    bash "$HERE/persist-plan.sh" --self-test
run "panel.js syntax" node --check "$HERE/../workflow/panel.js"
run "reviewer-loop syntax" node --check "$HERE/../workflow/reviewer-loop.js"
run "ceiling-guard"   node "$HERE/ceiling-test.js"
run "ledger"          bash "$HERE/ledger.sh" --self-test
run "golden fixtures" bash "$HERE/run-golden.sh"

echo
if [ "$FAIL" -eq 0 ]; then echo "✅ Stage 0 foundation: ALL self-tests passed"; exit 0
else echo "❌ Stage 0 foundation: $FAIL suite(s) failed"; exit 1; fi

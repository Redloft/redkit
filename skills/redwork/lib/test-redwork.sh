#!/usr/bin/env bash
# test-redwork.sh — единый раннер self-test'ов redwork-фундамента.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
declare -i FAIL=0
run() { printf '\n▶ %s\n' "$1"; shift; if "$@"; then :; else echo "  ↳ FAILED"; FAIL+=1; fi; }

run "state"         bash "$HERE/state.sh" --self-test
run "events"        bash "$HERE/events.sh" --self-test
run "risk-classify" bash "$HERE/risk-classify.sh" --self-test
run "escalate"      bash "$HERE/escalate.sh" --self-test
run "config"        bash "$HERE/config.sh" --self-test
run "autonomy-gate" bash "$HERE/autonomy-gate.sh" --self-test
run "onboarding-kb"  bash "$HERE/onboarding-kb.sh" --self-test

echo
if [ "$FAIL" -eq 0 ]; then echo "✅ redwork foundation: ALL self-tests passed"; exit 0
else echo "❌ redwork foundation: $FAIL suite(s) failed"; exit 1; fi

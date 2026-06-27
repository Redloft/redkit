#!/usr/bin/env bash
# test-core.sh — self-test общего kernel (strip-secrets, checkpoint, ledger, validators).
# secret-guard.sh — source-only (тестируется консьюмерами).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
declare -i FAIL=0
run(){ printf '\n▶ %s\n' "$1"; shift; if "$@"; then :; else echo "  ↳ FAILED"; FAIL+=1; fi; }
run "strip-secrets" bash "$HERE/strip-secrets.sh" --self-test
run "checkpoint"    bash "$HERE/checkpoint.sh" --self-test
run "ledger"        bash "$HERE/ledger.sh" --self-test
run "validators"    node "$HERE/validators.js" --self-test
echo
if [ "$FAIL" -eq 0 ]; then echo "✅ redkit core: ALL self-tests passed"; exit 0
else echo "❌ redkit core: $FAIL failed"; exit 1; fi

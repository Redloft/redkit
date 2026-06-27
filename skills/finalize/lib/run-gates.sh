#!/usr/bin/env bash
# run-gates.sh — прогон gate-команд, stable-репорт (DESIGN §1 STABILIZE, §fixer).
# НЕ чинит — только запускает и классифицирует (fixing = задача fixer-агента, потом повторный прогон).
# Различает code-failure от infra-failure (§fixer, action#5): отсутствие бинаря/ENOENT → infra-error.
#
# Usage:
#   run-gates.sh <cwd> '<gates_json>'      # gates_json = [{name,cmd},...] из detect-gates.sh
#   run-gates.sh --self-test
# Echoes JSON: { stable: true|false|"unknown", results:[{name,cmd,status,exit}], remaining_failures:[name] }
#   stable=true   — все гейты зелёные
#   stable=false  — есть code-failure
#   stable="unknown" — гейтов нет ИЛИ только infra-error (нельзя судить)
set -euo pipefail

run_gates() {
  local cwd="$1" gates="$2"
  local n; n="$(jq 'length' <<<"$gates" 2>/dev/null || echo 0)"
  if [ "$n" -eq 0 ]; then echo '{"stable":"unknown","results":[],"remaining_failures":[],"reason":"no gates"}'; return 0; fi

  local results='[]' remaining='[]' any_code_fail=0 any_pass=0 only_infra=1 i name cmd bin out rc status
  for ((i=0; i<n; i++)); do
    name="$(jq -r ".[$i].name" <<<"$gates")"; cmd="$(jq -r ".[$i].cmd" <<<"$gates")"
    bin="$(awk '{print $1}' <<<"$cmd")"
    if ! command -v "$bin" >/dev/null 2>&1; then
      status="infra-error"; rc=127
    else
      out="$(cd "$cwd" && eval "$cmd" >/dev/null 2>&1; echo $?)"; rc="$out"
      if [ "$rc" -eq 0 ]; then status="pass"; any_pass=1; only_infra=0
      elif [ "$rc" -eq 127 ]; then status="infra-error"
      else status="fail"; any_code_fail=1; only_infra=0; fi
    fi
    results="$(jq -c --arg n "$name" --arg c "$cmd" --arg s "$status" --argjson e "$rc" '. + [{name:$n,cmd:$c,status:$s,exit:$e}]' <<<"$results")"
    [ "$status" = "fail" ] && remaining="$(jq -c --arg n "$name" '. + [$n]' <<<"$remaining")"
  done

  local stable
  if [ "$any_code_fail" -eq 1 ]; then stable=false
  elif [ "$only_infra" -eq 1 ]; then stable='"unknown"'   # все упали по infra → судить нельзя
  else stable=true; fi
  jq -nc --argjson st "$stable" --argjson r "$results" --argjson rem "$remaining" \
    '{stable:$st, results:$r, remaining_failures:$rem}'
}

self_test() {
  local T fail=0; T="$(mktemp -d)"; trap 'rm -rf "$T"' RETURN
  local out
  # all green
  out="$(run_gates "$T" '[{"name":"a","cmd":"true"},{"name":"b","cmd":"true"}]')"
  [ "$(jq -r .stable <<<"$out")" = "true" ] || { echo "✗ all-true should be stable:true"; fail=1; }
  # code failure
  out="$(run_gates "$T" '[{"name":"a","cmd":"true"},{"name":"test","cmd":"false"}]')"
  [ "$(jq -r .stable <<<"$out")" = "false" ] || { echo "✗ false gate should be stable:false"; fail=1; }
  jq -e '.remaining_failures==["test"]' <<<"$out" >/dev/null || { echo "✗ remaining_failures wrong"; fail=1; }
  # infra-error only (missing binary) → unknown
  out="$(run_gates "$T" '[{"name":"x","cmd":"definitely-not-a-real-binary-xyz --run"}]')"
  [ "$(jq -r .stable <<<"$out")" = "unknown" ] || { echo "✗ missing-binary should be unknown, got $(jq -r .stable <<<"$out")"; fail=1; }
  jq -e '.results[0].status=="infra-error"' <<<"$out" >/dev/null || { echo "✗ infra-error not classified"; fail=1; }
  # no gates → unknown
  [ "$(run_gates "$T" '[]' | jq -r .stable)" = "unknown" ] || { echo "✗ empty gates should be unknown"; fail=1; }

  [ "$fail" -eq 0 ] && { echo "✓ run-gates self-test passed"; return 0; } || { echo "✗ run-gates FAILED"; return 1; }
}

case "${1:-}" in
  --self-test) self_test ;;
  "") echo "usage: run-gates.sh <cwd> '<gates_json>' | --self-test" >&2; exit 64 ;;
  *) run_gates "$@" ;;
esac

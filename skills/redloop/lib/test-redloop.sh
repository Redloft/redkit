#!/usr/bin/env bash
# test-redloop.sh — прогон всех self-тестов + сквозной smoke (контракт→промпт→журнал→детекторы→эскалация).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; fail=0
for s in events detect contract-lint patterns compile escalate; do
  out="$(bash "$HERE/$s.sh" --self-test 2>&1)"; rc=$?
  echo "$out" | tail -3
  [ $rc -ne 0 ] && fail=1
done

out="$(python3 "$HERE/dashboard.py" --self-test 2>&1)"; rc=$?
echo "$out" | tail -3; [ $rc -ne 0 ] && fail=1

echo "--- сквозной smoke ---"
T="$(mktemp -d)"; rd="$T/runs/run-smoke"; mkdir -p "$rd"
export REDLOOP_STATS_DIR="$T/stats" REDLOOP_ESCALATE_DRYRUN=1
ok(){ if [ "$1" -eq 0 ]; then echo "  ✓ $2"; else echo "  ✗ $2"; fail=1; fi; }
cat > "$rd/contract.json" <<'J'
{"task":"smoke","runner":"loop","scope_globs":["src/**"],
 "budget":{"max_iters":5,"max_minutes":30},"thresholds":{"stall":3,"loop":3},
 "escalation_channel":"tg:attunedbot","dod":[{"id":"t","cmd":"true","expect_exit":0}]}
J
bash "$HERE/compile.sh" "$rd/contract.json" "$rd" >/dev/null; ok $? "compile"
bash "$HERE/contract-lint.sh" "$rd/contract.json" >/dev/null; ok $? "контракт валиден ПОСЛЕ штампа patterns_sha"
bash "$HERE/events.sh" append "$rd" run_start "$(jq -nc --arg s "$(jq -r .patterns_sha "$rd/contract.json")" '{runner:"loop",contract_sha:$s}')" >/dev/null; ok $? "run_start"
i=1; while [ $i -le 3 ]; do
  bash "$HERE/events.sh" append "$rd" iter_done '{"task_id":"t","files_changed":0,"checkboxes_done":0}' --iter $i --of 3 >/dev/null
  i=$((i+1)); done
res="$(bash "$HERE/detect.sh" scan "$rd")"
printf '%s' "$res" | jq -e 'any(.[]; .detector=="STALL")' >/dev/null; ok $? "STALL пойман сквозным путём"
printf '%s' "$res" | jq -e 'all(.[]; .shadow==true)' >/dev/null; ok $? "shadow: человека не будим до калибровки"
bash "$HERE/escalate.sh" "$rd" STALL "unblock" "3 итерации без правок" "сузить задачу" >/dev/null; ok $? "эскалация доставлена"
grep -q '"event_type":"escalation"' "$rd/events.jsonl"; ok $? "эскалация в журнале"
# журнал не принимает сырой вывод даже в сквозном пути
bash "$HERE/events.sh" append "$rd" check_result '{"check_id":"c","cmd_hash":"h","exit_code":0,"stdout":"..."}' --iter 4 >/dev/null 2>&1
[ $? -ne 0 ]; ok $? "raw stdout по-прежнему отвергается"
rm -rf "$T"
echo; [ "$fail" -eq 0 ] && echo "✅ redloop: все тесты прошли" || echo "❌ redloop: есть падения"
exit $fail

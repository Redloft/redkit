#!/usr/bin/env bash
# events.sh — единственный писатель журнала прогона redloop (EVENTS-CONTRACT.md).
# Инварианты: append-only; монотонный seq под локом; обязательные kind/denominator;
# per-type required-поля; запрет raw-вывода и секретов в payload.
#
# Usage:
#   events.sh append <run_dir> <event_type> <payload_json> [--kind K] [--severity S] [--iter N] [--of M]
#   events.sh --self-test
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
# ⚠ FAIL-CLOSED. Реальный kw_secret_found возвращает 0 КОГДА СЕКРЕТ НАЙДЕН. Прежняя заглушка
# возвращала 1 всегда — то есть при недоступном guard (битый симлинк после checkout без симлинков,
# переезд core/) фильтр молча превращался в no-op. Теперь недоступность guard = отказ писать журнал.
GUARD_OK=1
source "$HERE/secret-guard.sh" || GUARD_OK=0

VALID_TYPES="run_start iter_start iter_done check_result runner_error assumption question detector_fire escalation run_done heartbeat"
VALID_KINDS="progress infra_failure negative_verdict"
FORBIDDEN_FIELDS="stdout stderr raw output command_output"

_required() { case "$1" in
  run_start)     echo "runner contract_sha" ;;
  iter_start)    echo "task_id" ;;
  iter_done)     echo "task_id files_changed checkboxes_done" ;;
  check_result)  echo "check_id cmd_hash exit_code" ;;
  runner_error)  echo "exit_code error_class" ;;
  assumption)    echo "assumption_id" ;;
  question)      echo "reason_code allowed" ;;
  detector_fire) echo "detector shadow evidence" ;;
  escalation)    echo "reason_code" ;;
  run_done)      echo "verdict iters interventions" ;;
  heartbeat)     echo "alive_at" ;;
  *) echo "" ;;
esac }

_lock() { local lk="$1" i
  for i in $(seq 1 100); do
    if mkdir "$lk" 2>/dev/null; then echo $$ > "$lk/pid"; return 0; fi
    local p; p="$(cat "$lk/pid" 2>/dev/null || echo 0)"
    if [ "${p:-0}" -gt 0 ] && ! kill -0 "$p" 2>/dev/null; then rm -rf "$lk"; else sleep 0.05; fi
  done; return 1; }

append() {
  local rd="${1:?run_dir}" et="${2:?event_type}" payload="${3:?payload_json}"; shift 3
  local kind="" sev="info" iter="null" of="null"
  while [ $# -gt 0 ]; do case "$1" in
    --kind) kind="$2"; shift 2;; --severity) sev="$2"; shift 2;;
    --iter) iter="$2"; shift 2;; --of) of="$2"; shift 2;; *) shift;;
  esac; done
  echo "$VALID_TYPES" | grep -qw "$et" || { echo "✗ event_type не в enum: $et" >&2; return 1; }
  printf '%s' "$payload" | jq -e . >/dev/null 2>&1 || { echo "✗ payload не JSON" >&2; return 1; }

  # kind по умолчанию — из типа события и exit_code (шов «упало» vs «вернуло отрицательный вердикт»)
  if [ -z "$kind" ]; then
    case "$et" in
      runner_error) kind="infra_failure" ;;
      check_result) [ "$(printf '%s' "$payload" | jq -r '.exit_code')" = "0" ] && kind="progress" || kind="negative_verdict" ;;
      *) kind="progress" ;;
    esac
  fi
  echo "$VALID_KINDS" | grep -qw "$kind" || { echo "✗ kind не в enum: $kind" >&2; return 1; }

  # обязательные поля per type
  local f; for f in $(_required "$et"); do
    printf '%s' "$payload" | jq -e --arg k "$f" 'has($k)' >/dev/null || { echo "✗ $et: нет обязательного поля $f" >&2; return 1; }
  done
  # запрещённые поля (raw-вывод в журнал не попадает никогда)
  for f in $FORBIDDEN_FIELDS; do
    printf '%s' "$payload" | jq -e --arg k "$f" 'has($k)' >/dev/null 2>&1 && { echo "✗ запрещённое поле в payload: $f" >&2; return 1; }
  done
  # знаменатель обязателен для итерационных событий («нет событий ≠ успех»)
  case "$et" in iter_start|iter_done|check_result)
    [ "$iter" = "null" ] && { echo "✗ $et без --iter (знаменатель обязателен)" >&2; return 1; } ;;
  esac
  if [ "$GUARD_OK" != "1" ]; then
    echo "✗ secret-guard недоступен ($HERE/secret-guard.sh) — отказываюсь писать журнал" >&2; return 1; fi
  if kw_secret_found "$payload"; then echo "✗ payload содержит секрет-паттерн — отказ" >&2; return 1; fi

  mkdir -p "$rd"
  local lk="$rd/.events.lock"; _lock "$lk" || { echo "✗ lock timeout" >&2; return 1; }
  local seq; local n=0; [ -f "$rd/events.jsonl" ] && n=$(wc -l < "$rd/events.jsonl" | tr -d " ")
  seq=$(( n + 1 ))
  local rid; rid="$(basename "$rd")"
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg rid "$rid" --argjson seq "$seq" \
     --arg et "$et" --arg kind "$kind" --arg sev "$sev" \
     --argjson iter "$iter" --argjson of "$of" --argjson p "$payload" \
     '{schema_version:1, ts:$ts, run_id:$rid, seq:$seq, event_type:$et, kind:$kind,
       severity:$sev, denominator:{iter:$iter, of:$of}, payload:$p}' >> "$rd/events.jsonl"
  rm -rf "$lk"
  return 0
}

self_test() {
  set +e; local T; T="$(mktemp -d)"; local rd="$T/run-abc"; local fail=0
  ok(){ if [ "$1" -eq 0 ]; then :; else echo "  ✗ $2"; fail=1; fi; }
  append "$rd" run_start '{"runner":"loop","contract_sha":"abc"}' >/dev/null; ok $? "run_start"
  append "$rd" check_result '{"check_id":"t1","cmd_hash":"h","exit_code":1}' --iter 1 --of 5 >/dev/null; ok $? "check_result"
  [ "$(tail -1 "$rd/events.jsonl" | jq -r .kind)" = "negative_verdict" ]; ok $? "exit≠0 → negative_verdict (не infra)"
  append "$rd" runner_error '{"exit_code":137,"error_class":"oom"}' >/dev/null
  [ "$(tail -1 "$rd/events.jsonl" | jq -r .kind)" = "infra_failure" ]; ok $? "runner_error → infra_failure"
  [ "$(tail -1 "$rd/events.jsonl" | jq -r .seq)" = "3" ]; ok $? "seq монотонный"
  append "$rd" iter_done '{"task_id":"t1","files_changed":0,"checkboxes_done":0}' >/dev/null 2>&1
  ok $((1-$?)) "iter_done без --iter отвергнут (знаменатель)"
  append "$rd" check_result '{"check_id":"x","cmd_hash":"h","exit_code":0,"stdout":"secret dump"}' --iter 2 >/dev/null 2>&1
  ok $((1-$?)) "raw stdout в payload отвергнут"
  append "$rd" nonsense '{"a":1}' >/dev/null 2>&1; ok $((1-$?)) "неизвестный event_type отвергнут"
  append "$rd" run_start '{"runner":"loop"}' >/dev/null 2>&1; ok $((1-$?)) "нет обязательного поля → отказ"
  # guard недоступен → журнал НЕ пишется (fail-closed), а не пишется без проверки
  local G="$T/guardless"; mkdir -p "$G"
  cp "$HERE/events.sh" "$G/events.sh"
  bash "$G/events.sh" append "$G/run" run_start '{"runner":"loop","contract_sha":"a"}' >/dev/null 2>&1
  ok $((1-$?)) "нет secret-guard → append отвергнут (fail-closed, не no-op)"
  [ ! -f "$G/run/events.jsonl" ]; ok $? "при недоступном guard журнал не создан"
  rm -rf "$T"
  [ "$fail" -eq 0 ] && { echo "✓ events self-test passed"; return 0; } || { echo "✗ events self-test FAILED"; return 1; }
}
case "${1:-}" in
  --self-test) self_test ;;
  append) shift; append "$@" ;;
  *) echo "usage: events.sh append <run_dir> <event_type> <payload> [--kind K --severity S --iter N --of M] | --self-test" >&2; exit 1 ;;
esac

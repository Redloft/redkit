#!/usr/bin/env bash
# events.sh — append-only observability-хребет redwork (spec v3 §events.jsonl).
# Инварианты (панель): strip + validate_no_secrets на КАЖДЫЙ append; НЕ писать raw stdout/stderr
# (только структурный summary); типизированный payload per event_type; retention-инвариант
# (не pruned пока phase!=DONE или blocked_on!=null).
#
# Usage:
#   events.sh append <run_dir> <event_type> <payload_json>
#   events.sh gc <run_dir>
#   events.sh --self-test
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/secret-guard.sh"
CAP="${REDWORK_EVENTS_CAP:-2000}"
LOCK_TTL="${REDWORK_LOCK_TTL_SEC:-300}"

# mkdir-страж с pid/at + stale-reclaim (без него краш между mkdir и unlock вешал append навсегда). 0=got,1=timeout.
_acquire_lock() {
  local LK="$1" i lpid lat now
  for i in $(seq 1 60); do
    if mkdir "$LK" 2>/dev/null; then echo "$$" > "$LK/pid"; date +%s > "$LK/at"; return 0; fi
    lpid="$(cat "$LK/pid" 2>/dev/null || echo 0)"; lat="$(cat "$LK/at" 2>/dev/null || echo 0)"; now="$(date +%s)"
    if { [ "${lpid:-0}" -gt 0 ] && ! kill -0 "$lpid" 2>/dev/null; } || [ $(( now - ${lat:-0} )) -ge "$LOCK_TTL" ]; then
      rm -rf "$LK" 2>/dev/null   # stale (мёртвый pid или протух) → reclaim, mkdir на след. итерации
    else sleep 0.05; fi
  done
  return 1
}

VALID_TYPES="phase_start phase_done gate_result smoke_result deploy rollback escalation"
# обязательные поля per event_type (machine-contract union)
_required() { case "$1" in
  smoke_result) echo "observed_status_code match expected_status_code" ;;
  deploy|rollback) echo "intent_id exit_code" ;;
  gate_result) echo "gate exit_code" ;;
  escalation) echo "reason_code" ;;
  *) echo "" ;;
esac }

append() {
  local rd="${1:?run_dir}" et="${2:?event_type}" payload="${3:?payload_json}"
  echo "$VALID_TYPES" | grep -qw "$et" || { echo "✗ неизвестный event_type: $et" >&2; return 1; }
  printf '%s' "$payload" | jq -e . >/dev/null 2>&1 || { echo "✗ payload не JSON" >&2; return 1; }
  # типовой контракт: обязательные поля
  local req; req="$(_required "$et")"
  for f in $req; do
    [ "$(printf '%s' "$payload" | jq "has(\"$f\")")" = "true" ] || { echo "✗ $et: payload без обязательного поля '$f'" >&2; return 1; }
  done
  # secrets-гейт: payload не должен нести raw-вывод/секреты (keyword-детектор — структурный payload содержит UUID/коды)
  if kw_secret_found "$payload"; then echo "✗ payload содержит секрет-паттерн (raw stdout/stderr?) — НЕ пишем в events" >&2; return 1; fi
  local S="$rd/state.json"
  local slug phase; slug="$(jq -r '.slug // "?"' "$S" 2>/dev/null || echo '?')"; phase="$(jq -r '.phase // "?"' "$S" 2>/dev/null || echo '?')"
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local line; line="$(jq -nc --arg ts "$ts" --arg slug "$slug" --arg phase "$phase" --arg et "$et" --argjson p "$payload" \
    '{ts:$ts, slug:$slug, phase:$phase, event_type:$et, payload_summary:$p}')"
  local L="$rd/events.jsonl"
  # lock со stale-reclaim; НЕ писать без лока (анти-corruption JSONL)
  _acquire_lock "$L.lock" || { echo "✗ events lock timeout — НЕ пишем (анти-corruption)" >&2; return 1; }
  printf '%s\n' "$line" >> "$L"
  rm -rf "$L.lock" 2>/dev/null || true
  echo "✓ event[$et] → $L"
}

# retention-ИНВАРИАНТ: не pruned пока phase!=DONE или blocked_on!=null; иначе cap последними CAP.
gc() {
  local rd="${1:?run_dir}"; local S="$rd/state.json" L="$rd/events.jsonl"
  [ -f "$L" ] || { echo "(нет events)"; return 0; }
  [ -f "$S" ] || { echo "(нет state.json — GC пропущен)"; return 0; }   # иначе jq exit≠0 + set -e роняет gc
  local phase blocked; phase="$(jq -r '.phase // ""' "$S" 2>/dev/null || echo "")"; blocked="$(jq -r '.blocked_on' "$S" 2>/dev/null || echo "null")"
  if [ "$phase" != "DONE" ] || [ "$blocked" != "null" ]; then echo "skip GC (phase=$phase blocked=$blocked — инвариант)"; return 0; fi
  local n; n="$(wc -l < "$L" | tr -d ' ')"
  if [ "$n" -gt "$CAP" ]; then
    _acquire_lock "$L.lock" || { echo "✗ GC lock timeout — пропускаю" >&2; return 1; }   # тот же страж, что append
    tail -n "$CAP" "$L" > "$L.tmp" && mv -f "$L.tmp" "$L"; rm -rf "$L.lock" 2>/dev/null || true; echo "✓ GC: $n→$CAP"
  else echo "GC: $n ≤ $CAP, нечего"; fi
}

self_test() {
  set +e; local T; T="$(mktemp -d)"; local rd="$T/run"; mkdir -p "$rd"; local fail=0
  ok(){ if [ "$1" -eq 0 ]; then :; else echo "  ✗ $2"; fail=1; fi; }
  jq -n '{slug:"s",phase:"P5_deploy",blocked_on:null}' > "$rd/state.json"
  # валидный smoke_result
  append "$rd" smoke_result '{"observed_status_code":200,"match":true,"expected_status_code":200}' >/dev/null; ok $? "smoke_result valid"
  # smoke_result без обязательного поля → reject
  if append "$rd" smoke_result '{"observed_status_code":200}' >/dev/null 2>&1; then ok 1 "должен требовать match+expected"; else ok 0 ""; fi
  # неизвестный тип → reject
  if append "$rd" garbage '{"x":1}' >/dev/null 2>&1; then ok 1 "неизвестный тип reject"; else ok 0 ""; fi
  # секрет в payload → reject (split-литерал)
  if append "$rd" deploy "{\"intent_id\":\"i\",\"exit_code\":0,\"note\":\"ghp_""ABCDEFGHIJKLMNOPQRST0123456789abcd\"}" >/dev/null 2>&1; then ok 1 "секрет в payload reject"; else ok 0 ""; fi
  [ "$(wc -l < "$rd/events.jsonl" | tr -d ' ')" = "1" ]; ok $? "только 1 валидное событие записано"
  # GC skip пока phase!=DONE
  gc "$rd" | grep -q "skip GC"; ok $? "GC уважает инвариант (skip пока не DONE)"
  # stale-reclaim: мёртвый lock (dead pid + старый at) не должен вешать append навсегда
  mkdir -p "$rd/events.jsonl.lock"; echo 999999 > "$rd/events.jsonl.lock/pid"; echo 0 > "$rd/events.jsonl.lock/at"
  append "$rd" gate_result '{"gate":"x","exit_code":0}' >/dev/null; ok $? "stale lock reclaimed (append не завис)"
  rm -rf "$T"
  if [ "$fail" -eq 0 ]; then echo "✓ events self-test passed"; return 0; else echo "✗ events self-test FAILED"; return 1; fi
}

case "${1:-}" in
  append) append "${2:-}" "${3:-}" "${4:-}" ;;
  gc) gc "${2:-}" ;;
  --self-test) self_test ;;
  *) echo "usage: events.sh append|gc|--self-test" >&2; exit 1 ;;
esac

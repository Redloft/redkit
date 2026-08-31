#!/usr/bin/env bash
# detect.sh — детерминированные детекторы патологий автономного прогона (DESIGN v2 §S5).
# Читает ТОЛЬКО events.jsonl (никакого транскрипта, никакого LLM). Никого не будит, пока
# детектор не вышел из shadow-фазы: выход = FP-rate < 10% на ≥5 живых прогонах (stats/detectors.json).
#
# Usage:
#   detect.sh scan <run_dir>            → JSON [{detector, severity, evidence, shadow}]
#   detect.sh calibration               → сводка по shadow-фазе (числа, не мнения)
#   detect.sh --self-test
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
STATS="${REDLOOP_STATS_DIR:-$ROOT/stats}"; DET="$STATS/detectors.json"
STALL_N="${REDLOOP_STALL_N:-3}"; LOOP_K="${REDLOOP_LOOP_K:-3}"; RETRY_N="${REDLOOP_RETRY_N:-3}"; ASK_N="${REDLOOP_ASK_N:-2}"

_shadow() { # 1 = ещё в shadow (не будим человека). Неизвестный детектор → shadow (fail-safe).
  local d="$1"; [ -f "$DET" ] || return 0
  [ "$(jq -r --arg d "$d" '.[$d].shadow // true' "$DET" 2>/dev/null)" = "false" ] && return 1 || return 0; }

scan() {
  local rd="${1:?run_dir}"; local ev="$rd/events.jsonl"; [ -f "$ev" ] || { echo '[]'; return 0; }
  local out="[]"
  add() { out="$(printf '%s' "$out" | jq -c --arg d "$1" --arg s "$2" --arg e "$3" \
          --argjson sh "$(_shadow "$1" && echo true || echo false)" \
          '. + [{detector:$d, severity:$s, evidence:$e, shadow:$sh}]')"; }

  # STALL: N подряд iter_done без изменений файлов и без прироста чекбоксов
  local stall; stall="$(jq -s --argjson n "$STALL_N" '
      [.[] | select(.event_type=="iter_done")] | .[-$n:] |
      if length==$n and all(.[]; .payload.files_changed==0) and
         ((.[-1].payload.checkboxes_done) == (.[0].payload.checkboxes_done)) then 1 else 0 end' "$ev")"
  [ "$stall" = "1" ] && add STALL critical "$STALL_N итераций без изменения файлов и чекбоксов"

  # LOOP: одна и та же команда вернула negative_verdict K раз (ретрай бесполезен по существу)
  local loop; loop="$(jq -s --argjson k "$LOOP_K" '
      [.[] | select(.event_type=="check_result" and .kind=="negative_verdict") | .payload.cmd_hash]
      | group_by(.) | map(select(length>=$k)) | length' "$ev")"
  [ "${loop:-0}" -gt 0 ] && add LOOP critical "одна проверка красная ≥$LOOP_K раз — ретрай не меняет исхода"

  # RETRY-BURN: N подряд infra_failure (упало, а не вернуло красный)
  local burn; burn="$(jq -s --argjson n "$RETRY_N" '
      [.[] | select(.kind=="infra_failure")] | .[-$n:] | if length==$n then 1 else 0 end' "$ev")"
  [ "$burn" = "1" ] && add RETRY-BURN warn "$RETRY_N инфра-падений подряд"

  # DRIFT: правка вне scope (раннер обязан слать iter_done.out_of_scope)
  local drift; drift="$(jq -s '[.[] | select(.payload.out_of_scope // 0 > 0)] | length' "$ev")"
  [ "${drift:-0}" -gt 0 ] && add DRIFT critical "правки вне scope_globs"

  # PREMATURE-EXIT: run_done есть, но не все проверки зелёные ПО ПОСЛЕДНЕМУ статусу.
  # Считать сырые события нельзя: штатный путь P-RETRY (красный → починил → зелёный) оставляет
  # красное событие в журнале навсегда, и детектор кричал бы на здоровом прогоне.
  local pre; pre="$(jq -s '
      if ([.[] | select(.event_type=="run_done")] | length) > 0 then
        ([.[] | select(.event_type=="check_result")]
         | sort_by(.seq) | group_by(.payload.check_id)
         | map(.[-1])) as $last
        | (if ($last|length)==0 then 1
           elif ([$last[] | select(.payload.exit_code!=0)] | length) > 0 then 1
           else 0 end)
      else 0 end' "$ev")"
  [ "$pre" = "1" ] && add PREMATURE-EXIT critical "прогон объявлен завершённым без полного зелёного чекера"

  # ASK-STORM: вопросы человеку вне разрешённого списка
  local ask; ask="$(jq -s --argjson n "$ASK_N" '[.[] | select(.event_type=="question" and .payload.allowed==false)] | length | if .>=$n then 1 else 0 end' "$ev")"
  [ "$ask" = "1" ] && add ASK-STORM warn "≥$ASK_N вопросов человеку вне разрешённого списка"

  # SILENCE — считает ВНЕШНИЙ сторож по heartbeat; здесь только знаменатель для отчёта
  printf '%s' "$out"
}

calibration() {
  local runs="${REDLOOP_RUNS_DIR:-$ROOT/runs}"; local total=0 fired=0 fp=0
  for d in "$runs"/*/; do [ -f "$d/events.jsonl" ] || continue; total=$((total+1))
    fired=$(( fired + $(jq -s '[.[] | select(.event_type=="detector_fire")] | length' "$d/events.jsonl") ))
    fp=$(( fp + $(jq -s '[.[] | select(.event_type=="detector_fire" and .payload.false_positive==true)] | length' "$d/events.jsonl") ))
  done
  local rate="n/a"; [ "$fired" -gt 0 ] && rate="$(awk -v a=$fp -v b=$fired 'BEGIN{printf "%.0f%%", 100*a/b}')"
  jq -nc --argjson runs "$total" --argjson fired "$fired" --argjson fp "$fp" --arg rate "$rate" \
    '{runs:$runs, fires:$fired, false_positives:$fp, fp_rate:$rate,
      exit_shadow_allowed: ($runs>=5 and $fired>0 and ($fp*10) < $fired)}'
}

self_test() {
  set +e; local T; T="$(mktemp -d)"; local rd="$T/r1"; mkdir -p "$rd"; local fail=0
  ok(){ if [ "$1" -eq 0 ]; then :; else echo "  ✗ $2"; fail=1; fi; }
  E(){ bash "$HERE/events.sh" append "$rd" "$@" >/dev/null 2>&1; }
  E run_start '{"runner":"loop","contract_sha":"a"}'
  local i; for i in 1 2 3; do E iter_done "{\"task_id\":\"t\",\"files_changed\":0,\"checkboxes_done\":2}" --iter $i --of 5; done
  printf '%s' "$(scan "$rd")" | jq -e 'any(.[]; .detector=="STALL")' >/dev/null; ok $? "STALL ловится"
  printf '%s' "$(scan "$rd")" | jq -e 'all(.[]; .shadow==true)' >/dev/null; ok $? "по умолчанию shadow (не будим человека)"
  for i in 4 5 6; do E check_result '{"check_id":"c","cmd_hash":"hh","exit_code":1}' --iter $i; done
  printf '%s' "$(scan "$rd")" | jq -e 'any(.[]; .detector=="LOOP")' >/dev/null; ok $? "LOOP ловится"
  # чистый прогон не даёт тревог (цена ложной тревоги — см. false-alarm-economics)
  local rd2="$T/r2"; mkdir -p "$rd2"
  bash "$HERE/events.sh" append "$rd2" run_start '{"runner":"loop","contract_sha":"a"}' >/dev/null
  bash "$HERE/events.sh" append "$rd2" iter_done '{"task_id":"t","files_changed":3,"checkboxes_done":1}' --iter 1 --of 2 >/dev/null
  bash "$HERE/events.sh" append "$rd2" check_result '{"check_id":"c","cmd_hash":"h","exit_code":0}' --iter 1 >/dev/null
  [ "$(scan "$rd2")" = "[]" ]; ok $? "чистый прогон → ноль тревог"
  bash "$HERE/events.sh" append "$rd2" run_done '{"verdict":"SHIP","iters":1,"interventions":0}' >/dev/null
  printf '%s' "$(scan "$rd2")" | jq -e 'all(.[]; .detector!="PREMATURE-EXIT")' >/dev/null; ok $? "полный зелёный чекер → нет PREMATURE-EXIT"
  # штатный P-RETRY: проверка упала и была починена — тревоги быть НЕ должно
  local rd4="$T/r4"; mkdir -p "$rd4"
  bash "$HERE/events.sh" append "$rd4" check_result '{"check_id":"t1","cmd_hash":"h","exit_code":1}' --iter 1 >/dev/null
  bash "$HERE/events.sh" append "$rd4" check_result '{"check_id":"t1","cmd_hash":"h","exit_code":0}' --iter 2 >/dev/null
  bash "$HERE/events.sh" append "$rd4" run_done '{"verdict":"SHIP","iters":2,"interventions":0}' >/dev/null
  printf '%s' "$(scan "$rd4")" | jq -e 'all(.[]; .detector!="PREMATURE-EXIT")' >/dev/null
  ok $? "красный→зелёный→run_done ⇒ ложной тревоги НЕТ (штатный P-RETRY)"
  local rd3="$T/r3"; mkdir -p "$rd3"
  bash "$HERE/events.sh" append "$rd3" check_result '{"check_id":"c","cmd_hash":"h","exit_code":1}' --iter 1 >/dev/null
  bash "$HERE/events.sh" append "$rd3" run_done '{"verdict":"SHIP","iters":1,"interventions":0}' >/dev/null
  printf '%s' "$(scan "$rd3")" | jq -e 'any(.[]; .detector=="PREMATURE-EXIT")' >/dev/null; ok $? "красный чекер + run_done → PREMATURE-EXIT"
  rm -rf "$T"
  [ "$fail" -eq 0 ] && { echo "✓ detect self-test passed"; return 0; } || { echo "✗ detect self-test FAILED"; return 1; }
}
case "${1:-}" in
  scan) shift; scan "$@" ;;
  calibration) calibration ;;
  --self-test) self_test ;;
  *) echo "usage: detect.sh scan <run_dir> | calibration | --self-test" >&2; exit 1 ;;
esac

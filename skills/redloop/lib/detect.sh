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
  local DET_NAME="?"
  local rd="${1:?run_dir}"; local ev="$rd/events.jsonl"; [ -f "$ev" ] || { echo '[]'; return 0; }
  local out="[]"
  # Каждый детектор считается изолированно: битый jq или неожиданное поле в журнале
  # роняли бы весь scan под set -euo pipefail, и молчание читалось бы как «тревог нет».
  # ⚠ Отметка о поломке пишется в ФАЙЛ, а не в переменную: q() всегда зовётся из
  # $( ), то есть из подоболочки, и присваивание переменной оттуда не переживает вызов.
  local brokef; brokef="$(mktemp)"
  q() { local r; r="$(jq "$@" "$ev" 2>/dev/null)" || { echo "$DET_NAME" >> "$brokef"; echo ""; return 0; }; printf '%s' "$r"; }
  add() { out="$(printf '%s' "$out" | jq -c --arg d "$1" --arg s "$2" --arg e "$3" \
          --argjson sh "$(_shadow "$1" && echo true || echo false)" \
          '. + [{detector:$d, severity:$s, evidence:$e, shadow:$sh}]')"; }

  DET_NAME=STALL
  # STALL: N подряд iter_done без изменений файлов и без прироста чекбоксов
  local stall; stall="$(q -s --argjson n "$STALL_N" '
      [.[] | select(.event_type=="iter_done")] | .[-$n:] |
      if length==$n and all(.[]; .payload.files_changed==0) and
         ((.[-1].payload.checkboxes_done) == (.[0].payload.checkboxes_done)) then 1 else 0 end')"
  [ "$stall" = "1" ] && add STALL critical "$STALL_N итераций без изменения файлов и чекбоксов"

  DET_NAME=LOOP
  # LOOP: одна и та же команда вернула negative_verdict K раз (ретрай бесполезен по существу)
  local loop; loop="$(q -s --argjson k "$LOOP_K" '
      [.[] | select(.event_type=="check_result" and .kind=="negative_verdict") | .payload.cmd_hash]
      | group_by(.) | map(select(length>=$k)) | length')"
  [ "${loop:-0}" -gt 0 ] && add LOOP critical "одна проверка красная ≥$LOOP_K раз — ретрай не меняет исхода"

  DET_NAME=RETRY-BURN
  # RETRY-BURN: N подряд infra_failure (упало, а не вернуло красный)
  local burn; burn="$(q -s --argjson n "$RETRY_N" '
      [.[] | select(.kind=="infra_failure")] | .[-$n:] | if length==$n then 1 else 0 end')"
  [ "$burn" = "1" ] && add RETRY-BURN warn "$RETRY_N инфра-падений подряд"

  DET_NAME=DRIFT
  # DRIFT: правка вне scope (раннер обязан слать iter_done.out_of_scope)
  local drift; drift="$(q -s '[.[] | select(.payload.out_of_scope // 0 > 0)] | length')"
  [ "${drift:-0}" -gt 0 ] && add DRIFT critical "правки вне scope_globs"

  # PREMATURE-EXIT: по ПОСЛЕДНЕМУ статусу каждой проверки; blocked внешним — не провал.
  # Заблокированная проверка не зелёная (DoD не закрыт), но и не ложный финал: действие за владельцем.
  DET_NAME=PREMATURE-EXIT
  local pre; pre="$(q -s '
      if ([.[] | select(.event_type=="run_done")] | length) > 0 then
        ([.[] | select(.event_type=="check_result")]
         | sort_by(.seq) | group_by(.payload.check_id) | map(.[-1])) as $last
        | (if ($last|length)==0 then 1
           elif ([$last[] | select(.payload.exit_code!=0 and .kind!="blocked")] | length) > 0 then 1
           else 0 end)
      else 0 end')"
  [ "$pre" = "1" ] && add PREMATURE-EXIT critical "прогон объявлен завершённым без полного зелёного чекера"

  # BLOCKED-EXTERNAL: проверка упёрлась во внешнее (токен, доступ, чужой сервер) — это владельцу,
  # а не «ошибка агента». Отдельный сигнал, чтобы не растворялся в partial-вердикте.
  DET_NAME=BLOCKED-EXTERNAL
  local blk; blk="$(q -s '[.[] | select(.event_type=="check_result" and .kind=="blocked")
                            | .payload.check_id] | unique | length')"
  [ "${blk:-0}" -gt 0 ] && add BLOCKED-EXTERNAL warn "ждут действия владельца (внешняя блокировка): $blk"

  # BUDGET-OVERRUN: бюджет берётся из СНАПШОТА в run_start, а не из contract.json —
  # детектор остаётся чистой функцией от журнала (И2, единогласное требование трёх ролей).
  DET_NAME=BUDGET-OVERRUN
  local bo; bo="$(q -s -r '
      (map(select(.event_type=="run_start"))|.[0].payload.budget) as $b
      | if $b == null then empty else
          ([.[] | select(.event_type=="iter_done")] | length) as $iters
          | (.[0].ts) as $t0 | (.[-1].ts) as $t1
          | (($t1|fromdateiso8601) - ($t0|fromdateiso8601)) / 60 | floor as $mins
          | { over_i: (($b.max_iters // 0) > 0 and $iters > $b.max_iters),
              over_t: (($b.max_minutes // 0) > 0 and $mins > $b.max_minutes),
              iters: $iters, mins: $mins, bi: ($b.max_iters // 0), bm: ($b.max_minutes // 0) }
          | if .over_i or .over_t
            then "итераций \(.iters) из \(.bi), времени \(.mins) мин из \(.bm)"
            else empty end
        end')"
  [ -n "$bo" ] && add BUDGET-OVERRUN critical "$bo"

  DET_NAME=ASK-STORM
  # ASK-STORM: вопросы человеку вне разрешённого списка
  local ask; ask="$(q -s --argjson n "$ASK_N" '[.[] | select(.event_type=="question" and .payload.allowed==false)] | length | if .>=$n then 1 else 0 end')"
  [ "$ask" = "1" ] && add ASK-STORM warn "≥$ASK_N вопросов человеку вне разрешённого списка"

  # SILENCE — считает ВНЕШНИЙ сторож по heartbeat; здесь только знаменатель для отчёта
  # Упавший детектор виден отдельной строкой: иначе его молчание неотличимо от «чисто».
  local broke; broke="$(sort -u "$brokef" 2>/dev/null | tr '\n' ' ')"; rm -f "$brokef"
  if [ -n "${broke// /}" ]; then
    out="$(printf '%s' "$out" | jq -c --arg d "детекторы не смогли посчитаться: $broke" \
          '. + [{detector:"DETECTOR-BROKEN", severity:"warn", evidence:$d, shadow:false}]')"
  fi
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
  bash "$HERE/events.sh" append "$rd4" iter_done '{"task_id":"t","files_changed":1,"checkboxes_done":1}' --iter 1 --of 2 >/dev/null
  bash "$HERE/events.sh" append "$rd4" check_result '{"check_id":"t1","cmd_hash":"h","exit_code":1}' --iter 1 >/dev/null
  bash "$HERE/events.sh" append "$rd4" check_result '{"check_id":"t1","cmd_hash":"h","exit_code":0}' --iter 2 >/dev/null
  bash "$HERE/events.sh" append "$rd4" run_done '{"verdict":"SHIP","iters":2,"interventions":0}' >/dev/null
  printf '%s' "$(scan "$rd4")" | jq -e 'all(.[]; .detector!="PREMATURE-EXIT")' >/dev/null
  ok $? "красный→зелёный→run_done ⇒ ложной тревоги НЕТ (штатный P-RETRY)"
  local rd3="$T/r3"; mkdir -p "$rd3"
  bash "$HERE/events.sh" append "$rd3" iter_done '{"task_id":"t","files_changed":1,"checkboxes_done":0}' --iter 1 --of 2 >/dev/null
  bash "$HERE/events.sh" append "$rd3" check_result '{"check_id":"c","cmd_hash":"h","exit_code":1}' --iter 1 >/dev/null
  bash "$HERE/events.sh" append "$rd3" run_done '{"verdict":"SHIP","iters":1,"interventions":0}' >/dev/null
  printf '%s' "$(scan "$rd3")" | jq -e 'any(.[]; .detector=="PREMATURE-EXIT")' >/dev/null; ok $? "красный чекер + run_done → PREMATURE-EXIT"
  # порог-минус-один: при двойном чтении журнала (хвостовой "$ev" в q()) эти три
  # детектора срабатывали ВДВОЕ раньше — тест ловит именно это.
  local rdT="$T/rt"; mkdir -p "$rdT"
  ET(){ bash "$HERE/events.sh" append "$rdT" "$@" >/dev/null 2>&1; }
  ET run_start '{"runner":"session","contract_sha":"a"}'
  local j; for j in 1 2; do ET iter_done '{"task_id":"t","files_changed":0,"checkboxes_done":0}' --iter $j --of 9; done
  printf '%s' "$(scan "$rdT")" | jq -e 'all(.[]; .detector!="STALL")' >/dev/null
  ok $? "STALL: 2 итерации при пороге 3 — тревоги нет (журнал не читается дважды)"
  for j in 3 4; do ET check_result '{"check_id":"c","cmd_hash":"hz","exit_code":1}' --iter $j; done
  printf '%s' "$(scan "$rdT")" | jq -e 'all(.[]; .detector!="LOOP")' >/dev/null
  ok $? "LOOP: 2 красных при пороге 3 — тревоги нет"
  ET runner_error '{"exit_code":1,"error_class":"net"}'; ET runner_error '{"exit_code":1,"error_class":"net"}'
  printf '%s' "$(scan "$rdT")" | jq -e 'all(.[]; .detector!="RETRY-BURN")' >/dev/null
  ok $? "RETRY-BURN: 2 инфра-сбоя при пороге 3 — тревоги нет"

  # ── v3 ──────────────────────────────────────────────────────────────────
  # blocked внешним: не зелёная, но и не ложный финал
  local rd5="$T/r5"; mkdir -p "$rd5"
  E5(){ bash "$HERE/events.sh" append "$rd5" "$@" >/dev/null 2>&1; }
  E5 run_start '{"runner":"session","contract_sha":"a"}'
  E5 iter_done '{"task_id":"t","files_changed":3,"checkboxes_done":1}' --iter 1 --of 2
  E5 check_result '{"check_id":"build","cmd_hash":"h1","exit_code":0}' --iter 1
  E5 check_result '{"check_id":"smoke","cmd_hash":"h2","exit_code":1,"result":"blocked_by_env"}' --iter 1
  E5 run_done '{"verdict":"partial","iters":1,"interventions":0}'
  printf '%s' "$(scan "$rd5")" | jq -e 'all(.[]; .detector!="PREMATURE-EXIT")' >/dev/null
  ok $? "И4: заблокированная внешним проверка НЕ даёт ложного PREMATURE-EXIT"
  printf '%s' "$(scan "$rd5")" | jq -e 'any(.[]; .detector=="BLOCKED-EXTERNAL")' >/dev/null
  ok $? "И4: blocked виден отдельным сигналом владельцу"

  # бюджет: перебор на единицу должен ловиться (порог пересекается, а не «где-то далеко»)
  local rd6="$T/r6"; mkdir -p "$rd6"
  echo '{"budget":{"max_iters":2,"max_minutes":600}}' > "$rd6/contract.json"
  bash "$HERE/events.sh" append "$rd6" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null
  local k; for k in 1 2; do bash "$HERE/events.sh" append "$rd6" iter_done "{\"task_id\":\"t\",\"files_changed\":1,\"checkboxes_done\":$k}" --iter $k --of 2 >/dev/null; done
  printf '%s' "$(scan "$rd6")" | jq -e 'all(.[]; .detector!="BUDGET-OVERRUN")' >/dev/null
  ok $? "И2: ровно по бюджету (2 из 2) тревоги нет"
  bash "$HERE/events.sh" append "$rd6" iter_done '{"task_id":"t","files_changed":1,"checkboxes_done":3}' --iter 3 --of 2 >/dev/null
  printf '%s' "$(scan "$rd6")" | jq -e 'any(.[]; .detector=="BUDGET-OVERRUN" and (.evidence|test("3 из 2")))' >/dev/null
  ok $? "И2: перебор на единицу пойман, знаменатель в тексте"

  # бюджет по ВРЕМЕНИ: ветка over_t отдельно от over_i
  local rd8="$T/r8"; mkdir -p "$rd8"
  echo '{"budget":{"max_iters":99,"max_minutes":10}}' > "$rd8/contract.json"
  bash "$HERE/events.sh" append "$rd8" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null
  bash "$HERE/events.sh" append "$rd8" iter_done '{"task_id":"t","files_changed":1,"checkboxes_done":1}' --iter 1 --of 9 >/dev/null
  # сдвигаем ts последнего события на 3 часа вперёд — иначе ветку времени не проверить
  python3 - "$rd8/events.jsonl" <<'PYY'
import json,sys,datetime
p=sys.argv[1]; rows=[json.loads(l) for l in open(p) if l.strip()]
t=datetime.datetime.strptime(rows[-1]["ts"],"%Y-%m-%dT%H:%M:%SZ")+datetime.timedelta(hours=3)
rows[-1]["ts"]=t.strftime("%Y-%m-%dT%H:%M:%SZ")
open(p,"w").write("".join(json.dumps(r,ensure_ascii=False)+"\n" for r in rows))
PYY
  printf '%s' "$(scan "$rd8")" | jq -e 'any(.[]; .detector=="BUDGET-OVERRUN" and (.evidence|test("180 мин из 10")))' >/dev/null
  ok $? "И2: перебор по ВРЕМЕНИ пойман (ветка over_t)"

  # изоляция: битая строка в журнале не должна гасить остальные детекторы
  local rd7="$T/r7"; mkdir -p "$rd7"
  bash "$HERE/events.sh" append "$rd7" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null
  local n; for n in 1 2 3; do bash "$HERE/events.sh" append "$rd7" iter_done '{"task_id":"t","files_changed":0,"checkboxes_done":0}' --iter $n --of 5 >/dev/null; done
  echo '{битый json' >> "$rd7/events.jsonl"
  local r7; r7="$(scan "$rd7")"; ok $? "scan не падает на битой строке журнала"
  printf '%s' "$r7" | jq -e 'any(.[]; .detector=="DETECTOR-BROKEN")' >/dev/null
  ok $? "поломка детектора видна отдельной строкой, а не молчанием"

  rm -rf "$T"
  [ "$fail" -eq 0 ] && { echo "✓ detect self-test passed"; return 0; } || { echo "✗ detect self-test FAILED"; return 1; }
}
case "${1:-}" in
  scan) shift; scan "$@" ;;
  calibration) calibration ;;
  --self-test) self_test ;;
  *) echo "usage: detect.sh scan <run_dir> | calibration | --self-test" >&2; exit 1 ;;
esac

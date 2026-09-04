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
# зелёные вердикты — из общего файла: один список на гейт, детектор и карточку
CONST_D="$HERE/constants.json"
# ⚠ Ранний выход применяется ТОЛЬКО к scan. Раньше он стоял до разбора команды, и
# `detect.sh --self-test` при сломанном словаре печатал тревогу и возвращал 0 — набор
# тестов был зелёным, не выполнив ни одной проверки. Зелёный тест, ничего не проверивший,
# хуже красного.
CONST_D_OK=1
jq -e '.fresh_ok_verdicts and .non_shadow_detectors and .fresh_check_id' "$CONST_D" >/dev/null 2>&1 || CONST_D_OK=0
FRESH_OK_JSON="$(jq -c '.fresh_ok_verdicts // ["SHIP"]' "$CONST_D" 2>/dev/null || echo '["SHIP"]')"
FRESH_ID_D="$(jq -r '.fresh_check_id // "fresh_check"' "$CONST_D" 2>/dev/null || echo fresh_check)"
SILENCE_MIN="${REDLOOP_SILENCE_MIN:-45}"
STALL_N="${REDLOOP_STALL_N:-3}"; LOOP_K="${REDLOOP_LOOP_K:-3}"; RETRY_N="${REDLOOP_RETRY_N:-3}"; ASK_N="${REDLOOP_ASK_N:-2}"

# Детекторы, не тихие ПО УМОЛЧАНИЮ (из словаря в git). stats/detectors.json — накопленная
# эмпирика ПОВЕРХ этого дефолта, а не единственный источник: он в .gitignore и до чужой
# установки не доезжает.
NON_SHADOW_DEFAULT="$(jq -r '(.non_shadow_detectors // [])|join(" ")' "$CONST_D" 2>/dev/null || echo "")"

_shadow() { # 1 = ещё в shadow (не будим человека). Неизвестный детектор → shadow (fail-safe).
  # ⚠ НЕ `.shadow // true`: в jq оператор // считает false пустым, поэтому явный флип
  # {"SILENCE":{"shadow":false}} молча читался бы как shadow=true — выключатель не выключал.
  # Тот же капкан уже ловили в events.sh на strict_journal; здесь он сидел в ЧИТАТЕЛЕ.
  local d="$1" x
  for x in $NON_SHADOW_DEFAULT; do [ "$x" = "$d" ] && return 1; done
  [ -f "$DET" ] || return 0
  local v; v="$(jq -r --arg d "$d" 'if (.[$d] // {}) | has("shadow") then (.[$d].shadow|tostring) else "true" end' "$DET" 2>/dev/null)"
  [ "$v" = "false" ] && return 1 || return 0; }

scan() {
  if [ "$CONST_D_OK" != "1" ]; then
    echo '[{"detector":"CONSTANTS-MISSING","severity":"critical","evidence":"словарь constants.json недоступен или неполон — сканировать нечем (fail-closed)","shadow":false}]'
    return 0; fi
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

  # Режим прогона: assisted = человек пишет промпты сам и задаёт темп. Детекторы темпа
  # (STALL, SILENCE) для такого прогона бессмысленны: пауза значит, что человек занят,
  # а не что агент завис. Судить их той же меркой — гарантированные ложные тревоги.
  local mode; mode="$(q -s -r 'map(select(.event_type=="run_start"))|.[0].payload.mode // "autonomous"')"
  [ "$mode" = "assisted" ] || [ "$mode" = "autonomous" ] || mode="autonomous"

  DET_NAME=STALL
  # STALL: N подряд iter_done без изменений файлов и без прироста чекбоксов
  local stall; stall="$(q -s --argjson n "$STALL_N" '
      [.[] | select(.event_type=="iter_done")] | .[-$n:] |
      if length==$n and all(.[]; .payload.files_changed==0) and
         ((.[-1].payload.checkboxes_done) == (.[0].payload.checkboxes_done)) then 1 else 0 end')"
  [ "$stall" = "1" ] && [ "$mode" = "autonomous" ] && add STALL critical "$STALL_N итераций без изменения файлов и чекбоксов"

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
  # ⚠ «Рано объявил победу» — обвинение в НЕЧЕСТНОСТИ. Прогон, который сам объявил
  # outcome != success, победы не объявлял: тревожить по нему значит ругать за честность
  # и учить агента молчать вместо признания провала (false-alarm-economics).
  local pre; pre="$(q -s '
      if ([.[] | select(.event_type=="run_done")] | length) > 0
         and ((([.[] | select(.event_type=="run_done")] | .[-1].payload.outcome) // "success") == "success") then
        ([.[] | select(.event_type=="check_result")]
         | sort_by(.seq) | group_by(.payload.check_id) | map(.[-1])) as $last
        | (if ($last|length)==0 then 1
           elif ([$last[] | select(.payload.exit_code!=0 and .kind!="blocked")] | length) > 0 then 1
           else 0 end)
      else 0 end')"
  [ "$pre" = "1" ] && add PREMATURE-EXIT critical "прогон объявлен завершённым без полного зелёного чекера"

  # FRESH-CHECK-MISSING: финал есть, а подписи свежего контекста нет (или она красная).
  # v3.3. Жёсткий запрет живёт в events.sh (run_done отвергается), детектор — второй невод:
  # он видит прогоны со strict=0 и прогоны, разобранные постфактум чужой сессией.
  DET_NAME=FRESH-CHECK-MISSING
  local fresh; fresh="$(q -s -r --argjson ok "$FRESH_OK_JSON" --arg fid "$FRESH_ID_D" '
      if ([.[] | select(.event_type=="run_done")] | length) == 0 then empty
      else
        ((map(select(.event_type=="run_start"))|.[0].payload.fresh_check.required) // false) as $req
        # ⚠ Прогон, честно объявивший НЕуспех (outcome != success), подписи чекера не должен:
        # гейт с него её и не спрашивает. Без этой строки КАЖДАЯ честная сдача поднимала
        # не-тихую тревогу и будила владельца — ложная тревога обесценивает сторож быстрее
        # пропуска, а заодно учит агента не объявлять провал.
        | (([.[] | select(.event_type=="run_done")] | .[-1].payload.outcome) // "success") as $oc
        | if ($oc != "success") then empty
          elif ($req|not) then empty
          else ([.[] | select(.event_type=="check_result" and .payload.check_id==$fid)]
                | sort_by(.seq) | .[-1]) as $last
            | ([.[] | select(.event_type=="iter_done")] | .[-1].seq // 0) as $lastiter
            | if $last == null then "финал без свежего чекера"
              elif ($last.payload.exit_code != 0)
                   or ($ok | index($last.payload.verdict // "") | not)
              then "свежий чекер дал \($last.payload.verdict // "красный"), а прогон закрыт"
              elif ($last.seq < $lastiter)
              then "подпись чекера (seq \($last.seq)) старше последней итерации (seq \($lastiter)) — прогон закрыт подписью под прошлым кодом"
              else empty end
          end
      end')"
  [ -n "$fresh" ] && add FRESH-CHECK-MISSING critical "$fresh"

  # RUN-ABANDONED: прогон честно объявил неуспех. Это НЕ тревога об обходе гейта —
  # раньше такой финал поднимал FRESH-CHECK-MISSING (не-тихий, будит владельца) с ЛОЖНЫМ
  # диагнозом «закрыт без свежего чекера». Отдельный сигнал говорит правду и не кричит.
  DET_NAME=RUN-ABANDONED
  local ab; ab="$(q -s -r '
      ([.[] | select(.event_type=="run_done")] | .[-1]) as $d
      | if $d == null then empty
        else (($d.payload.outcome) // "success") as $oc
          | if $oc == "success" then empty
            else "прогон закрыт честным неуспехом: outcome=\($oc), verdict=\($d.payload.verdict // "?")"
            end
        end')"
  [ -n "$ab" ] && add RUN-ABANDONED warn "$ab"

  # ITERS-MISMATCH: раннер отчитался одним числом итераций, журнал знает другое.
  # Два живых прогона рапортовали 13 и 19 итераций при нуле событий iter_done — то есть
  # «сколько он работал» вообще нельзя было проверить. events.sh теперь считает по журналу
  # и сохраняет самоотчёт рядом; расхождение остаётся сигналом о слепом раннере.
  DET_NAME=ITERS-MISMATCH
  local ims; ims="$(q -s -r '[.[] | select(.event_type=="run_done" and .payload.iters_mismatch==true)]
      | .[-1] // empty | "раннер заявил \(.payload.iters_claimed) итераций, в журнале \(.payload.iters)"')"
  [ -n "$ims" ] && add ITERS-MISMATCH warn "$ims"

  # POLICY-REJECT: журнал отверг событие по политике (финал без чекера, итерация без состояния).
  # v3.3.1: раньше отказ был ТИШИНОЙ — событие не писалось, и худший случай прогона выглядел
  # как «ничего не происходило». Теперь отказ оставляет след, и у следа есть читатель.
  DET_NAME=POLICY-REJECT
  # ⚠ Отказ — часть ШТАТНОГО сценария: гейт сам пишет «создай файлы и повтори событие»,
  # и дисциплинированный прогон почти всегда имеет ≥1 отказ. Тревога только если отказ
  # НЕ ИЗЛЕЧЕН: после него не было ни успешного события того же класса, ни зелёного финала.
  local pr; pr="$(q -s -r '
      ([.[] | select(.event_type=="runner_error" and .payload.error_class=="journal_policy_reject")]) as $rej
      | if ($rej|length)==0 then empty
        else ($rej[-1].seq) as $lastrej
          | ([.[] | select(.seq > $lastrej) | select(.event_type=="iter_done" or .event_type=="run_done")] | length) as $healed
          | if $healed > 0 then empty
            else "не излечен последний отказ политики: \($rej[-1].payload.reason) (всего отказов \($rej|length), причин \([$rej[].payload.reason]|unique|length))"
            end
        end')"
  [ -n "$pr" ] && add POLICY-REJECT warn "$pr"

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

  # SILENCE: прогон не закрыт, а событий нет дольше порога. Три прогона подряд закончились
  # именно так — работа шла (или встала), журнал молчал, и никто не узнал.
  # ⚠ Единственный детектор, зависящий от «сейчас»: тишину иначе не измерить.
  DET_NAME=SILENCE
  local sil; sil="$(q -s -r --argjson now "$(date -u +%s)" --argjson lim "$SILENCE_MIN" '
      if ([.[] | select(.event_type=="run_done")] | length) > 0 then empty
      else ([.[] | select(.event_type=="iter_start" or .event_type=="iter_done"
                          or .event_type=="check_result" or .event_type=="run_done"
                          or .event_type=="heartbeat")] | .[-1]) as $sig
        | ([.[] | select(.event_type=="run_start")] | .[0]) as $start
        # содержательных событий нет → считаем от старта прогона, а не от последнего отказа
        | (($sig // $start // .[0]).ts | fromdateiso8601) as $last
        | (($now - $last) / 60 | floor) as $mins
        | if $mins > $lim then "молчит \($mins) мин при пороге \($lim); финала нет" else empty end
      end')"
  [ -n "$sil" ] && [ "$mode" = "autonomous" ] && add SILENCE critical "$sil"


  # Упавший детектор виден отдельной строкой: иначе его молчание неотличимо от «чисто».
  local broke; broke="$(sort -u "$brokef" 2>/dev/null | tr '\n' ' ')"; rm -f "$brokef"
  if [ -n "${broke// /}" ]; then
    out="$(printf '%s' "$out" | jq -c --arg d "детекторы не смогли посчитаться: $broke" \
          '. + [{detector:"DETECTOR-BROKEN", severity:"warn", evidence:$d, shadow:false}]')"
  fi
  printf '%s' "$out"
}

calibration() {
  # ⚠ Знаменатель берём из РЕЕСТРА, а не из одного каталога: прогоны живут и в папке скилла,
  # и в .redloop/runs/ проектов. Пока считали по каталогу, третий живой прогон был невидим,
  # и порог «5 прогонов» никогда не набрался бы честно.
  local reg="${REDLOOP_INDEX:-$ROOT/runs/index.jsonl}"
  local runs="${REDLOOP_RUNS_DIR:-$ROOT/runs}"
  local total=0 fired=0 fp=0 missing=0 assisted=0
  local dirs; dirs="$(mktemp)"
  [ -f "$reg" ] && jq -r '.path' "$reg" 2>/dev/null >> "$dirs"
  for d in "$runs"/*/; do [ -d "$d" ] && printf '%s\n' "${d%/}" >> "$dirs"; done
  local d ev
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    ev="$d/events.jsonl"
    if [ ! -f "$ev" ]; then missing=$((missing+1)); continue; fi
    local m; m="$(jq -s -r 'map(select(.event_type=="run_start"))|.[0].payload.mode // "autonomous"' "$ev" 2>/dev/null || echo autonomous)"
    if [ "$m" = "assisted" ]; then assisted=$((assisted+1)); continue; fi
    total=$((total+1))
    # ⚠ Находки живут в alerts.jsonl (их пишет сторож), а не событиями в журнале. Пока
    # калибровка считала detector_fire в events.jsonl, она всегда видела ноль — и порог
    # выхода из тихого режима был недостижим В ПРИНЦИПЕ. Считаем НАХОДКИ (строки), а не
    # повторы: одна и та же находка на 100 обходах — один факт, а не сто улик.
    local al="$d/alerts.jsonl"
    if [ -f "$al" ]; then
      fired=$(( fired + $(jq -s '[.[] | select(.suppressed_count // 0 == 0 or (.seen_count // 1) > (.suppressed_count // 0))] | length' "$al" 2>/dev/null || echo 0) ))
      fp=$(( fp + $(jq -s '[.[] | select(.false_positive==true)] | length' "$al" 2>/dev/null || echo 0) ))
    fi
    # legacy: событийные detector_fire, если их кто-то писал раньше
    fired=$(( fired + $(jq -s '[.[] | select(.event_type=="detector_fire")] | length' "$ev" 2>/dev/null || echo 0) ))
    fp=$(( fp + $(jq -s '[.[] | select(.event_type=="detector_fire" and .payload.false_positive==true)] | length' "$ev" 2>/dev/null || echo 0) ))
  done < <(sort -u "$dirs")
  rm -f "$dirs"
  local rate="n/a"; [ "$fired" -gt 0 ] && rate="$(awk -v a=$fp -v b=$fired 'BEGIN{printf "%.0f%%", 100*a/b}')"
  jq -nc --argjson runs "$total" --argjson fired "$fired" --argjson fp "$fp" --arg rate "$rate" \
     --argjson missing "$missing" --argjson assisted "$assisted" \
    '{runs_autonomous:$runs, runs_assisted:$assisted, fires:$fired, false_positives:$fp,
      fp_rate:$rate, unreadable:$missing,
      exit_shadow_allowed: ($runs>=5 and $fired>0 and ($fp*10) < $fired)}'
}

self_test() {
  set +e; local T; T="$(mktemp -d)"; local rd="$T/r1"; mkdir -p "$rd"; local fail=0
  echo '{"state_files":[],"human_acceptance":[]}' > "$rd/contract.json"
  export REDLOOP_INDEX="$T/index.jsonl"   # боевой реестр не трогаем
  # Фикстуры здесь намеренно патологические (пустые итерации, финал без чекера). Правило
  # внешнего состояния — предмет тестов events.sh, а не детекторов: держим его выключенным,
  # иначе журнал фикстуры не соберётся и детектор будет «чист» по ложной причине.
  export REDLOOP_STATE_FILES_ENFORCE=0
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
  echo '{"state_files":[],"human_acceptance":[]}' > "$rd2/contract.json"
  bash "$HERE/events.sh" append "$rd2" run_start '{"runner":"loop","contract_sha":"a"}' >/dev/null
  bash "$HERE/events.sh" append "$rd2" iter_done '{"task_id":"t","files_changed":3,"checkboxes_done":1}' --iter 1 --of 2 >/dev/null
  bash "$HERE/events.sh" append "$rd2" check_result '{"check_id":"c","cmd_hash":"h","exit_code":0}' --iter 1 >/dev/null
  [ "$(scan "$rd2")" = "[]" ]; ok $? "чистый прогон → ноль тревог"
  bash "$HERE/events.sh" append "$rd2" run_done '{"verdict":"SHIP","iters":1,"interventions":0}' >/dev/null
  printf '%s' "$(scan "$rd2")" | jq -e 'all(.[]; .detector!="PREMATURE-EXIT")' >/dev/null; ok $? "полный зелёный чекер → нет PREMATURE-EXIT"
  # штатный P-RETRY: проверка упала и была починена — тревоги быть НЕ должно
  local rd4="$T/r4"; mkdir -p "$rd4"
  echo '{"state_files":[],"human_acceptance":[]}' > "$rd4/contract.json"
  bash "$HERE/events.sh" append "$rd4" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null
  bash "$HERE/events.sh" append "$rd4" iter_done '{"task_id":"t","files_changed":1,"checkboxes_done":1}' --iter 1 --of 2 >/dev/null
  bash "$HERE/events.sh" append "$rd4" check_result '{"check_id":"t1","cmd_hash":"h","exit_code":1}' --iter 1 >/dev/null
  bash "$HERE/events.sh" append "$rd4" check_result '{"check_id":"t1","cmd_hash":"h","exit_code":0}' --iter 2 >/dev/null
  bash "$HERE/events.sh" append "$rd4" run_done '{"verdict":"SHIP","iters":2,"interventions":0}' >/dev/null
  printf '%s' "$(scan "$rd4")" | jq -e 'all(.[]; .detector!="PREMATURE-EXIT")' >/dev/null
  ok $? "красный→зелёный→run_done ⇒ ложной тревоги НЕТ (штатный P-RETRY)"
  local rd3="$T/r3"; mkdir -p "$rd3"
  echo '{"state_files":[],"human_acceptance":[]}' > "$rd3/contract.json"
  bash "$HERE/events.sh" append "$rd3" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null
  bash "$HERE/events.sh" append "$rd3" iter_done '{"task_id":"t","files_changed":1,"checkboxes_done":0}' --iter 1 --of 2 >/dev/null
  bash "$HERE/events.sh" append "$rd3" check_result '{"check_id":"c","cmd_hash":"h","exit_code":1}' --iter 1 >/dev/null
  bash "$HERE/events.sh" append "$rd3" run_done '{"verdict":"SHIP","iters":1,"interventions":0}' >/dev/null
  printf '%s' "$(scan "$rd3")" | jq -e 'any(.[]; .detector=="PREMATURE-EXIT")' >/dev/null; ok $? "красный чекер + run_done → PREMATURE-EXIT"
  # порог-минус-один: при двойном чтении журнала (хвостовой "$ev" в q()) эти три
  # детектора срабатывали ВДВОЕ раньше — тест ловит именно это.
  local rdT="$T/rt"; mkdir -p "$rdT"
  echo '{"state_files":[],"human_acceptance":[]}' > "$rdT/contract.json"
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
  echo '{"state_files":[],"human_acceptance":[]}' > "$rd5/contract.json"
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

  # ── v3.3: свежий чекер и честный счёт итераций ──────────────────────────
  local rdF="$T/r-fresh"; mkdir -p "$rdF"
  echo '{"fresh_check":{"kind":"finalize","required":true},"budget":{"max_iters":9,"max_minutes":600},"human_acceptance":[]}' > "$rdF/contract.json"
  EF(){ bash "$HERE/events.sh" append "$rdF" "$@" >/dev/null 2>&1; }
  env REDLOOP_STRICT_JOURNAL=0 bash "$HERE/events.sh" append "$rdF" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null 2>&1
  EF iter_done '{"task_id":"t","files_changed":3,"checkboxes_done":1}' --iter 1 --of 9
  EF check_result '{"check_id":"build","cmd_hash":"h","exit_code":0}' --iter 1
  bash "$HERE/events.sh" append "$rdF" run_done '{"verdict":"green","iters":6,"interventions":0}' >/dev/null 2>&1
  printf '%s' "$(scan "$rdF")" | jq -e 'any(.[]; .detector=="FRESH-CHECK-MISSING")' >/dev/null
  ok $? "финал без подписи свежего контекста пойман (случай 2026-09-03)"
  printf '%s' "$(scan "$rdF")" | jq -e 'any(.[]; .detector=="ITERS-MISMATCH" and (.evidence|test("6")) and (.evidence|test("1")))' >/dev/null
  ok $? "расхождение «заявлено 6 / в журнале 1» пойман со знаменателем"
  local rdG="$T/r-fresh-ok"; mkdir -p "$rdG"
  echo '{"fresh_check":{"kind":"finalize","required":true},"budget":{"max_iters":9,"max_minutes":600},"human_acceptance":[]}' > "$rdG/contract.json"
  EG(){ bash "$HERE/events.sh" append "$rdG" "$@" >/dev/null 2>&1; }
  EG run_start '{"runner":"session","contract_sha":"a"}'
  EG iter_done '{"task_id":"t","files_changed":3,"checkboxes_done":1}' --iter 1 --of 9
  printf '# Finalize\nverdict: **SHIP**\n' > "$rdG/judge.md"
  EG check_result "$(jq -nc --arg r "$rdG/judge.md" '{check_id:"fresh_check",cmd_hash:"finalize",exit_code:0,verdict:"SHIP",report:$r}')" --iter 1
  EG run_done '{"verdict":"green","iters":1,"interventions":0}'
  printf '%s' "$(scan "$rdG")" | jq -e 'all(.[]; .detector!="FRESH-CHECK-MISSING" and .detector!="ITERS-MISMATCH")' >/dev/null
  ok $? "честный прогон с SHIP свежего чекера → ни одной новой тревоги"
  local rdH="$T/r-fresh-nowork"; mkdir -p "$rdH"
  echo '{"fresh_check":{"kind":"finalize","required":true},"budget":{"max_iters":9,"max_minutes":600},"human_acceptance":[]}' > "$rdH/contract.json"
  EH(){ bash "$HERE/events.sh" append "$rdH" "$@" >/dev/null 2>&1; }
  env REDLOOP_STRICT_JOURNAL=0 bash "$HERE/events.sh" append "$rdH" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null 2>&1
  EH iter_done '{"task_id":"t","files_changed":3,"checkboxes_done":1}' --iter 1 --of 9
  printf '# Finalize\nverdict: **NEEDS-WORK**\n' > "$rdH/judge.md"
  EH check_result "$(jq -nc --arg r "$rdH/judge.md" '{check_id:"fresh_check",cmd_hash:"finalize",exit_code:0,verdict:"NEEDS-WORK",report:$r}')" --iter 1
  bash "$HERE/events.sh" append "$rdH" run_done '{"verdict":"green","iters":1,"interventions":0}' >/dev/null 2>&1
  printf '%s' "$(scan "$rdH")" | jq -e 'any(.[]; .detector=="FRESH-CHECK-MISSING" and (.evidence|test("NEEDS-WORK")))' >/dev/null
  ok $? "NEEDS-WORK при exit 0 не сходит за подпись (вердикт назван в улике)"
  # ── круг 6: честный неуспех не должен шуметь как обход гейта ─────────────
  # До правки run_done с outcome=abandoned поднимал FRESH-CHECK-MISSING (НЕ тихий, будит
  # владельца через TG) с ложным диагнозом «закрыт без свежего чекера» — то есть каждая
  # честная сдача наказывалась ложной тревогой, а агент учился не признавать провал.
  local rdAB="$T/r-abandoned"; mkdir -p "$rdAB"
  echo '{"fresh_check":{"kind":"finalize","required":true},"budget":{"max_iters":9,"max_minutes":600},"state_files":[],"human_acceptance":[]}' > "$rdAB/contract.json"
  EAB(){ bash "$HERE/events.sh" append "$rdAB" "$@" >/dev/null 2>&1; }
  EAB run_start '{"runner":"session","contract_sha":"a"}'
  EAB iter_done '{"task_id":"t","files_changed":1,"checkboxes_done":1}' --iter 1 --of 9
  EAB run_done '{"verdict":"blocked","iters":1,"interventions":0,"outcome":"blocked"}'
  printf '%s' "$(scan "$rdAB")" | jq -e 'all(.[]; .detector!="FRESH-CHECK-MISSING")' >/dev/null
  ok $? "круг6: честный неуспех НЕ поднимает FRESH-CHECK-MISSING (ложная тревога на штатном сценарии)"
  printf '%s' "$(scan "$rdAB")" | jq -e 'all(.[]; .detector!="PREMATURE-EXIT")' >/dev/null
  ok $? "круг6: честный неуспех НЕ обвиняется в ранней победе"
  printf '%s' "$(scan "$rdAB")" | jq -e 'any(.[]; .detector=="RUN-ABANDONED" and (.evidence|test("blocked")))' >/dev/null
  ok $? "круг6: у честного неуспеха есть СВОЙ сигнал с верным диагнозом"
  # …а прогон, заявивший УСПЕХ без подписи, тревогу поднимает по-прежнему
  local rdAB2="$T/r-abandoned-lie"; mkdir -p "$rdAB2"
  echo '{"fresh_check":{"kind":"finalize","required":true},"budget":{"max_iters":9,"max_minutes":600},"state_files":[],"human_acceptance":[]}' > "$rdAB2/contract.json"
  EAB2(){ bash "$HERE/events.sh" append "$rdAB2" "$@" >/dev/null 2>&1; }
  # strict=0 на СТАРТЕ — это и есть сценарий второго невода: гейт отключён, ловит детектор
  REDLOOP_STRICT_JOURNAL=0 bash "$HERE/events.sh" append "$rdAB2" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null 2>&1
  EAB2 iter_done '{"task_id":"t","files_changed":1,"checkboxes_done":1}' --iter 1 --of 9
  EAB2 run_done '{"verdict":"green","iters":1,"interventions":0}' 
  printf '%s' "$(scan "$rdAB2")" | jq -e 'any(.[]; .detector=="FRESH-CHECK-MISSING")' >/dev/null
  ok $? "круг6: заявка на успех без подписи тревогу поднимает (outcome не глушилка)"

  local rdI="$T/r-nofresh"; mkdir -p "$rdI"
  echo '{"fresh_check":{"kind":"artifact-pass","required":false,"why":"правка на 3 строки"},"budget":{"max_iters":9,"max_minutes":600},"human_acceptance":[]}' > "$rdI/contract.json"
  EI(){ bash "$HERE/events.sh" append "$rdI" "$@" >/dev/null 2>&1; }
  EI run_start '{"runner":"session","contract_sha":"a"}'
  EI iter_done '{"task_id":"t","files_changed":1,"checkboxes_done":1}' --iter 1 --of 9
  EI run_done '{"verdict":"green","iters":1,"interventions":0}'
  printf '%s' "$(scan "$rdI")" | jq -e 'all(.[]; .detector!="FRESH-CHECK-MISSING")' >/dev/null
  ok $? "осознанный отказ от чекера не даёт ложной тревоги"

  # отказ политики виден отдельным сигналом, а не тишиной.
  # ⚠ Нужен СТРОГИЙ прогон: при strict=0 политика И8 не отрабатывает и отказывать нечему.
  local rdJ="$T/r-reject"; mkdir -p "$rdJ"
  echo '{"fresh_check":{"kind":"finalize","required":true},"state_files":[],"budget":{"max_iters":9,"max_minutes":600},"human_acceptance":[]}' > "$rdJ/contract.json"
  EJ(){ bash "$HERE/events.sh" append "$rdJ" "$@" >/dev/null 2>&1; }
  EJ run_start '{"runner":"session","contract_sha":"a"}'
  EJ iter_done '{"task_id":"t","files_changed":1,"checkboxes_done":1}' --iter 1 --of 9
  EJ run_done '{"verdict":"green","iters":1,"interventions":0}'   # отвергнут: чекера нет
  printf '%s' "$(scan "$rdJ")" | jq -e 'any(.[]; .detector=="POLICY-REJECT" and (.evidence|test("fresh_check_missing")))' >/dev/null
  ok $? "НЕизлеченный отказ политики пойман детектором с причиной"
  # ⚠ Отказ — часть штатного сценария («создай файлы и повтори»): излеченный НЕ должен шуметь,
  # иначе дисциплинированный прогон тревожит на каждом обходе (false-alarm-economics).
  EJ iter_done '{"task_id":"t2","files_changed":1,"checkboxes_done":2}' --iter 2 --of 9
  printf '%s' "$(scan "$rdJ")" | jq -e 'all(.[]; .detector!="POLICY-REJECT")' >/dev/null
  ok $? "излеченный отказ (после него была успешная итерация) тревоги НЕ даёт"
  printf '%s' "$(scan "$rdG")" | jq -e 'all(.[]; .detector!="POLICY-REJECT")' >/dev/null
  ok $? "здоровый прогон без отказов POLICY-REJECT не даёт"

  # бюджет: перебор на единицу должен ловиться (порог пересекается, а не «где-то далеко»)
  local rd6="$T/r6"; mkdir -p "$rd6"
  echo '{"budget":{"max_iters":2,"max_minutes":600},"human_acceptance":[]}' > "$rd6/contract.json"
  bash "$HERE/events.sh" append "$rd6" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null
  local k; for k in 1 2; do bash "$HERE/events.sh" append "$rd6" iter_done "{\"task_id\":\"t\",\"files_changed\":1,\"checkboxes_done\":$k}" --iter $k --of 2 >/dev/null; done
  printf '%s' "$(scan "$rd6")" | jq -e 'all(.[]; .detector!="BUDGET-OVERRUN")' >/dev/null
  ok $? "И2: ровно по бюджету (2 из 2) тревоги нет"
  bash "$HERE/events.sh" append "$rd6" iter_done '{"task_id":"t","files_changed":1,"checkboxes_done":3}' --iter 3 --of 2 >/dev/null
  printf '%s' "$(scan "$rd6")" | jq -e 'any(.[]; .detector=="BUDGET-OVERRUN" and (.evidence|test("3 из 2")))' >/dev/null
  ok $? "И2: перебор на единицу пойман, знаменатель в тексте"

  # бюджет по ВРЕМЕНИ: ветка over_t отдельно от over_i
  local rd8="$T/r8"; mkdir -p "$rd8"
  echo '{"budget":{"max_iters":99,"max_minutes":10},"human_acceptance":[]}' > "$rd8/contract.json"
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

  # флип из тихого режима обязан РАБОТАТЬ (jq // считает false пустым — уже ловили дважды)
  local SD="$T/stats"; mkdir -p "$SD"; echo '{"STALL":{"shadow":false}}' > "$SD/detectors.json"
  printf '%s' "$(REDLOOP_STATS_DIR="$SD" DET="$SD/detectors.json" STATS="$SD" scan "$rd")" \
    | jq -e 'any(.[]; .detector=="STALL" and .shadow==false)' >/dev/null
  ok $? "флип shadow=false реально выводит детектор из тихого режима"

  # SILENCE: живой прогон без финала, последнее событие давно
  # assisted: тот же молчащий журнал НЕ даёт тревоги — темп задаёт человек
  local rdA="$T/rA"; mkdir -p "$rdA"; echo '{"mode":"assisted","human_acceptance":[]}' > "$rdA/contract.json"
  bash "$HERE/events.sh" append "$rdA" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null
  local m2; for m2 in 1 2 3; do bash "$HERE/events.sh" append "$rdA" iter_done '{"task_id":"t","files_changed":0,"checkboxes_done":0}' --iter $m2 --of 5 >/dev/null; done
  printf '%s' "$(scan "$rdA")" | jq -e 'all(.[]; .detector!="STALL" and .detector!="SILENCE")' >/dev/null
  ok $? "assisted: детекторы темпа молчат (промпты пишет человек)"

  local rd9="$T/r9"; mkdir -p "$rd9"
  echo '{"state_files":[],"human_acceptance":[]}' > "$rd9/contract.json"
  bash "$HERE/events.sh" append "$rd9" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null
  bash "$HERE/events.sh" append "$rd9" iter_done '{"task_id":"t","files_changed":1,"checkboxes_done":1}' --iter 1 --of 9 >/dev/null
  printf '%s' "$(scan "$rd9")" | jq -e 'all(.[]; .detector!="SILENCE")' >/dev/null
  ok $? "SILENCE: свежий прогон молчанием не считается"
  python3 - "$rd9/events.jsonl" <<'PYY'
import json,sys,datetime
p=sys.argv[1]; rows=[json.loads(l) for l in open(p) if l.strip()]
t=datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)-datetime.timedelta(hours=2)
rows[-1]["ts"]=t.strftime("%Y-%m-%dT%H:%M:%SZ")
open(p,"w").write("".join(json.dumps(r,ensure_ascii=False)+"\n" for r in rows))
PYY
  printf '%s' "$(scan "$rd9")" | jq -e 'any(.[]; .detector=="SILENCE" and (.evidence|test("при пороге 45")))' >/dev/null
  ok $? "SILENCE: два часа тишины без финала пойманы, порог в тексте"
  bash "$HERE/events.sh" append "$rd9" run_done '{"verdict":"partial","iters":1,"interventions":0}' >/dev/null
  printf '%s' "$(scan "$rd9")" | jq -e 'all(.[]; .detector!="SILENCE")' >/dev/null
  ok $? "SILENCE: закрытый прогон молчит законно"

  # изоляция: битая строка в журнале не должна гасить остальные детекторы
  local rd7="$T/r7"; mkdir -p "$rd7"
  echo '{"state_files":[],"human_acceptance":[]}' > "$rd7/contract.json"
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

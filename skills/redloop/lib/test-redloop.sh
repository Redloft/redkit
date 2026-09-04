#!/usr/bin/env bash
# test-redloop.sh — прогон всех self-тестов + сквозной smoke (контракт→промпт→журнал→детекторы→эскалация).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; fail=0
for s in events detect contract-lint patterns compile escalate watch; do
  out="$(bash "$HERE/$s.sh" --self-test 2>&1)"; rc=$?
  echo "$out" | tail -3
  [ $rc -ne 0 ] && fail=1
done

out="$(python3 "$HERE/dashboard.py" --self-test 2>&1)"; rc=$?
echo "$out" | tail -3; [ $rc -ne 0 ] && fail=1

ok(){ if [ "$1" -eq 0 ]; then echo "  ✓ $2"; else echo "  ✗ $2"; fail=1; fi; }

# ⚠ От constants.json теперь fail-closed зависит КАЖДАЯ запись журнала. Файл обязан ехать
# в установку вместе с кодом, поэтому его целостность — часть набора, а не предположение.
if jq -e '.fresh_check_id and .fresh_ok_verdicts and .fresh_verdict_all and .default_state_files and .non_shadow_detectors and .contract_version' "$HERE/constants.json" >/dev/null 2>&1; then
  echo "  ✓ словарь constants.json полон (от него зависят пять потребителей)"
else
  echo "  ✗ словарь constants.json отсутствует или неполон — журнал писать не сможет"; fail=1
fi

# ── гейт вердикта по КОРПУСУ РЕАЛЬНЫХ отчётов ────────────────────────────────
# ⚠ Три круга панели подряд синтетическая фикстура зеленела, пока гейт отвергал честные
# отчёты (3 из 8 на живом парке). Контроль обязан идти тем же путём, что система.
# ⚠ ШЕСТОЙ потребитель словаря — сами доки: они диктуют раннеру список вердиктов прозой.
# В круге 5 из fresh_ok_verdicts убрали GREEN/OK, а SKILL.md и EVENTS-CONTRACT.md продолжали
# их обещать. Первая версия ЭТОГО контроля не работала: условие содержало собственное
# слово-исключение, а строка «✓ …» печаталась безусловно — отчёт утверждал результат
# проверки, которая не выполнялась («контроль, который ничего не сломал»).
# Теперь сверка машинная: в обеих доках стоит маркер <!-- fresh_ok_verdicts: … -->,
# он обязан совпасть со словарём ПОБУКВЕННО. Ничего не захардкожено: сравнивается весь
# список, поэтому снятие или добавление ЛЮБОЙ метки контроль заметит.
# ⚠ Цикл по ВСЕМ полям-словарям, а не по одному: класс «проза дублирует enum» починили
# для fresh_ok_verdicts и тут же воспроизвели на соседнем новом run_done_outcomes.
for key in fresh_ok_verdicts run_done_outcomes; do
  dict_val="$(jq -r --arg k "$key" '.[$k]|join(" ")' "$HERE/constants.json")"
  for doc in SKILL.md EVENTS-CONTRACT.md; do
    marker="$(grep -o "<!-- $key:[^>]*-->" "$HERE/../$doc" 2>/dev/null | head -1 \
              | sed -E "s/<!-- $key:[[:space:]]*//; s/[[:space:]]*-->//")"
    if [ -z "$marker" ]; then
      echo "  ✗ в $doc нет маркера <!-- $key: … --> — дрейф словаря и прозы не проверяется"; fail=1
    elif [ "$marker" != "$dict_val" ]; then
      echo "  ✗ $doc обещает «${marker}», словарь $key говорит «${dict_val}» — проза и constants.json разошлись"; fail=1
    else
      echo "  ✓ $doc · $key совпадает со словарём ($marker)"
    fi
  done
done

echo "--- корпус реальных отчётов чекера ---"
CT="$(mktemp -d)"; CR="$CT/run"; mkdir -p "$CR"
export REDLOOP_INDEX="$CT/idx.jsonl"
echo '{"fresh_check":{"kind":"finalize","required":true},"state_files":[],"human_acceptance":[]}' > "$CR/contract.json"
bash "$HERE/events.sh" append "$CR" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null 2>&1
bash "$HERE/events.sh" append "$CR" iter_done '{"task_id":"t","files_changed":1,"checkboxes_done":1}' --iter 1 >/dev/null 2>&1
corpus_total=0; corpus_total_ways=0; corpus_ok=0; corpus_bad=""
for rep_dir in "$HERE/fixtures/reports"/*/; do
  [ -f "$rep_dir/judge.md" ] || continue
  corpus_total=$((corpus_total+1))
  rv="$(jq -r '.verdict' "$rep_dir/judge.json")"
  # ⚠ КАЖДЫЙ отчёт гоняем ДВУМЯ путями. Класть рядом judge.json и радоваться зелёному —
  # значит ни разу не позвать markdown-разбор, то есть ровно тот код, который ломался три
  # круга подряд, остаётся непокрытым, а строка «9 из 9» становится ложной гарантией.
  for way in machine markdown; do
    rm -rf "$CR/rep"; mkdir -p "$CR/rep"; cp "$rep_dir/judge.md" "$CR/rep/"
    [ "$way" = "machine" ] && cp "$rep_dir/judge.json" "$CR/rep/"
    touch "$CR/rep/judge.md"
    corpus_total_ways=$((corpus_total_ways+1))
    if bash "$HERE/events.sh" append "$CR" check_result "$(jq -nc --arg r "$CR/rep/judge.md" --arg v "$rv" '{check_id:"fresh_check",cmd_hash:"f",exit_code:0,verdict:$v,report:$r}')" --iter 1 >/dev/null 2>&1; then
      corpus_ok=$((corpus_ok+1))
      src="$(jq -s -r '[.[]|select(.payload.check_id=="fresh_check")]|.[-1].payload.verdict_source' "$CR/events.jsonl")"
      case "$way|$src" in
        "machine|machine:judge.json") ;;
        "markdown|markdown") ;;
        *) corpus_bad="$corpus_bad $(basename "$rep_dir")[$way→$src]" ;;
      esac
    else corpus_bad="$corpus_bad $(basename "$rep_dir")/$way"; fi
  done
done
[ "$corpus_total" -gt 0 ]; ok $? "корпус реальных отчётов на месте (иначе контроль ничего не проверяет)"
[ "$corpus_ok" = "$corpus_total_ways" ] && [ -z "$corpus_bad" ]
ok $? "гейт принимает ВСЕ реальные отчёты ОБОИМИ путями: $corpus_ok из $corpus_total_ways ($corpus_total отчётов × machine|markdown; проблемы:${corpus_bad:- —})"
# и негативный: событие с ЧУЖИМ вердиктом на том же реальном отчёте обязано краснеть
rm -rf "$CR/rep"; mkdir -p "$CR/rep"; first_dir="$(ls -d "$HERE/fixtures/reports"/*/ | head -1)"
cp "$first_dir"/judge.* "$CR/rep/"; touch "$CR/rep/judge.md"
wrong=SHIP; [ "$(jq -r .verdict "$first_dir/judge.json")" = "SHIP" ] && wrong=NEEDS-WORK
bash "$HERE/events.sh" append "$CR" check_result "$(jq -nc --arg r "$CR/rep/judge.md" --arg v "$wrong" '{check_id:"fresh_check",cmd_hash:"f",exit_code:0,verdict:$v,report:$r}')" --iter 1 >/dev/null 2>&1
[ $? -ne 0 ]; ok $? "на реальном отчёте вердикт со слов события отвергается (сверка с артефактом жива)"
rm -rf "$CT"

echo "--- сквозной smoke ---"
T="$(mktemp -d)"; rd="$T/runs/run-smoke"; mkdir -p "$rd"
export REDLOOP_STATS_DIR="$T/stats" REDLOOP_ESCALATE_DRYRUN=1 REDLOOP_INDEX="$T/index.jsonl"
mkdir -p "$T/proj"; REP="$T/proj/judge.md"
cat > "$rd/contract.json" <<J
{"task":"smoke","runner":"loop","scope_globs":["src/**"],
 "budget":{"max_iters":5,"max_minutes":30},"thresholds":{"stall":3,"loop":3},
 "escalation_channel":"tg:attunedbot",
 "fresh_check":{"kind":"finalize","required":true},
 "project_root":"$T/proj","state_files":["PLAN.md","state.json"],
 "dod":[{"id":"t","cmd":"true","expect_exit":0},
        {"id":"card","cmd":"grep -q wb- a.css","expect_exit":0,"weak":true}],
 "human_acceptance":[{"id":"52","what":"карточка","probe":"card"},
                     {"id":"57","what":"ощущение","manual_only":true,"why":"тактильное"}]}
J
bash "$HERE/compile.sh" "$rd/contract.json" "$rd" >/dev/null; ok $? "compile"
bash "$HERE/contract-lint.sh" "$rd/contract.json" >/dev/null; ok $? "контракт валиден ПОСЛЕ штампа patterns_sha"
grep -q 'fresh_check' "$rd/prompt.md"; ok $? "свежий чекер доехал до промпта"
grep -q 'машинно непроверяемо' "$rd/prompt.md"; ok $? "непроверяемый пункт приёмки предъявлен в промпте"
bash "$HERE/events.sh" append "$rd" run_start "$(jq -nc --arg s "$(jq -r .patterns_sha "$rd/contract.json")" '{runner:"loop",contract_sha:$s}')" >/dev/null; ok $? "run_start"
bash "$HERE/events.sh" append "$rd" iter_done '{"task_id":"t","files_changed":0,"checkboxes_done":0}' --iter 1 --of 3 >/dev/null
bash "$HERE/events.sh" append "$rd" iter_done '{"task_id":"t","files_changed":0,"checkboxes_done":0}' --iter 2 --of 3 >/dev/null 2>&1
[ $? -eq 4 ]; ok $? "вторая итерация без PLAN.md отвергнута сквозным путём"
echo "- [ ] задача" > "$T/proj/PLAN.md"; echo '{"iter":1}' > "$T/proj/state.json"
i=2; while [ $i -le 3 ]; do
  bash "$HERE/events.sh" append "$rd" iter_done '{"task_id":"t","files_changed":0,"checkboxes_done":0}' --iter $i --of 3 >/dev/null
  i=$((i+1)); done
res="$(bash "$HERE/detect.sh" scan "$rd")"
printf '%s' "$res" | jq -e 'any(.[]; .detector=="STALL")' >/dev/null; ok $? "STALL пойман сквозным путём"
printf '%s' "$res" | jq -e 'all(.[]; .shadow==true)' >/dev/null; ok $? "shadow: человека не будим до калибровки"
bash "$HERE/events.sh" append "$rd" run_done '{"verdict":"green","iters":3,"interventions":0}' >/dev/null 2>&1
[ $? -eq 4 ]; ok $? "финал без свежего чекера отвергнут сквозным путём"
printf '# Finalize — 2026-09-04\n\nrun_id: `smoke`  verdict: **NEEDS-WORK**  confidence: 0.9\n' > "$REP"
bash "$HERE/events.sh" append "$rd" check_result "$(jq -nc --arg r "$REP" '{check_id:"fresh_check",cmd_hash:"finalize",exit_code:0,verdict:"SHIP"}')" --iter 3 >/dev/null 2>&1
[ $? -ne 0 ]; ok $? "свежий чекер без отчёта не записывается (самоаттестация закрыта)"
bash "$HERE/events.sh" append "$rd" check_result "$(jq -nc --arg r "$REP" '{check_id:"fresh_check",cmd_hash:"finalize",exit_code:0,verdict:"NEEDS-WORK",report:$r}')" --iter 3 >/dev/null
bash "$HERE/events.sh" append "$rd" run_done '{"verdict":"green","iters":3,"interventions":0}' >/dev/null 2>&1
[ $? -eq 4 ]; ok $? "NEEDS-WORK свежего чекера не закрывает прогон (случай 2026-09-03)"
printf '# Finalize\nverdict: %s\n' '.*' > "$REP"
bash "$HERE/events.sh" append "$rd" check_result "$(jq -nc --arg r "$REP" '{check_id:"fresh_check",cmd_hash:"finalize",exit_code:0,verdict:".*",report:$r}')" --iter 3 >/dev/null
bash "$HERE/events.sh" append "$rd" run_done '{"verdict":"green","iters":3,"interventions":0}' >/dev/null 2>&1
[ $? -eq 4 ]; ok $? "метасимвол вместо вердикта не закрывает прогон (сверка списком)"
# ⚠ Контроль не «подстрока есть», а «образец РАБОЧИЙ»: сломанное экранирование печатало
# невалидный JSON, и grep по подстроке на нём зеленел — контроль, который ничего не доказывал.
sample="$(grep -o '{"acceptance_presented":[^}]*}' "$rd/prompt.md" | head -1)"
printf '%s' "$sample" | jq -e . >/dev/null 2>&1; ok $? "образец acceptance_presented в промпте — валидный JSON"
[ "$(printf '%s' "$sample" | jq -c '.acceptance_presented')" = "$(bash "$HERE/events.sh" acceptance-ids "$rd/contract.json" manual)" ]
ok $? "адреса в промпте совпадают с адресами журнала (один источник, не вторая формула)"
# ⚠ Отчёт чекера — РЕАЛЬНОГО формата /finalize (объявление вердикта В СЕРЕДИНЕ строки),
# а не синтетика «verdict: SHIP с начала строки». Именно синтетика скрыла, что гейт
# отвергал каждый честный отчёт: тест шёл не тем путём, что система.
printf '# Finalize — 2026-09-04\n\nrun_id: `smoke`  verdict: **SHIP**  confidence: 0.94  stable: `unknown`\n' > "$REP"
bash "$HERE/events.sh" append "$rd" check_result "$(jq -nc --arg r "$REP" '{check_id:"fresh_check",cmd_hash:"finalize",exit_code:0,verdict:"SHIP",report:$r}')" --iter 3 >/dev/null
# И9, негативный контроль сквозным путём: зелёный чекер и закрытый DoD НЕ закрывают прогон,
# пока машинно непроверяемый кадр 57 не назван владельцу поимённо (класс «сигнал без читателя»).
bash "$HERE/events.sh" append "$rd" run_done '{"verdict":"green","iters":9,"interventions":0}' >/dev/null 2>&1
[ $? -eq 4 ] && [ "$(jq -s -r '[.[]|select(.payload.error_class=="journal_policy_reject")]|.[-1].payload.reason' "$rd/events.jsonl")" = "acceptance_not_presented" ]
ok $? "финал без предъявленных кадров приёмки отвергнут сквозным путём"
bash "$HERE/events.sh" append "$rd" run_done '{"verdict":"green","iters":9,"interventions":0,"acceptance_presented":["57"]}' >/dev/null; ok $? "после SHIP и предъявления кадров финал принят"
card="$(python3 "$HERE/dashboard.py" "$rd" --stage S6)"
printf '%s' "$card" | grep -q '>приёмка человеком<'; ok $? "блок приёмки есть в карточке"
printf '%s' "$card" | grep -q 'названо в финале 1 из 1'; ok $? "карточка показывает предъявленное со знаменателем"
# отказы политики оставили след в журнале (раньше худший исход прогона был тишиной)
[ "$(jq -s '[.[]|select(.payload.error_class=="journal_policy_reject")]|length' "$rd/events.jsonl")" -ge 3 ]
ok $? "каждый отказ политики записан событием сквозным путём"
# ...но ИЗЛЕЧЕННЫЕ отказы тревогой не становятся: прогон закрылся зелёным
res2="$(bash "$HERE/detect.sh" scan "$rd")"
printf '%s' "$res2" | jq -e 'all(.[]; .detector!="POLICY-REJECT")' >/dev/null
ok $? "излеченные отказы не шумят (штатный сценарий гейта — не тревога)"
[ "$(jq -s -r '[.[]|select(.event_type=="run_done")]|.[-1].payload.iters' "$rd/events.jsonl")" = "3" ]
ok $? "iters в финале взят из журнала (3), а не со слов раннера (9)"
bash "$HERE/escalate.sh" "$rd" STALL "unblock" "3 итерации без правок" "сузить задачу" >/dev/null; ok $? "эскалация доставлена"
grep -q '"event_type":"escalation"' "$rd/events.jsonl"; ok $? "эскалация в журнале"
# журнал не принимает сырой вывод даже в сквозном пути
bash "$HERE/events.sh" append "$rd" check_result '{"check_id":"c","cmd_hash":"h","exit_code":0,"stdout":"..."}' --iter 4 >/dev/null 2>&1
[ $? -ne 0 ]; ok $? "raw stdout по-прежнему отвергается"
rm -rf "$T"
echo; [ "$fail" -eq 0 ] && echo "✅ redloop: все тесты прошли" || echo "❌ redloop: есть падения"
exit $fail

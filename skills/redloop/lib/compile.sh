#!/usr/bin/env bash
# compile.sh — сборка автономного промпта из контракта + библиотеки приёмов (DESIGN v2 §S3).
# Бюджет ≤6000 токенов; обязательные приёмы входят всегда; остальные — по (применимость × success_rate).
# Штампует patterns_sha в contract.json (#9): LAUNCH обязан отказать, если снапшот разъехался.
#
# Usage: compile.sh <contract.json> <out_dir> [--profile code|content|research|infra] | --self-test
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
BUDGET="${REDLOOP_PROMPT_BUDGET:-6000}"

compile() {
  local cf="${1:?contract.json}" out="${2:?out_dir}"; shift 2
  local profile="code"; while [ $# -gt 0 ]; do case "$1" in --profile) profile="$2"; shift 2;; *) shift;; esac; done
  mkdir -p "$out"
  local psha; psha="$(bash "$HERE/patterns.sh" sha)"
  # ⚠ Версию контракта штампует ТОТ, кто его собирает: без штампа подсказка линтера
  # «контракт собран до v3.3, перекомпилируй» срабатывала и на только что собранном.
  local cver; cver="$(jq -r '.contract_version // "unknown"' "$HERE/constants.json" 2>/dev/null || echo unknown)"
  local tmp; tmp="$(mktemp)"; jq --arg s "$psha" --arg v "$cver" '.patterns_sha=$s | .contract_version=$v' "$cf" > "$tmp" && mv "$tmp" "$cf"

  # отбор: mandatory всегда; прочие — по applies и success_rate, пока влезают в бюджет
  local sel; sel="$(bash "$HERE/patterns.sh" list | jq -s --arg pr "$profile" --argjson b "$BUDGET" '
      (map(select(.mandatory)) ) as $must
    | (map(select(.mandatory|not) | select(.applies=="always" or (.applies|test($pr))))
       | sort_by(-.success_rate)) as $opt
    | ($must + $opt)
    | reduce .[] as $p ({acc:[], used:0};
        if .used + $p.tokens <= $b or $p.mandatory
        then {acc: (.acc + [$p]), used: (.used + $p.tokens)} else . end)
    ')"
  local used; used="$(printf '%s' "$sel" | jq '.used')"

  { echo "# Автономный прогон — REDLOOP"
    echo
    echo "## Задача"; jq -r '.task // "(не задана)"' "$cf"; echo
    echo "## Контракт готовности (DoD) — единственный критерий «сделано»"
    # слабая проба (grep/test) едет в промпт с пометкой: агент обязан знать, что она
    # доказывает наличие строки, а не работу поведения — и не считать её подтверждением
    jq -r '.dod[]? | "- [ ] `\(.id)` — "
             + (if (.cmd//"")!="" then "`\(.cmd)` → exit \(.expect_exit)" else "\(.desc) _(вкусовое: приёмка человеком)_" end)
             + (if (.weak // false) then " ⚠ _слабая проба: подтверждает строку в файле, а не поведение_" else "" end)
             + (if (.baseline // null) != null then " _(порог от факта на старте: \(.baseline))_" else "" end)' "$cf"
    # свежий чекер — строка контракта, а не пожелание: без её события run_done отвергается
    if jq -e '(.fresh_check.required // false) == true' "$cf" >/dev/null; then
      echo "- [ ] \`fresh_check\` — свежий контекст ($(jq -r '.fresh_check.kind' "$cf")) вынес вердикт →"
      echo "      событие \`check_result\` с \`check_id: fresh_check\`, полем \`verdict\` (ЕГО вердикт, не твой)"
      echo "      и полем \`report\` — путём к отчёту чекера. Отчёт обязан существовать, быть непустым"
      echo "      и созданным ПОСЛЕ последней итерации; sha256 журнал посчитает сам."
      echo "      Зелёным считается вердикт из списка: $(jq -r '.fresh_ok_verdicts|join(", ")' "$HERE/constants.json")."
      echo "      NEEDS-WORK/FIX-FIRST — не зелёные, журнал отвергнет финал кодом 4."
      echo
      echo "      **Откуда журнал берёт вердикт** (порядок фиксированный, первый сработавший):"
      echo "      1. отчёт сам машинный (\`*.json\` с полем \`verdict\`) → берётся оттуда;"
      echo "      2. рядом с markdown-отчётом лежит $(jq -r '.fresh_machine_artifacts|join(" / ")' "$HERE/constants.json") →"
      echo "         вердикт берётся ИЗ НЕГО, текст отчёта не решает ничего. \`/finalize\` и \`plan-panel\`"
      echo "         пишут его всегда — клади отчёт рядом с ним, это главный и самый надёжный путь."
      echo "         Машинный артефакт проверяется как отчёт: непуст, валиден, не старее последней"
      echo "         итерации; его sha журнал пишет отдельным полем;"
      echo "      3. машинного артефакта нет → объявление вердикта в тексте: сначала строка"
      echo "         ВЕРХНЕГО уровня (\`Вердикт: X\` с начала строки), иначе первое объявление"
      echo "         в строке. Запасной путь, он слабее — не полагайся на него."
      echo "      Вердикт события обязан СОВПАСТЬ с найденным, иначе событие не запишется."
      echo "      Отчёт пишет та же машина, что и патч, — это защита от небрежности и рассинхрона,"
      echo "      это защита от небрежности и рассинхрона, а не доказательство того, что чекер звали."
    elif jq -e 'has("fresh_check")' "$cf" >/dev/null; then
      echo; echo "Свежий чекер отключён владельцем: $(jq -r '.fresh_check.why // "без причины"' "$cf")"
    fi
    # приёмка человеком — по пунктам: у каждого либо адрес пробы, либо честная отметка
    if jq -e '(.human_acceptance // null) != null' "$cf" >/dev/null; then
      echo; echo "Приёмка человеком:"
      if [ "$(jq -r '.human_acceptance | type' "$cf")" = "array" ]; then
        jq -r '.human_acceptance[] | "- \(.id // "•") \(.what // "") — "
                 + (if (.manual_only // false) then "**машинно непроверяемо** (\(.why // "")) → предъявить владельцу в отчёте отдельной строкой"
                    else "проба `\(.probe)`" end)' "$cf"
        echo
        echo "Пункт приёмки без зелёной пробы и без предъявления владельцу — не сделан."
        # ⚠ У предъявления обязан быть машинный след: до v3.3.3 оно жило прозой в ответе
        # агента, которую никто не сверял со списком, — так и потерялись кадры 53/57.
        # ⚠⚠ Адреса берём У ЖУРНАЛА (events.sh acceptance-ids), а не считаем своей jq-формулой.
        # Своя формула уже разошлась: промпт печатал «?» для безымянного пункта, журнал ждал
        # «#2», и предъявление отвергалось как описка. Строку собирает jq, а не склейка кавычек —
        # ручное экранирование давало НЕВАЛИДНЫЙ JSON (acceptance_presented: [53", "57]), то есть
        # единственный машинный инструктаж по новому обязательному полю был заведомо нерабочим.
        local mo; mo="$(bash "$HERE/events.sh" acceptance-ids "$cf" manual 2>/dev/null || echo '[]')"
        if [ "$(printf '%s' "$mo" | jq -r 'length' 2>/dev/null || echo 0)" != "0" ]; then
          echo "В финальном событии \`run_done\` перечисли предъявленные кадры машинно —"
          echo "ровно этими адресами (их знает журнал, свои не выдумывай):"
          echo
          echo '```json'
          jq -nc --argjson ids "$mo" '{acceptance_presented: $ids}'
          echo '```'
          echo "Все до одного. Без этого журнал отвергнет финал кодом 4"
          echo "(reason=acceptance_not_presented), а id, которого нет в приёмке контракта,"
          echo "отвергается как описка (reason=acceptance_presented_unknown)."
        fi
      else
        jq -r '.human_acceptance' "$cf"
      fi
    fi
    echo
    echo "## Рамки"
    echo "- Scope: $(jq -r '.scope_globs | join(", ")' "$cf") — правки вне этих путей запрещены."
    echo "- Бюджет: $(jq -r '.budget.max_iters' "$cf") итераций / $(jq -r '.budget.max_minutes' "$cf") минут."
    echo "- Пороги: stall=$(jq -r '.thresholds.stall' "$cf"), loop=$(jq -r '.thresholds.loop' "$cf")."
    echo "- Эскалация: $(jq -r '.escalation_channel' "$cf")."
    echo "- Раннер: $(jq -r '.runner' "$cf")."
    local dsf; dsf="$(jq -r '(.default_state_files // ["PLAN.md","state.json"])|join(", ")' "$HERE/constants.json" 2>/dev/null || echo "PLAN.md, state.json")"
    local sfl; sfl="$(jq -r --arg d "$dsf" 'if has("state_files") then (.state_files|join(", ")) else $d end' "$cf")"
    if [ -n "$sfl" ]; then
      echo "- Внешнее состояние: $sfl в $(jq -r '.project_root // "<project_root не задан>"' "$cf") —"
      echo "  обязательны со ВТОРОЙ итерации: журнал отвергнет \`iter_done\` без них (reason=state_files_missing)."
      echo "  Эти файлы — служебные, они ВНЕ scope-запрета выше: создавать и править их нужно,"
      echo "  и правкой «вне scope» они не считаются."
    fi
    echo
    echo "## Как работать"
    printf '%s' "$sel" | jq -r '.acc[].file' | while read -r f; do
      echo; sed '1{/^---$/!q;};1,/^---$/d' "$f"
    done
    echo
    echo "## Журнал"
    echo "Каждое действие — событие в \`events.jsonl\` через \`lib/events.sh append\`:"
    echo "**\`run_start\` ПЕРВЫМ** (без него журнал не знает о прогоне ничего и отвергнет финал"
    echo "с \`reason=run_start_missing\`), затем начало и конец итерации (\`--iter N --of M\`),"
    echo "результат каждой проверки (\`check_result\`), каждое допущение (\`assumption\`),"
    echo "финал (\`run_done\`). Молчащий прогон считается упавшим."
    echo
    echo "Поля надзора (\`fresh_check\`, \`state_files\`, \`human_acceptance\`, \`budget\`, \`mode\`)"
    echo "в payload \`run_start\` НЕ слать: журнал берёт их из контракта и отвергнет событие"
    echo "(\`snapshot_override_attempt\`). Правило меняется правкой контракта, не события."
    echo
    echo "Не получилось — это тоже финал, и его надо ЗАПИСАТЬ:"
    # ⚠ Список исходов ПЕЧАТАЕТСЯ ИЗ СЛОВАРЯ, а не прозой: дубль enum'а в промпте уже был
    # назван панелью — переименуй метку, и промпт продолжит учить раннера старой, а гейт
    # ответит outcome_not_in_enum, то есть честный провал снова станет незаписываемым.
    echo "\`run_done\` с \`\"outcome\"\` из: $(jq -r '[.run_done_outcomes[]|select(.!="success")]|join(" | ")' "$HERE/constants.json"). Тогда с прогона"
    echo "не спрашивают ни подписи чекера, ни предъявления кадров — но провал остаётся фактом"
    echo "журнала, а не тишиной. Умолчание \`success\` означает «заявляю успех» со всеми гейтами."
  } > "$out/prompt.md"

  jq -nc --arg out "$out/prompt.md" --argjson used "$used" --argjson budget "$BUDGET" \
     --arg psha "$psha" --argjson picked "$(printf '%s' "$sel" | jq '[.acc[].id]')" \
     '{prompt:$out, tokens_est:$used, budget:$budget, patterns_sha:$psha, patterns:$picked}'
}

self_test() {
  set +e; local T; T="$(mktemp -d)"; local fail=0
  ok(){ if [ "$1" -eq 0 ]; then :; else echo "  ✗ $2"; fail=1; fi; }
  cat > "$T/c.json" <<'J'
{"task":"починить X","runner":"loop","scope_globs":["src/**"],
 "budget":{"max_iters":10,"max_minutes":60},"thresholds":{"stall":3,"loop":3},
 "escalation_channel":"tg:attunedbot",
 "dod":[{"id":"t","cmd":"npm test","expect_exit":0}]}
J
  local r; r="$(compile "$T/c.json" "$T/out")"; ok $? "compile отрабатывает"
  printf '%s' "$r" | jq -e '.tokens_est <= .budget' >/dev/null; ok $? "укладывается в бюджет"
  printf '%s' "$r" | jq -e '.patterns | index("P-UNTRUSTED")' >/dev/null; ok $? "P-UNTRUSTED в промпте всегда"
  printf '%s' "$r" | jq -e '.patterns | index("P-EXIT")' >/dev/null; ok $? "P-EXIT в промпте всегда"
  grep -q "npm test" "$T/out/prompt.md"; ok $? "DoD-команда попала в промпт"
  grep -q "REDLOOP_STATUS" "$T/out/prompt.md"; ok $? "блок статуса (двухусловный выход) в промпте"
  grep -q "^---$" "$T/out/prompt.md" && ok 1 "frontmatter приёмов вырезан" || ok 0 ""
  [ -n "$(jq -r .patterns_sha "$T/c.json")" ]; ok $? "patterns_sha проштампован в контракт"
  # тесный бюджет: обязательные всё равно внутри
  REDLOOP_PROMPT_BUDGET=100 compile "$T/c.json" "$T/out2" | jq -e '.patterns | index("P-NOASK")' >/dev/null
  ok $? "при тесном бюджете обязательные приёмы не режутся"

  # ── v3.3: новые поля контракта обязаны дойти до промпта, иначе правило живёт только в гейте
  cat > "$T/c2.json" <<'J'
{"task":"витрина","runner":"session","scope_globs":["src/**"],"project_root":"/tmp",
 "budget":{"max_iters":12,"max_minutes":120},"thresholds":{"stall":3,"loop":3},
 "escalation_channel":"tg:attunedbot",
 "fresh_check":{"kind":"finalize","required":true},
 "state_files":["PLAN.md","state.json"],
 "dod":[{"id":"smoke","cmd":"npm run smoke","expect_exit":0},
        {"id":"card","cmd":"grep -q wb-pr- a.css","expect_exit":0,"weak":true},
        {"id":"n","cmd":"test $(grep -c x a.ts) -ge 43","expect_exit":0,"weak":true,"baseline":40}],
 "human_acceptance":[{"id":"52","what":"карточка программы","probe":"card"},
                     {"id":"57","what":"конструктор без программ","manual_only":true,"why":"вкусовой кадр"}]}
J
  compile "$T/c2.json" "$T/out3" >/dev/null; ok $? "compile переваривает контракт v3.3"
  grep -q 'fresh_check' "$T/out3/prompt.md"; ok $? "свежий чекер стоит отдельной строкой DoD"
  grep -q 'NEEDS-WORK' "$T/out3/prompt.md"; ok $? "промпт называет вердикт, который НЕ считается зелёным"
  grep -q 'слабая проба' "$T/out3/prompt.md"; ok $? "слабая проба помечена в промпте"
  grep -q 'порог от факта на старте: 40' "$T/out3/prompt.md"; ok $? "порог показан вместе с фактом на старте"
  grep -q 'конструктор без программ' "$T/out3/prompt.md"; ok $? "пункт приёмки без пробы попал в промпт (а не растворился в прозе)"
  grep -q 'машинно непроверяемо' "$T/out3/prompt.md"; ok $? "он помечен как предъявляемый владельцу"
  grep -q 'state_files_missing' "$T/out3/prompt.md"; ok $? "требование внешнего состояния названо машинной причиной отказа"
  # отключённый чекер: промпт обязан назвать причину, а не молчать
  jq '.fresh_check={"kind":"finalize","required":false,"why":"правка на три строки"}' "$T/c2.json" > "$T/c3.json"
  compile "$T/c3.json" "$T/out4" >/dev/null
  grep -q 'правка на три строки' "$T/out4/prompt.md"; ok $? "осознанный отказ от чекера виден в промпте с причиной"
  rm -rf "$T"
  [ "$fail" -eq 0 ] && { echo "✓ compile self-test passed"; return 0; } || { echo "✗ compile self-test FAILED"; return 1; }
}
case "${1:-}" in --self-test) self_test ;; "") echo "usage: compile.sh <contract.json> <out_dir> [--profile P] | --self-test" >&2; exit 1;; *) compile "$@" ;; esac

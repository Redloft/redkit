#!/usr/bin/env bash
# contract-lint.sh — гейт автономного старта (DESIGN v2 §S2). Fail-closed.
# Контракт годен, если ≥80% строк DoD исполнимы командой с exit code, пороги проставлены
# числами, scope задан, бюджет задан. Иначе — отказ с точным списком, что спросить у owner'а.
#
# v3.3 (разбор прогона 2026-09-03): прогон объявил себя зелёным, а свежий чекер дал NEEDS-WORK,
# и два кадра приёмки («сочетаемость», «конструктор») не были тронуты вообще. Причина не в модели,
# а в контракте: свежая проверка жила только в прозе промпта, приёмка человеком была одной строкой
# текста, а половина проб — `grep -q`. Отсюда четыре новых правила:
#   fresh_check      — свежий чекер обязателен и объявлен машинно (или явный отказ с причиной);
#   human_acceptance — список пунктов, у каждого проба ЛИБО отметка «машинно непроверяемо»;
#   weak             — проба вида grep/test обязана быть признана слабой явно;
#   baseline         — порог вида `-ge N` считается от факта на старте, а не берётся из воздуха.
#   state_files      — внешнее состояние прогона (PLAN.md/state.json) имеет адрес, а не подразумевается.
#
# Usage: contract-lint.sh <contract.json> | --self-test
set -euo pipefail
MIN_RATIO="${REDLOOP_DOD_MIN_RATIO:-80}"
FRESH_STRICT="${REDLOOP_FRESH_CHECK_STRICT:-1}"
ACC_STRICT="${REDLOOP_ACCEPTANCE_STRICT:-1}"
PROBE_STRICT="${REDLOOP_PROBE_STRICT:-1}"
STATE_STRICT="${REDLOOP_STATE_FILES_STRICT:-1}"
HERE_L="$(cd "$(dirname "$0")" && pwd)"
CONST_L="$HERE_L/constants.json"
# fail-closed, как у остальных потребителей словаря: молчаливый фолбэк на зашитую копию —
# это ровно тот тихий дрейф, ради устранения которого словарь и заведён
jq -e '.fresh_kinds' "$CONST_L" >/dev/null 2>&1 || {
  echo '{"ok":false,"failed":["constants_missing"]}'; exit 1; }
FRESH_KINDS="$(jq -r '.fresh_kinds|join(" ")' "$CONST_L")"
# точное сравнение, НЕ grep: kind=".*" проходил регуляркой (тот же дефект, что в гейте И8)
_in_list() { local needle="$1"; shift; local x; for x in $*; do [ "$x" = "$needle" ] && return 0; done; return 1; }

# Проба слабая, если она смотрит на файл глазами grep/test, а не гоняет проверку проекта.
# Слабая проба допустима (иногда другой нет), но обязана быть подписана — тогда она попадёт
# в промпт и в отчёт владельцу с пометкой, а не сойдёт за доказательство.
# ⚠ Якорим test/ls/[ по НАЧАЛУ команды или шов оболочки, а не по любому пробелу: иначе
# честная строка `npm test --silent` объявляется слабой пробой. Ложная тревога обесценивает
# правило быстрее пропуска (false-alarm-economics), а тут она била бы по самым нужным DoD.
# Словарь слабых проб: любой grep/rg/ag (в ЛЮБОМ написании флага — -q, --quiet, -c, --count),
# а также test/[/[[/ls/jq -e в начале команды или после шва оболочки. Узкий словарь пропускал
# ровно те формы, которыми проще всего зазеленить контракт, не сделав работы.
WEAK_RE='(^|[;&|(]|&& |\|\| |\$\()[[:space:]]*(grep|egrep|fgrep|rg|ag|test|ls|\[\[|\[)[[:space:]]|(grep|rg|ag)[[:space:]]+-[-A-Za-z]*(q|c|quiet|count)|jq[[:space:]]+-[A-Za-z]*e[[:space:]]'
THRESH_RE='-(ge|gt|le|lt|eq)[[:space:]]+[0-9]'
# порог «не меньше нуля» ничего не утверждает — факт на старте для него не нужен
THRESH_ZERO_RE='-(ge|gt|le|lt|eq)[[:space:]]+0([^0-9]|$)'

lint() {
  local f="${1:?contract.json}"; [ -f "$f" ] || { echo '{"ok":false,"failed":["contract_missing"]}'; return 1; }
  jq -e . "$f" >/dev/null 2>&1 || { echo '{"ok":false,"failed":["contract_not_json"]}'; return 1; }
  local failed="[]"; add(){ failed="$(printf '%s' "$failed" | jq -c --arg x "$1" '. + [$x]')"; }

  local total green ratio
  total="$(jq '[.dod[]?] | length' "$f")"
  green="$(jq '[.dod[]? | select((.cmd // "") != "" and has("expect_exit"))] | length' "$f")"
  [ "${total:-0}" -eq 0 ] && { add "dod_empty"; ratio=0; } || ratio=$(( green * 100 / total ))
  [ "$ratio" -lt "$MIN_RATIO" ] && add "dod_not_machine_checkable(${ratio}%<${MIN_RATIO}%)"

  # вкусовое качество допустимо, но обязано быть явно вынесено человеку, а не молча пропасть
  jq -e '(.human_acceptance // null) != null or ([.dod[]? | select((.cmd//"")=="")] | length)==0' "$f" >/dev/null \
    || add "subjective_criteria_without_human_acceptance"

  jq -e '(.scope_globs // []) | length > 0' "$f" >/dev/null || add "scope_globs_empty"
  jq -e '(.budget.max_iters // 0) > 0' "$f" >/dev/null || add "budget_max_iters_missing"
  jq -e '(.budget.max_minutes // 0) > 0' "$f" >/dev/null || add "budget_max_minutes_missing"
  jq -e '(.thresholds.stall // 0) > 0 and (.thresholds.loop // 0) > 0' "$f" >/dev/null \
    || add "thresholds_not_numeric"   # порог, назначаемый постфактум, — не порог
  jq -e '(.escalation_channel // "") != ""' "$f" >/dev/null || add "escalation_channel_missing"
  jq -e '(.runner // "") != ""' "$f" >/dev/null || add "runner_missing"
  # штамп версий: без него снапшот приёмов не проверить на quarantine-дрейф
  jq -e '(.patterns_sha // "") != ""' "$f" >/dev/null || add "patterns_sha_missing"

  # ── R1. Свежий чекер — строка контракта, а не пожелание промпта ────────────────
  if [ "$FRESH_STRICT" = "1" ]; then
    if ! jq -e 'has("fresh_check")' "$f" >/dev/null; then
      add "fresh_check_missing"
    else
      local fk req why
      fk="$(jq -r '.fresh_check.kind // ""' "$f")"
      req="$(jq -r 'if (.fresh_check|has("required")) then (.fresh_check.required|tostring) else "" end' "$f")"
      _in_list "$fk" $FRESH_KINDS || add "fresh_check_kind_unknown($fk)"
      case "$req" in true|false) ;; *) add "fresh_check_required_not_boolean" ;; esac
      # отказ от свежего чекера возможен — но с причиной в контракте, а не молча
      if [ "$req" = "false" ]; then
        why="$(jq -r '.fresh_check.why // ""' "$f")"
        [ -n "$why" ] || add "fresh_check_optout_without_why"
      fi
    fi
  fi

  # ── R2. Приёмка человеком — список пунктов, каждый с адресом проверки ─────────
  # Кадры 53/57 прошлого прогона выпали именно тут: они были в прозе, пробы под них не было,
  # и «зелёный» контракт про них ничего не знал.
  if [ "$ACC_STRICT" = "1" ]; then
   # ⚠ Правило было opt-in: контракт БЕЗ поля проходил с ok:true, и исходный инцидент
   # воспроизводился удалением строки. Теперь поле обязательно; осознанный отказ — пустой
   # список плюс причина, ровно как у fresh_check.
   if ! jq -e 'has("human_acceptance")' "$f" >/dev/null; then
    add "human_acceptance_missing"
   else
    local hatype; hatype="$(jq -r '.human_acceptance | type' "$f")"
    if [ "$hatype" = "array" ] && [ "$(jq '.human_acceptance|length' "$f")" = "0" ]; then
      jq -e '(.acceptance_optout_why // "") != ""' "$f" >/dev/null \
        || add "acceptance_optout_without_why"
    elif [ "$hatype" != "array" ]; then
      add "human_acceptance_not_itemized"
    else
      local bad
      bad="$(jq -r '[.human_acceptance[] | select((.what // "") == "")] | length' "$f")"
      [ "${bad:-0}" -gt 0 ] && add "acceptance_item_without_what($bad)"
      bad="$(jq -r '[.human_acceptance[]
                     | select((.probe // "") == "" and (.manual_only // false) != true)
                     | (.id // .what)] | join(",")' "$f")"
      [ -n "$bad" ] && add "acceptance_item_without_probe($bad)"
      bad="$(jq -r '[.human_acceptance[]
                     | select((.manual_only // false) == true and (.why // "") == "")
                     | (.id // .what)] | join(",")' "$f")"
      [ -n "$bad" ] && add "acceptance_manual_only_without_why($bad)"
      # ссылка на пробу обязана указывать на существующую строку DoD, иначе это та же проза
      bad="$(jq -r '([.dod[]?.id]) as $ids
                    | [.human_acceptance[] | select((.probe // "") != "")
                       | select((.probe | IN($ids[])) | not) | .probe] | join(",")' "$f")"
      [ -n "$bad" ] && add "acceptance_probe_unknown($bad)"
    fi
   fi
  fi

  # ── R3. Слабые пробы и пороги из воздуха ─────────────────────────────────────
  if [ "$PROBE_STRICT" = "1" ]; then
    local unack thr
    unack="$(jq -r --arg re "$WEAK_RE" '[.dod[]? | select((.cmd // "") | test($re))
                | select((.weak // false) != true) | .id] | join(",")' "$f")"
    [ -n "$unack" ] && add "weak_probe_unacknowledged($unack)"
    thr="$(jq -r --arg re "$THRESH_RE" --arg z "$THRESH_ZERO_RE" '[.dod[]?
                | select((.cmd // "") | test($re)) | select((.cmd // "") | test($z) | not)
                | select((.baseline // null) | type != "number") | .id] | join(",")' "$f")"
    [ -n "$thr" ] && add "threshold_without_baseline($thr)"
    # все пробы слабые = контракт не проверяет ничего, кроме собственных строк
    local w a
    w="$(jq --arg re "$WEAK_RE" '[.dod[]? | select((.cmd // "") | test($re))] | length' "$f")"
    a="$(jq '[.dod[]? | select((.cmd // "") != "")] | length' "$f")"
    [ "${a:-0}" -gt 0 ] && [ "$w" = "$a" ] && add "all_probes_weak(${w}/${a})"
  fi

  # ── R4. Внешнее состояние имеет адрес ────────────────────────────────────────
  # Прогон 2026-09-03 шёл по памяти: PLAN.md и state.json не появились ни разу.
  if [ "$STATE_STRICT" = "1" ]; then
    local sf; sf="$(jq -r 'if has("state_files") then (.state_files | length | tostring) else "default" end' "$f")"
    if [ "$sf" != "0" ]; then   # [] = осознанный отказ (одноитерационная работа)
      local pr; pr="$(jq -r '.project_root // ""' "$f")"
      if [ -z "$pr" ]; then add "project_root_missing"
      else
        # относительный путь резолвится от caller'а, а не от прогона: гейт и раннер
        # смотрели бы в разные каталоги и расходились молча
        case "$pr" in /*) ;; *) add "project_root_not_absolute" ;; esac
        [ -d "$pr" ] || add "project_root_not_a_dir"
      fi
    fi
  fi

  # ⚠ Старый контракт и плохой контракт — разные диагнозы. Без этого resume любого прогона
  # парка упирался в NO-GO с четырьмя причинами и без подсказки, что делать.
  local cv; cv="$(jq -r '.contract_version // ""' "$f")"
  local n; n="$(printf '%s' "$failed" | jq 'length')"
  if [ "$n" -gt 0 ] && [ -z "$cv" ]; then
    echo "ℹ контракт без contract_version — вероятно, собран до v3.3. Не правь руками: перекомпилируй" >&2
    echo "  bash lib/compile.sh $f <run_dir>   (заодно обновит patterns_sha)" >&2
  fi
  jq -nc --argjson f "$failed" --argjson ratio "${ratio:-0}" --argjson ok "$([ "$n" -eq 0 ] && echo true || echo false)" \
    '{ok:$ok, dod_machine_ratio:$ratio, failed:$f}'
  [ "$n" -eq 0 ]
}

self_test() {
  set +e; local T; T="$(mktemp -d)"; local fail=0
  ok(){ if [ "$1" -eq 0 ]; then :; else echo "  ✗ $2"; fail=1; fi; }
  # ⚠ НЕ `lint f | jq`: под pipefail статус конвейера берётся от lint (он законно возвращает 1
  # на плохом контракте), и проверка содержимого молча читалась бы как провал самого теста.
  hasfail(){ local out; out="$(lint "$1" 2>/dev/null || true)"
             printf '%s' "$out" | jq -e --arg p "$2" '.failed | any(. == $p or startswith($p))' >/dev/null; }
  mkdir -p "$T/proj"
  cat > "$T/good.json" <<J
{"runner":"loop","scope_globs":["src/**"],"patterns_sha":"deadbeef",
 "budget":{"max_iters":12,"max_minutes":90},"thresholds":{"stall":3,"loop":3},
 "escalation_channel":"tg:attunedbot",
 "fresh_check":{"kind":"finalize","required":true},
 "project_root":"$T/proj",
 "human_acceptance":[{"id":"1","what":"экран открывается","probe":"t"}],
 "dod":[{"id":"t","cmd":"npm test","expect_exit":0},{"id":"b","cmd":"npm run build","expect_exit":0}]}
J
  lint "$T/good.json" >/dev/null; ok $? "валидный контракт проходит"
  jq '.dod += [{"id":"nice","desc":"красиво"}]' "$T/good.json" > "$T/mix.json"
  lint "$T/mix.json" >/dev/null 2>&1; ok $((1-$?)) "66% исполнимых DoD → отказ (ниже порога 80%)"
  jq '.dod = [{"id":"a","cmd":"x","expect_exit":0},{"id":"b","cmd":"y","expect_exit":0},{"id":"c","cmd":"z","expect_exit":0},{"id":"d","cmd":"w","expect_exit":0},{"id":"e","desc":"вкусовое"}] | .human_acceptance=[{"id":"52","what":"карточка","probe":"a"}]' "$T/good.json" > "$T/m80.json"
  lint "$T/m80.json" >/dev/null; ok $? "80% + разобранная приёмка проходит"
  jq 'del(.human_acceptance)' "$T/m80.json" > "$T/m80b.json"
  lint "$T/m80b.json" >/dev/null 2>&1; ok $((1-$?)) "вкусовой критерий без human_acceptance отвергнут"
  # ⚠ Правило было opt-in: контракт БЕЗ поля проходил, и исходный инцидент воспроизводился
  # простым удалением строки. Негативный контроль на это — обязателен.
  hasfail "$T/m80b.json" "human_acceptance_missing"
  ok $? "R2: контракт вообще без human_acceptance отвергнут, а не пропущен"
  jq '.human_acceptance=[]' "$T/good.json" > "$T/haempty.json"
  hasfail "$T/haempty.json" "acceptance_optout_without_why"
  ok $? "R2: пустая приёмка без причины отвергнута"
  jq '.human_acceptance=[] | .acceptance_optout_why="правка тулинга, кадров нет"' "$T/good.json" > "$T/haopt.json"
  lint "$T/haopt.json" >/dev/null; ok $? "R2: осознанный отказ от приёмки с причиной проходит"
  jq 'del(.thresholds)' "$T/good.json" > "$T/nothr.json"
  lint "$T/nothr.json" >/dev/null 2>&1; ok $((1-$?)) "нет числовых порогов → отказ"
  jq 'del(.escalation_channel)' "$T/good.json" > "$T/noch.json"
  lint "$T/noch.json" >/dev/null 2>&1; ok $((1-$?)) "нет канала эскалации → отказ"
  lint "$T/missing.json" >/dev/null 2>&1; ok $((1-$?)) "нет файла → fail-closed"

  # R1 — свежий чекер
  jq 'del(.fresh_check)' "$T/good.json" > "$T/nofc.json"
  hasfail "$T/nofc.json" "fresh_check_missing"
  ok $? "R1: нет fresh_check → отказ (прогон закроется собственным ощущением готовности)"
  jq '.fresh_check={"kind":"finalize","required":false}' "$T/good.json" > "$T/fcopt.json"
  hasfail "$T/fcopt.json" "fresh_check_optout_without_why"
  ok $? "R1: отказ от чекера без причины отвергнут"
  jq '.fresh_check={"kind":"finalize","required":false,"why":"артефакт на 5 строк"}' "$T/good.json" > "$T/fcok.json"
  lint "$T/fcok.json" >/dev/null; ok $? "R1: осознанный отказ с причиной проходит"
  jq '.fresh_check={"kind":"вручную","required":true}' "$T/good.json" > "$T/fcbad.json"
  hasfail "$T/fcbad.json" "fresh_check_kind_unknown"
  ok $? "R1: неизвестный вид чекера отвергнут"
  jq '.fresh_check={"kind":".*","required":true}' "$T/good.json" > "$T/fcre.json"
  hasfail "$T/fcre.json" "fresh_check_kind_unknown"
  ok $? "R1: метасимвол .* вместо вида чекера НЕ проходит (сверка списком, не регуляркой)"

  # R2 — приёмка
  jq '.human_acceptance="глазами по кадрам 52, 53, 57"' "$T/good.json" > "$T/hastr.json"
  hasfail "$T/hastr.json" "human_acceptance_not_itemized"
  ok $? "R2: приёмка одной строкой прозы отвергнута"
  jq '.human_acceptance=[{"id":"53","what":"сочетаемость"}]' "$T/good.json" > "$T/hanop.json"
  hasfail "$T/hanop.json" "acceptance_item_without_probe"
  ok $? "R2: пункт приёмки без пробы и без отметки отвергнут"
  jq '.human_acceptance=[{"id":"57","what":"конструктор","probe":"нет-такой-строки"}]' "$T/good.json" > "$T/habad.json"
  hasfail "$T/habad.json" "acceptance_probe_unknown"
  ok $? "R2: ссылка на несуществующую пробу отвергнута"
  jq '.human_acceptance=[{"id":"61","what":"ощущение приседа","manual_only":true}]' "$T/good.json" > "$T/hamo.json"
  hasfail "$T/hamo.json" "acceptance_manual_only_without_why"
  ok $? "R2: «машинно непроверяемо» без причины отвергнуто"
  jq '.human_acceptance=[{"id":"61","what":"ощущение приседа","manual_only":true,"why":"тактильное"},{"id":"52","what":"карточка","probe":"t"}]' "$T/good.json" > "$T/hagood.json"
  lint "$T/hagood.json" >/dev/null; ok $? "R2: проба + честная отметка проходят"

  # R3 — слабые пробы и пороги
  jq '.dod += [{"id":"card","cmd":"grep -q wb-pr- src/x.css","expect_exit":0}]' "$T/good.json" > "$T/weak.json"
  hasfail "$T/weak.json" "weak_probe_unacknowledged"
  ok $? "R3: grep -q как непризнанная проба отвергнут"
  jq '.dod += [{"id":"card","cmd":"grep -q wb-pr- src/x.css","expect_exit":0,"weak":true}]' "$T/good.json" > "$T/weakok.json"
  lint "$T/weakok.json" >/dev/null; ok $? "R3: признанная слабой проба проходит"
  # негативный контроль: честная команда со словом test внутри слабой НЕ объявляется
  jq '.dod += [{"id":"unit","cmd":"npm test --silent","expect_exit":0},{"id":"e2e","cmd":"cd app && npx playwright test","expect_exit":0}]' "$T/good.json" > "$T/nottest.json"
  lint "$T/nottest.json" >/dev/null; ok $? "R3: «npm test» и «playwright test» слабыми НЕ считаются"
  jq '.dod += [{"id":"f","cmd":"cd app && test -f dist/index.html","expect_exit":0}]' "$T/good.json" > "$T/weak2.json"
  hasfail "$T/weak2.json" "weak_probe_unacknowledged"; ok $? "R3: «test -f» после && всё же ловится"
  # формы, которыми проще всего обойти узкий словарь
  jq '.dod += [{"id":"g1","cmd":"grep --quiet foo a.ts","expect_exit":0}]' "$T/good.json" > "$T/wq.json"
  hasfail "$T/wq.json" "weak_probe_unacknowledged"; ok $? "R3: grep --quiet ловится"
  jq '.dod += [{"id":"g2","cmd":"cd app && rg -c foo a.ts","expect_exit":0}]' "$T/good.json" > "$T/wrg.json"
  hasfail "$T/wrg.json" "weak_probe_unacknowledged"; ok $? "R3: rg -c ловится"
  jq '.dod += [{"id":"g3","cmd":"cd app && [[ -f dist/i.html ]]","expect_exit":0}]' "$T/good.json" > "$T/wbb.json"
  hasfail "$T/wbb.json" "weak_probe_unacknowledged"; ok $? "R3: [[ -f ]] ловится"
  jq '.dod += [{"id":"g4","cmd":"jq -e . out.json","expect_exit":0}]' "$T/good.json" > "$T/wjq.json"
  hasfail "$T/wjq.json" "weak_probe_unacknowledged"; ok $? "R3: jq -e ловится"
  # порог «не меньше нуля» ничего не утверждает — факта на старте не требуем
  jq '.dod += [{"id":"z","cmd":"test $(ls dist | wc -l) -ge 0","expect_exit":0,"weak":true}]' "$T/good.json" > "$T/thz.json"
  lint "$T/thz.json" >/dev/null; ok $? "R3: порог -ge 0 не требует baseline (утверждения в нём нет)"
  jq '.dod += [{"id":"n","cmd":"test $(grep -c foo a.ts) -ge 43","expect_exit":0,"weak":true}]' "$T/good.json" > "$T/thr.json"
  hasfail "$T/thr.json" "threshold_without_baseline"
  ok $? "R3: порог -ge N без факта на старте отвергнут"
  jq '.dod += [{"id":"n","cmd":"test $(grep -c foo a.ts) -ge 43","expect_exit":0,"weak":true,"baseline":40}]' "$T/good.json" > "$T/throk.json"
  lint "$T/throk.json" >/dev/null; ok $? "R3: порог с baseline проходит"
  jq '.dod=[{"id":"a","cmd":"grep -q x y","expect_exit":0,"weak":true},{"id":"b","cmd":"grep -q z y","expect_exit":0,"weak":true}]' "$T/good.json" > "$T/allweak.json"
  hasfail "$T/allweak.json" "all_probes_weak"
  ok $? "R3: контракт из одних grep'ов отвергнут целиком"

  # R4 — внешнее состояние
  jq 'del(.project_root)' "$T/good.json" > "$T/nopr.json"
  hasfail "$T/nopr.json" "project_root_missing"
  ok $? "R4: нет адреса проекта → отказ (PLAN.md негде проверить)"
  jq '.project_root="/нет/такого/пути"' "$T/good.json" > "$T/badpr.json"
  hasfail "$T/badpr.json" "project_root_not_a_dir"
  ok $? "R4: несуществующий project_root отвергнут"
  jq '.project_root="proj"' "$T/good.json" > "$T/relpr.json"
  hasfail "$T/relpr.json" "project_root_not_absolute"
  ok $? "R4: относительный project_root отвергнут (гейт и раннер смотрели бы в разные каталоги)"
  jq 'del(.project_root) | .state_files=[]' "$T/good.json" > "$T/nostate.json"
  lint "$T/nostate.json" >/dev/null; ok $? "R4: осознанный отказ от внешнего состояния (state_files=[]) проходит"

  # рубильники действительно выключают
  REDLOOP_FRESH_CHECK_STRICT=0 REDLOOP_ACCEPTANCE_STRICT=0 REDLOOP_PROBE_STRICT=0 REDLOOP_STATE_FILES_STRICT=0 \
    bash "$0" "$T/hastr.json" >/dev/null 2>&1
  ok $? "рубильники снимают все четыре новых правила разом"

  rm -rf "$T"
  [ "$fail" -eq 0 ] && { echo "✓ contract-lint self-test passed"; return 0; } || { echo "✗ contract-lint self-test FAILED"; return 1; }
}
case "${1:-}" in --self-test) self_test ;; "") echo "usage: contract-lint.sh <contract.json> | --self-test" >&2; exit 1;; *) lint "$@" ;; esac

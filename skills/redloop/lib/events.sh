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
VALID_KINDS="progress infra_failure negative_verdict blocked"
# закрытый enum причин блокировки: свободный текст здесь развалит машинное чтение
BLOCKED_RESULTS="blocked_by_env blocked_owner_action"
FORBIDDEN_FIELDS="stdout stderr raw output command_output"

_required() { case "$1" in
  run_start)     echo "runner contract_sha" ;;   # budget/strict_journal дописываются ниже
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


# ── реестр прогонов (v3.1) ────────────────────────────────────────────────────
# Прогоны живут ГДЕ УГОДНО: в папке скилла и в .redloop/runs/ самого проекта.
# Пока учёт шёл по одному каталогу, третий живой прогон был невидим — а значит и
# знаменатель калибровки («5 живых прогонов») считался по неполному парку.
REG="${REDLOOP_INDEX:-$(cd "$HERE/.." && pwd)/runs/index.jsonl}"

_register_run() {
  local rd="$1" payload="$2"
  local abs; abs="$(cd "$rd" 2>/dev/null && pwd)" || abs="$rd"
  mkdir -p "$(dirname "$REG")" 2>/dev/null || true
  # идемпотентно: повторный run_start того же прогона не плодит строк
  # у реестра свой лок: второй писатель без сериализации — тот же класс, что уже держим
  # под локом для events.jsonl
  local rlk="$REG.lock"; _lock "$rlk" || { echo "⚠ реестр занят, прогон не зарегистрирован" >&2; return 0; }
  if [ -f "$REG" ] && grep -qF "\"path\":\"$abs\"" "$REG" 2>/dev/null; then rm -rf "$rlk"; return 0; fi
  # ⚠ Текст задачи в реестр НЕ копируем. Это был единственный писатель, обходивший
  # fail-closed секрет-гард: формулировка задачи может содержать что угодно, а реестр
  # читают и сторож, и калибровка. Им хватает пути, run_id, раннера и режима.
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg rid "$(basename "$rd")" \
     --arg path "$abs" \
     --arg runner "$(printf '%s' "$payload" | jq -r '.runner // "?"')" \
     --arg mode "$(printf '%s' "$payload" | jq -r '.mode // "autonomous"')" \
     '{ts:$ts, run_id:$rid, path:$path, runner:$runner, mode:$mode}' >> "$REG" 2>/dev/null \
    || echo "⚠ прогон не попал в реестр ($REG) — он будет невидим для калибровки и статуса" >&2
  rm -rf "$rlk"
}

# ── политика журнала (И1/И3, v3) ───────────────────────────────────────────────
# Строгость фиксируется в run_start и дальше читается ИЗ ЖУРНАЛА, а не из окружения:
# иначе прогон, стартовавший до выката, потерял бы финал на ужесточении (панель, critical #6).
# Рубильник: REDLOOP_STRICT_JOURNAL=0 на старте прогона.
_strict_of_run() {
  local rd="$1"
  [ -f "$rd/events.jsonl" ] || { echo "${REDLOOP_STRICT_JOURNAL:-1}"; return; }
  # ⚠ НЕ `// empty`: в jq оператор // считает false пустым, и рубильник strict=0 молча
  # превращался бы в strict=1 — то есть выключатель не выключал бы.
  local v; v="$(jq -s -r 'map(select(.event_type=="run_start"))|.[0].payload
                          | if has("strict_journal") then (.strict_journal|tostring) else "" end' \
                "$rd/events.jsonl" 2>/dev/null)"
  # Журнал есть, а поля нет → прогон стартовал ДО выката v3. Такой доживает по старым
  # правилам (strict=0): иначе обещание «идущий прогон не потеряет финал» было бы ложным.
  case "$v" in true) echo 1 ;; false) echo 0 ;; *) echo 0 ;; esac
}

# Отказ по политике: код 4 (машинно отличим от 1 «невалидный вход») + причина в машинном виде.
_reject() { echo "✗ REJECT reason=$1 :: $2" >&2; return 4; }

_policy_check() {
  local rd="$1" et="$2" payload="$3"
  [ "$et" = "run_done" ] || return 0
  local strict; strict="$(_strict_of_run "$rd")"
  # ⚠ отсутствие журнала — не повод пропустить политику: run_done первым событием означает
  # ровно ноль итераций, то есть самый слепой прогон из возможных.
  if [ ! -f "$rd/events.jsonl" ]; then
    [ "$strict" = "1" ] || return 0
    _reject no_iterations_logged "финал первым событием прогона — в журнале нет ни одной итерации"; return 4
  fi

  # И3: финал объявляется ОДИН раз. Идентичный повтор — no-op (ретрай раннера),
  # отличающийся payload — отказ: это «доделал после финала», ему нужен новый run_id.
  local prev; prev="$(jq -s -c 'map(select(.event_type=="run_done"))|.[-1].payload // empty' "$rd/events.jsonl" 2>/dev/null)"
  if [ -n "$prev" ] && [ "$prev" != "null" ]; then
    if [ "$(printf '%s' "$prev" | jq -S -c .)" = "$(printf '%s' "$payload" | jq -S -c .)" ]; then
      echo "⚠ run_done уже записан с тем же payload — повтор проигнорирован (no-op)" >&2
      return 9   # 9 = идемпотентный no-op, не ошибка
    fi
    if [ "$strict" = "1" ]; then
      _reject run_done_already_recorded "финал уже объявлен; продолжение работы = новый run_id"; return 4
    fi
    echo "⚠ второй run_done (strict off) — записываю" >&2
  fi

  # И1: финал без единой итерации в журнале означает, что пять детекторов из шести были слепы.
  if [ "$strict" = "1" ]; then
    local iters; iters="$(jq -s '[.[]|select(.event_type=="iter_done")]|length' "$rd/events.jsonl" 2>/dev/null || echo 0)"
    if [ "${iters:-0}" -eq 0 ]; then
      _reject no_iterations_logged "финал без единого iter_done — детекторы слепые; пиши iter_done каждую итерацию"; return 4
    fi
  fi
  return 0
}

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
      check_result)
        # порядок важен: blocked проверяется ПЕРВЫМ, иначе exit≠0 штампует negative_verdict
        # и заблокированная внешним проверка навсегда считается красной (панель, critical #1)
        local res; res="$(printf '%s' "$payload" | jq -r '.result // ""')"
        if [ -n "$res" ] && [ "${res#blocked}" != "$res" ]; then
          echo "$BLOCKED_RESULTS" | grep -qw "$res" || {
            echo "✗ result вне enum блокировок ($BLOCKED_RESULTS): $res" >&2; return 1; }
          kind="blocked"
        elif [ "$(printf '%s' "$payload" | jq -r '.exit_code')" = "0" ]; then kind="progress"
        else kind="negative_verdict"; fi ;;
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

  _policy_check "$rd" "$et" "$payload" || { local pc=$?; [ "$pc" = "9" ] && return 0; return $pc; }

  mkdir -p "$rd"
  local lk="$rd/.events.lock"; _lock "$lk" || { echo "✗ lock timeout" >&2; return 1; }
  local seq; local n=0; [ -f "$rd/events.jsonl" ] && n=$(wc -l < "$rd/events.jsonl" | tr -d " ")
  seq=$(( n + 1 ))
  local rid; rid="$(basename "$rd")"
  # снапшот бюджета в сам журнал: детектор остаётся чистой функцией от events.jsonl (И2)
  if [ "$et" = "run_start" ]; then
    local strict_flag; [ "${REDLOOP_STRICT_JOURNAL:-1}" = "0" ] && strict_flag=false || strict_flag=true
    local budget="null" mode="autonomous"
    if [ -f "$rd/contract.json" ]; then
      budget="$(jq -c '.budget // null' "$rd/contract.json" 2>/dev/null || echo null)"
      mode="$(jq -r '.mode // "autonomous"' "$rd/contract.json" 2>/dev/null || echo autonomous)"
    fi
    [ "$mode" = "autonomous" ] || [ "$mode" = "assisted" ] || mode="autonomous"
    payload="$(printf '%s' "$payload" | jq -c --argjson b "$budget" --argjson sj "$strict_flag" --arg m "$mode" \
      '. + {budget: (.budget // $b), strict_journal: (.strict_journal // $sj), mode: (.mode // $m)}')"
  fi
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg rid "$rid" --argjson seq "$seq" \
     --arg et "$et" --arg kind "$kind" --arg sev "$sev" \
     --argjson iter "$iter" --argjson of "$of" --argjson p "$payload" \
     '{schema_version:1, ts:$ts, run_id:$rid, seq:$seq, event_type:$et, kind:$kind,
       severity:$sev, denominator:{iter:$iter, of:$of}, payload:$p}' >> "$rd/events.jsonl"
  rm -rf "$lk"

  # реестр — ПОСЛЕ снятия лока (пишем в чужой файл, лок журнала к нему отношения не имеет)
  [ "$et" = "run_start" ] && _register_run "$rd" "$payload"

  # финал прогона обязан дойти до человека (И6). ВНЕ лока — escalate.sh сам пишет событие
  # через этот же events.sh, и вызов из-под лока молча провалился бы на каждом прогоне.
  # Пока путь op run → TG не подтверждён живым прогоном, по умолчанию выключено.
  if [ "$et" = "run_done" ] && [ "${REDLOOP_AUTO_FINAL_NOTIFY:-0}" = "1" ]; then
    # только машинные поля: свободный текст агента во внешний канал не уезжает (панель, critical #3)
    local diag; diag="$(printf '%s' "$payload" | jq -r '"verdict=\(.verdict) dod=\(.dod_green // "?")/\(.dod_total // "?") iters=\(.iters // "?")"')"
    bash "$HERE/escalate.sh" "$rd" RUN_DONE none "$diag" >/dev/null || \
      echo "⚠ финал не доставлен (escalate exit $?) — смотри $rd/escalations.log" >&2
  fi
  return 0
}

self_test() {
  set +e; local T; T="$(mktemp -d)"; local rd="$T/run-abc"; local fail=0
  export REDLOOP_INDEX="$T/index.jsonl"; REG="$REDLOOP_INDEX"   # боевой реестр не трогаем
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

  # ── v3: политика журнала ────────────────────────────────────────────────
  # И1: финал без единой итерации отвергается кодом 4 (машинно отличим от 1)
  local R1="$T/r-noiter"; append "$R1" run_start '{"runner":"loop","contract_sha":"a"}' >/dev/null
  append "$R1" run_done '{"verdict":"partial","iters":9,"interventions":0}' >/dev/null 2>&1
  [ $? -eq 4 ]; ok $? "И1: run_done без iter_done → отказ с кодом 4"
  append "$R1" iter_done '{"task_id":"t","files_changed":2,"checkboxes_done":1}' --iter 1 --of 3 >/dev/null
  append "$R1" run_done '{"verdict":"partial","iters":9,"interventions":0}' >/dev/null; ok $? "И1: после iter_done финал проходит"
  # И3: тот же payload — no-op; другой payload — отказ
  append "$R1" run_done '{"verdict":"partial","iters":9,"interventions":0}' >/dev/null 2>&1; ok $? "И3: идентичный повтор финала = no-op"
  [ "$(jq -s '[.[]|select(.event_type=="run_done")]|length' "$R1/events.jsonl")" = "1" ]; ok $? "И3: no-op не задвоил событие"
  append "$R1" run_done '{"verdict":"SHIP","iters":22,"interventions":0}' >/dev/null 2>&1
  [ $? -eq 4 ]; ok $? "И3: второй ОТЛИЧАЮЩИЙСЯ финал отвергнут"
  # рубильник: прогон, стартовавший с strict=0, доживает по старым правилам
  local R2="$T/r-loose"; REDLOOP_STRICT_JOURNAL=0 append "$R2" run_start '{"runner":"loop","contract_sha":"a"}' >/dev/null
  append "$R2" run_done '{"verdict":"partial","iters":3,"interventions":0}' >/dev/null; ok $? "рубильник: strict=0 из run_start уважается"
  [ "$(jq -s -r '.[0].payload.strict_journal' "$R2/events.jsonl")" = "false" ]; ok $? "режим строгости зафиксирован в журнале"
  # run_done ПЕРВЫМ событием — самый слепой прогон, политика обязана сработать и без журнала
  local R5="$T/r-first"; append "$R5" run_done '{"verdict":"SHIP","iters":5,"interventions":0}' >/dev/null 2>&1
  [ $? -eq 4 ]; ok $? "И1: run_done первым событием отвергнут (журнала ещё нет)"
  # прогон, начатый ДО выката v3 (run_start без strict_journal), финал не теряет
  local R6="$T/r-legacy"; mkdir -p "$R6"
  jq -nc '{schema_version:1,ts:"2026-08-31T22:10:16Z",run_id:"legacy",seq:1,event_type:"run_start",
           kind:"progress",severity:"info",denominator:{iter:null,of:null},
           payload:{runner:"session",contract_sha:"old"}}' > "$R6/events.jsonl"
  append "$R6" run_done '{"verdict":"partial","iters":22,"interventions":0}' >/dev/null 2>&1
  ok $? "старый прогон без strict_journal доживает по прежним правилам"

  # И4: blocked — третий kind, а не префикс в payload
  local R3="$T/r-blocked"
  append "$R3" check_result '{"check_id":"smoke","cmd_hash":"h","exit_code":1,"result":"blocked_by_env"}' --iter 1 >/dev/null
  [ "$(tail -1 "$R3/events.jsonl" | jq -r .kind)" = "blocked" ]; ok $? "И4: blocked_by_env → kind=blocked, а не negative_verdict"
  append "$R3" check_result '{"check_id":"x","cmd_hash":"h","exit_code":1,"result":"blocked_by_mood"}' --iter 2 >/dev/null 2>&1
  ok $((1-$?)) "И4: result вне enum блокировок отвергнут"
  append "$R3" check_result '{"check_id":"y","cmd_hash":"h","exit_code":1}' --iter 3 >/dev/null
  [ "$(tail -1 "$R3/events.jsonl" | jq -r .kind)" = "negative_verdict" ]; ok $? "И4: обычный красный по-прежнему negative_verdict"

  # И2: бюджет снапшотится в run_start из contract.json (детектор не читает контракт)
  local R4="$T/r-budget"; mkdir -p "$R4"
  echo '{"budget":{"max_iters":14,"max_minutes":120}}' > "$R4/contract.json"
  append "$R4" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null
  [ "$(jq -s -r '.[0].payload.budget.max_iters' "$R4/events.jsonl")" = "14" ]; ok $? "И2: бюджет снят в run_start"

  # режим прогона попадает в журнал: assisted — человек пишет промпты сам и задаёт темп
  local RM="$T/r-mode"; mkdir -p "$RM"
  echo '{"mode":"assisted","budget":{"max_iters":3}}' > "$RM/contract.json"
  append "$RM" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null
  [ "$(jq -s -r '.[0].payload.mode' "$RM/events.jsonl")" = "assisted" ]; ok $? "режим assisted зафиксирован в run_start"
  local RA="$T/r-auto"; mkdir -p "$RA"; echo '{"budget":{"max_iters":3}}' > "$RA/contract.json"
  append "$RA" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null
  [ "$(jq -s -r '.[0].payload.mode' "$RA/events.jsonl")" = "autonomous" ]; ok $? "по умолчанию autonomous"

  # реестр: прогон в ЛЮБОМ каталоге обязан стать видимым для калибровки и статуса
  # отдельный индекс на этот блок: в общем уже есть записи предыдущих фикстур
  REG="$T/index-reg.jsonl"; export REDLOOP_INDEX="$REG"
  local RX="$T/elsewhere/runs/proj-run"; mkdir -p "$RX"
  append "$RX" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null
  [ "$(grep -c . "$REG")" = "1" ]; ok $? "реестр: прогон вне папки скилла зарегистрирован"
  append "$RX" iter_done '{"task_id":"t","files_changed":1,"checkboxes_done":1}' --iter 1 --of 2 >/dev/null
  append "$RX" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null
  [ "$(grep -c . "$REG")" = "1" ]; ok $? "реестр идемпотентен (повтор не плодит строк)"
  grep -q '"path"' "$REG"; ok $? "в реестре есть абсолютный путь прогона"
  grep -q '"task"' "$REG" ; ok $((1-$?)) "текст задачи в реестр НЕ копируется (обход секрет-гарда)"
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

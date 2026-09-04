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
# Свежий чекер (v3.3). Прогон 2026-09-03 закрылся «зелёным», а /finalize по тому же диффу дал
# NEEDS-WORK: требование «финальную проверку делает свежий контекст» жило только в прозе промпта.
# Теперь это строка журнала: check_result с check_id=fresh_check, обязательным verdict и
# зелёным исходом — без неё run_done отвергается кодом 4.
# ⚠ Список зелёных вердиктов НЕ дублировать: он один на три потребителя (гейт, детектор,
# карточка). Дубль уже стоил дефекта — карточка считала зелёным fresh_check с NEEDS-WORK.
# ⚠ fail-CLOSED, как secret-guard: молчаливый фолбэк на зашитый дефолт вернул бы ровно тот
# дефект, ради устранения которого словарь и заведён (три копии смысла, расходящиеся тихо).
CONST="$HERE/constants.json"
CONST_OK=1
jq -e '.fresh_check_id and .fresh_ok_verdicts and .default_state_files and .fresh_verdict_all' "$CONST" >/dev/null 2>&1 || CONST_OK=0
FRESH_CHECK_ID="$(jq -r '.fresh_check_id // "fresh_check"' "$CONST" 2>/dev/null || echo fresh_check)"
FRESH_OK_VERDICTS="$(jq -r '(.fresh_ok_verdicts // ["SHIP"])|join(" ")' "$CONST" 2>/dev/null || echo SHIP)"
DEFAULT_STATE_FILES="$(jq -c '.default_state_files // ["PLAN.md","state.json"]' "$CONST" 2>/dev/null || echo '["PLAN.md","state.json"]')"
CONTRACT_VERSION="$(jq -r '.contract_version // "unknown"' "$CONST" 2>/dev/null || echo unknown)"
FRESH_ALL_VERDICTS="$(jq -r '(.fresh_verdict_all // [])|join(" ")' "$CONST" 2>/dev/null || echo "")"
FRESH_MACHINE_ARTIFACTS="$(jq -r '(.fresh_machine_artifacts // ["judge.json"])|join(" ")' "$CONST" 2>/dev/null || echo "judge.json")"
RUN_DONE_OUTCOMES="$(jq -r '(.run_done_outcomes // ["success","failed","blocked","abandoned"])|join(" ")' "$CONST" 2>/dev/null || echo "success failed blocked abandoned")"

# Точное сравнение со списком, НЕ grep: $fv приходит из payload события, и `grep -qw ".*"`
# пропускал любой вердикт — гейт И8 обходился двумя символами (security, critical).
_in_list() { local needle="$1"; shift; local x; for x in "$@"; do [ "$x" = "$needle" ] && return 0; done; return 1; }
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

_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }

# Внешнее состояние прогона (PLAN.md/state.json): адрес берём из СНАПШОТА в run_start,
# чтобы правка contract.json задним числом не отменяла надзор — тот же приём, что с бюджетом.
# Пустой список = осознанный отказ владельца (одноитерационная работа), а не «забыли».
_state_missing() {  # печатает список ненайденных/протухших файлов
  local rd="$1"
  [ -f "$rd/events.jsonl" ] || return 0
  local snap; snap="$(jq -s -c 'map(select(.event_type=="run_start"))|.[0].payload // {}' "$rd/events.jsonl" 2>/dev/null)"
  # прогон стартовал до выката v3.3 → поля нет → судим по старым правилам
  printf '%s' "$snap" | jq -e 'has("state_files")' >/dev/null 2>&1 || return 0
  local files; files="$(printf '%s' "$snap" | jq -r '.state_files[]?')"
  [ -n "$files" ] || return 0
  # ⚠ Никакого фолбэка на каталог прогона: без адреса проекта гейт проверял бы ЧУЖИЕ файлы
  # и зеленел на них. Нет адреса — это отказ, а не «проверим что-нибудь рядом».
  local root; root="$(printf '%s' "$snap" | jq -r '.project_root // ""')"
  [ -n "$root" ] || { printf '%s' "project_root(не задан в снапшоте run_start)"; return 0; }
  local t0; t0="$(jq -s -r 'map(select(.event_type=="run_start"))|.[0].ts|fromdateiso8601' "$rd/events.jsonl" 2>/dev/null || true)"
  case "$t0" in ''|*[!0-9]*) t0=0 ;; esac   # нет разбираемого старта → судим только по факту существования
  local miss="" f path
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # путь состояния обязан лежать ПОД корнем проекта: абсолютный путь наружу или ../
    # позволяли зазеленить гейт файлом из чужого каталога
    # ⚠ Подстрока «..» ловила легальный notes..v2.md и давала отказ с неверной причиной.
    # Опасен только СЕГМЕНТ «..», он же единственный, который выводит путь наружу.
    local seg bad_seg=0
    case "$f" in /*) miss="$miss $f(абсолютный путь вне project_root)"; continue ;; esac
    local IFS_SAVE="$IFS"; IFS='/'
    for seg in $f; do [ "$seg" = ".." ] && bad_seg=1; done
    IFS="$IFS_SAVE"
    [ "$bad_seg" = "1" ] && { miss="$miss $f(выход за project_root через ..)"; continue; }
    path="$root/$f"
    if [ ! -f "$path" ]; then miss="$miss $f(нет)"
    elif [ ! -s "$path" ]; then miss="$miss $f(пустой)"
    # ⚠ свежесть, а не факт существования: файл двухмесячной давности уже однажды
    # зачёлся зелёным (наблюдение verify-artifact-freshness, прогон dream-cast).
    else
      local mt; mt="$(_mtime "$path")"; case "$mt" in ''|*[!0-9]*) mt=0 ;; esac
      if [ "$mt" -lt "$t0" ]; then miss="$miss $f(старее старта прогона)"; fi
    fi
  done <<< "$files"
  printf '%s' "${miss# }"
}

# Приёмка человеком → машинный снапшот. ЕДИНСТВЕННОЕ место, где «пункт приёмки»
# превращается в адрес (id). Читают ДВОЕ: снапшот run_start и подсказка в промпте
# (compile.sh зовёт подкоманду `acceptance-ids`). Вторая копия выражения уже стоила дефекта:
# промпт печатал «?» для безымянного пункта, а гейт ждал «#2» — предъявление отвергалось
# как описка, и финал становился ловушкой.
# ⚠ Свободный текст what/why НЕ едет: снапшот дописывается после первого прогона секрет-гарда.
# ⚠ Массив СТРОК (проза, разложенная по пунктам) — не приёмка: элементы обязаны быть объектами,
# иначе jq молча отдавал null и гейт выключался ровно на том входе, ради которого заведён.
_acceptance_from_contract() {
  local cf="$1"
  [ -f "$cf" ] || { echo "null"; return 0; }
  jq -c 'if (has("human_acceptance") and (.human_acceptance|type=="array")
             and (all(.human_acceptance[]; type=="object")))
         then [ .human_acceptance | to_entries[] | {
                id: (if (.value|has("id")) then (.value.id|tostring) else "#\(.key)" end),
                probe: (if (.value|has("probe")) then (.value.probe|tostring) else null end),
                manual_only: (if (.value|has("manual_only")) then (.value.manual_only == true) else false end) } ]
         else null end' "$cf" 2>/dev/null || echo "__ERROR__"
}

# Поля, которыми журнал НАДЗИРАЕТ за прогоном. Раннер прислать их не вправе: он — та сторона,
# за которой надзор и ведётся. `run_start '{"…","human_acceptance":[]}'` снимал И9 целиком
# тридцатью символами, а карточка при этом УТВЕРЖДАЛА «осознанный отказ владельца».
SNAPSHOT_FIELDS="human_acceptance fresh_check state_files project_root budget mode strict_journal acceptance_enforce state_files_enforce"

# Рубильники надзора тоже СНАПШОТЯТСЯ. Читать их из окружения на финале означало, что
# надзираемая сторона снимает правило одной переменной ПОСЛЕ старта: прогон стартовал
# с двумя кадрами приёмки, а `REDLOOP_ACCEPTANCE_ENFORCE=0 events.sh append run_done`
# закрывал его с exit 0. Ровно тот класс, ради которого снапшотится strict_journal.
_flag_of_run() {   # <run_dir> <имя поля в снапшоте> <env-умолчание>
  local rd="$1" key="$2" dflt="$3"
  [ -f "$rd/events.jsonl" ] || { echo "$dflt"; return; }
  # ⚠ has(), не `// null`: у jq оператор // считает false пустым — выключатель не выключал бы
  local v; v="$(jq -s -r --arg k "$key" 'map(select(.event_type=="run_start"))|.[0].payload
                | if has($k) then (.[$k]|tostring) else "" end' "$rd/events.jsonl" 2>/dev/null)"
  case "$v" in true) echo 1 ;; false) echo 0 ;; *) echo "$dflt" ;; esac
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
# ⚠ Отказ обязан оставить СЛЕД в журнале: иначе худший случай прогона («пытался закрыться и не
# смог») выглядит как тишина, а оба новых детектора читают только существующий run_done.
# Пишем напрямую в файл, без рекурсии через append(): политика уже отработала, второй заход
# по ней зациклился бы.
_REJECT_RD=""
_reject() {
  echo "✗ REJECT reason=$1 :: $2" >&2
  local rd="$_REJECT_RD"
  if [ -n "$rd" ]; then
    # журнала может не быть вовсе (run_done первым событием — самый слепой случай):
    # именно его молчание и лечим, поэтому файл создаём
    mkdir -p "$rd"; [ -f "$rd/events.jsonl" ] || : > "$rd/events.jsonl"
    local n; n=$(wc -l < "$rd/events.jsonl" | tr -d " ")
    jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg rid "$(basename "$rd")" \
       --argjson seq "$(( n + 1 ))" --arg reason "$1" \
       '{schema_version:1, ts:$ts, run_id:$rid, seq:$seq, event_type:"runner_error",
         kind:"negative_verdict", severity:"warn", denominator:{iter:null,of:null},
         payload:{exit_code:4, error_class:"journal_policy_reject", reason:$reason}}' \
       >> "$rd/events.jsonl" 2>/dev/null || true
  fi
  return 4
}

_policy_check() {
  local rd="$1" et="$2" payload="$3"
  _REJECT_RD="$rd"

  # И9 (v3.3.3): приёмка человеком обязана быть машинно предъявляемой.
  # Класс — «сигнал без читателя»: поле было обязательным в гейте контракта и печаталось
  # в промпте, но ни журнал, ни карточка о нём не знали. 03.09 два кадра приёмки из девяти
  # не тронуты вообще, а владельцу они доехали прозой в ответе агента, которую никто не сверял.
  # Гейт стоит на run_start, а не на run_done: снапшот неизменяем, и отказ в финале
  # был бы ловушкой — прогон отработал часы и закрыться уже не смог бы никогда.
  if [ "$et" = "run_start" ] && [ "${REDLOOP_STRICT_JOURNAL:-1}" = "1" ]; then
    # Раннер не задаёт себе правила надзора. Молча игнорировать присланное поле мало:
    # раннер считал бы, что оно применилось, и разошёлся бы с журналом.
    local sf_k
    for sf_k in $SNAPSHOT_FIELDS; do
      if printf '%s' "$payload" | jq -e --arg k "$sf_k" 'has($k)' >/dev/null 2>&1; then
        _reject snapshot_override_attempt "поле надзора «${sf_k}» пришло в payload run_start: снапшот берётся ТОЛЬКО из contract.json — правь контракт"; return 4
      fi
    done
  fi
  if [ "$et" = "run_start" ] && [ "${REDLOOP_STRICT_JOURNAL:-1}" = "1" ] \
     && [ "${REDLOOP_ACCEPTANCE_ENFORCE:-1}" = "1" ]; then
    # ⚠ Отсутствие contract.json — НЕ «правило неприменимо», а «надзирать нечем». Раньше
    # гейт был обвешан `[ -f contract.json ]` и раннер без контракта в run_dir стартовал
    # с нулевым покрытием приёмки: fail-OPEN там, где вся остальная база fail-closed.
    if [ ! -f "$rd/contract.json" ]; then
      _reject acceptance_not_declared "в каталоге прогона нет contract.json — надзирать за приёмкой нечем; положи контракт рядом с журналом или сними рубильником REDLOOP_ACCEPTANCE_ENFORCE=0"; return 4
    fi
    # ⚠ has(), а не `// null`: у jq оператор // считает false пустым, и «human_acceptance: false»
    # (равно как и любой ложный литерал) молча превратился бы в «поля нет».
    if ! jq -e 'has("human_acceptance")' "$rd/contract.json" >/dev/null 2>&1; then
      _reject acceptance_not_declared "контракт не объявляет human_acceptance — следить за приёмкой нечем; впиши список пунктов (или [] с acceptance_optout_why) и повтори run_start"; return 4
    fi
    if [ "$(jq -r '.human_acceptance|type' "$rd/contract.json" 2>/dev/null)" != "array" ]; then
      _reject acceptance_not_itemized "human_acceptance прозой: журнал умеет следить только за списком пунктов с id — ровно проза и потеряла кадры 53/57"; return 4
    fi
    # массив СТРОК — та же проза, просто разложенная по строкам; снапшот на ней падал в null
    local acc_probe; acc_probe="$(_acceptance_from_contract "$rd/contract.json")"
    if [ "$acc_probe" = "__ERROR__" ] || [ "$acc_probe" = "null" ]; then
      _reject acceptance_not_itemized "пункты приёмки должны быть объектами ({id, probe|manual_only}), а не строками — снапшот собрать невозможно"; return 4
    fi
    # ⚠ Дубль id схлопывал гейт: разность множеств в jq удаляет ВСЕ вхождения, поэтому один
    # предъявленный «57» закрывал произвольное число кадров с тем же id, а карточка печатала
    # «названо 2 из 2». Знаменатель врал ровно там, где его и заводили.
    # Сюда же попадает столкновение пользовательского id вида «#1» с автоадресом позиции.
    # ⚠ НЕ через `-`: разность массивов в jq удаляет ВСЕ вхождения, поэтому ["57","57"] - ["57"]
    # даёт [] и дубль не находится. Это ровно тот же оператор и тот же промах, который дублем
    # id и схлопывал гейт приёмки — здесь он чуть не спрятал сам себя.
    local dup; dup="$(printf '%s' "$acc_probe" | jq -r '[.[].id]|group_by(.)|map(select(length>1)|.[0])|join(",")')"
    if [ -n "$dup" ]; then
      _reject acceptance_ids_not_unique "id кадров приёмки повторяются ($dup) — по такому адресу нельзя отличить предъявленный кадр от непредъявленного"; return 4
    fi
  fi

  # И7 (v3.3): со ВТОРОЙ итерации прогон обязан вести внешнее состояние на диске.
  # Прогон 2026-09-03 шёл по памяти — PLAN.md и state.json не появились ни разу, и «остановился
  # рано» было нечему помешать: списка задач, который видно недоделанным, не существовало.
  if [ "$et" = "iter_done" ] && [ "$(_strict_of_run "$rd")" = "1" ] \
     && [ "$(_flag_of_run "$rd" state_files_enforce "${REDLOOP_STATE_FILES_ENFORCE:-1}")" = "1" ]; then
    # ⚠ Санитизация обязательна: на несуществующем/битом журнале jq печатал 0 И выходил
    # ненулевым, `|| echo 0` дописывал второй 0, и `[ "0 0" -ge 1 ]` падал с «integer expected» —
    # ветка И7 молча не выполнялась. Форма fail-open там, где смысл fail-closed.
    local done_before; done_before="$(jq -s '[.[]|select(.event_type=="iter_done")]|length' "$rd/events.jsonl" 2>/dev/null)" || done_before=0
    case "$done_before" in ''|*[!0-9]*) done_before=0 ;; esac
    if [ "$done_before" -ge 1 ]; then
      local miss; miss="$(_state_missing "$rd")"
      [ -n "$miss" ] && { _reject state_files_missing "нет внешнего состояния:$miss — создай их и повтори событие"; return 4; }
    fi
  fi

  [ "$et" = "run_done" ] || return 0
  local strict; strict="$(_strict_of_run "$rd")"
  # ⚠ отсутствие журнала — не повод пропустить политику: run_done первым событием означает
  # ровно ноль итераций, то есть самый слепой прогон из возможных.
  if [ ! -f "$rd/events.jsonl" ]; then
    [ "$strict" = "1" ] || return 0
    _reject no_iterations_logged "финал первым событием прогона — в журнале нет ни одной итерации"; return 4
  fi

  # ⚠ Вся политика И7/И8/И9 читает требования ИЗ СНАПШОТА run_start. Значит «не позвать
  # run_start» — не пропуск удобства, а полный обход надзора: снапшота нет → требований нет →
  # финал зелёный. Гейт, поставленный на необязательный шаг, гейтом не является.
  # ⚠ БЕЗ рубильника — намеренно. Строгость, рубильники и требования живут В СНАПШОТЕ
  # run_start; без него журнал не знает о прогоне НИЧЕГО, в том числе того, разрешено ли
  # ослаблять правила. Читать здесь окружение значило бы дать надзираемой стороне снимать
  # весь надзор одной переменной — тот же класс, что уже закрыт для payload
  # (snapshot_override_attempt). Прогоны до выката v3 звали run_start тоже (иначе не было бы
  # снапшота бюджета), поэтому обещание «идущий прогон не потеряет финал» не нарушается.
  if ! jq -s -e 'any(.[]; .event_type=="run_start")' "$rd/events.jsonl" >/dev/null 2>&1; then
    _reject run_start_missing "в журнале нет run_start — прогон не объявлял ни бюджета, ни приёмки, ни свежего чекера; надзирать не за чем"; return 4
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

  # ── Исход прогона (v3.3.5) ────────────────────────────────────────────────
  # ⚠ Честно сдавшийся прогон обязан УМЕТЬ записать финал. До этого И8 требовал зелёного
  # чекера, а И9 — предъявления кадров: у прогона, который упёрся во внешнее, выбрал бюджет
  # или был убит, нет ни того, ни другого, и финал не записывался ВООБЩЕ. Отсутствие записи
  # читается как «ничего не было» — тот же класс «нет событий ≠ успех», только наоборот.
  # Дешёвым выходом для агента становилось вписать id кадров, которых он не показывал.
  local outcome; outcome="$(printf '%s' "$payload" | jq -r 'if has("outcome") then .outcome else "success" end')"
  if ! _in_list "$outcome" $RUN_DONE_OUTCOMES; then
    _reject outcome_not_in_enum "outcome=$outcome вне enum ($RUN_DONE_OUTCOMES) — исход прогона машинный, а не проза"; return 4
  fi
  # ⚠ «SHIP + blocked» писалось молча, и эту строку печатали и карточка, и улика детектора.
  # Исход и вердикт — два поля об одном, противоречие между ними нельзя записывать как факт.
  if [ "$outcome" != "success" ]; then
    local dv; dv="$(printf '%s' "$payload" | jq -r '.verdict // ""')"
    if _in_list "$dv" $FRESH_OK_VERDICTS; then
      _reject outcome_contradicts_verdict "outcome=$outcome при verdict=$dv: исход и вердикт противоречат друг другу — либо прогон сделал задачу, либо нет"; return 4
    fi
  fi

  # И1: финал без единой итерации в журнале означает, что пять детекторов из шести были слепы.
  # ⚠ …но не у сдавшегося прогона: типичный blocked_by_env (нет токена, снят доступ) упирается
  # на НУЛЕВОЙ итерации, и требовать с него итераций значило бы снова запретить записать провал.
  # То же с внешним состоянием: PLAN.md незачем, если работа не начиналась.
  if [ "$strict" = "1" ] && [ "$outcome" = "success" ]; then
    local iters; iters="$(jq -s '[.[]|select(.event_type=="iter_done")]|length' "$rd/events.jsonl" 2>/dev/null || echo 0)"
    if [ "${iters:-0}" -eq 0 ]; then
      _reject no_iterations_logged "финал без единого iter_done — детекторы слепые; пиши iter_done каждую итерацию"; return 4
    fi

    # И7: внешнее состояние обязано пережить прогон и на финале тоже
    if [ "$(_flag_of_run "$rd" state_files_enforce "${REDLOOP_STATE_FILES_ENFORCE:-1}")" = "1" ]; then
      local miss; miss="$(_state_missing "$rd")"
      [ -n "$miss" ] && { _reject state_files_missing "финал без внешнего состояния:$miss"; return 4; }
    fi

    # ⚠ И8 и И9 ниже спрашивают за УСПЕХ. Прогон с outcome != success успеха не заявляет:
    # с него нечего требовать ни подписи чекера, ни предъявления кадров — требовать значило бы
    # запретить ему записать собственный провал.
    # И8: «сделано» подписывает свежий контекст, а не автор патча.
    # Требование берём из снапшота run_start: прогон, стартовавший до выката, доживает по старым правилам.
    local req; req="$(jq -s -r 'map(select(.event_type=="run_start"))|.[0].payload
                        | if has("fresh_check") then ((.fresh_check.required // false)|tostring) else "" end' \
                      "$rd/events.jsonl" 2>/dev/null)"
    if [ "$req" = "true" ] && [ "$outcome" = "success" ]; then
      local last; last="$(jq -s -c --arg id "$FRESH_CHECK_ID" '
          [.[]|select(.event_type=="check_result" and .payload.check_id==$id)] | sort_by(.seq) | .[-1] // empty' \
          "$rd/events.jsonl" 2>/dev/null)"
      if [ -z "$last" ] || [ "$last" = "null" ]; then
        _reject fresh_check_missing "финал без свежего чекера: нужен check_result check_id=$FRESH_CHECK_ID (/finalize, plan-panel или проход по артефакту с нуля)"; return 4
      fi
      local fex fv; fex="$(printf '%s' "$last" | jq -r '.payload.exit_code // 1')"
      fv="$(printf '%s' "$last" | jq -r '.payload.verdict // ""')"
      if [ "$fex" != "0" ] || ! _in_list "$fv" $FRESH_OK_VERDICTS; then
        _reject fresh_check_not_green "свежий чекер дал verdict=$fv (exit $fex) — это не «готово», а следующая задача"; return 4
      fi
      # ⚠ Подпись протухает после КАЖДОЙ следующей итерации: «последний fresh_check» ещё не
      # значит «после последней правки». Схема iter → SHIP → iter → run_done проходила гейт
      # и закрывала прогон подписью под ПРОШЛЫМ состоянием кода.
      local fseq iseq
      fseq="$(printf '%s' "$last" | jq -r '.seq')"
      iseq="$(jq -s -r '[.[]|select(.event_type=="iter_done")]|.[-1].seq // 0' "$rd/events.jsonl" 2>/dev/null || echo 0)"
      case "$fseq" in ''|*[!0-9]*) fseq=0 ;; esac
      case "$iseq" in ''|*[!0-9]*) iseq=0 ;; esac
      if [ "$fseq" -lt "$iseq" ]; then
        _reject fresh_check_stale "подпись чекера (seq $fseq) старше последней итерации (seq $iseq) — после неё код менялся"; return 4
      fi
    fi

    # И9: машинно непроверяемые кадры приёмки закрываются только предъявлением ВЛАДЕЛЬЦУ,
    # и предъявление — тоже строка журнала, а не проза в ответе агента.
    # Список берём из СНАПШОТА run_start: правка contract.json задним числом надзор не снимает.
    if [ "$(_flag_of_run "$rd" acceptance_enforce "${REDLOOP_ACCEPTANCE_ENFORCE:-1}")" = "1" ] && [ "$outcome" = "success" ]; then
      local ha; ha="$(jq -s -c 'map(select(.event_type=="run_start"))|.[0].payload
                        | if (has("human_acceptance") and .human_acceptance != null)
                          then .human_acceptance else [] end' "$rd/events.jsonl" 2>/dev/null || echo "[]")"
      # снапшота нет вовсе → прогон стартовал до выката v3.3.3, доживает по старым правилам
      [ -n "$ha" ] && [ "$ha" != "null" ] || ha='[]'
      local need; need="$(printf '%s' "$ha" | jq -r '[.[]|select(.manual_only==true)]|length' 2>/dev/null || echo 0)"
      case "$need" in ''|*[!0-9]*) need=0 ;; esac
      # ⚠ has(), не `// null`: пустой массив предъявленных — осмысленный ответ («ничего не
      # предъявил»), и `//` спутал бы его с отсутствием поля.
      local pres; pres="$(printf '%s' "$payload" | jq -c 'if has("acceptance_presented") then .acceptance_presented else null end' 2>/dev/null || echo null)"
      [ -n "$pres" ] || pres=null
      if [ "$need" -gt 0 ] && [ "$pres" = "null" ]; then
        _reject acceptance_not_presented "финал без acceptance_presented[]: кадров приёмки без пробы — $need, каждый обязан быть назван владельцу поимённо"; return 4
      fi
      if [ "$pres" != "null" ]; then
        printf '%s' "$pres" | jq -e 'type=="array" and all(.[]; type=="string")' >/dev/null 2>&1 \
          || { _reject acceptance_not_presented "acceptance_presented обязан быть массивом строк-id пунктов приёмки"; return 4; }
        # id уникальны по гейту run_start, поэтому разность множеств здесь корректна;
        # без той гарантии один предъявленный id закрывал бы произвольное число кадров.
        local miss_a; miss_a="$(jq -n -r --argjson ha "$ha" --argjson p "$pres" \
            '([$ha[]|select(.manual_only==true)|.id] - ($p|unique))|join(",")' 2>/dev/null || echo "")"
        [ -n "$miss_a" ] && { _reject acceptance_not_presented "не предъявлены владельцу кадры приёмки: $miss_a"; return 4; }
        # id, которого нет в приёмке контракта, — не предъявление, а описка: она бы закрыла
        # знаменатель карточки чужим числом
        local unk_a; unk_a="$(jq -n -r --argjson ha "$ha" --argjson p "$pres" \
            '($p - [$ha[]|.id])|join(",")' 2>/dev/null || echo "")"
        [ -n "$unk_a" ] && { _reject acceptance_presented_unknown "acceptance_presented называет id, которых нет в приёмке контракта: $unk_a"; return 4; }
      fi
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
  # свежий чекер обязан назвать вердикт: exit 0 при NEEDS-WORK — ровно тот случай,
  # ради которого правило и появилось (прогон 2026-09-03).
  if [ "$et" = "check_result" ] && \
     [ "$(printf '%s' "$payload" | jq -r '.check_id // ""')" = "$FRESH_CHECK_ID" ]; then
    printf '%s' "$payload" | jq -e 'has("verdict")' >/dev/null \
      || { echo "✗ $FRESH_CHECK_ID без поля verdict (ждём одно из: $FRESH_OK_VERDICTS или красный)" >&2; return 1; }
    # ⚠ Самоаттестация запрещена: событие обязано указывать на ОТЧЁТ чекера, который
    # существует, непуст и создан ПОСЛЕ последней итерации. Иначе «свежая проверка» —
    # это строка, которую пишет та же сессия, что и патч, ни разу чекер не позвав.
    local rep fvd tsec=0; rep="$(printf '%s' "$payload" | jq -r '.report // ""')"
    fvd="$(printf '%s' "$payload" | jq -r '.verdict // ""')"
    [ -n "$rep" ] || { echo "✗ $FRESH_CHECK_ID без поля report (путь к отчёту чекера: judge.md/judge.json)" >&2; return 1; }
    [ -f "$rep" ] || { echo "✗ отчёт чекера не найден: $rep" >&2; return 1; }
    [ -s "$rep" ] || { echo "✗ отчёт чекера пуст: $rep" >&2; return 1; }
    if [ -f "$rd/events.jsonl" ]; then
      local tref; tref="$(jq -s -r '([.[]|select(.event_type=="iter_done")]|.[-1].ts)
                                     // ([.[]|select(.event_type=="run_start")]|.[0].ts) // empty' \
                          "$rd/events.jsonl" 2>/dev/null || true)"
      if [ -n "$tref" ]; then
        tsec="$(printf '%s' "$tref" | jq -R -r 'fromdateiso8601' 2>/dev/null || true)"
        case "$tsec" in ''|*[!0-9]*) tsec=0 ;; esac
        local rmt; rmt="$(_mtime "$rep")"; case "$rmt" in ''|*[!0-9]*) rmt=0 ;; esac
        [ "$rmt" -ge "$tsec" ] || { echo "✗ отчёт чекера старее последней итерации — это отчёт о ПРОШЛОМ состоянии кода" >&2; return 1; }
      fi
    fi
    # ⚠ Отчёт обязан лежать ПОД каталогом прогона или проекта: иначе «подписью» становится
    # любой файл на диске, а с прогоном не архивируется ничего.
    local proot; proot="$(jq -s -r 'map(select(.event_type=="run_start"))|.[0].payload.project_root // ""' \
                          "$rd/events.jsonl" 2>/dev/null || echo "")"
    local rd_abs; rd_abs="$(cd "$rd" 2>/dev/null && pwd)"
    local rep_abs; rep_abs="$(cd "$(dirname "$rep")" 2>/dev/null && pwd)/$(basename "$rep")"
    local under=0
    [ -n "$rd_abs" ] && case "$rep_abs" in "$rd_abs"/*) under=1 ;; esac
    [ -n "$proot" ] && case "$rep_abs" in "$proot"/*) under=1 ;; esac
    [ "$under" = "1" ] || { echo "✗ отчёт чекера вне каталога прогона и проекта: $rep_abs" >&2; return 1; }

    # ⚠ Вердикт берём ИЗ ОТЧЁТА, а не со слов события. Без этого «подпись свежего контекста»
    # оставалась самоаттестацией: отчёт с NEEDS-WORK и событие с SHIP проходили гейт.
    #
    # ⚠⚠ МЕХАНИЗМ, а не регулярка. Три круга подряд правка шаблона переносила один и тот же
    # класс на новое место: сначала подстрока в теле («всё OK по стилю» зеленило NEEDS-WORK),
    # потом якорь `^` (отвергал КАЖДЫЙ реальный judge.md — вердикт стоит в середине строки),
    # потом проверка неоднозначности (отвергала 3 из 8 РЕАЛЬНЫХ отчётов: judge.md цитирует
    # чужие вердикты в тексте находок). Разбор человеческого текста — неверный инструмент.
    # Порядок теперь такой:
    #   1) отчёт — JSON → .verdict, точное сравнение. Машинный факт.
    #   2) рядом с markdown лежит машинный артефакт чекера (judge.json) → вердикт ИЗ НЕГО.
    #      /finalize и plan-panel пишут его всегда, то есть боевой маршрут машинный целиком.
    #   3) машинного артефакта нет (artifact-pass, чужой чекер) → ПЕРВАЯ строка объявления
    #      и ПЕРВЫЙ токен в ней. Без сверки по всем строкам: ложный отказ обесценивает гейт
    #      быстрее, чем пропуск, а сюда доходят только отчёты без машинной формы.
    # ⚠ machine_sha объявляется ЗДЕСЬ, а не в markdown-ветке: при отчёте-JSON (путь 1,
    # собственный документированный маршрут) ветка не выполняется, и обращение к переменной
    # ниже падало под `set -u` с «unbound variable» — append умирал кодом 1 вместо
    # осмысленного отказа. Путь 1 не был покрыт ни одним тестом: корпус состоит из markdown.
    local vfound=0 vsrc="" rvd="" machine_sha=""
    if jq -e . "$rep" >/dev/null 2>&1; then
      # сам отчёт машинный — он же и источник авторитета, его sha и пишем
      vsrc="json"; rvd="$(jq -r '.verdict // .verdict_label // ""' "$rep" 2>/dev/null)"
      machine_sha="$(shasum -a 256 "$rep" 2>/dev/null | cut -d" " -f1)"
    else
      # ⚠ Авторитет переехал на машинный артефакт — значит И ПРОВЕРКИ ПОДЛИННОСТИ переезжают
      # вместе с ним. Иначе класс «подпись под прошлым состоянием кода» просто меняет файл:
      # judge.json со SHIP от 2020 года рядом со свежим judge.md закрывал прогон зелёным.
      # Правила те же, что для отчёта: непуст, валиден, НЕ старее последней итерации;
      # его sha256 пишется отдельным полем (report_sha относится к markdown и о подмене
      # авторитета не говорит ничего).
      local mart
      for mart in $FRESH_MACHINE_ARTIFACTS; do
        local mpath="$(dirname "$rep")/$mart"
        [ -f "$mpath" ] && [ -s "$mpath" ] && jq -e . "$mpath" >/dev/null 2>&1 || continue
        local mmt; mmt="$(_mtime "$mpath")"; case "$mmt" in ''|*[!0-9]*) mmt=0 ;; esac
        if [ -n "${tsec:-}" ] && [ "${tsec:-0}" -gt 0 ] && [ "$mmt" -lt "$tsec" ]; then
          echo "✗ машинный артефакт чекера $mpath старее последней итерации — это подпись под ПРОШЛЫМ состоянием кода" >&2; return 1; fi
        local mv; mv="$(jq -r '.verdict // .verdict_label // ""' "$mpath" 2>/dev/null)"
        # ⚠ НЕ молчаливый фолбэк на markdown: файл уже прошёл проверки подлинности (свежий,
        # валидный), значит он релевантен — и отсутствие в нём вердикта это дефект чекера,
        # а не повод вернуть авторитет пути, который ломался четыре круга подряд.
        [ -n "$mv" ] || { echo "✗ машинный артефакт $mpath валиден и свеж, но не несёт вердикта (.verdict / .verdict_label) — чинить чекер, а не разбирать текст" >&2; return 1; }
        machine_sha="$(shasum -a 256 "$mpath" 2>/dev/null | cut -d" " -f1)"
        vsrc="machine:$mart"; rvd="$mv"; break
      done
      if [ -z "$vsrc" ]; then
        # ⚠ Кириллица — полной альтернацией, НЕ через [Вв]: bracket-выражение над многобайтным
        # символом в C-локали (у launchd-джоб LANG пуст) распадается на байты и не матчит.
        # ⚠ Якоря `^` нет: реальные отчёты объявляют вердикт в середине строки
        # (`run_id: \`x\`  verdict: **SHIP**  confidence: …`).
        # ⚠ Приоритет — объявлению ВЕРХНЕГО УРОВНЯ (с начала строки, максимум под markdown-
        # украшением). Простое «первое совпадение в файле» ловило прозу: отчёт
        # «Ссылаюсь на прошлый verdict: SHIP … Вердикт: NEEDS-WORK» закрывал прогон зелёным.
        # Якоря на ВСЕ объявления ставить нельзя — реальный judge.md пишет его в середине
        # строки (`run_id: … verdict: **SHIP**`), поэтому mid-line остаётся запасным.
        local decl_top decl
        decl_top="$(grep -m1 -E '^[[:space:]]*[*_`>#-]*[[:space:]]*[*_`]*([Vv]erdict|VERDICT|вердикт|Вердикт|ВЕРДИКТ)[*_`]*[[:space:]]*[:=—–-]' "$rep" || true)"
        if [ -n "$decl_top" ]; then decl="$decl_top"
        else decl="$(grep -m1 -E '(^|[[:space:]]|[`|*_>#-])[*_`]*([Vv]erdict|VERDICT|вердикт|Вердикт|ВЕРДИКТ)[*_`]*[[:space:]]*[:=—–-]' "$rep" || true)"; fi
        [ -n "$decl" ] || { echo "✗ в отчёте $rep нет ни машинного артефакта ($FRESH_MACHINE_ARTIFACTS рядом), ни строки объявления вердикта — сверять нечего" >&2; return 1; }
        # ⚠ ПЕРВОЕ объявление в строке, не последнее: жадный `.*` брал последнее, и строка
        # «Вердикт: NEEDS-WORK — прошлый verdict: SHIP» отдавала SHIP.
        # ⚠ Срезаем префикс с ЯКОРЕМ ^: жадный `.*[:=—–-]+` съедал дефис ВНУТРИ метки и
        # из «NEEDS-WORK» получалось «WORK» — неизвестный вердикт на честном отчёте.
        rvd="$(printf '%s' "$decl" \
          | grep -o -E '([Vv]erdict|VERDICT|вердикт|Вердикт|ВЕРДИКТ)[*_`]*[[:space:]]*[:=—–-]+[[:space:]]*[*_`"'"'"']*[A-Za-z][A-Za-z-]*' \
          | head -1 \
          | sed -E 's/^([Vv]erdict|VERDICT|вердикт|Вердикт|ВЕРДИКТ)[*_`]*[[:space:]]*[:=—–-]+[[:space:]]*[*_`"'"'"']*//')"
        vsrc="markdown"
      fi
    fi
    [ -n "$rvd" ] || { echo "✗ в отчёте $rep вердикт не распознан (источник: ${vsrc:-нет}) — сверять нечего" >&2; return 1; }
    _in_list "$rvd" $FRESH_ALL_VERDICTS || {
      echo "✗ в отчёте объявлен неизвестный вердикт «${rvd}» (известные: $FRESH_ALL_VERDICTS)" >&2; return 1; }
    [ "$rvd" = "$fvd" ] || {
      echo "✗ вердикт события ($fvd) не совпадает с вердиктом отчёта ($rvd, источник $vsrc)" >&2; return 1; }
    vfound=1
    payload="$(printf '%s' "$payload" | jq -c --arg s "$vsrc" '. + {verdict_source:$s}')"

    # хэш считает журнал, а не автор события: подставить чужую строку нельзя
    local rsha; rsha="$(shasum -a 256 "$rep" 2>/dev/null | cut -d" " -f1)"
    payload="$(printf '%s' "$payload" | jq -c --arg h "${rsha:-unknown}" '. + {report_sha:$h}')"
    [ -n "$machine_sha" ] && payload="$(printf '%s' "$payload" | jq -c --arg h "$machine_sha" '. + {verdict_source_sha:$h}')"
  fi

  # ⚠ Число итераций в финале считаем ПО ЖУРНАЛУ, а не со слов раннера: в двух живых прогонах
  # run_done рапортовал 13 и 19 итераций при нуле событий iter_done. Самоотчёт сохраняем
  # рядом (iters_claimed) — расхождение само по себе сигнал.
  if [ "$et" = "run_done" ]; then
    local jit; jit="$(jq -s '[.[]|select(.event_type=="iter_done")]|length' "$rd/events.jsonl" 2>/dev/null || echo 0)"
    payload="$(printf '%s' "$payload" | jq -c --argjson j "${jit:-0}" '
        (.iters // null) as $c
        | . + {iters: $j, iters_claimed: $c, iters_mismatch: ($c != null and $c != $j)}')"
    # до v3.3 iters = самоотчёт раннера, с v3.3 = счёт по журналу. Без явной отметки
    # агрегация по парку прогонов сравнивала бы несравнимое.
    payload="$(printf '%s' "$payload" | jq -c --arg v "$CONTRACT_VERSION" '. + {contract_version: $v}')"
    # умолчание записываем явно: «поля нет» и «исход успешный» — разные вещи для читателя
    payload="$(printf '%s' "$payload" | jq -c 'if has("outcome") then . else . + {outcome:"success"} end')"
    [ "$(printf '%s' "$payload" | jq -r '.iters_mismatch')" = "true" ] && [ "$sev" = "info" ] && sev=warn
  fi

  if [ "$GUARD_OK" != "1" ]; then
    echo "✗ secret-guard недоступен ($HERE/secret-guard.sh) — отказываюсь писать журнал" >&2; return 1; fi
  if [ "$CONST_OK" != "1" ]; then
    echo "✗ словарь $CONST недоступен или неполон — отказываюсь писать журнал (fail-closed: иначе гейт и карточка разъедутся молча)" >&2; return 1; fi
  if kw_secret_found "$payload"; then echo "✗ payload содержит секрет-паттерн — отказ" >&2; return 1; fi

  # ⚠ Лок берём ДО политики: _reject пишет своё событие сам и считает seq по файлу, а до этой
  # правки он делал это ВНЕ лока — то есть ровно у самого доверенного события был шанс
  # переплестись со вторым писателем (escalate.sh из сторожа живёт параллельно сессии).
  mkdir -p "$rd"
  local lk="$rd/.events.lock"; _lock "$lk" || { echo "✗ lock timeout" >&2; return 1; }
  _policy_check "$rd" "$et" "$payload" || { local pc=$?; rm -rf "$lk"
    [ "$pc" = "9" ] && return 0; return $pc; }
  local seq; local n=0; [ -f "$rd/events.jsonl" ] && n=$(wc -l < "$rd/events.jsonl" | tr -d " ")
  seq=$(( n + 1 ))
  local rid; rid="$(basename "$rd")"
  # снапшот бюджета в сам журнал: детектор остаётся чистой функцией от events.jsonl (И2)
  if [ "$et" = "run_start" ]; then
    local strict_flag; [ "${REDLOOP_STRICT_JOURNAL:-1}" = "0" ] && strict_flag=false || strict_flag=true
    local acc_flag; [ "${REDLOOP_ACCEPTANCE_ENFORCE:-1}" = "0" ] && acc_flag=false || acc_flag=true
    local sfe_flag; [ "${REDLOOP_STATE_FILES_ENFORCE:-1}" = "0" ] && sfe_flag=false || sfe_flag=true
    local budget="null" mode="autonomous"
    if [ -f "$rd/contract.json" ]; then
      budget="$(jq -c '.budget // null' "$rd/contract.json" 2>/dev/null || echo null)"
      mode="$(jq -r '.mode // "autonomous"' "$rd/contract.json" 2>/dev/null || echo autonomous)"
    fi
    [ "$mode" = "autonomous" ] || [ "$mode" = "assisted" ] || mode="autonomous"
    # снапшот требований к финалу — по той же причине, что и бюджет: детекторы и политика
    # остаются функцией от журнала, а правка контракта задним числом надзор не снимает
    local fresh="null" statef="$DEFAULT_STATE_FILES" proot="" accept="null"
    if [ -f "$rd/contract.json" ]; then
      # ⚠ В журнал кладём ТОЛЬКО машинные поля: свободный текст why из контракта проезжал
      # мимо kw_secret_found (гард отрабатывал до обогащения) — тот же обход, что когда-то
      # в _register_run с текстом задачи.
      fresh="$(jq -c 'if has("fresh_check") then {kind:(.fresh_check.kind//null), required:(.fresh_check.required//false)} else null end' "$rd/contract.json" 2>/dev/null || echo null)"
      statef="$(jq -c 'if has("state_files") then .state_files else '"$DEFAULT_STATE_FILES"' end' "$rd/contract.json" 2>/dev/null || echo "$DEFAULT_STATE_FILES")"
      proot="$(jq -r '.project_root // ""' "$rd/contract.json" 2>/dev/null || echo "")"
      # ⚠ Приёмка едет в журнал ТОЛЬКО машинными полями (id/probe/manual_only): свободный
      # текст what/why остаётся в контракте — тем же правилом, что и why у fresh_check,
      # иначе снапшот снова стал бы вторым писателем в обход секрет-гарда.
      # id может не быть — тогда адресом становится позиция: безымянный пункт всё равно
      # обязан быть предъявляемым, «—» вместо адреса вернуло бы потерю кадра молча.
      accept="$(_acceptance_from_contract "$rd/contract.json")"
      [ "$accept" = "__ERROR__" ] && accept="null"
    fi
    payload="$(printf '%s' "$payload" | jq -c --argjson b "$budget" --argjson sj "$strict_flag" --arg m "$mode" \
      --argjson fc "$fresh" --argjson sf "$statef" --arg pr "$proot" --argjson ha "$accept" \
      --argjson ae "$acc_flag" --argjson sfe "$sfe_flag" \
      '. + {budget: $b, strict_journal: $sj, mode: $m,
            fresh_check: $fc, state_files: $sf, project_root: $pr,
            human_acceptance: $ha, acceptance_enforce: $ae, state_files_enforce: $sfe}')"
  fi
  # ⚠ ВТОРОЙ прогон гарда — по ИТОГОВОМУ payload: первый видел только то, что прислал раннер,
  # а снапшот из contract.json дописывается ниже по коду. Fail-closed, как и первый.
  if kw_secret_found "$payload"; then
    rm -rf "$lk"; echo "✗ итоговый payload (после снапшота контракта) содержит секрет-паттерн — отказ" >&2; return 1; fi
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
    # ⚠ Единственный канал, который реально доходит до владельца, обязан нести и приёмку:
    # иначе новый сигнал виден только тому, кто сам откроет карточку.
    local acc_n acc_m
    acc_m="$(jq -s -r 'map(select(.event_type=="run_start"))|.[0].payload.human_acceptance
                        | if . == null then 0 else ([.[]|select(.manual_only==true)]|length) end' "$rd/events.jsonl" 2>/dev/null || echo 0)"
    case "$acc_m" in ''|*[!0-9]*) acc_m=0 ;; esac
    acc_n="$(printf '%s' "$payload" | jq -r 'if has("acceptance_presented") then (.acceptance_presented|length) else 0 end' 2>/dev/null || echo 0)"
    case "$acc_n" in ''|*[!0-9]*) acc_n=0 ;; esac
    local diag; diag="$(printf '%s' "$payload" | jq -r --arg an "$acc_n" --arg am "$acc_m" \
      '"verdict=\(.verdict) outcome=\(.outcome // "success") dod=\(.dod_green // "?")/\(.dod_total // "?") iters=\(.iters // "?") кадров названо=\($an)/\($am)"')"
    bash "$HERE/escalate.sh" "$rd" RUN_DONE none "$diag" >/dev/null || \
      echo "⚠ финал не доставлен (escalate exit $?) — смотри $rd/escalations.log" >&2
  fi
  return 0
}

self_test() {
  set +e; local T; T="$(mktemp -d)"; local rd="$T/run-abc"; local fail=0
  export REDLOOP_INDEX="$T/index.jsonl"; REG="$REDLOOP_INDEX"   # боевой реестр не трогаем
  ok(){ if [ "$1" -eq 0 ]; then :; else echo "  ✗ $2"; fail=1; fi; }
  # ⚠ contract.json обязателен и в фикстурах: без него run_start отвергается (надзирать нечем),
  # то есть фикстура шла бы НЕ тем путём, что боевой прогон.
  mkdir -p "$rd"; echo '{"state_files":[],"human_acceptance":[]}' > "$rd/contract.json"
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
  local R1="$T/r-noiter"; mkdir -p "$R1"
  jq -nc --arg r "$R1" '{project_root:$r, human_acceptance:[]}' > "$R1/contract.json"
  append "$R1" run_start '{"runner":"loop","contract_sha":"a"}' >/dev/null
  append "$R1" run_done '{"verdict":"partial","iters":9,"interventions":0}' >/dev/null 2>&1
  [ $? -eq 4 ]; ok $? "И1: run_done без iter_done → отказ с кодом 4"
  append "$R1" iter_done '{"task_id":"t","files_changed":2,"checkboxes_done":1}' --iter 1 --of 3 >/dev/null
  echo "- [x] задача" > "$R1/PLAN.md"; echo '{"iter":1}' > "$R1/state.json"   # внешнее состояние (И7)
  append "$R1" run_done '{"verdict":"partial","iters":9,"interventions":0}' >/dev/null; ok $? "И1: после iter_done финал проходит"
  [ "$(jq -s -r '[.[]|select(.event_type=="run_done")]|.[-1].payload.iters' "$R1/events.jsonl")" = "1" ]
  ok $? "И5: iters в финале пересчитан по журналу (1), а не взят со слов раннера (9)"
  [ "$(jq -s -r '[.[]|select(.event_type=="run_done")]|.[-1].payload.iters_claimed' "$R1/events.jsonl")" = "9" ]
  ok $? "И5: самоотчёт сохранён отдельным полем iters_claimed"
  [ "$(jq -s -r '[.[]|select(.event_type=="run_done")]|.[-1].payload.iters_mismatch' "$R1/events.jsonl")" = "true" ]
  ok $? "И5: расхождение помечено флагом"
  [ "$(jq -s -r '[.[]|select(.event_type=="run_done")]|.[-1].severity' "$R1/events.jsonl")" = "warn" ]
  ok $? "И5: расхождение поднимает severity до warn"
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

  # ── v3.3 · И7: внешнее состояние прогона ────────────────────────────────
  # Прогон 2026-09-03 шёл по памяти: PLAN.md/state.json не появились ни разу.
  local R7="$T/r-state"; mkdir -p "$R7"
  jq -nc --arg r "$R7" '{budget:{max_iters:5}, project_root:$r, human_acceptance:[]}' > "$R7/contract.json"
  append "$R7" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null
  [ "$(jq -s -r '.[0].payload.state_files|join(",")' "$R7/events.jsonl")" = "PLAN.md,state.json" ]
  ok $? "И7: список файлов состояния снят в run_start (умолчание)"
  append "$R7" iter_done '{"task_id":"t","files_changed":1,"checkboxes_done":1}' --iter 1 --of 5 >/dev/null
  ok $? "И7: ПЕРВАЯ итерация не требует состояния (его ещё пишут)"
  append "$R7" iter_done '{"task_id":"t2","files_changed":1,"checkboxes_done":2}' --iter 2 --of 5 >/dev/null 2>&1
  [ $? -eq 4 ]; ok $? "И7: вторая итерация без PLAN.md → отказ кодом 4"
  : > "$R7/PLAN.md"; : > "$R7/state.json"
  append "$R7" iter_done '{"task_id":"t2","files_changed":1,"checkboxes_done":2}' --iter 2 --of 5 >/dev/null 2>&1
  [ $? -eq 4 ]; ok $? "И7: ПУСТОЙ PLAN.md не засчитан (файл-заглушка не есть состояние)"
  echo "- [ ] задача" > "$R7/PLAN.md"; echo '{"iter":2}' > "$R7/state.json"
  append "$R7" iter_done '{"task_id":"t2","files_changed":1,"checkboxes_done":2}' --iter 2 --of 5 >/dev/null
  ok $? "И7: с внешним состоянием итерация проходит"
  # свежесть, а не факт существования (урок verify-artifact-freshness)
  touch -t 202001010000 "$R7/PLAN.md"   # содержимое есть, но файл из прошлой жизни
  append "$R7" iter_done '{"task_id":"t3","files_changed":1,"checkboxes_done":3}' --iter 3 --of 5 >/dev/null 2>&1
  [ $? -eq 4 ]; ok $? "И7: файл состояния старее старта прогона не засчитан"
  echo "- [ ] задача" > "$R7/PLAN.md"
  REDLOOP_STATE_FILES_ENFORCE=0 append "$R7" iter_done '{"task_id":"t4","files_changed":1,"checkboxes_done":4}' --iter 4 --of 5 >/dev/null
  ok $? "И7: рубильник REDLOOP_STATE_FILES_ENFORCE=0 снимает правило"
  local R8="$T/r-nostate"; mkdir -p "$R8"
  echo '{"state_files":[],"budget":{"max_iters":5},"human_acceptance":[]}' > "$R8/contract.json"
  append "$R8" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null
  append "$R8" iter_done '{"task_id":"a","files_changed":1,"checkboxes_done":1}' --iter 1 --of 2 >/dev/null
  append "$R8" iter_done '{"task_id":"b","files_changed":1,"checkboxes_done":2}' --iter 2 --of 2 >/dev/null
  ok $? "И7: осознанный отказ (state_files=[]) уважается"

  # ── v3.3 · И8: финал подписывает свежий контекст ─────────────────────────
  # 2026-09-03: прогон закрылся verdict=green, а /finalize по тому же диффу дал NEEDS-WORK.
  local R9="$T/r-fresh"; mkdir -p "$R9"
  echo '{"fresh_check":{"kind":"finalize","required":true,"why":"внутренний-текст-в-журнал-не-едет"},"state_files":[],"budget":{"max_iters":5},"human_acceptance":[]}' > "$R9/contract.json"
  # отчёт живёт ПОД каталогом прогона и содержит вердикт — как настоящий judge.md
  local REP="$R9/judge.md"; _rep(){ printf '# Finalize\nverdict: **%s**\n' "$1" > "$REP"; }
  append "$R9" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null
  [ "$(jq -s -r '.[0].payload.fresh_check.required' "$R9/events.jsonl")" = "true" ]
  ok $? "И8: требование свежего чекера снято в run_start"
  append "$R9" iter_done '{"task_id":"t","files_changed":3,"checkboxes_done":1}' --iter 1 --of 5 >/dev/null
  append "$R9" run_done '{"verdict":"green","iters":1,"interventions":0}' >/dev/null 2>&1
  [ $? -eq 4 ]; ok $? "И8: финал без свежего чекера отвергнут кодом 4"
  [ "$(jq -s -r '.[0].payload.fresh_check|has("why")' "$R9/events.jsonl")" = "false" ]
  ok $? "И8: свободный текст why в журнал НЕ попадает (гард обходить нечем)"
  append "$R9" check_result '{"check_id":"fresh_check","cmd_hash":"finalize","exit_code":0}' --iter 1 >/dev/null 2>&1
  ok $((1-$?)) "И8: свежий чекер без поля verdict отвергнут"
  append "$R9" check_result "$(jq -nc '{check_id:"fresh_check",cmd_hash:"finalize",exit_code:0,verdict:"SHIP"}')" --iter 1 >/dev/null 2>&1
  ok $((1-$?)) "И8: свежий чекер без отчёта (report) отвергнут — самоаттестация запрещена"
  append "$R9" check_result "$(jq -nc --arg r "$T/нет-такого.md" '{check_id:"fresh_check",cmd_hash:"finalize",exit_code:0,verdict:"SHIP",report:$r}')" --iter 1 >/dev/null 2>&1
  ok $((1-$?)) "И8: несуществующий отчёт отвергнут"
  # отчёт вне каталога прогона/проекта — не подпись, а произвольный файл на диске
  local OUTREP="$T/чужой.md"; echo "verdict: SHIP" > "$OUTREP"
  append "$R9" check_result "$(jq -nc --arg r "$OUTREP" '{check_id:"fresh_check",cmd_hash:"f",exit_code:0,verdict:"SHIP",report:$r}')" --iter 1 >/dev/null 2>&1
  ok $((1-$?)) "И8: отчёт вне каталога прогона отвергнут"
  # ГЛАВНОЕ: вердикт берётся из ОТЧЁТА, а не со слов события
  _rep "NEEDS-WORK"
  append "$R9" check_result "$(jq -nc --arg r "$REP" '{check_id:"fresh_check",cmd_hash:"f",exit_code:0,verdict:"SHIP",report:$r}')" --iter 1 >/dev/null 2>&1
  ok $((1-$?)) "И8: отчёт с NEEDS-WORK + событие со SHIP отвергнуты (самоаттестация закрыта)"
  append "$R9" check_result "$(jq -nc --arg r "$REP" '{check_id:"fresh_check",cmd_hash:"finalize",exit_code:0,verdict:"NEEDS-WORK",report:$r}')" --iter 1 >/dev/null
  ok $? "И8: вердикт NEEDS-WORK записывается (это факт прогона)"
  [ "$(jq -s -r '[.[]|select(.payload.check_id=="fresh_check")]|.[-1].payload.report_sha|length' "$R9/events.jsonl")" = "64" ]
  ok $? "И8: журнал сам считает sha256 отчёта, а не верит полю события"
  append "$R9" run_done '{"verdict":"green","iters":1,"interventions":0}' >/dev/null 2>&1
  [ $? -eq 4 ]; ok $? "И8: NEEDS-WORK при exit 0 НЕ считается зелёным финалом"
  # метасимвол вместо вердикта: раньше grep -qw ".*" проходил и гейт обходился двумя символами
  _rep ".*"
  append "$R9" check_result "$(jq -nc --arg r "$REP" '{check_id:"fresh_check",cmd_hash:"x",exit_code:0,verdict:".*",report:$r}')" --iter 2 >/dev/null
  append "$R9" run_done '{"verdict":"green","iters":1,"interventions":0}' >/dev/null 2>&1
  [ $? -eq 4 ]; ok $? "И8: verdict=\".*\" НЕ проходит (сверка списком, не регуляркой)"
  _rep "SHIP"
  append "$R9" check_result "$(jq -nc --arg r "$REP" '{check_id:"fresh_check",cmd_hash:"finalize",exit_code:0,verdict:"SHIP",report:$r}')" --iter 2 >/dev/null
  append "$R9" run_done '{"verdict":"green","iters":1,"interventions":0}' >/dev/null
  ok $? "И8: после SHIP свежего чекера финал проходит"
  [ "$(jq -s -r '[.[]|select(.event_type=="run_done")]|.[-1].payload.contract_version' "$R9/events.jsonl")" != "null" ]
  ok $? "миграция: финал помечен версией контракта (смысл iters сменился)"
  # отказ политики обязан оставить след, а не тишину
  [ "$(jq -s '[.[]|select(.event_type=="runner_error" and .payload.error_class=="journal_policy_reject")]|length' "$R9/events.jsonl")" -ge 2 ]
  ok $? "отказ кодом 4 записан событием (плохой финал больше не выглядит тишиной)"
  [ "$(jq -s -r '[.[]|select(.payload.error_class=="journal_policy_reject")]|.[-1].payload.reason' "$R9/events.jsonl")" = "fresh_check_not_green" ]
  ok $? "в событии отказа названа машинная причина"

  # ⚠ Дыра третьего круга: сверка была подстрочной, а в списке зелёных жил короткий «OK» —
  # отчёт «Вердикт: NEEDS-WORK / всё OK по стилю» + событие verdict=OK закрывал прогон.
  printf '# Ревью\nВердикт: NEEDS-WORK\nвсё OK по стилю, но 3 critical\n' > "$REP"
  append "$R9" check_result "$(jq -nc --arg r "$REP" '{check_id:"fresh_check",cmd_hash:"f",exit_code:0,verdict:"PASS",report:$r}')" --iter 2 >/dev/null 2>&1
  ok $((1-$?)) "И8: вердикт PASS при объявленном NEEDS-WORK отвергнут (сверка по объявлению, не по подстроке)"
  printf '# Ревью\nвсё прошло хорошо, замечаний нет\n' > "$REP"
  append "$R9" check_result "$(jq -nc --arg r "$REP" '{check_id:"fresh_check",cmd_hash:"f",exit_code:0,verdict:"SHIP",report:$r}')" --iter 2 >/dev/null 2>&1
  ok $((1-$?)) "И8: отчёт без строки объявления вердикта отвергнут"
  # ⚠ Проверка «неоднозначности по всему тексту» УБРАНА сознательно: она отвергала 3 из 8
  # РЕАЛЬНЫХ judge.md (текст находок цитирует чужие вердикты), то есть 37% ложных отказов
  # на живом парке — false-alarm-economics. Вместо неё: если рядом лежит машинный артефакт
  # чекера, вердикт берётся ИЗ НЕГО и текст отчёта не решает ничего. Контроль ровно на это.
  printf '# Ревью\nverdict: SHIP\nВердикт: NEEDS-WORK\nцитата: verdict: **PASS**\n' > "$REP"
  echo '{"verdict":"NEEDS-WORK"}' > "$R9/judge.json"
  append "$R9" check_result "$(jq -nc --arg r "$REP" '{check_id:"fresh_check",cmd_hash:"f",exit_code:0,verdict:"SHIP",report:$r}')" --iter 2 >/dev/null 2>&1
  ok $((1-$?)) "И8: машинный артефакт (judge.json) главнее текста — событие SHIP при NEEDS-WORK отвергнуто"
  append "$R9" check_result "$(jq -nc --arg r "$REP" '{check_id:"fresh_check",cmd_hash:"f",exit_code:0,verdict:"NEEDS-WORK",report:$r}')" --iter 2 >/dev/null 2>&1
  ok $? "И8: вердикт из машинного артефакта принимается, сколько бы меток ни было в тексте"
  [ "$(jq -s -r '[.[]|select(.payload.check_id=="fresh_check")]|.[-1].payload.verdict_source' "$R9/events.jsonl")" = "machine:judge.json" ]
  ok $? "И8: источник вердикта записан в событие (machine:judge.json)"
  rm -f "$R9/judge.json"

  # ── И8b: подпись протухает после следующей итерации ─────────────────────
  # Схема iter → SHIP → iter → run_done проходила гейт: «последний fresh_check» ещё
  # не значит «после последней правки» (поймано вторым кругом панели, воспроизведено дважды).
  local RS="$T/r-stale"; mkdir -p "$RS"
  echo '{"fresh_check":{"kind":"finalize","required":true},"state_files":[],"budget":{"max_iters":5},"human_acceptance":[]}' > "$RS/contract.json"
  local RSREP="$RS/judge.md"; printf '# Finalize\nverdict: **SHIP**\n' > "$RSREP"
  append "$RS" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null
  append "$RS" iter_done '{"task_id":"t1","files_changed":3,"checkboxes_done":1}' --iter 1 --of 5 >/dev/null
  touch "$RSREP"
  append "$RS" check_result "$(jq -nc --arg r "$RSREP" '{check_id:"fresh_check",cmd_hash:"f",exit_code:0,verdict:"SHIP",report:$r}')" --iter 1 >/dev/null
  append "$RS" run_done '{"verdict":"green","iters":1,"interventions":0}' >/dev/null
  ok $? "И8b: подпись сразу после итерации закрывает прогон"
  local RS2="$T/r-stale2"; mkdir -p "$RS2"
  echo '{"fresh_check":{"kind":"finalize","required":true},"state_files":[],"budget":{"max_iters":5},"human_acceptance":[]}' > "$RS2/contract.json"
  local RS2REP="$RS2/judge.md"; printf '# Finalize\nverdict: **SHIP**\n' > "$RS2REP"
  append "$RS2" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null
  append "$RS2" iter_done '{"task_id":"t1","files_changed":3,"checkboxes_done":1}' --iter 1 --of 5 >/dev/null
  touch "$RS2REP"
  append "$RS2" check_result "$(jq -nc --arg r "$RS2REP" '{check_id:"fresh_check",cmd_hash:"f",exit_code:0,verdict:"SHIP",report:$r}')" --iter 1 >/dev/null
  append "$RS2" iter_done '{"task_id":"t2","files_changed":99,"checkboxes_done":2}' --iter 2 --of 5 >/dev/null
  append "$RS2" run_done '{"verdict":"green","iters":2,"interventions":0}' >/dev/null 2>&1
  [ $? -eq 4 ]; ok $? "И8b: iter → SHIP → iter → финал ОТВЕРГНУТ (подпись под прошлым кодом)"
  [ "$(jq -s -r '[.[]|select(.payload.error_class=="journal_policy_reject")]|.[-1].payload.reason' "$RS2/events.jsonl")" = "fresh_check_stale" ]
  ok $? "И8b: причина названа отдельно — fresh_check_stale"

  # ── v3.3.3 · И9: приёмка человеком имеет читателя в журнале ──────────────
  # 03.09 два кадра приёмки из девяти не были тронуты вообще: поле жило в контракте и
  # в промпте, но ни одного потребителя у него не было. Ниже — негативные контроли:
  # откати гейт И9 — и каждый из них позеленеет там, где обязан краснеть.
  local RH="$T/r-accept"; mkdir -p "$RH"
  cat > "$RH/contract.json" <<'JHA'
{"fresh_check":{"kind":"finalize","required":true},"state_files":[],"budget":{"max_iters":5},
 "dod":[{"id":"card","cmd":"true","expect_exit":0}],
 "human_acceptance":[{"id":"52","what":"карточка программы","probe":"card"},
                     {"id":"53","what":"сочетаемость","manual_only":true,"why":"вкусовой кадр"},
                     {"id":"57","what":"конструктор без программ","manual_only":true,"why":"вкусовой кадр"}]}
JHA
  local RHREP="$RH/judge.md"; printf '# Finalize\nverdict: **SHIP**\n' > "$RHREP"
  append "$RH" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null
  [ "$(jq -s -r '.[0].payload.human_acceptance|length' "$RH/events.jsonl")" = "3" ]
  ok $? "И9: приёмка снята снапшотом в run_start"
  [ "$(jq -s -r '.[0].payload.human_acceptance|map(select(.manual_only==true)|.id)|join(",")' "$RH/events.jsonl")" = "53,57" ]
  ok $? "И9: машинно непроверяемые кадры различимы в снапшоте (manual_only)"
  # свободный текст what/why в журнал не едет — тот же обход гарда, что закрыт у fresh_check
  [ "$(jq -s -r '[.[0].payload.human_acceptance[]|has("what") or has("why")]|any' "$RH/events.jsonl")" = "false" ]
  ok $? "И9: what/why в журнал НЕ попадают (только машинные поля)"
  append "$RH" iter_done '{"task_id":"t","files_changed":2,"checkboxes_done":1}' --iter 1 --of 5 >/dev/null
  touch "$RHREP"
  append "$RH" check_result "$(jq -nc --arg r "$RHREP" '{check_id:"fresh_check",cmd_hash:"f",exit_code:0,verdict:"SHIP",report:$r}')" --iter 1 >/dev/null
  # ГЛАВНЫЙ негативный контроль: зелёный чекер + закрытый DoD, но кадры не названы
  append "$RH" run_done '{"verdict":"green","iters":1,"interventions":0}' >/dev/null 2>&1
  [ $? -eq 4 ]; ok $? "И9: финал без acceptance_presented отвергнут (кадры приёмки потерялись бы молча)"
  [ "$(jq -s -r '[.[]|select(.payload.error_class=="journal_policy_reject")]|.[-1].payload.reason' "$RH/events.jsonl")" = "acceptance_not_presented" ]
  ok $? "И9: причина отказа названа машинно"
  # ⚠ Проверяем не только код 4, но и ПРИЧИНУ: без гейта эти два случая тоже дают 4 —
  # но по причине run_done_already_recorded, то есть контроль зеленел бы вхолостую.
  append "$RH" run_done '{"verdict":"green","iters":1,"interventions":0,"acceptance_presented":["53"]}' >/dev/null 2>&1
  [ $? -eq 4 ] && [ "$(jq -s -r '[.[]|select(.payload.error_class=="journal_policy_reject")]|.[-1].payload.reason' "$RH/events.jsonl")" = "acceptance_not_presented" ]
  ok $? "И9: предъявлен ОДИН кадр из двух — финал всё равно отвергнут"
  append "$RH" run_done '{"verdict":"green","iters":1,"interventions":0,"acceptance_presented":["53","61"]}' >/dev/null 2>&1
  [ $? -eq 4 ] && [ "$(jq -s -r '[.[]|select(.payload.error_class=="journal_policy_reject")]|.[-1].payload.reason' "$RH/events.jsonl")" = "acceptance_not_presented" ]
  ok $? "И9: чужой id не подменяет непредъявленный кадр"
  append "$RH" run_done '{"verdict":"green","iters":1,"interventions":0,"acceptance_presented":"53 и 57"}' >/dev/null 2>&1
  [ $? -eq 4 ]; ok $? "И9: приёмка прозой в финале отвергнута (нужен массив id)"
  append "$RH" run_done '{"verdict":"green","iters":1,"interventions":0,"acceptance_presented":["53","57","99"]}' >/dev/null 2>&1
  [ $? -eq 4 ]; ok $? "И9: неизвестный id в предъявленных отвергнут"
  [ "$(jq -s -r '[.[]|select(.payload.error_class=="journal_policy_reject")]|.[-1].payload.reason' "$RH/events.jsonl")" = "acceptance_presented_unknown" ]
  ok $? "И9: описка в id названа отдельной причиной, а не смешана с непредъявлением"
  append "$RH" run_done '{"verdict":"green","iters":1,"interventions":0,"acceptance_presented":["53","57"]}' >/dev/null
  ok $? "И9: после предъявления ОБОИХ кадров финал проходит"
  # осознанный отказ и прогон без приёмки надзора не требуют
  local RH2="$T/r-accept-none"; mkdir -p "$RH2"
  echo '{"state_files":[],"budget":{"max_iters":3},"human_acceptance":[]}' > "$RH2/contract.json"
  append "$RH2" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null
  append "$RH2" iter_done '{"task_id":"t","files_changed":1,"checkboxes_done":1}' --iter 1 --of 3 >/dev/null
  append "$RH2" run_done '{"verdict":"partial","iters":1,"interventions":0}' >/dev/null
  ok $? "И9: осознанный отказ (human_acceptance=[]) финал не блокирует"
  # контракт БЕЗ поля и контракт ПРОЗОЙ отвергаются на старте, а не в финале-ловушке
  local RH3="$T/r-accept-missing"; mkdir -p "$RH3"
  echo '{"state_files":[],"budget":{"max_iters":3}}' > "$RH3/contract.json"
  append "$RH3" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null 2>&1
  [ $? -eq 4 ]; ok $? "И9: контракт без human_acceptance не стартует (удаление строки больше не воспроизводит инцидент)"
  [ "$(jq -s -r '[.[]|select(.payload.error_class=="journal_policy_reject")]|.[-1].payload.reason' "$RH3/events.jsonl")" = "acceptance_not_declared" ]
  ok $? "И9: отказ старта записан событием с машинной причиной"
  local RH4="$T/r-accept-prose"; mkdir -p "$RH4"
  echo '{"state_files":[],"budget":{"max_iters":3},"human_acceptance":"глазами по кадрам 52, 53, 57"}' > "$RH4/contract.json"
  append "$RH4" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null 2>&1
  [ $? -eq 4 ]; ok $? "И9: приёмка прозой не стартует (журналу нечем следить за абзацем)"
  # прогон, стартовавший ДО выката v3.3.3 (в снапшоте нет поля), финал не теряет
  local RH5="$T/r-accept-legacy"; mkdir -p "$RH5"
  jq -nc '{schema_version:1,ts:"2026-09-01T10:00:00Z",run_id:"legacy2",seq:1,event_type:"run_start",
           kind:"progress",severity:"info",denominator:{iter:null,of:null},
           payload:{runner:"session",contract_sha:"old",strict_journal:true,state_files:[]}}' > "$RH5/events.jsonl"
  jq -nc '{schema_version:1,ts:"2026-09-01T10:05:00Z",run_id:"legacy2",seq:2,event_type:"iter_done",
           kind:"progress",severity:"info",denominator:{iter:1,of:3},
           payload:{task_id:"t",files_changed:1,checkboxes_done:1}}' >> "$RH5/events.jsonl"
  append "$RH5" run_done '{"verdict":"partial","iters":1,"interventions":0}' >/dev/null 2>&1
  ok $? "И9: прогон, начатый до выката, финал не теряет (поля в снапшоте нет)"
  # рубильник
  local RH6="$T/r-accept-off"; mkdir -p "$RH6"
  echo '{"state_files":[],"budget":{"max_iters":3}}' > "$RH6/contract.json"
  REDLOOP_ACCEPTANCE_ENFORCE=0 append "$RH6" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null
  ok $? "И9: рубильник REDLOOP_ACCEPTANCE_ENFORCE=0 снимает правило"

  # ── круг 4 · дыры, найденные свежим чекером в самих гейтах ───────────────
  # C1/C6. Сверка вердикта шла по НАЧАЛУ строки и подстрокой. Реальный judge.md, который
  # пишет /finalize, объявляет вердикт В СЕРЕДИНЕ строки — гейт отвергал КАЖДЫЙ честный
  # отчёт, а зелёными были только синтетические фикстуры. Ниже позитивный контроль на
  # артефакте РЕАЛЬНОГО формата и негативные — на отрицании и на неизвестной метке.
  local RV="$T/r-verdict"; mkdir -p "$RV"
  echo '{"fresh_check":{"kind":"finalize","required":true},"state_files":[],"human_acceptance":[]}' > "$RV/contract.json"
  append "$RV" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null
  append "$RV" iter_done '{"task_id":"t","files_changed":1,"checkboxes_done":1}' --iter 1 --of 5 >/dev/null
  local RVREP="$RV/judge.md"
  _vchk(){ append "$RV" check_result "$(jq -nc --arg r "$RVREP" --arg v "$1" \
      '{check_id:"fresh_check",cmd_hash:"f",exit_code:0,verdict:$v,report:$r}')" --iter 1 >/dev/null 2>&1; }
  # формат /finalize: `run_id: \`x\`  verdict: **SHIP**  confidence: 0.94`
  printf '# Finalize — 2026-09-04\n\nrun_id: `x`  verdict: **SHIP**  confidence: 0.94  stable: `unknown`\n' > "$RVREP"
  _vchk SHIP; ok $? "C1: РЕАЛЬНЫЙ формат judge.md (объявление в середине строки) принимается"
  # формат строки роли в review.md
  printf '**verdict**: PASS · confidence 0.9\n' > "$RVREP"
  _vchk PASS; ok $? "C1: формат роли (**verdict**: PASS) принимается"
  printf -- '- Вердикт — SHIP\n' > "$RVREP"
  _vchk SHIP; ok $? "C1: пункт списка «- Вердикт — SHIP» принимается"
  # ГЛАВНЫЙ негативный: отрицание в объявлении больше не зеленит
  printf 'Вердикт: это НЕ SHIP, нужна доработка\n' > "$RVREP"
  _vchk SHIP; ok $((1-$?)) "C6: «Вердикт: это НЕ SHIP» + событие SHIP отвергнуты (сверка токеном, не подстрокой)"
  printf 'verdict: ЗЕЛЕНО\n' > "$RVREP"
  _vchk ЗЕЛЕНО; ok $((1-$?)) "C6: метка вне enum отвергнута"
  # markdown без машинного артефакта — деградированный путь: берём ПЕРВОЕ объявление.
  # ⚠ Жадный разбор брал ПОСЛЕДНЕЕ, и «Вердикт: NEEDS-WORK — прошлый verdict: SHIP»
  # отдавал SHIP, закрывая прогон зелёным.
  printf 'Вердикт: NEEDS-WORK — 3 critical, прошлый verdict: SHIP\n' > "$RVREP"
  _vchk SHIP; ok $((1-$?)) "C6: цитата чужого вердикта в конце строки не подменяет объявленный (первое объявление, не последнее)"
  _vchk NEEDS-WORK; ok $? "C6: настоящий объявленный вердикт из той же строки принимается"

  # C2. Раннер снимал надзор одним полем в payload run_start.
  local RO="$T/r-override"; mkdir -p "$RO"
  echo '{"state_files":[],"human_acceptance":[{"id":"53","manual_only":true,"why":"w"},{"id":"57","manual_only":true,"why":"w"}]}' > "$RO/contract.json"
  append "$RO" run_start '{"runner":"session","contract_sha":"a","human_acceptance":[]}' >/dev/null 2>&1
  [ $? -eq 4 ]; ok $? "C2: поле надзора в payload run_start отвергнуто (раннер не задаёт себе правила)"
  [ "$(jq -s -r '[.[]|select(.payload.error_class=="journal_policy_reject")]|.[-1].payload.reason' "$RO/events.jsonl")" = "snapshot_override_attempt" ]
  ok $? "C2: причина названа машинно"
  append "$RO" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null
  [ "$(jq -s -r '[.[]|select(.event_type=="run_start")]|.[0].payload.human_acceptance|length' "$RO/events.jsonl")" = "2" ]
  ok $? "C2: снапшот взят ИЗ КОНТРАКТА (2 кадра), а не со слов раннера"
  append "$RO" iter_done '{"task_id":"t","files_changed":1,"checkboxes_done":1}' --iter 1 --of 3 >/dev/null
  append "$RO" run_done '{"verdict":"green","iters":1,"interventions":0}' >/dev/null 2>&1
  [ $? -eq 4 ]; ok $? "C2: и финал теперь требует предъявления, а не проходит по подменённому снапшоту"

  # C4. Гейт был fail-OPEN там, где вся база fail-closed.
  local RC1="$T/r-nocontract"; mkdir -p "$RC1"
  append "$RC1" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null 2>&1
  [ $? -eq 4 ]; ok $? "C4a: run_start без contract.json отвергнут (надзирать нечем), а не пропущен"
  local RC2="$T/r-strarray"; mkdir -p "$RC2"
  echo '{"state_files":[],"human_acceptance":["посмотреть кадр 53","и кадр 57"]}' > "$RC2/contract.json"
  append "$RC2" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null 2>&1
  [ $? -eq 4 ]; ok $? "C4b: приёмка массивом СТРОК отвергнута (проза по пунктам — та же проза)"
  [ "$(jq -s -r '[.[]|select(.payload.error_class=="journal_policy_reject")]|.[-1].payload.reason' "$RC2/events.jsonl")" = "acceptance_not_itemized" ]
  ok $? "C4b: причина — acceptance_not_itemized, а не тихий null в снапшоте"

  # C5. Гейт стоял на run_start, а сам run_start был необязателен → обход всей политики.
  local RN="$T/r-nostart"; mkdir -p "$RN"
  echo '{"state_files":[],"human_acceptance":[{"id":"57","manual_only":true,"why":"w"}]}' > "$RN/contract.json"
  append "$RN" iter_done '{"task_id":"t","files_changed":1,"checkboxes_done":1}' --iter 1 --of 3 >/dev/null
  append "$RN" run_done '{"verdict":"green","iters":1,"interventions":0}' >/dev/null 2>&1
  [ $? -eq 4 ]; ok $? "C5: финал прогона, не звавшего run_start, отвергнут (иначе весь надзор обходится пропуском старта)"
  [ "$(jq -s -r '[.[]|select(.payload.error_class=="journal_policy_reject")]|.[-1].payload.reason' "$RN/events.jsonl")" = "run_start_missing" ]
  ok $? "C5: причина названа отдельно — run_start_missing"

  # C3. Промпт и журнал обязаны звать кадр ОДНИМ адресом.
  local RI="$T/r-ids"; mkdir -p "$RI"
  echo '{"human_acceptance":[{"id":"53","manual_only":true},{"what":"безымянный","manual_only":true},{"id":"52","probe":"card"}]}' > "$RI/contract.json"
  [ "$(acceptance_ids "$RI/contract.json" manual)" = '["53","#1"]' ]
  ok $? "C3: адреса кадров отдаёт ОДИН источник (events.sh acceptance-ids), безымянный — позицией"

  # ── круг 5 · рубильники в снапшоте и честный аварийный финал ─────────────
  # A. Рубильник, снятый ПОСЛЕ старта, снимал надзор целиком: прогон стартовал с двумя
  # кадрами приёмки, а `REDLOOP_ACCEPTANCE_ENFORCE=0 … run_done` закрывал его с exit 0.
  local RE="$T/r-enforce"; mkdir -p "$RE"
  echo '{"state_files":[],"human_acceptance":[{"id":"53","manual_only":true,"why":"w"}]}' > "$RE/contract.json"
  append "$RE" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null
  [ "$(jq -s -r '.[0].payload.acceptance_enforce' "$RE/events.jsonl")" = "true" ]
  ok $? "круг5: рубильник приёмки снят в снапшот run_start"
  append "$RE" iter_done '{"task_id":"t","files_changed":1,"checkboxes_done":1}' --iter 1 --of 3 >/dev/null
  REDLOOP_ACCEPTANCE_ENFORCE=0 append "$RE" run_done '{"verdict":"green","iters":1,"interventions":0}' >/dev/null 2>&1
  [ $? -eq 4 ]; ok $? "круг5: рубильник, выключенный ПОСЛЕ старта, надзор не снимает (читаем снапшот, не env)"
  # симметрично: выключенный НА СТАРТЕ рубильник уважается весь прогон
  local RE2="$T/r-enforce-off"; mkdir -p "$RE2"
  echo '{"state_files":[],"human_acceptance":[{"id":"53","manual_only":true,"why":"w"}]}' > "$RE2/contract.json"
  REDLOOP_ACCEPTANCE_ENFORCE=0 append "$RE2" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null
  append "$RE2" iter_done '{"task_id":"t","files_changed":1,"checkboxes_done":1}' --iter 1 --of 3 >/dev/null
  append "$RE2" run_done '{"verdict":"green","iters":1,"interventions":0}' >/dev/null 2>&1
  ok $? "круг5: рубильник, выключенный НА СТАРТЕ, уважается и в финале"

  # B. Честно сдавшийся прогон обязан УМЕТЬ записать финал: иначе провал неотличим от тишины.
  local RQ="$T/r-abandon"; mkdir -p "$RQ"
  echo '{"fresh_check":{"kind":"finalize","required":true},"state_files":[],"human_acceptance":[{"id":"53","manual_only":true,"why":"w"}]}' > "$RQ/contract.json"
  append "$RQ" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null
  append "$RQ" iter_done '{"task_id":"t","files_changed":1,"checkboxes_done":1}' --iter 1 --of 3 >/dev/null
  append "$RQ" run_done '{"verdict":"red","iters":1,"interventions":0}' >/dev/null 2>&1
  [ $? -eq 4 ]; ok $? "круг5: финал БЕЗ outcome по-прежнему спрашивают за успех (умолчание success)"
  append "$RQ" run_done '{"verdict":"red","iters":1,"interventions":0,"outcome":"abandoned"}' >/dev/null
  ok $? "круг5: прогон, честно объявивший outcome=abandoned, финал записывает (провал ≠ тишина)"
  [ "$(jq -s -r '[.[]|select(.event_type=="run_done")]|.[-1].payload.outcome' "$RQ/events.jsonl")" = "abandoned" ]
  ok $? "круг5: исход записан машинно"
  local RQ2="$T/r-outcome-bad"; mkdir -p "$RQ2"
  echo '{"state_files":[],"human_acceptance":[]}' > "$RQ2/contract.json"
  append "$RQ2" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null
  append "$RQ2" iter_done '{"task_id":"t","files_changed":1,"checkboxes_done":1}' --iter 1 --of 3 >/dev/null
  append "$RQ2" run_done '{"verdict":"x","iters":1,"interventions":0,"outcome":"почти получилось"}' >/dev/null 2>&1
  [ $? -eq 4 ]; ok $? "круг5: исход прозой отвергнут (закрытый enum, иначе «сдался» станет отговоркой)"
  append "$RQ2" run_done '{"verdict":"x","iters":1,"interventions":0}' >/dev/null
  [ "$(jq -s -r '[.[]|select(.event_type=="run_done")]|.[-1].payload.outcome' "$RQ2/events.jsonl")" = "success" ]
  ok $? "круг5: умолчание success записано ЯВНО («поля нет» и «успех» — разные вещи для читателя)"

  # ── круг 7б · находки седьмого круга ─────────────────────────────────────
  local RC7="$T/r-round7"; mkdir -p "$RC7"
  echo '{"fresh_check":{"kind":"finalize","required":true},"state_files":[],"human_acceptance":[]}' > "$RC7/contract.json"
  append "$RC7" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null
  append "$RC7" iter_done '{"task_id":"t","files_changed":1,"checkboxes_done":1}' --iter 1 --of 5 >/dev/null
  # A. Цитата чужого вердикта ВЫШЕ настоящего объявления закрывала прогон зелёным.
  printf 'Ссылаюсь на прошлый verdict: SHIP — с тех пор код менялся.\n\nВердикт: NEEDS-WORK\n' > "$RC7/judge.md"
  append "$RC7" check_result "$(jq -nc --arg r "$RC7/judge.md" '{check_id:"fresh_check",cmd_hash:"f",exit_code:0,verdict:"SHIP",report:$r}')" --iter 1 >/dev/null 2>&1
  ok $((1-$?)) "круг7: цитата чужого вердикта ВЫШЕ объявления не подменяет вердикт (объявление верхнего уровня главнее)"
  append "$RC7" check_result "$(jq -nc --arg r "$RC7/judge.md" '{check_id:"fresh_check",cmd_hash:"f",exit_code:0,verdict:"NEEDS-WORK",report:$r}')" --iter 1 >/dev/null 2>&1
  ok $? "круг7: настоящее объявление верхнего уровня распознано"
  # B. Машинный артефакт без вердикта — дефект чекера, а не повод вернуться к прозе.
  echo '{"confidence":0.9}' > "$RC7/judge.json"
  append "$RC7" check_result "$(jq -nc --arg r "$RC7/judge.md" '{check_id:"fresh_check",cmd_hash:"f",exit_code:0,verdict:"NEEDS-WORK",report:$r}')" --iter 1 >/dev/null 2>&1
  ok $((1-$?)) "круг7: валидный машинный артефакт БЕЗ вердикта отвергается, а не молча уступает markdown"
  rm -f "$RC7/judge.json"
  # C. Исход и вердикт не могут противоречить друг другу.
  local RC7B="$T/r-contradict"; mkdir -p "$RC7B"
  echo '{"state_files":[],"human_acceptance":[]}' > "$RC7B/contract.json"
  append "$RC7B" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null
  append "$RC7B" run_done '{"verdict":"SHIP","iters":0,"interventions":0,"outcome":"blocked"}' >/dev/null 2>&1
  [ $? -eq 4 ]; ok $? "круг7: «SHIP + blocked» отвергнуто — исход и вердикт об одном"
  [ "$(jq -s -r '[.[]|select(.payload.error_class=="journal_policy_reject")]|.[-1].payload.reason' "$RC7B/events.jsonl")" = "outcome_contradicts_verdict" ]
  ok $? "круг7: причина названа машинно"
  append "$RC7B" run_done '{"verdict":"не получилось: нет токена","iters":0,"interventions":0,"outcome":"blocked"}' >/dev/null
  ok $? "круг7: честный неуспех с непротиворечивым вердиктом записывается"
  # D. Дубли id приёмки схлопывали знаменатель.
  local RC7C="$T/r-dupids"; mkdir -p "$RC7C"
  echo '{"state_files":[],"human_acceptance":[{"id":"57","manual_only":true,"why":"w"},{"id":"57","manual_only":true,"why":"w"}]}' > "$RC7C/contract.json"
  append "$RC7C" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null 2>&1
  [ $? -eq 4 ]; ok $? "круг7: повторяющиеся id кадров приёмки отвергнуты на старте (иначе один предъявленный закрывал оба)"
  [ "$(jq -s -r '[.[]|select(.payload.error_class=="journal_policy_reject")]|.[-1].payload.reason' "$RC7C/events.jsonl")" = "acceptance_ids_not_unique" ]
  ok $? "круг7: причина названа машинно"
  # столкновение пользовательского «#1» с автоадресом позиции ловится тем же правилом
  local RC7D="$T/r-hashclash"; mkdir -p "$RC7D"
  # автоадрес позиции для второго пункта = «#1», и он сталкивается с явным «#1» у первого
  echo '{"state_files":[],"human_acceptance":[{"id":"#1","manual_only":true,"why":"w"},{"what":"безымянный","manual_only":true,"why":"w"}]}' > "$RC7D/contract.json"
  append "$RC7D" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null 2>&1
  [ $? -eq 4 ]; ok $? "круг7: пользовательский id «#1» против автоадреса позиции пойман тем же правилом"

  # ── круг 7 · путь «отчёт сам машинный» (JSON) ────────────────────────────
  # Собственный документированный путь 1 не был покрыт НИ ОДНИМ тестом: корпус реальных
  # отчётов состоит из markdown, фикстуры — тоже. Обращение к переменной, объявленной
  # в чужой ветке, роняло append под `set -u` кодом 1 вместо осмысленного отказа.
  local RJ="$T/r-jsonreport"; mkdir -p "$RJ"
  echo '{"fresh_check":{"kind":"finalize","required":true},"state_files":[],"human_acceptance":[]}' > "$RJ/contract.json"
  append "$RJ" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null
  append "$RJ" iter_done '{"task_id":"t","files_changed":1,"checkboxes_done":1}' --iter 1 --of 5 >/dev/null
  echo '{"verdict":"SHIP","confidence":0.94}' > "$RJ/judge.json"
  append "$RJ" check_result "$(jq -nc --arg r "$RJ/judge.json" '{check_id:"fresh_check",cmd_hash:"f",exit_code:0,verdict:"SHIP",report:$r}')" --iter 1 >/dev/null 2>&1
  ok $? "круг7: отчёт-JSON как отчёт (путь 1) записывается, а не роняет append"
  [ "$(jq -s -r '[.[]|select(.payload.check_id=="fresh_check")]|.[-1].payload.verdict_source' "$RJ/events.jsonl")" = "json" ]
  ok $? "круг7: источник вердикта помечен json"
  [ "$(jq -s -r '[.[]|select(.payload.check_id=="fresh_check")]|.[-1].payload.verdict_source_sha|length' "$RJ/events.jsonl")" = "64" ]
  ok $? "круг7: sha источника посчитан и на пути 1"
  echo '{"verdict":"NEEDS-WORK"}' > "$RJ/judge.json"
  append "$RJ" check_result "$(jq -nc --arg r "$RJ/judge.json" '{check_id:"fresh_check",cmd_hash:"f",exit_code:0,verdict:"SHIP",report:$r}')" --iter 1 >/dev/null 2>&1
  ok $((1-$?)) "круг7: на пути 1 вердикт со слов события тоже отвергается"
  # честный незелёный ЗАПИСЫВАЕТСЯ (это факт прогона) и закрыть прогон не даёт
  append "$RJ" check_result "$(jq -nc --arg r "$RJ/judge.json" '{check_id:"fresh_check",cmd_hash:"f",exit_code:0,verdict:"NEEDS-WORK",report:$r}')" --iter 1 >/dev/null 2>&1
  ok $? "круг7: незелёный вердикт с пути 1 записывается (факт прогона, а не тишина)"
  append "$RJ" run_done '{"verdict":"green","iters":1,"interventions":0}' >/dev/null 2>&1
  [ $? -eq 4 ]; ok $? "круг7: путь 1 доводит незелёный вердикт до отказа финала"

  # ── круг 6 · авторитет вердикта и честный неуспех ────────────────────────
  # C1. Авторитет переехал на judge.json — проверки подлинности обязаны переехать с ним.
  local RM6="$T/r-machine"; mkdir -p "$RM6"
  echo '{"fresh_check":{"kind":"finalize","required":true},"state_files":[],"human_acceptance":[]}' > "$RM6/contract.json"
  append "$RM6" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null
  append "$RM6" iter_done '{"task_id":"t","files_changed":1,"checkboxes_done":1}' --iter 1 --of 5 >/dev/null
  printf '# Finalize\n\nrun_id: `x`  verdict: **NEEDS-WORK**  confidence: 0.9\n' > "$RM6/judge.md"
  echo '{"verdict":"SHIP"}' > "$RM6/judge.json"; touch -t 202001010000 "$RM6/judge.json"
  append "$RM6" check_result "$(jq -nc --arg r "$RM6/judge.md" '{check_id:"fresh_check",cmd_hash:"f",exit_code:0,verdict:"SHIP",report:$r}')" --iter 1 >/dev/null 2>&1
  ok $((1-$?)) "круг6: ПРОТУХШИЙ машинный артефакт (judge.json из 2020) не подписывает прогон"
  touch "$RM6/judge.json"
  append "$RM6" check_result "$(jq -nc --arg r "$RM6/judge.md" '{check_id:"fresh_check",cmd_hash:"f",exit_code:0,verdict:"SHIP",report:$r}')" --iter 1 >/dev/null
  ok $? "круг6: свежий машинный артефакт главнее текста markdown"
  [ "$(jq -s -r '[.[]|select(.payload.check_id=="fresh_check")]|.[-1].payload.verdict_source_sha|length' "$RM6/events.jsonl")" = "64" ]
  ok $? "круг6: sha источника вердикта считает журнал (report_sha про markdown, не про авторитет)"

  # C2. Сдавшийся прогон обязан уметь записать финал в САМЫХ слепых случаях.
  local RB="$T/r-blocked0"; mkdir -p "$RB"
  jq -nc --arg r "$RB" '{fresh_check:{kind:"finalize",required:true}, project_root:$r, human_acceptance:[]}' > "$RB/contract.json"
  append "$RB" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null
  append "$RB" run_done '{"verdict":"blocked","iters":0,"interventions":0,"outcome":"blocked"}' >/dev/null
  ok $? "круг6: blocked на НУЛЕВОЙ итерации записывает финал (нет токена — работа не начиналась)"
  [ "$(jq -s -r '[.[]|select(.event_type=="run_done")]|.[-1].payload.outcome' "$RB/events.jsonl")" = "blocked" ]
  ok $? "круг6: исход записан, провал не стал тишиной"
  # …но успех в тех же условиях по-прежнему спрашивают полностью
  local RB2="$T/r-blocked0-lie"; mkdir -p "$RB2"
  jq -nc --arg r "$RB2" '{fresh_check:{kind:"finalize",required:true}, project_root:$r, human_acceptance:[]}' > "$RB2/contract.json"
  append "$RB2" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null
  append "$RB2" run_done '{"verdict":"green","iters":0,"interventions":0}' >/dev/null 2>&1
  [ $? -eq 4 ]; ok $? "круг6: заявка на успех без итераций по-прежнему отвергается (outcome не лазейка)"

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
  echo '{"budget":{"max_iters":14,"max_minutes":120},"human_acceptance":[]}' > "$R4/contract.json"
  append "$R4" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null
  [ "$(jq -s -r '.[0].payload.budget.max_iters' "$R4/events.jsonl")" = "14" ]; ok $? "И2: бюджет снят в run_start"

  # режим прогона попадает в журнал: assisted — человек пишет промпты сам и задаёт темп
  local RM="$T/r-mode"; mkdir -p "$RM"
  echo '{"mode":"assisted","budget":{"max_iters":3},"human_acceptance":[]}' > "$RM/contract.json"
  append "$RM" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null
  [ "$(jq -s -r '.[0].payload.mode' "$RM/events.jsonl")" = "assisted" ]; ok $? "режим assisted зафиксирован в run_start"
  local RA="$T/r-auto"; mkdir -p "$RA"; echo '{"budget":{"max_iters":3},"human_acceptance":[]}' > "$RA/contract.json"
  append "$RA" run_start '{"runner":"session","contract_sha":"a"}' >/dev/null
  [ "$(jq -s -r '.[0].payload.mode' "$RA/events.jsonl")" = "autonomous" ]; ok $? "по умолчанию autonomous"

  # реестр: прогон в ЛЮБОМ каталоге обязан стать видимым для калибровки и статуса
  # отдельный индекс на этот блок: в общем уже есть записи предыдущих фикстур
  REG="$T/index-reg.jsonl"; export REDLOOP_INDEX="$REG"
  local RX="$T/elsewhere/runs/proj-run"; mkdir -p "$RX"
  echo '{"state_files":[],"human_acceptance":[]}' > "$RX/contract.json"
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
# Адреса кадров приёмки для ВНЕШНЕГО потребителя (compile.sh печатает их в промпт).
# Отдельная подкоманда, а не вторая копия jq-выражения: копия уже разошлась с журналом.
acceptance_ids() {
  local cf="${1:?contract.json}" mode="${2:-manual}"
  local acc; acc="$(_acceptance_from_contract "$cf")"
  [ "$acc" = "__ERROR__" ] && { echo "[]"; return 1; }
  [ "$acc" = "null" ] && { echo "[]"; return 0; }
  case "$mode" in
    manual) printf '%s' "$acc" | jq -c '[.[]|select(.manual_only==true)|.id]' ;;
    all)    printf '%s' "$acc" | jq -c '[.[]|.id]' ;;
    *) echo "[]"; return 1 ;;
  esac
}

case "${1:-}" in
  --self-test) self_test ;;
  append) shift; append "$@" ;;
  acceptance-ids) shift; acceptance_ids "$@" ;;
  *) echo "usage: events.sh append <run_dir> <event_type> <payload> [--kind K --severity S --iter N --of M] | acceptance-ids <contract.json> [manual|all] | --self-test" >&2; exit 1 ;;
esac

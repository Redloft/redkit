#!/usr/bin/env bash
# step.sh — ЕДИНСТВЕННАЯ точка перехода фаз redwork. Механизация state-гигиены (panel 2026-07-27, NEEDS-WORK@0.86).
#
# Зачем: механика, записанная текстом в SKILL.md («не забудь выставить .phase / инкрементировать бюджет»),
# эмпирически не выполняется. Данные 8 прогонов: 5 брошены в P2_implement/pending при сделанной работе;
# budget.llm_calls=0 ВЕЗДЕ (BUDGET_EXCEEDED не выстрелил бы никогда); ledger не писался ни разу.
# Инварианты на пути деплоя выживают — они преграждают путь физически. Бухгалтерия не выживает.
# Лечение: продвинуть фазу МОЖНО только вызовом, который одновременно пишет phase+phase_status+event+heartbeat.
#
# Usage:
#   step.sh begin  <run_dir>                                  # начать тик (lock+heartbeat+iterations+контракт)
#   step.sh llm    <run_dir> [n=1]                            # ПЕРЕД каждым Agent/Workflow: бюджет+heartbeat
#   step.sh end    <run_dir> --next <PHASE>                   # фаза успешна → следующая
#   step.sh end    <run_dir> --done [--note <text>]           # финал прогона (+ledger, +gc, +unlock)
#   step.sh end    <run_dir> --escalate <REASON> <needs_csv> [detail]   # нужен человек
#   step.sh sweep  [--data-root DIR] [--dry-run]              # пометить брошенные (НЕ разлочивает — см. §sweep)
#   step.sh --version | --self-test
#
# Exit-коды (enum; сессия ОБЯЗАНА различать):
#   0 ok · 1 нарушение контракта/usage · 2 BUDGET_EXCEEDED (стоп loop) · 3 ошибка state/схемы
#   4 lock занят (другой run на repo) · 5 внутренний крах step.sh (записан events step_crash)
set -uEo pipefail   # -E ОБЯЗАТЕЛЕН: без errtrace ERR-trap не наследуется в функциях → _on_err не срабатывал ни разу
HERE="$(cd "$(dirname "$0")" && pwd)"
STATE="$HERE/state.sh"; EVENTS="$HERE/events.sh"; ESCALATE="$HERE/escalate.sh"
LEDGER="$HERE/ledger.sh"
# SKILL_ROOT переопределяем в self-test — тесты не должны писать в боевой feedback/ (изоляция)
SKILL_ROOT="${REDWORK_SKILL_ROOT:-$(cd "$HERE/.." && pwd)}"

STEP_VERSION=1
BUDGET_MAX="${REDWORK_BUDGET_MAX:-40}"
# STALE_SEC откалиброван по ЭМПИРИКЕ 8 прогонов, не взят с потолка: максимальный ЛЕГИТИМНЫЙ разрыв между
# событиями в успешном прод-прогоне 720bb6635d8e = 6.9 ч (ночная пауза внутри живой работы), p95 = 22 мин.
# Порог 7200 (2 ч) из черновика плана пометил бы этот прогон брошенным. 12 ч = 6.9 ч + запас.
STALE_SEC="${REDWORK_STALE_SEC:-43200}"

_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_die() { echo "✗ $2" >&2; exit "$1"; }

# ERR-trap: крах самого step.sh не должен быть немым (иначе класс D1 воспроизводится ВНУТРИ лекарства от D1).
_RD_FOR_TRAP=""
_on_err() {
  local code=$?
  [ -n "$_RD_FOR_TRAP" ] && bash "$EVENTS" append "$_RD_FOR_TRAP" step_crash \
    "$(jq -nc --argjson c "$code" --argjson l "${BASH_LINENO[0]:-0}" '{exit_code:$c, line:$l}')" >/dev/null 2>&1
  exit 5
}
trap _on_err ERR

_get() { bash "$STATE" get "$1" "$2" 2>/dev/null; }
# _num: числовое чтение с ЖЁСТКИМ отказом. Раньше нечитаемый state (чужая схема → cmd_get exit 3)
# давал пустую строку, а $(( "" + 1 )) = 1 → счётчик 30 молча превращался в 1 и BUDGET_EXCEEDED не стрелял.
_num() {
  local v; v="$(_get "$1" "$2")"
  case "$v" in ''|*[!0-9]*) _die 3 "поле $2 нечитаемо/не число ('$v') — state битый или чужой схемы" ;; esac
  echo "$v"
}

# ── begin ─────────────────────────────────────────────────────────────────────
cmd_begin() {
  local rd="${1:?run_dir}"; _RD_FOR_TRAP="$rd"
  [ -f "$rd/state.json" ] || _die 3 "нет state.json: $rd"
  local sv; sv="$(_get "$rd" '.schema_version')" || _die 3 "state нечитаем (schema?)"
  [ "$sv" = "2" ] || _die 3 "state schema_version=$sv, нужен v2 → прогони: bash lib/migrate.sh <run_dir>"
  bash "$STATE" lock "$rd" >/dev/null 2>&1 || _die 4 "lock занят — на этом repo уже активен redwork-run"

  local blocked; blocked="$(_get "$rd" '.blocked_on')"
  if [ "$blocked" != "null" ]; then
    bash "$STATE" unlock "$rd" >/dev/null 2>&1 || true   # НЕ течь локом: иначе следующий begin вернёт 4 «занято» вместо 1 «нужен resume»
    _die 1 "run заблокирован ($(_get "$rd" '.blocked_on.reason_code')) — сначала /redwork-resume"
  fi
  case "$(_get "$rd" '.phase')" in DONE) bash "$STATE" unlock "$rd" >/dev/null 2>&1 || true; _die 1 "run уже DONE — нечего продолжать" ;; esac

  local it; it="$(_num "$rd" '.iterations')"
  bash "$STATE" set_json "$rd" '.iterations = $val' "$(( it + 1 ))" >/dev/null || _die 3 "не удалось записать iterations"
  bash "$STATE" set_json "$rd" '.step_version = $val' "$STEP_VERSION" >/dev/null || true
  local phase mode budget
  phase="$(_get "$rd" '.phase')"; mode="$(_get "$rd" '.mode')"; budget="$(_get "$rd" '.budget.llm_calls')"
  bash "$EVENTS" append "$rd" phase_start "$(jq -nc --arg p "$phase" '{phase:$p}')" >/dev/null || true

  cat <<EOF
PHASE=$phase
MODE=$mode
ITERATION=$(( it + 1 ))
BUDGET=$budget/$BUDGET_MAX
CONTRACT: тик ОБЯЗАН закончиться одним из:
  bash $HERE/step.sh end "$rd" --next <PHASE>
  bash $HERE/step.sh end "$rd" --done [--note "<итог>"]
  bash $HERE/step.sh end "$rd" --escalate <REASON_CODE> <needs_csv> [detail]
Перед КАЖДЫМ Agent/Workflow: bash $HERE/step.sh llm "$rd"   (exit 2 = бюджет исчерпан, стоп)
EOF
}

# ── llm (бюджет + heartbeat) ──────────────────────────────────────────────────
# Идемпотентность (решение панели, конфликт «overcount vs undercount»): дедупа НЕТ намеренно.
# Повторный вызов на retry ЗАВЫШАЕТ счётчик — это допустимо. Занижение — нет: недосчитанный бюджет
# и есть дефект D2. Heartbeat идемпотентен и от задвоения не страдает.
cmd_llm() {
  local rd="${1:?run_dir}" n="${2:-1}"; _RD_FOR_TRAP="$rd"
  [ -f "$rd/state.json" ] || _die 3 "нет state.json"
  local sv; sv="$(_get "$rd" '.schema_version')"
  [ "$sv" = "2" ] || _die 3 "state schema_version='$sv' — llm отказан (бюджет обнулился бы молча)"
  local cur; cur="$(_num "$rd" '.budget.llm_calls')"
  local new=$(( cur + n ))
  bash "$STATE" set_json "$rd" '.budget.llm_calls = $val' "$new" >/dev/null || _die 3 "не удалось записать бюджет"
  bash "$STATE" touch "$rd" || true
  if [ "$new" -gt "$BUDGET_MAX" ]; then
    bash "$ESCALATE" "$rd" BUDGET_EXCEEDED "approve_more_budget" "llm_calls_${new}_over_${BUDGET_MAX}" >/dev/null 2>&1 || true
    bash "$STATE" set_str "$rd" '.phase_status = $val' blocked >/dev/null 2>&1 || true
    bash "$STATE" unlock "$rd" >/dev/null 2>&1 || true
    echo "✗ BUDGET_EXCEEDED: $new > $BUDGET_MAX — эскалировано, СТОП loop" >&2
    exit 2
  fi
  echo "budget=$new/$BUDGET_MAX"
}

# ── end ───────────────────────────────────────────────────────────────────────
cmd_end() {
  local rd="${1:?run_dir}"; shift; _RD_FOR_TRAP="$rd"
  [ -f "$rd/state.json" ] || _die 3 "нет state.json"
  local kind="" next="" reason="" needs="" detail="" note=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --next) kind=next; next="${2:?--next требует PHASE}"; shift 2 ;;
      --done) kind=done; shift ;;
      --escalate) kind=escalate; reason="${2:?--escalate требует REASON_CODE}"; needs="${3:?--escalate требует needs_csv}"
                  shift 3
                  # detail опционален; НЕ съедать следующий флаг (`--note` и т.п.) как detail
                  case "${1:-}" in --*|"") detail="" ;; *) detail="$1"; shift ;; esac ;;
      --note) note="${2:-}"; shift 2 ;;
      *) _die 1 "неизвестный аргумент end: $1" ;;
    esac
  done
  [ -n "$kind" ] || _die 1 "end без --next|--done|--escalate — тик нельзя завершить «никак» (это и есть дефект D1)"

  case "$kind" in
    next)
      case "$next" in
        P2_implement|P3_testgate|P4_finalize_pre|P5_deploy|P6_postverify|P6.5_devsync) ;;
        DONE) _die 1 "DONE только через --done (там ledger+gc+unlock) — иначе воспроизводится ровно дефект «DONE/pending»" ;;
        *) _die 1 "неизвестная фаза '$next' (опечатка?) — допустимы P2_implement|P3_testgate|P4_finalize_pre|P5_deploy|P6_postverify|P6.5_devsync" ;;
      esac
      [ -z "$note" ] || _die 1 "--note имеет смысл только с --done (иначе молча теряется)"
      # АТОМАРНО: phase+phase_status одной записью (полу-состояние «фаза сменилась, статус старый» невозможно)
      bash "$STATE" set_json "$rd" '.phase = $val.phase | .phase_status = $val.phase_status' \
        "$(jq -nc --arg p "$next" '{phase:$p, phase_status:"pending"}')" >/dev/null || _die 3 "переход фазы не записан"
      bash "$EVENTS" append "$rd" phase_done "$(jq -nc --arg n "$next" '{next:$n}')" >/dev/null || true
      bash "$STATE" touch "$rd" || true
      echo "✓ phase → $next"
      ;;
    done)
      local phase; phase="$(_get "$rd" '.phase')"
      case "$phase" in P6_postverify|P6.5_devsync|P6|DONE) ;;
        *) bash "$EVENTS" append "$rd" phase_done "$(jq -nc --arg p "$phase" '{next:"DONE", warn:"done_from_early_phase", from:$p}')" >/dev/null || true ;;
      esac
      bash "$STATE" set_json "$rd" '.phase = $val.phase | .phase_status = $val.phase_status' \
        '{"phase":"DONE","phase_status":"done"}' >/dev/null || _die 3 "DONE не записан"
      _write_ledger "$rd" "$note" || echo "⚠ ledger не записан (не блокирует DONE)" >&2
      bash "$EVENTS" gc "$rd" >/dev/null 2>&1 || true
      bash "$STATE" unlock "$rd" >/dev/null || true
      echo "✓ DONE (ledger записан, lock снят)"
      ;;
    escalate)
      # escalate.sh сам пишет blocked_on + durable log + TG. Каналы: ТОЛЬКО TG + локальный лог.
      # В Я.Трекер step.sh/sweep НЕ пишут — там fail-closed money-guard, а detail/note машинные (см. SKILL §Инварианты).
      bash "$ESCALATE" "$rd" "$reason" "$needs" "$detail" >/dev/null || _die 1 "escalate провален (reason в enum?)"
      bash "$STATE" set_str "$rd" '.phase_status = $val' blocked >/dev/null || _die 3 "phase_status=blocked не записан"
      bash "$STATE" unlock "$rd" >/dev/null || true
      echo "✓ escalated: $reason (needs: $needs) — СТОП loop, ждём /redwork-resume"
      ;;
  esac
}

# ledger: ОТДЕЛЬНЫЙ поток. feedback/learnings.jsonl — методологические находки петли самоулучшения
# (её формат ждёт solidify); исходы прогонов туда мешать нельзя — испортит обе выборки (gap панели).
_write_ledger() {
  local rd="$1" note="${2:-}"
  local out="$SKILL_ROOT/feedback/runs.jsonl"; mkdir -p "$(dirname "$out")"
  local ev=0; [ -f "$rd/events.jsonl" ] && ev="$(wc -l < "$rd/events.jsonl" | tr -d ' ')"
  local esc=0; [ -f "$rd/escalations.log" ] && esc="$(wc -l < "$rd/escalations.log" | tr -d ' ')"
  bash "$STATE" validate-no-secrets "$note" >/dev/null || { echo "✗ ledger: note содержит секрет-подобное" >&2; return 1; }
  local line
  line="$(jq -nc --argjson sv 1 \
    --arg slug "$(_get "$rd" '.slug')" --arg ts "$(_now_iso)" \
    --arg created "$(_get "$rd" '.created_at')" --argjson mode "$(_get "$rd" '.mode')" \
    --argjson iters "$(_get "$rd" '.iterations')" --argjson llm "$(_get "$rd" '.budget.llm_calls')" \
    --argjson ev "$ev" --argjson esc "$esc" --arg note "$note" \
    --argjson fp "$(jq -c '.verdicts.finalize_pre // null' "$rd/state.json" 2>/dev/null || echo null)" \
    --argjson di "$(jq -c '.deploy_intent // null' "$rd/state.json" 2>/dev/null || echo null)" \
    '{schema_version:$sv, kind:"run_outcome", skill:"redwork", ts:$ts, slug:$slug, created_at:$created,
      mode:$mode, iterations:$iters, llm_calls:$llm, events:$ev, escalations:$esc,
      finalize_pre:$fp, deploy_intent:$di, note:$note}' 2>/dev/null)" || return 1
  [ -n "$line" ] || return 1
  printf '%s\n' "$line" >> "$out"
}

# ── sweep ─────────────────────────────────────────────────────────────────────
# Ловит то, чего сессия сделать не может по определению: сообщить, что она умерла.
#
# ⚠ ДВА ОТСТУПЛЕНИЯ ОТ ЧЕРНОВИКА ПЛАНА (обосновано кодом, панель этого видеть не могла — роли не читали исходники):
#  1. sweep НИКОГДА не снимает lock. Панель требовала «не разлочивать при живом pid», но pid как признак
#     жизни не работает в принципе: state.sh lock пишет $$ короткоживущего процесса, он мёртв через миллисекунды.
#     Значит «живой pid» — не veto, а шум. Убираем разлочивание целиком: reclaim протухшего лока уже делает
#     state.sh lock в момент захвата (там это безопасно — по свежести heartbeat). Так sweep физически не может
#     разлочить run посреди two-phase deploy — критический риск R2 закрыт конструктивно, а не порогом.
#  2. Пометка обратима и дешева: phase_status=abandoned + blocked_on. /redwork-resume снимает blocked_on
#     и продолжает. Ложное срабатывание стоит одну команду, поэтому эвристика по времени допустима (R6).
cmd_sweep() {
  local root="${REDWORK_DATA_DIR:-$HOME/Library/Application Support/redwork/runs}" dry=0
  while [ $# -gt 0 ]; do
    case "$1" in --data-root) root="${2:?}"; shift 2 ;; --dry-run) dry=1; shift ;; *) shift ;; esac
  done
  [ -d "$root" ] || { echo "sweep: нет $root"; return 0; }
  local now; now="$(date +%s)"; local n_ab=0 n_ok=0 n_bad=0
  local d
  for d in "$root"/*/; do
    [ -f "$d/state.json" ] || continue
    local phase blocked upd sv
    phase="$(jq -r '.phase // ""' "$d/state.json" 2>/dev/null || echo "")"
    blocked="$(jq -r '.blocked_on' "$d/state.json" 2>/dev/null || echo "null")"
    sv="$(jq -r '.schema_version // 1' "$d/state.json" 2>/dev/null || echo 1)"
    # ИДЕМПОТЕНТНОСТЬ (R1: Stop-hook фаерит часто — уже помеченный run не переэскалируется, иначе TG-спам)
    [ "$phase" = "DONE" ] && { n_ok=$((n_ok+1)); continue; }
    [ "$blocked" = "null" ] || { n_ok=$((n_ok+1)); continue; }
    [ "$sv" = "2" ] || { n_ok=$((n_ok+1)); continue; }        # немигрированные не трогаем
    upd="$(jq -r '.updated_at // .created_at // ""' "$d/state.json" 2>/dev/null || echo "")"
    if [ -z "$upd" ]; then echo "⚠ пропуск (нет updated_at): ${d%/}"; n_bad=$((n_bad+1)); continue; fi
    local upd_s; upd_s="$(_iso_to_epoch "$upd")" || upd_s=""
    if [ -z "$upd_s" ]; then echo "⚠ пропуск (непарсимая дата '$upd'): ${d%/}"; n_bad=$((n_bad+1)); continue; fi
    [ $(( now - upd_s )) -gt "$STALE_SEC" ] || { n_ok=$((n_ok+1)); continue; }
    if [ "$dry" = "1" ]; then echo "DRY: пометил бы abandoned — ${d%/} (тишина $(( (now-upd_s)/3600 ))ч, phase=$phase)"; n_ab=$((n_ab+1)); continue; fi
    # ПОРЯДОК ВАЖЕН: escalate сам ставит phase_status=blocked; если звать его вторым, он затрёт abandoned.
    bash "$ESCALATE" "${d%/}" WAIT_HUMAN "resume_or_close" "abandoned_stale" >/dev/null 2>&1 || true
    bash "$STATE" set_str "${d%/}" '.phase_status = $val' abandoned >/dev/null 2>&1 || continue
    n_ab=$((n_ab+1))
    echo "⚠ abandoned: ${d%/} (тишина $(( (now-upd_s)/3600 ))ч, phase=$phase)"
  done
  echo "sweep: помечено $n_ab, пропущено $n_ok, нечитаемых $n_bad (порог ${STALE_SEC}с)"
  return 0
}

_iso_to_epoch() {   # macOS date -j -f ↔ GNU date -d
  date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null || date -u -d "$1" +%s 2>/dev/null
}

# ── self-test ─────────────────────────────────────────────────────────────────
self_test() {
  set +e; trap - ERR
  local T; T="$(mktemp -d)"; export REDWORK_DATA_DIR="$T"; export REDWORK_ESCALATE_DRYRUN=1
  export REDWORK_SKILL_ROOT="$T/skill"; SKILL_ROOT="$T/skill"; mkdir -p "$SKILL_ROOT/feedback"
  local fail=0; ok(){ if [ "$1" -eq 0 ]; then :; else echo "  ✗ $2"; fail=1; fi; }
  local rd; rd="$(bash "$STATE" init "$(bash "$STATE" slug t1)" 'demo task' /tmp/repo 2 redwork/t1)"

  # begin
  local out; out="$(cmd_begin "$rd" 2>&1)"; ok $? "begin"
  printf '%s' "$out" | grep -q "PHASE=P2_implement"; ok $? "begin печатает контракт тика"
  [ "$(_get "$rd" '.iterations')" = "1" ]; ok $? "begin инкрементит iterations"
  [ "$(_get "$rd" '.step_version')" = "1" ]; ok $? "step_version записан (различение протоколов)"
  [ -d "$rd/.lock" ]; ok $? "begin взял lock"

  # llm
  cmd_llm "$rd" >/dev/null; ok $? "llm"
  [ "$(_get "$rd" '.budget.llm_calls')" = "1" ]; ok $? "бюджет инкрементится (D2)"
  cmd_llm "$rd" 3 >/dev/null; [ "$(_get "$rd" '.budget.llm_calls')" = "4" ]; ok $? "llm n=3"

  # end --next
  cmd_end "$rd" --next P3_testgate >/dev/null; ok $? "end --next"
  [ "$(_get "$rd" '.phase')" = "P3_testgate" ]; ok $? "фаза сдвинулась"
  [ "$(_get "$rd" '.phase_status')" = "pending" ]; ok $? "phase_status=pending для новой фазы"
  # end без флага → контрактная ошибка (exit 1)
  ( cmd_end "$rd" >/dev/null 2>&1 ); [ "$?" = "1" ]; ok $? "end без флага → exit 1 (нельзя закончить «никак»)"

  # бюджет: превышение → exit 2 + blocked + unlock
  REDWORK_BUDGET_MAX=5 bash "$0" llm "$rd" 10 >/dev/null 2>&1; [ "$?" = "2" ]; ok $? "превышение бюджета → exit 2"
  [ "$(_get "$rd" '.blocked_on.reason_code')" = "BUDGET_EXCEEDED" ]; ok $? "BUDGET_EXCEEDED в blocked_on"
  [ ! -d "$rd/.lock" ]; ok $? "бюджет-стоп снял lock"
  # begin на заблокированном run → отказ
  ( cmd_begin "$rd" >/dev/null 2>&1 ); [ "$?" = "1" ]; ok $? "begin на blocked run → отказ (нужен resume)"

  # end --done: ledger + gc + unlock
  local rd2; rd2="$(bash "$STATE" init "$(bash "$STATE" slug t2)" 'demo 2' /tmp/repo 2 redwork/t2)"
  cmd_begin "$rd2" >/dev/null
  bash "$STATE" set_str "$rd2" '.phase = $val' P6_postverify >/dev/null
  local LG="$SKILL_ROOT/feedback/runs.jsonl"; local before=0; [ -f "$LG" ] && before="$(wc -l < "$LG" | tr -d ' ')"
  cmd_end "$rd2" --done --note "self-test прогон" >/dev/null; ok $? "end --done"
  [ "$(_get "$rd2" '.phase')" = "DONE" ]; ok $? "phase=DONE"
  [ "$(_get "$rd2" '.phase_status')" = "done" ]; ok $? "phase_status=done (а НЕ pending — дефект 720bb…)"
  [ ! -d "$rd2/.lock" ]; ok $? "DONE снял lock"
  local after=0; [ -f "$LG" ] && after="$(wc -l < "$LG" | tr -d ' ')"
  [ "$after" -gt "$before" ]; ok $? "ledger-строка записана (D3)"
  tail -1 "$LG" | jq -e '.kind=="run_outcome" and .schema_version==1' >/dev/null; ok $? "ledger-строка: kind+schema_version"
  tail -1 "$LG" | jq -e 'has("note")' >/dev/null; ok $? "note в ledger"
  # секрет в note → отказ записи ledger (но не падение DONE)
  local rd5; rd5="$(bash "$STATE" init "$(bash "$STATE" slug t5)" 'demo 5' /tmp/repo 2 redwork/t5)"
  cmd_begin "$rd5" >/dev/null
  cmd_end "$rd5" --done --note "ключ sk-""ABCDEFGHIJ1234567890abcd" >/dev/null 2>&1
  [ "$(_get "$rd5" '.phase')" = "DONE" ]; ok $? "секрет в note не сорвал DONE"
  [ "$(tail -1 "$LG" | jq -r '.slug')" != "$(_get "$rd5" '.slug')" ]; ok $? "ledger-строка с секретом НЕ записана"

  # ── РЕГРЕСС на находки адверсариального ревью 2026-07-27 ──
  local rdr; rdr="$(bash "$STATE" init "$(bash "$STATE" slug reg)" 'regress' /tmp/repo 2 redwork/reg)"
  cmd_begin "$rdr" >/dev/null
  # #2: --escalate НЕ должен съедать следующий флаг как detail
  ( cmd_end "$rdr" --escalate IMPL_AMBIGUOUS answer_question --note "итог" >/dev/null 2>&1 )
  [ "$(_get "$rdr" '.blocked_on.reason_code')" = "IMPL_AMBIGUOUS" ]; ok $? "#2 --escalate + --note: эскалация записана (не съела флаг)"
  # #9: --next валидирует фазу; DONE только через --done
  local rdn; rdn="$(bash "$STATE" init "$(bash "$STATE" slug reg2)" 'regress2' /tmp/repo 2 redwork/reg2)"
  cmd_begin "$rdn" >/dev/null
  ( cmd_end "$rdn" --next P3_testgat >/dev/null 2>&1 ); [ "$?" = "1" ]; ok $? "#9 опечатка в фазе → отказ"
  ( cmd_end "$rdn" --next DONE >/dev/null 2>&1 ); [ "$?" = "1" ]; ok $? "#9 --next DONE запрещён (обходил ledger/unlock)"
  [ "$(_get "$rdn" '.phase')" = "P2_implement" ]; ok $? "#9 фаза не испорчена отказами"
  # #10: --note с --next теряется молча → теперь ошибка
  ( cmd_end "$rdn" --next P3_testgate --note "x" >/dev/null 2>&1 ); [ "$?" = "1" ]; ok $? "#10 --note при --next → ошибка, не тихая потеря"
  # #3: чужая схема НЕ должна молча обнулять бюджет
  bash "$STATE" set_json "$rdn" '.budget.llm_calls = $val' 30 >/dev/null
  python3 - "$rdn/state.json" <<'PYX'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["schema_version"]=9; json.dump(d,open(p,"w"))
PYX
  ( cmd_llm "$rdn" 1 >/dev/null 2>&1 ); [ "$?" = "3" ]; ok $? "#3 llm на чужой схеме → exit 3 (а не тихое обнуление)"
  [ "$(jq -r '.budget.llm_calls' "$rdn/state.json")" = "30" ]; ok $? "#3 счётчик не затёрт"
  # #5: begin на blocked-run НЕ течёт локом
  local rdb; rdb="$(bash "$STATE" init "$(bash "$STATE" slug reg3)" 'regress3' /tmp/repo 2 redwork/reg3)"
  bash "$ESCALATE" "$rdb" WAIT_HUMAN "review_dev" >/dev/null 2>&1
  ( cmd_begin "$rdb" >/dev/null 2>&1 ); [ "$?" = "1" ]; ok $? "#5 begin на blocked → exit 1"
  [ ! -d "$rdb/.lock" ]; ok $? "#5 lock не течёт при отказе"
  ( cmd_begin "$rdb" >/dev/null 2>&1 ); [ "$?" = "1" ]; ok $? "#5 повторный begin: снова 1 (а не 4 «занято»)"
  # #4: ERR-trap жив (set -E) — проверяем сам факт errtrace
  case "$(set -o | grep errtrace)" in *on*) ok 0 "" ;; *) ok 1 "#4 errtrace должен быть включён (иначе ERR-trap мёртв)" ;; esac

  # end --escalate
  local rd3; rd3="$(bash "$STATE" init "$(bash "$STATE" slug t3)" 'demo 3' /tmp/repo 1 redwork/t3)"
  cmd_begin "$rd3" >/dev/null
  cmd_end "$rd3" --escalate IMPL_AMBIGUOUS "answer_question" "which_api" >/dev/null; ok $? "end --escalate"
  [ "$(_get "$rd3" '.blocked_on.reason_code')" = "IMPL_AMBIGUOUS" ]; ok $? "blocked_on выставлен"
  [ "$(_get "$rd3" '.phase_status')" = "blocked" ]; ok $? "phase_status=blocked"
  [ ! -d "$rd3/.lock" ]; ok $? "escalate снял lock"

  # sweep
  local rd4; rd4="$(bash "$STATE" init "$(bash "$STATE" slug t4)" 'demo 4' /tmp/repo 2 redwork/t4)"
  cmd_begin "$rd4" >/dev/null   # берём lock — проверяем, что sweep его НЕ снимет
  cmd_sweep >/dev/null; [ "$(_get "$rd4" '.phase_status')" = "pending" ]; ok $? "sweep НЕ трогает свежий run"
  # протухший: updated_at в прошлом
  bash "$STATE" set_str "$rd4" '.created_at = $val' "2020-01-01T00:00:00Z" >/dev/null
  python3 - "$rd4/state.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["updated_at"]="2020-01-01T00:00:00Z"; json.dump(d,open(p,"w"))
PY
  cmd_sweep >/dev/null 2>&1
  [ "$(_get "$rd4" '.phase_status')" = "abandoned" ]; ok $? "sweep помечает протухший как abandoned (D4)"
  [ "$(_get "$rd4" '.blocked_on.reason_code')" = "WAIT_HUMAN" ]; ok $? "sweep эскалирует (blocked_on)"
  [ -d "$rd4/.lock" ]; ok $? "⚑ sweep НЕ снимает lock (R2: не разлочить two-phase deploy)"
  # идемпотентность: повторный sweep не переэскалирует (R1 — TG-спам на каждый Stop)
  local e1; e1="$(wc -l < "$rd4/escalations.log" | tr -d ' ')"
  cmd_sweep >/dev/null 2>&1; cmd_sweep >/dev/null 2>&1
  [ "$(wc -l < "$rd4/escalations.log" | tr -d ' ')" = "$e1" ]; ok $? "sweep идемпотентен (уже-blocked не переэскалируется)"
  # dry-run ничего не пишет
  local rd6; rd6="$(bash "$STATE" init "$(bash "$STATE" slug t6)" 'demo 6' /tmp/repo 2 redwork/t6)"
  python3 - "$rd6/state.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["updated_at"]="2020-01-01T00:00:00Z"; json.dump(d,open(p,"w"))
PY
  # NB: без пайпа в grep -q — тот закрывает пайп на первом совпадении, cmd_sweep ловит SIGPIPE,
  # и pipefail роняет весь пайплайн (тест ловил бы артефакт, а не поведение).
  local dryout; dryout="$(cmd_sweep --dry-run)"
  case "$dryout" in *"DRY:"*) ok 0 "" ;; *) ok 1 "--dry-run показывает кандидатов" ;; esac
  [ "$(_get "$rd6" '.phase_status')" = "pending" ]; ok $? "--dry-run ничего не изменил"

  rm -rf "$T"
  if [ "$fail" -eq 0 ]; then echo "✓ step self-test passed"; return 0; else echo "✗ step self-test FAILED"; return 1; fi
}

case "${1:-}" in
  begin) shift; cmd_begin "$@" ;;
  llm)   shift; cmd_llm "$@" ;;
  end)   shift; cmd_end "$@" ;;
  sweep) shift; cmd_sweep "$@" ;;
  --version) echo "$STEP_VERSION" ;;
  --self-test) self_test ;;
  *) echo "usage: step.sh begin|llm|end|sweep|--version|--self-test  (см. шапку файла)" >&2; exit 1 ;;
esac

#!/usr/bin/env bash
# escalate.sh — доставка эскалаций и финалов прогона владельцу (DESIGN v2 §S5, panel critical #6).
# «Строка в файле потребителем не считается»: durable-лог — пол, но обязателен внешний канал.
# Канал: TG @Attunedbot (redcontrol/scripts/rc_tg_send.py, токен из 1Password, в argv не попадает).
# Схема payload строгая: без task-текста, без command-output, без PII.
#
# Usage:
#   escalate.sh <run_dir> <reason_code> <needs_csv> [diagnosis_code] [suggested_action]
#   escalate.sh --self-test          (dry-run: REDLOOP_ESCALATE_DRYRUN=1)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SENDER="${REDLOOP_TG_SENDER:-$HOME/.claude/skills/redcontrol/scripts/rc_tg_send.py}"
CHAT="${REDLOOP_TG_CHAT:-}"                       # адресат: env, иначе локальный файл ниже
CHAT_FILE="${REDLOOP_TG_CHAT_FILE:-$HOME/.claude/.redloop-tg-chat}"   # gitignored, НЕ в репо
[ -z "$CHAT" ] && [ -f "$CHAT_FILE" ] && CHAT="$(tr -d "[:space:]" < "$CHAT_FILE")"
# ⚠ имена детекторов пишутся ТОЧНО так же, как их печатает detect.sh (через дефис).
# Рассинхрон конвенций уже стоил трёх немых детекторов: escalate отвергал reason_code,
# и RETRY-BURN / PREMATURE-EXIT / ASK-STORM физически не могли позвать человека.
REASONS="STALL LOOP RETRY-BURN DRIFT PREMATURE-EXIT ASK-STORM SILENCE BUDGET_EXCEEDED CONTRACT_INVALID FLOOR_BLOCKED RUNNER_DEAD RUN_DONE NO_GO"

escalate() {
  local rd="${1:?run_dir}" reason="${2:?reason_code}" needs="${3:?needs_csv}" diag="${4:-}" sugg="${5:-}"
  echo "$REASONS" | grep -qw "$reason" || { echo "✗ reason_code не в enum: $reason" >&2; return 1; }
  mkdir -p "$rd"
  local rid; rid="$(basename "$rd")"
  local attempts=0; [ -f "$rd/events.jsonl" ] && attempts="$(jq -s '[.[] | select(.event_type=="iter_done")] | length' "$rd/events.jsonl")"
  local payload; payload="$(jq -nc --arg rid "$rid" --arg rc "$reason" --argjson att "${attempts:-0}" \
      --argjson needs "$(printf '%s' "$needs" | tr ',' '\n' | sed '/^$/d' | jq -R . | jq -s .)" \
      --arg diag "$diag" --arg sugg "$sugg" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{run_id:$rid, reason_code:$rc, attempts:$att, needs:$needs, diagnosis:$diag, suggested_action:$sugg, ts:$ts}')"

  printf '%s\n' "$payload" >> "$rd/escalations.log"           # durable пол
  bash "$HERE/events.sh" append "$rd" escalation \
     "$(jq -nc --arg rc "$reason" --argjson n "$(printf '%s' "$payload" | jq .needs)" '{reason_code:$rc, needs:$n}')" \
     --severity critical >/dev/null 2>&1 || true

  local tg="skipped"
  if [ "${REDLOOP_ESCALATE_DRYRUN:-0}" = "1" ]; then tg="dryrun"
  elif [ -z "$CHAT" ]; then tg="no_recipient(лог сохранён)"
  elif [ -f "$SENDER" ]; then
    # текст — в stdin (в argv не попадает); токен инъектит op run в окружение дочернего процесса
    local msg="🔁 redloop · $reason · run $rid · итераций: $attempts"
    [ -n "$diag" ] && msg="$msg
диагноз: $diag"
    [ -n "$sugg" ] && msg="$msg
предложение: $sugg"
    if printf '%s' "$msg" | op run --env-file=<(echo "TELEGRAM_BOT_TOKEN=op://AI-Tokens/TG Attune/password") -- \
         python3 "$SENDER" --chat-id "$CHAT" >/dev/null 2>&1; then tg="sent"; else tg="failed(лог сохранён)"; fi
  fi
  printf '%s' "$payload" | jq -c --arg tg "$tg" '. + {delivery:$tg}'
  case "$tg" in failed*|no_recipient*)
    echo "⚠ внешний канал не отработал ($tg) — эскалация видна только в escalations.log; задай REDLOOP_TG_CHAT или $CHAT_FILE" >&2
    return 3 ;;   # exit 3 = записано локально, но человек НЕ извещён (машинно отличимо от успеха)
  esac
  return 0
}

self_test() {
  set +e; export REDLOOP_ESCALATE_DRYRUN=1; local T; T="$(mktemp -d)"; local rd="$T/run-x"; mkdir -p "$rd"; local fail=0
  ok(){ if [ "$1" -eq 0 ]; then :; else echo "  ✗ $2"; fail=1; fi; }
  local out; out="$(escalate "$rd" STALL "unblock,review" "3 итерации без правок" "переформулировать задачу")"; ok $? "валидная эскалация"
  printf '%s' "$out" | jq -e '.reason_code=="STALL"' >/dev/null; ok $? "reason_code в payload"
  printf '%s' "$out" | jq -e 'has("task")|not' >/dev/null; ok $? "нет текста задачи/PII"
  printf '%s' "$out" | jq -e '.delivery=="dryrun"' >/dev/null; ok $? "канал отчитывается о доставке"
  [ -f "$rd/escalations.log" ]; ok $? "durable лог (пол доставки)"
  grep -q '"event_type":"escalation"' "$rd/events.jsonl"; ok $? "эскалация видна в журнале"
  local d; for d in STALL LOOP RETRY-BURN DRIFT PREMATURE-EXIT ASK-STORM; do
    escalate "$rd" "$d" "unblock" >/dev/null 2>&1; ok $? "детектор $d принимается эскалацией"
  done
  escalate "$rd" BOGUS "x" >/dev/null 2>&1; ok $((1-$?)) "невалидный reason_code отвергнут"
  escalate "$rd" RUN_DONE "none" "DoD зелёный" >/dev/null; ok $? "финал прогона тоже идёт в канал"
  # литерал разрезан, иначе проверка находит саму себя (грабля канареек в publish-gate)
  pat="1543""83433"; grep -q "$pat" "$HERE/escalate.sh"; ok $((1-$?)) "личный chat_id НЕ захардкожен (публичный репо)"
  # ⚠ pipefail жив даже при set +e: exit 3 из escalate утёк бы в статус пайпа и уронил проверку.
  # Поэтому сначала забираем вывод, потом отдельно проверяем его и отдельно — код возврата.
  unset REDLOOP_ESCALATE_DRYRUN
  local nr; nr="$(REDLOOP_TG_CHAT="" REDLOOP_TG_CHAT_FILE="/nonexistent" bash "$HERE/escalate.sh" "$rd" STALL "x" 2>/dev/null)"
  local nrc=$?
  printf '%s' "$nr" | jq -e '.delivery|startswith("no_recipient")' >/dev/null
  ok $? "нет адресата → доставка помечена, а не выдана за успех"
  [ "$nrc" -eq 3 ]; ok $? "недоставка → exit 3, а не 0 (машинно отличимо)"
  rm -rf "$T"
  [ "$fail" -eq 0 ] && { echo "✓ escalate self-test passed"; return 0; } || { echo "✗ escalate self-test FAILED"; return 1; }
}
case "${1:-}" in --self-test) self_test ;; "") echo "usage: escalate.sh <run_dir> <reason_code> <needs_csv> [diag] [suggestion] | --self-test" >&2; exit 1;; *) escalate "$@" ;; esac

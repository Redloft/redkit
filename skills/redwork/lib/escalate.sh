#!/usr/bin/env bash
# escalate.sh — эскалация redwork к человеку (spec v3 §Эскалация).
# Инварианты (панель): СТРОГАЯ схема {slug,phase,reason_code(enum),needs,run_path,ts} — без command-output,
# без task-текста/PII; per-channel strip; «доставлено ≥1»=успех (локальный durable-лог = пол).
# Каналы: TG @rltimebot (bash, best-effort через op) — здесь; push + Трекер — фаерит СЕССИЯ после вызова
# (у bash нет доступа к этим инструментам) по emitted-директиве. dry-run: REDWORK_ESCALATE_DRYRUN=1.
#
# Usage:
#   escalate.sh <run_dir> <reason_code> <needs_csv> [detail_code]
#   escalate.sh --self-test
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
STATE="$HERE/state.sh"; EVENTS="$HERE/events.sh"
source "$HERE/secret-guard.sh"

REASON_ENUM="PLAN_BLOCKED IMPL_AMBIGUOUS TEST_FIXER_FAILED FINALIZE_NOT_SHIP DEPLOY_HIGH_RISK DEPLOY_NO_ROLLBACK SMOKE_FAILED ROLLBACK_FAILED POSTVERIFY_ISSUE BUDGET_EXCEEDED WAIT_TIMEOUT WAIT_HUMAN BASELINE_LINT_BROKEN CONFIG_INVALID"

escalate() {
  local rd="${1:?run_dir}" reason="${2:?reason_code}" needs="${3:?needs_csv}" detail="${4:-}"
  echo "$REASON_ENUM" | grep -qw "$reason" || { echo "✗ reason_code не в enum: $reason" >&2; return 1; }
  # needs → structured [{need_type,detail_code}] (need_type = csv-элементы)
  local needs_json; needs_json="$(printf '%s' "$needs" | tr ',' '\n' | sed '/^$/d' | jq -R --arg d "$detail" '{need_type:., detail_code:$d}' | jq -s .)"
  local slug phase; slug="$(jq -r '.slug // "?"' "$rd/state.json")"; phase="$(jq -r '.phase // "?"' "$rd/state.json")"
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # СТРОГАЯ схема — только разрешённые поля (no command-output, no task/PII)
  local payload; payload="$(jq -nc --arg slug "$slug" --arg phase "$phase" --arg rc "$reason" \
    --argjson needs "$needs_json" --arg rp "$rd" --arg ts "$ts" \
    '{slug:$slug, phase:$phase, reason_code:$rc, needs:$needs, run_path:$rp, ts:$ts}')"
  # secrets-гейт (keyword — payload содержит run_path/slug-hash, энтропия ложно бьёт)
  if kw_secret_found "$payload"; then echo "✗ escalation payload содержит секрет-паттерн — отказ" >&2; return 1; fi

  # 1) durable локальный лог (пол: гарантирует «доставлено ≥1»)
  printf '%s\n' "$payload" >> "$rd/escalations.log"
  # 2) событие + blocked_on в state
  bash "$EVENTS" append "$rd" escalation "$(jq -nc --arg rc "$reason" '{reason_code:$rc}')" >/dev/null || true   # событие — best-effort
  # blocked_on — SAFETY-критично: НЕ глотать. Провал записи → run не помечен заблокированным → опасно.
  bash "$STATE" set_json "$rd" '.blocked_on = $val' "$(jq -nc --arg rc "$reason" --argjson n "$needs_json" '{reason_code:$rc, needs:$n}')" >/dev/null \
    || { echo "✗ escalate: не удалось записать blocked_on — run НЕ заблокирован (опасно)" >&2; return 1; }
  [ "$(jq -r '.blocked_on.reason_code // "null"' "$rd/state.json" 2>/dev/null)" = "$reason" ] \
    || { echo "✗ escalate: read-back blocked_on провален" >&2; return 1; }

  # 3) TG @rltimebot — best-effort (bash-канал). dry-run в тестах.
  local tg="skipped"
  if [ "${REDWORK_ESCALATE_DRYRUN:-0}" = "1" ]; then tg="dryrun"
  elif [ -n "${REDWORK_TG_CHAT:-}" ]; then
    # секрет инъектится op-run снаружи; тело — только sanitized payload (без command-output)
    local msg; msg="🤖 redwork эскалация · $slug · $phase · $reason · needs: $needs"   # без run_path (топология ФС/username — не в 3rd-party канал; путь в durable escalations.log)
    # анти-инъекция: значения идут через ENV, bash -c тело в ОДИНАРНЫХ кавычках (нет интерполяции $msg/$chat),
    # curl --data-urlencode принимает их как значения, не как shell. TG_TOKEN инъектится op-run в child. %20 — пробел в имени item.
    if MSG="$msg" CHAT="$REDWORK_TG_CHAT" op run --env-file=<(echo "TG_TOKEN=op://AI-Tokens/TG%20rltimebot/credential") -- \
        bash -c 'curl -fsS --max-time 10 --data-urlencode "chat_id=$CHAT" --data-urlencode "text=$MSG" "https://api.telegram.org/bot$TG_TOKEN/sendMessage" >/dev/null' 2>/dev/null; then tg="sent"; else tg="failed(локальный лог сохранён)"; fi
  fi

  # 4) emit-директива для СЕССИИ: дофаерить push + Трекер (bash не имеет этих инструментов)
  echo "$payload"
  echo "‹ESCALATE-DIRECTIVE› channels: TG=$tg ; session→ PushNotification + (если CPMO-id) tracker issue_add_comment с reason_code+needs+run_path (без command-output)" >&2
  return 0
}

self_test() {
  set +e; export REDWORK_ESCALATE_DRYRUN=1; local T; T="$(mktemp -d)"; local rd="$T/run"; mkdir -p "$rd"; local fail=0
  ok(){ if [ "$1" -eq 0 ]; then :; else echo "  ✗ $2"; fail=1; fi; }
  # фикстура как реальный state.json (schema_version обязателен — state.sh _write требует валидный state-объект)
  jq -n '{schema_version:1,slug:"s",phase:"P5_deploy",blocked_on:null}' > "$rd/state.json"
  local out; out="$(escalate "$rd" DEPLOY_HIGH_RISK "approve_deploy,review_diff" "high_risk_migration" 2>/dev/null)"
  ok $? "escalate valid"
  printf '%s' "$out" | jq -e '.reason_code=="DEPLOY_HIGH_RISK"' >/dev/null; ok $? "reason_code в payload"
  printf '%s' "$out" | jq -e '.needs|length==2' >/dev/null; ok $? "needs structured (2)"
  printf '%s' "$out" | jq -e 'has("task")|not' >/dev/null; ok $? "НЕТ task/PII в payload"
  [ "$(jq -r '.blocked_on.reason_code' "$rd/state.json")" = "DEPLOY_HIGH_RISK" ]; ok $? "blocked_on выставлен в state"
  [ -f "$rd/escalations.log" ]; ok $? "durable локальный лог (пол доставки)"
  # WAIT_HUMAN (dev-чекпоинт режимов 1/2) ОБЯЗАН быть в enum (был critical-баг — SKILL зовёт его)
  escalate "$rd" WAIT_HUMAN "review_dev" >/dev/null 2>&1; ok $? "WAIT_HUMAN в enum (dev-чекпоинт)"
  # невалидный reason_code → reject
  if escalate "$rd" NOT_A_REASON "x" >/dev/null 2>&1; then ok 1 "невалидный reason_code reject"; else ok 0 ""; fi
  rm -rf "$T"
  if [ "$fail" -eq 0 ]; then echo "✓ escalate self-test passed"; return 0; else echo "✗ escalate self-test FAILED"; return 1; fi
}

case "${1:-}" in
  --self-test) self_test ;;
  "") echo "usage: escalate.sh <run_dir> <reason_code> <needs_csv> [detail_code] | --self-test" >&2; exit 1 ;;
  *) escalate "$@" ;;
esac

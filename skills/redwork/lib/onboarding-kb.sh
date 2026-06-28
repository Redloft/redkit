#!/usr/bin/env bash
# onboarding-kb.sh — САМООБУЧАЮЩАЯСЯ база архетипов проектов для redwork-онбординга.
# Каждый успешный /redwork-init дописывает САНИТИЗИРОВАННЫЙ архетип (абстрактный shape: stack-теги +
# классы механизмов), новый онбординг читает базу и предлагает дефолты от ПОХОЖИХ проектов → меньше
# вопросов со временем (push-петля, как plan-panel/ledger.sh).
#
# 🔒 АНТИ-УТЕЧКА: хранится ТОЛЬКО абстрактный shape — НИКАКИХ host/path/url/IP/имён/секретов.
#    record отвергает запись, если значение похоже на host/url/path/ip (fail-closed) + whitelist ключей + enum.
#    База ЛОКАЛЬНА (~/.claude/skills/redwork/knowledge/archetypes.jsonl) — НЕ синкается в публичный redkit.
#
# Usage:
#   onboarding-kb.sh record  <archetype_json>   # +1 архетип (санитизация); exit≠0 при подозрении на утечку
#   onboarding-kb.sh suggest <stack_csv>         # JSON: modal-дефолты от пересекающихся по стеку архетипов
#   onboarding-kb.sh stats
#   onboarding-kb.sh --self-test
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
STRIP="$HERE/strip-secrets.sh"
_kb(){ echo "${REDWORK_KB:-$HOME/.claude/skills/redwork/knowledge/archetypes.jsonl}"; }

ALLOWED_KEYS='^(stack|git_flow|deploy_class|cachebust_class|rollback_class|branch_convention|mode_default|autonomy|ts)$'
DEPLOY_ENUM='^(ssh-git-ff-only|ssh-rsync|ci-trigger|vercel|netlify|docker-compose|k8s-apply|manual|other)$'
CACHE_ENUM='^(php-opcache|cdn-purge|asset-hash|service-worker|none|other)$'
ROLLBACK_ENUM='^(git-reset-prev-sha|git-revert|ci-rollback|snapshot-restore|redeploy-prev|none|other)$'

record(){
  local j="${1:?archetype_json}"
  printf '%s' "$j" | jq -e 'type=="object"' >/dev/null 2>&1 || { echo "✗ не JSON-объект" >&2; return 1; }
  # whitelist ключей (никаких лишних полей, где могла бы осесть PII)
  local extra; extra="$(printf '%s' "$j" | jq -r 'keys[]' | grep -vE "$ALLOWED_KEYS" || true)"
  [ -z "$extra" ] || { echo "✗ запрещённые ключи: $extra (храним только абстрактный shape)" >&2; return 1; }
  # 🔒 анти-утечка: ни одно строковое значение не должно выглядеть как url/host/ip/path
  local blob; blob="$(printf '%s' "$j" | jq -r '[.. | strings] | join(" ")')"
  if printf '%s' "$blob" | grep -qiE '://|@|[0-9]{1,3}(\.[0-9]{1,3}){3}|~/|(^|[[:space:]])/[A-Za-z]'; then
    echo "✗ значение похоже на host/url/ip/path — отказ записи (анти-утечка)" >&2; return 1; fi
  # enum-валидация (пустое поле допустимо — пропускаем)
  local v
  v="$(printf '%s' "$j" | jq -r '.deploy_class // empty')";   [ -z "$v" ] || printf '%s' "$v" | grep -qE "$DEPLOY_ENUM"   || { echo "✗ deploy_class '$v' вне allowlist" >&2; return 1; }
  v="$(printf '%s' "$j" | jq -r '.cachebust_class // empty')";[ -z "$v" ] || printf '%s' "$v" | grep -qE "$CACHE_ENUM"    || { echo "✗ cachebust_class '$v' вне allowlist" >&2; return 1; }
  v="$(printf '%s' "$j" | jq -r '.rollback_class // empty')"; [ -z "$v" ] || printf '%s' "$v" | grep -qE "$ROLLBACK_ENUM" || { echo "✗ rollback_class '$v' вне allowlist" >&2; return 1; }
  # strip-secrets как defense-in-depth (на shape-данных не должно ничего срабатывать, но не доверяем)
  local clean; clean="$(printf '%s' "$j" | "$STRIP" 2>/dev/null || printf '%s' "$j")"
  [ -n "$clean" ] || { echo "✗ strip дал пусто" >&2; return 1; }
  local KB; KB="$(_kb)"; mkdir -p "$(dirname "$KB")"
  printf '%s\n' "$(printf '%s' "$clean" | jq -c .)" >> "$KB"
  echo "✓ архетип записан в KB"
}

suggest(){
  local stack_csv="${1:-}"; local KB; KB="$(_kb)"
  [ -f "$KB" ] || { echo '{"matches":0}'; return 0; }
  jq -s --arg s "$stack_csv" '
    ($s | split(",") | map(select(length>0))) as $q
    | map(. + {overlap: ([.stack[]? as $t | $q[] | select(.==$t)] | length)})
    | map(select(.overlap > 0)) as $m
    | if ($m|length)==0 then {matches:0}
      else {
        matches: ($m|length),
        deploy_class:      ($m|map(.deploy_class // empty)|group_by(.)|max_by(length)|.[0] // null),
        cachebust_class:   ($m|map(.cachebust_class // empty)|group_by(.)|max_by(length)|.[0] // null),
        rollback_class:    ($m|map(.rollback_class // empty)|group_by(.)|max_by(length)|.[0] // null),
        branch_convention: ($m|map(.branch_convention // empty)|group_by(.)|max_by(length)|.[0] // null),
        mode_default:      ($m|map(.mode_default // empty)|group_by(.)|max_by(length)|.[0] // null)
      } end' "$KB"
}

stats(){ local KB; KB="$(_kb)"; [ -f "$KB" ] && echo "архетипов: $(wc -l < "$KB" | tr -d ' ')" || echo "архетипов: 0 (база пуста)"; }

self_test(){
  set +e; local T; T="$(mktemp -d)"; export REDWORK_KB="$T/kb.jsonl"; local fail=0
  ok(){ if [ "$1" -eq 0 ]; then :; else echo "  ✗ $2"; fail=1; fi; }
  record '{"stack":["node","vite","typescript","scss"],"deploy_class":"ssh-git-ff-only","cachebust_class":"php-opcache","rollback_class":"git-reset-prev-sha","branch_convention":"ai/<slug>-prod","mode_default":2,"autonomy":false}' >/dev/null; ok $? "record валидного архетипа"
  record '{"stack":["python","fastapi"],"deploy_class":"ci-trigger","rollback_class":"ci-rollback","mode_default":2}' >/dev/null; ok $? "record второго"
  # suggest по пересекающемуся стеку → modal deploy_class
  local s; s="$(suggest "node,vite,scss")"
  [ "$(printf '%s' "$s" | jq -r '.matches')" -ge 1 ]; ok $? "suggest нашёл похожий"
  [ "$(printf '%s' "$s" | jq -r '.deploy_class')" = "ssh-git-ff-only" ]; ok $? "suggest вернул modal deploy_class"
  # 🔒 анти-утечка: URL в значении → reject
  if record '{"stack":["node"],"branch_convention":"https://evil.host/x"}' >/dev/null 2>&1; then ok 1 "URL должен reject"; else ok 0 ""; fi
  # 🔒 path в значении → reject
  if record '{"stack":["node"],"git_flow":"/Users/me/secret"}' >/dev/null 2>&1; then ok 1 "path должен reject"; else ok 0 ""; fi
  # лишний ключ (потенц. PII) → reject
  if record '{"stack":["node"],"host":"prod.example"}' >/dev/null 2>&1; then ok 1 "лишний ключ должен reject"; else ok 0 ""; fi
  # enum вне allowlist → reject
  if record '{"stack":["node"],"deploy_class":"rm-rf-prod"}' >/dev/null 2>&1; then ok 1 "deploy_class вне enum должен reject"; else ok 0 ""; fi
  # база не пуста, нет утечек
  [ "$(grep -c . "$REDWORK_KB")" = "2" ]; ok $? "записаны ровно 2 валидных (мусор отклонён)"
  rm -rf "$T"; unset REDWORK_KB
  if [ "$fail" -eq 0 ]; then echo "✓ onboarding-kb self-test passed"; return 0; else echo "✗ onboarding-kb self-test FAILED"; return 1; fi
}

case "${1:-}" in
  record)  record "${2:-}" ;;
  suggest) suggest "${2:-}" ;;
  stats)   stats ;;
  --self-test) self_test ;;
  *) echo "usage: onboarding-kb.sh record <json> | suggest <stack_csv> | stats | --self-test" >&2; exit 1 ;;
esac

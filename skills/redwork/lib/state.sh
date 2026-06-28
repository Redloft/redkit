#!/usr/bin/env bash
# state.sh — single source of truth для redwork-прогона (spec v3 §State.json).
# Инварианты (заложены панелью): schema_version + read-policy; ВСЕ записи через jq --arg/--argjson
# (никакого shell-heredoc — защита task с кавычками/newlines; iterations строго int); project-lock
# (mkdir-страж + pid/at/ttl + stale-reclaim); validate_no_secrets перед каждой записью.
#
# Usage:
#   state.sh slug <text>
#   state.sh init <slug> <task> <repo> <mode> <branch>     → печатает RUN_DIR
#   state.sh get  <run_dir> <jq_filter>
#   state.sh set_str  <run_dir> <jq_path_expr> <value>     # jq --arg  (string, безопасно)
#   state.sh set_json <run_dir> <jq_path_expr> <json>      # jq --argjson (number/obj/bool)
#   state.sh lock <run_dir> | unlock <run_dir>
#   state.sh validate-no-secrets <string>                  # exit 1 если есть секрет
#   state.sh --self-test
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/secret-guard.sh"

SCHEMA_VERSION=1
KNOWN_MAX=1
# DATA_ROOT и LOCK_TTL читаются ЛЕНИВО (в момент вызова), иначе env-override после load игнорируется.
_data_root() { echo "${REDWORK_DATA_DIR:-$HOME/Library/Application Support/redwork/runs}"; }
_lock_ttl()  { echo "${REDWORK_LOCK_TTL_SEC:-3600}"; }

_slug() { printf '%s' "$1" | { shasum 2>/dev/null || sha1sum; } | cut -c1-12; }   # shasum=macOS, sha1sum=Linux/TOM1

# validate_no_secrets: keyword-детектор (не энтропия — иначе ложно бьёт по путям/SHA в task). См. secret-guard.sh.
validate_no_secrets() {
  if kw_secret_found "${1:-}"; then echo "✗ secret-like (known token) detected — отказ записи" >&2; return 1; fi
  return 0
}

_state_path() { echo "$1/state.json"; }

# Атомарная jq-запись с проверкой схемы и секретов значения.
_write() {  # _write <run_dir> <jq_flag> <argname> <value> <jq_path_expr>
  local rd="$1" flag="$2" name="$3" val="$4" expr="$5"
  local S; S="$(_state_path "$rd")"
  [ -f "$S" ] || { echo "✗ нет state.json: $S" >&2; return 1; }
  validate_no_secrets "$val" || return 1   # гейт и для --argjson (JSON-значение может нести секрет-строку)
  # tmp РЯДОМ со state.json (та же ФС) → mv атомарен; mktemp в TMPDIR + cross-fs mv не атомарен (Yandex.Disk)
  local tmp; tmp="$(mktemp "${S}.XXXXXX")"
  jq "$flag" "$name" "$val" "$expr" "$S" > "$tmp" || { rm -f "$tmp"; echo "✗ jq write failed" >&2; return 1; }
  # СТРУКТУРНЫЙ пост-чек: результат обязан остаться объектом со schema_version+slug (catch-all против
  # любого выражения, давшего не-state JSON). Без него повреждённый jq-expr тихо рушил state.json.
  jq -e 'type=="object" and has("schema_version") and has("slug")' "$tmp" >/dev/null 2>&1 \
    || { rm -f "$tmp"; echo "✗ jq-результат — не валидный state-объект (schema_version+slug) → откат, state.json не тронут" >&2; return 1; }
  mv -f "$tmp" "$S"
}

cmd_init() {
  local slug="${1:?slug}" task="${2:?task}" repo="${3:?repo}" mode="${4:-2}" branch="${5:-}"
  case "$mode" in 1|2|3) ;; *) echo "✗ mode должен быть 1|2|3 (получено: '$mode')" >&2; return 1 ;; esac
  validate_no_secrets "$task" || { echo "  (task содержит секрет-подобное — очисти описание)" >&2; return 1; }
  local DATA_ROOT; DATA_ROOT="$(_data_root)"
  local rd="$DATA_ROOT/$slug"; mkdir -p "$rd"
  local S; S="$(_state_path "$rd")"
  if [ -f "$S" ]; then echo "$rd"; return 0; fi   # уже есть → resume, не перетираем
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -n --argjson sv "$SCHEMA_VERSION" --arg slug "$slug" --arg task "$task" --arg repo "$repo" \
        --argjson mode "$mode" --arg branch "$branch" --arg ts "$ts" '{
    schema_version:$sv, slug:$slug, task:$task, repo:$repo, mode:$mode, branch:$branch,
    phase:"P2_implement", phase_status:"pending", risk_class:null,
    lock:null,
    verdicts:{plan:null, finalize_pre:null, finalize_post:null},
    deploy_intent:null, live_verify_dod:[], blocked_on:null,
    iterations:0, budget:{llm_calls:0}, created_at:$ts
  }' > "$S"
  echo "$rd"
}

cmd_get() {
  local rd="${1:?run_dir}" filter="${2:-.}"; local S; S="$(_state_path "$rd")"
  [ -f "$S" ] || { echo "✗ нет state.json" >&2; return 1; }
  local v; v="$(jq -r '.schema_version // 0' "$S")"
  [ "$v" -le "$KNOWN_MAX" ] || { echo "✗ schema_version $v > KNOWN_MAX $KNOWN_MAX → abort (нужна новая версия redwork)" >&2; return 3; }
  jq -r "$filter" "$S"
}

# project-lock: один активный run на repo. mkdir-страж + pid/at/ttl + stale-reclaim.
cmd_lock() {
  local rd="${1:?run_dir}"; local LK="$rd/.lock"
  if mkdir "$LK" 2>/dev/null; then :; else
    # есть лок — проверим stale
    local lpid lat
    lpid="$(cat "$LK/pid" 2>/dev/null || echo 0)"; lat="$(cat "$LK/at" 2>/dev/null || echo 0)"
    local now; now="$(date +%s)"
    if { [ "$lpid" -gt 0 ] && kill -0 "$lpid" 2>/dev/null; } && [ $(( now - lat )) -lt "$(_lock_ttl)" ]; then
      echo "✗ run уже активен (pid $lpid, $(( now - lat ))s назад) — один redwork на repo. exit." >&2; return 1
    fi
    echo "⚠ stale lock (pid $lpid) — reclaim" >&2; rm -rf "$LK"; mkdir "$LK"
  fi
  echo "$$" > "$LK/pid"; date +%s > "$LK/at"; echo "$(_lock_ttl)" > "$LK/ttl"
  echo "✓ locked ($rd, pid $$)"
}
cmd_unlock() { rm -rf "${1:?run_dir}/.lock" 2>/dev/null || true; echo "✓ unlocked"; }

self_test() {
  set +e; local T; T="$(mktemp -d)"; export REDWORK_DATA_DIR="$T"; local fail=0
  ok(){ if [ "$1" -eq 0 ]; then :; else echo "  ✗ $2"; fail=1; fi; }
  local rd; rd="$(cmd_init "$(_slug 'task: "fix" promo\nbug')" 'fix promo bug' '/tmp/repo' 2 'redwork/x')"
  ok $? "init"
  [ -f "$rd/state.json" ]; ok $? "state.json создан"
  [ "$(cmd_get "$rd" '.schema_version')" = "1" ]; ok $? "schema_version=1"
  [ "$(cmd_get "$rd" '.iterations')" = "0" ]; ok $? "iterations=0 (int)"
  # jq-safe: task с кавычками/newlines прочитался валидным JSON
  cmd_get "$rd" '.task' >/dev/null; ok $? "task с кавычками — валидный JSON"
  # set_json iterations += 1
  _write "$rd" --argjson n 1 '.iterations = $n'; ok $? "set_json iterations"
  [ "$(cmd_get "$rd" '.iterations')" = "1" ]; ok $? "iterations=1"
  # set_str phase (через публичный диспетчер: argname=val)
  _write "$rd" --arg val "P5_deploy" '.phase = $val'; ok $? "set_str phase"
  [ "$(cmd_get "$rd" '.phase')" = "P5_deploy" ]; ok $? "phase=P5_deploy"
  # РЕГРЕССИЯ (баг битого state): читающий фильтр без $val → reject, state.json НЕ перетёрт
  if _write "$rd" --arg val "P6_postverify" '.phase' 2>/dev/null; then ok 1 "читающий фильтр (.phase) должен reject'иться"; else ok 0 ""; fi
  [ "$(cmd_get "$rd" '.schema_version')" = "1" ]; ok $? "state.json остался объектом после отказа (не голая строка)"
  [ "$(cmd_get "$rd" '.phase')" = "P5_deploy" ]; ok $? "phase не изменился после отказа"
  # validate_no_secrets: чистая строка ok, секрет — reject
  validate_no_secrets "just a normal task description"; ok $? "чистая строка проходит"
  # секрет split-литералом чтобы не триггерить хук/push-protection
  if validate_no_secrets "key sk-""ABCDEFGHIJ1234567890abcd" 2>/dev/null; then ok 1 "секрет должен reject'иться"; else ok 0 ""; fi
  # lock/stale
  cmd_lock "$rd" >/dev/null; ok $? "lock"
  if cmd_lock "$rd" >/dev/null 2>&1; then ok 1 "второй lock должен отказать (pid жив)"; else ok 0 ""; fi
  cmd_unlock "$rd" >/dev/null; ok $? "unlock"
  rm -rf "$T"
  if [ "$fail" -eq 0 ]; then echo "✓ state self-test passed"; return 0; else echo "✗ state self-test FAILED"; return 1; fi
}

case "${1:-}" in
  slug) _slug "${2:?text}" ;;
  init) shift; cmd_init "$@" ;;
  get) cmd_get "${2:-}" "${3:-.}" ;;
  set_str|set_json)
    # usage: <run_dir=$2> <jq_path_expr=$3> <value=$4>. Публичный контракт: expr ОБЯЗАН присваивать через $val.
    # Читающий фильтр (напр. '.phase') заставил бы jq напечатать текущее значение поля и перетереть им
    # state.json (баг битого state: state.json=="P2_implement").
    case "${3:?jq_path_expr использует \$val}" in *'$val'*) ;; *) echo "✗ jq-expr не присваивающий (нет \$val): '$3' — отказ" >&2; exit 1 ;; esac
    if [ "$1" = "set_str" ]; then _write "${2:?}" --arg val "${4:?}" "$3"; else _write "${2:?}" --argjson val "${4:?}" "$3"; fi
    ;;
  lock) cmd_lock "${2:?}" ;;
  unlock) cmd_unlock "${2:?}" ;;
  validate-no-secrets) validate_no_secrets "${2:-}" ;;
  --self-test) self_test ;;
  *) echo "usage: state.sh slug|init|get|set_str|set_json|lock|unlock|validate-no-secrets|--self-test" >&2; exit 1 ;;
esac

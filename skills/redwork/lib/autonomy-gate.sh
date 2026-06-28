#!/usr/bin/env bash
# autonomy-gate.sh — детерминированный гейт автономного прод-деплоя (spec v2, Phase A gate-only).
# Чистая функция: читает state.json + <repo>/.redwork-autonomy.json + <repo>/.redwork.json + changed-files
# + events.jsonl. НЕ ходит в сеть, НЕ деплоит. Перечисляет ВСЕ провалы (не short-circuit). FAIL-CLOSED везде:
# отсутствие/ошибка/неизвестность любого критерия → human. decision:auto ⟺ failed пуст И нет floor.
# exit: 0 = решение принято (читай .decision), 1 = infra_error (→human), 2 = floor-нарушение (→human, отд. класс P5).
#
# Usage:
#   autonomy-gate.sh decide <run_dir> <repo> <changed_files_file>   → JSON {decision,failed[],passed[]}
#   autonomy-gate.sh --self-test
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/defaults.sh"

# floor-паттерны (идентичны risk-classify.sh — независимый классификатор, spec E1)
FLOOR_RE='(^|/)migrations?/|(^|/)auth/|payment|\.pem$|\.key$|(^|/)\.env'

FAILED='[]'; FLOOR_HIT=0; INFRA=0
add_fail(){ FAILED="$(printf '%s' "$FAILED" | jq -c --arg c "$1" --arg d "$2" '. + [{criterion:$c,detail:$d}]')"; }
_jq(){ printf '%s' "$1" | jq -r "$2" 2>/dev/null; }   # _jq <json> <filter>

# rate-limit: считаем ТОЛЬКО фактически-deployed события (exit_code==0). FAIL-CLOSED: любая ошибка чтения → =M-эквивалент.
_deploy_count_window(){
  local L="$1/events.jsonl"
  [ -f "$L" ] || { echo 0; return; }   # нет событий → 0 деплоев
  local n; n="$(jq -rs '[.[] | select(.event_type=="deploy" and (.payload_summary.exit_code==0))] | length' "$L" 2>/dev/null)" \
    || { echo 999999; return; }        # read/parse-fail → fail-closed
  case "$n" in ''|*[!0-9]*) echo 999999;; *) echo "$n";; esac
}

decide(){
  local rd="${1:?run_dir}" repo="${2:?repo}" cf="${3:?changed_files_file}"
  local S="$rd/state.json"
  [ -f "$S" ] || { echo '{"decision":"human","failed":[{"criterion":"infra","detail":"no state.json"}],"passed":[]}'; return 1; }
  [ -f "$cf" ] || { INFRA=1; add_fail infra "no changed_files file"; }

  # ── E1 floor — НЕЗАВИСИМО от контракта (defense in depth) ──
  if [ -f "$cf" ] && grep -qiE "$FLOOR_RE" "$cf"; then
    FLOOR_HIT=1; add_fail E1_floor "changed-files задевают floor-glob (migrations/auth/payment/.pem/.key/.env) — всегда человек"
  fi

  # ── Резолв authorization-слоя (in-tree | out-of-tree) через verified-resolver config.sh ──
  # Autonomy-контракт живёт РЯДОМ с резолвнутым .redwork.json; его git = cfg_top (§Out-of-tree authorization).
  local RES cfgpath cfgtop AF AGIT AF_REL
  RES="$(bash "$HERE/config.sh" resolve "$repo" 2>/dev/null || true)"
  cfgpath="$(printf '%s' "$RES" | grep -oE 'path=[^ ]+' | head -1 | cut -d= -f2-)"
  cfgtop="$(printf '%s' "$RES" | grep -oE 'cfg_top=[^ ]+' | head -1 | cut -d= -f2-)"
  if [ -n "$cfgpath" ] && [ -n "$cfgtop" ] && [ "$cfgtop" != "(non-git)" ]; then
    AF="$(dirname "$cfgpath")/.redwork-autonomy.json"; AGIT="$cfgtop"     # контракт рядом с конфигом, в его git
  else
    AF="$repo/.redwork-autonomy.json"; AGIT="$repo"                       # in-tree default (нет out-of-tree config-слоя)
  fi
  AF_REL="${AF#"$AGIT"/}"

  # ── A0 integrity (в git'е, который РЕАЛЬНО трекает контракт; single committed-blob read = TOCTOU) ──
  local IS_GIT=0
  if git -C "$AGIT" rev-parse --git-dir >/dev/null 2>&1; then IS_GIT=1; else add_fail A0_integrity "config-слой не git ($AGIT) → autonomy запрещена"; fi
  if [ ! -f "$AF" ]; then add_fail A0_integrity "нет .redwork-autonomy.json (config-слой: $AF)"; fi
  local A='{}'
  if [ -f "$AF" ] && [ "$IS_GIT" = 1 ]; then
    git -C "$AGIT" ls-files --error-unmatch "$AF_REL" >/dev/null 2>&1 || add_fail A0_integrity "autonomy-файл не git-tracked в $AGIT"
    git -C "$AGIT" diff HEAD --quiet -- "$AF_REL" 2>/dev/null || add_fail A0_integrity "autonomy-файл modified/staged в $AGIT"
    local blob; blob="$(git -C "$AGIT" show "HEAD:$AF_REL" 2>/dev/null)"
    if printf '%s' "$blob" | jq -e . >/dev/null 2>&1; then A="$blob"; else add_fail A0_integrity ".redwork-autonomy.json (committed) не валидный JSON"; fi
  elif [ -f "$AF" ]; then
    jq -e . "$AF" >/dev/null 2>&1 && A="$(cat "$AF")"   # слой не git → A0 уже зафейлен; читаем worktree для прочих критериев
  fi

  # ── A0′ authorization-root: коммит autonomy-файла verified-signed И автор ∈ owners (в AGIT) ──
  if [ -f "$AF" ] && [ "$IS_GIT" = 1 ]; then
    local last; last="$(git -C "$AGIT" log -n1 --format=%H -- "$AF_REL" 2>/dev/null)"
    if [ -z "$last" ]; then add_fail A0prime_auth "нет коммита, тронувшего autonomy-файл"
    else
      git -C "$AGIT" verify-commit "$last" >/dev/null 2>&1 || add_fail A0prime_auth "коммит autonomy-файла НЕ verified-signed (fail-closed)"
      local author; author="$(git -C "$AGIT" log -n1 --format=%ae "$last" 2>/dev/null)"
      [ "$(_jq "$A" "((.owners // []) | index(\"$author\")) != null")" = "true" ] || add_fail A0prime_auth "автор коммита ($author) ∉ owners[]"
    fi
  fi

  # ── A1 enabled + owners ──
  [ "$(_jq "$A" '.autonomy // "absent"')" = "enabled" ] || add_fail A1_enabled "autonomy != enabled"
  [ "$(_jq "$A" '(.owners // []) | length > 0')" = "true" ] || add_fail A1_enabled "owners[] пуст"

  # ── A2 scope well-formed ──
  [ "$(_jq "$A" '(.scope.globs // []) | length > 0')" = "true" ] || add_fail A2_scope "scope.globs пуст (нет неявного «всё»)"
  [ "$(_jq "$A" '(.scope.max_files // 0) > 0')" = "true" ] || add_fail A2_scope "max_files ≤ 0"
  [ "$(_jq "$A" '(.scope.branches // []) | length > 0')" = "true" ] || add_fail A2_scope "branches[] пуст"
  [ "$(_jq "$A" '(.scope.max_deploys_per_window // 0) > 0')" = "true" ] || add_fail A2_scope "max_deploys_per_window ≤ 0"

  # ── A3 in-scope ──
  if [ -f "$cf" ]; then
    local globs; globs="$(_jq "$A" '(.scope.globs // [])[]')"
    local f g m
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      m=0
      while IFS= read -r g; do [ -z "$g" ] && continue; case "$f" in $g) m=1; break;; esac; done <<< "$globs"
      [ "$m" = 1 ] || add_fail A3_inscope "файл вне scope-globs: $f"
    done < "$cf"
    local cnt maxf; cnt="$(grep -cve '^$' "$cf" 2>/dev/null || echo 0)"; maxf="$(_jq "$A" '.scope.max_files // 0')"
    [ "${cnt:-0}" -le "${maxf:-0}" ] 2>/dev/null || add_fail A3_inscope "changed count $cnt > max_files $maxf"
  fi
  local cur_branch; cur_branch="$(git -C "$repo" branch --show-current 2>/dev/null || echo '')"
  # branches[] — glob-паттерны (конвенция ai/<slug>-prod динамическая → не exact-match)
  local bmatch=0 b branches; branches="$(_jq "$A" '(.scope.branches // [])[]')"
  while IFS= read -r b; do [ -z "$b" ] && continue; case "$cur_branch" in $b) bmatch=1; break;; esac; done <<< "$branches"
  [ "$bmatch" = 1 ] || add_fail A3_inscope "ветка '$cur_branch' ∉ branches[] (glob)"
  [ "$(_jq "$A" '.scope.kill_switch // false')" = "false" ] || add_fail A3_inscope "kill_switch (git-флаг) ON"
  [ -f "$repo/.redwork-killswitch" ] && add_fail A3_inscope "runtime kill-switch (.redwork-killswitch) присутствует"
  local M dcount; M="$(_jq "$A" '.scope.max_deploys_per_window // 0')"; dcount="$(_deploy_count_window "$rd")"
  [ "${dcount:-999999}" -lt "${M:-0}" ] 2>/dev/null || add_fail A3_inscope "rate-limit: deploys-in-window $dcount ≥ max $M (или read-error → fail-closed)"
  # NB: точная TZ-window-логика (scope.windows[]) — [IMPL-DEFAULT], Phase B/C DoD.

  # ── A4 meta-rule: нельзя автокатить изменение собственной авторизации/конфига/floor ──
  if [ -f "$cf" ] && { grep -qE '(^|/)\.redwork-autonomy\.json$|(^|/)\.redwork\.json$' "$cf" || grep -qiE "$FLOOR_RE" "$cf"; }; then
    add_fail A4_meta "diff трогает autonomy-файл / .redwork.json / floor → autonomy VOID"
  fi
  # A4 (out-of-tree): контракт в ДРУГОМ git'е (cfg_top), его нет в deploy-диффе code-repo → автокатить его
  # изменение структурно нельзя (безопаснее in-tree). Floor-проба выше остаётся на code-repo diff.
  # Прежний blanket fail-closed (REDWORK_CONFIG_FILE→human) СНЯТ — §Out-of-tree authorization.

  # ── A5 require-блок ──
  [ "$(_jq "$A" '.require.rollback_validated // false')" = "true" ] || add_fail A5_require "require.rollback_validated != true"
  case "$(_jq "$A" '.require.prebackup // "absent"')" in true|"n/a") ;; *) add_fail A5_require "require.prebackup не true|n/a";; esac
  [ "$(_jq "$A" '.require.prod_health_green // false')" = "true" ] || add_fail A5_require "require.prod_health_green != true"
  [ "$(_jq "$A" "(.require.watch_minutes // 0) >= $REDWORK_WATCH_MINUTES_MIN")" = "true" ] || add_fail A5_require "watch_minutes < $REDWORK_WATCH_MINUTES_MIN"
  [ "$(_jq "$A" '(.require.signals // []) | length > 0')" = "true" ] || add_fail A5_require "signals[] пуст"
  [ "$(_jq "$A" '((.require.target // "") | length) > 0')" = "true" ] || add_fail A5_require "require.target не задан"
  local sup; sup="$(_jq "$A" '.require.supervisor // "absent"')"
  echo "$REDWORK_AUTONOMY_SUPERVISORS" | grep -qw "$sup" || add_fail A5_require "supervisor '$sup' ∉ {systemd,launchd,cron} (degraded → fail-closed)"

  # ── B готовность (из state.json; отсутствие флага = fail-closed) ──
  [ "$(jq -r '.verdicts.finalize_pre.verdict // "absent"' "$S" 2>/dev/null)" = "SHIP" ] || add_fail B1_ready "finalize_pre.verdict != SHIP"
  local head bsha; head="$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo HEAD_ERR)"; bsha="$(jq -r '.verdicts.finalize_pre.build_sha // "none"' "$S" 2>/dev/null)"
  [ "$head" = "$bsha" ] || add_fail B1_ready "HEAD != finalize_pre.build_sha (дрейф)"
  # NB: читаем raw (НЕ `// true`) — jq `//` считает false «пустым», `false // true`→true дало бы ложный провал хорошего случая.
  [ "$(jq -r '.verdicts.finalize_pre.high_severity' "$S" 2>/dev/null)" = "false" ] || add_fail B1_ready "finalize_pre high-severity findings (или флаг != false → fail-closed)"
  [ "$(jq -r '.risk_class // "unknown"' "$S" 2>/dev/null)" = "low" ] || add_fail B2_ready "risk_class != low"
  [ "$(jq -r '.gates_green // false' "$S" 2>/dev/null)" = "true" ] || add_fail B3_ready "P3 test-gate не зелёный (gates_green != true → fail-closed)"

  # ── вердикт ──
  local nfail; nfail="$(printf '%s' "$FAILED" | jq 'length')"
  local decision; [ "$nfail" -eq 0 ] && decision=auto || decision=human
  jq -nc --arg d "$decision" --argjson f "$FAILED" '{decision:$d, failed:$f, passed:[]}'
  if [ "$INFRA" = 1 ]; then return 1; fi
  if [ "$FLOOR_HIT" = 1 ]; then return 2; fi
  return 0
}

self_test(){
  set +e; local T; T="$(mktemp -d)"; local rd="$T/run"; mkdir -p "$rd"; local repo="$T/repo"; mkdir -p "$repo"; local fail=0
  ok(){ if [ "$1" -eq 0 ]; then :; else echo "  ✗ $2"; fail=1; fi; }
  jq -n '{schema_version:1,slug:"s",risk_class:"low"}' > "$rd/state.json"
  printf 'src/a.ts\n' > "$rd/cf"
  # 1) пустой/невалидный контекст (не-git, нет autonomy) → human, НИКОГДА не auto (fail-closed)
  local out rc; out="$(decide "$rd" "$repo" "$rd/cf")"; rc=$?
  [ "$(printf '%s' "$out" | jq -r .decision)" = "human" ]; ok $? "пустой контекст → human (fail-closed)"
  # 2) floor-файл → exit 2 + E1 в failed
  printf 'db/migrations/001.sql\n' > "$rd/cf2"; out="$(decide "$rd" "$repo" "$rd/cf2")"; rc=$?
  [ "$rc" -eq 2 ]; ok $? "floor → exit 2"
  printf '%s' "$out" | jq -e '.failed[]|select(.criterion=="E1_floor")' >/dev/null; ok $? "floor → E1 в failed"
  # 3) нет state.json → exit 1 (infra)
  out="$(decide "$T/nope" "$repo" "$rd/cf")"; rc=$?; [ "$rc" -eq 1 ]; ok $? "нет state.json → exit 1"
  # 4) decision НИКОГДА не auto без полного валидного контракта (здесь его нет)
  [ "$(printf '%s' "$out" | jq -r '.decision')" = "human" ]; ok $? "без контракта decision=human"
  # 5) out-of-tree config задан, но недоступен/нет контракта → human (fail-closed, НЕ auto)
  out="$( export REDWORK_CONFIG_FILE=/tmp/nonexistent-redwork-$$.json; decide "$rd" "$repo" "$rd/cf" )"
  [ "$(printf '%s' "$out" | jq -r .decision)" = "human" ]; ok $? "out-of-tree без валидного контракта → human (fail-closed)"
  rm -rf "$T"
  if [ "$fail" -eq 0 ]; then echo "✓ autonomy-gate self-test passed"; return 0; else echo "✗ autonomy-gate self-test FAILED"; return 1; fi
}

case "${1:-}" in
  decide) decide "${2:-}" "${3:-}" "${4:-}" ;;
  --self-test) self_test ;;
  *) echo "usage: autonomy-gate.sh decide <run_dir> <repo> <changed_files_file> | --self-test" >&2; exit 1 ;;
esac

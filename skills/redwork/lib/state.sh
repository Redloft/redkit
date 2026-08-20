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

SCHEMA_VERSION=2
KNOWN_MAX=2
# DATA_ROOT и LOCK_TTL читаются ЛЕНИВО (в момент вызова), иначе env-override после load игнорируется.
_data_root() { echo "${REDWORK_DATA_DIR:-$HOME/Library/Application Support/redwork/runs}"; }
# TTL лока согласован с порогом sweep (REDWORK_STALE_SEC=43200): раньше 3600 против эмпирических 6.9 ч
# легитимной тишины → лок ЖИВОГО прогона отбирался через час, и «один run/repo» снова не работал.
_lock_ttl()  { echo "${REDWORK_LOCK_TTL_SEC:-43200}"; }

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
  # ЦЕЛЕВОЙ whitelist: phase_status — конечный enum. Неизвестное значение = баг оркестратора, не данные.
  case "$expr" in *phase_status*)
    case "$val" in pending|done|blocked|abandoned) ;;
      *) case "$val" in *'"phase_status"'*)
           local _ps; _ps="$(printf '%s' "$val" | jq -r '.phase_status // empty' 2>/dev/null || true)"
           case "${_ps:-pending}" in pending|done|blocked|abandoned) ;;
             *) echo "✗ phase_status вне enum (pending|done|blocked|abandoned): '$_ps'" >&2; return 1 ;; esac ;;
         *) echo "✗ phase_status вне enum (pending|done|blocked|abandoned): '$val'" >&2; return 1 ;;
      esac ;;
    esac ;;
  esac
  local tmp; tmp="$(mktemp "${S}.XXXXXX")"
  # heartbeat: КАЖДАЯ запись обновляет updated_at (сессия не может «забыть» — это не отдельный шаг).
  local _now; _now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq "$flag" "$name" "$val" --arg _hb "$_now" "($expr) | .updated_at = \$_hb" "$S" > "$tmp" \
    || { rm -f "$tmp"; echo "✗ jq write failed" >&2; return 1; }
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
    iterations:0, budget:{llm_calls:0}, created_at:$ts, updated_at:$ts
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
    # ⚠ pid НЕ является признаком жизни: cmd_lock пишет $$ процесса state.sh, который умирает сразу после.
    # Признак жизни = СВЕЖЕСТЬ .lock/at (её обновляет step.sh на каждом тике). Раньше проверка pid-а
    # делала любой лок мгновенно stale → инвариант «один run/repo» фактически не работал.
    if [ $(( now - lat )) -lt "$(_lock_ttl)" ]; then
      local age=$(( now - lat ))
      echo "✗ run уже активен (heartbeat ${age}s назад) — один redwork на repo. exit." >&2
      # heartbeat обновляет step.sh на каждом тике; тишина в часы означает либо длинную
      # легитимную паузу, либо краш. Отличить снаружи нельзя — поэтому подсказываем путь.
      if [ "$age" -gt 3600 ]; then
        echo "  ⚠ тишина ${age}s (> 1ч). Если ран упал — санкционированный путь: bash lib/state.sh unlock <run_dir>." >&2
        echo "    Ручное удаление .lock обходит защиту инварианта «один run на repo» — не делать." >&2
        echo "    Брошенные раны штатно подбирает step.sh sweep + Stop-хук ~/.claude/hooks/redwork-sweep.sh." >&2
      fi
      return 1
    fi
    # ── ПЕРЕХВАТ ПРОТУХШЕГО ЛОКА (атомарный, 2026-08-20) ──────────────────────
    # Было `rm -rf "$LK"; mkdir "$LK"` — НЕ атомарно: два процесса могли одновременно
    # пройти проверку staleness, после чего rm второго сносил свежий лок первого, и оба
    # считали себя единственными держателями. Это ровно тот инвариант («один run на repo»),
    # на котором стоит вся стейт-машина. Найдено панелью 2026-08-20.
    # Примитив: rename(2) директории атомарен — сдвинуть протухший лок в сторону может
    # РОВНО ОДИН процесс, остальные получат ENOENT и честно проигрывают гонку.
    local stale="$LK.stale.$$"
    if mv "$LK" "$stale" 2>/dev/null; then
      rm -rf "$stale" 2>/dev/null || true
      if mkdir "$LK" 2>/dev/null; then
        echo "⚠ stale lock (pid $lpid, heartbeat $(( now - lat ))s назад) — перехвачен" >&2
      else
        echo "✗ перехват не удался: лок занят другим процессом сразу после сдвига. exit." >&2; return 1
      fi
    else
      echo "✗ проиграли гонку за перехват протухшего лока (перехватил другой процесс). exit." >&2; return 1
    fi
  fi
  echo "$$" > "$LK/pid"; date +%s > "$LK/at"; echo "$(_lock_ttl)" > "$LK/ttl"
  echo "✓ locked ($rd, pid $$)"
}
# touch: обновить heartbeat лока (зовёт step.sh на каждом тике; без него живой run выглядит протухшим)
cmd_touch() { local LK="${1:?run_dir}/.lock"; [ -d "$LK" ] || return 0; date +%s > "$LK/at"; }
# health: внешние зависимости, о которых SKILL.md говорит как о штатных, но которые лежат
# ВНЕ дерева скилла (значит не едут в репо и ничем не проверяются). Молчит, когда всё на месте.
cmd_health() {
  local hook="$HOME/.claude/hooks/redwork-sweep.sh" st="$HOME/.claude/settings.json" warn=""
  [ -f "$hook" ] || warn="${warn}\n  ⚑ нет Stop-хука $hook — брошенные раны держат repo-lock до $(_lock_ttl)с"
  if [ -f "$st" ] && ! grep -q 'redwork-sweep' "$st" 2>/dev/null; then
    warn="${warn}\n  ⚑ redwork-sweep.sh не зарегистрирован в settings.json (hooks.Stop) — автоподбор брошенных ранов не сработает"
  fi
  if [ -n "$warn" ]; then printf '%b\n' "$warn"; return 1; fi
  echo "✓ redwork health: sweep-хук на месте и зарегистрирован"
}
cmd_unlock() { rm -rf "${1:?run_dir}/.lock" 2>/dev/null || true; echo "✓ unlocked"; }

self_test() {
  set +e; local T; T="$(mktemp -d)"; export REDWORK_DATA_DIR="$T"; local fail=0
  # ── ГОНКА ЗА ПЕРЕХВАТ ПРОТУХШЕГО ЛОКА (2026-08-20) ──────────────────────────
  # Инвариант «один run на repo» держится только если перехват атомарен. Прежний
  # `rm -rf; mkdir` пропускал двух держателей одновременно. Гоним 8 параллельных.
  _race_test() {
    local T; T="$(mktemp -d)"; mkdir -p "$T/run/.lock"
    echo 1 > "$T/run/.lock/pid"; echo 0 > "$T/run/.lock/at"   # заведомо протухший
    local i
    for i in 1 2 3 4 5 6 7 8; do
      ( cmd_lock "$T/run" >/dev/null 2>&1 && echo W >> "$T/won" ) &
    done
    wait
    local won; won="$(wc -l < "$T/won" 2>/dev/null | tr -d ' ')"; won="${won:-0}"
    local stale; stale="$(find "$T/run" -maxdepth 1 -name '.lock.stale.*' 2>/dev/null | wc -l | tr -d ' ')"
    rm -rf "$T"
    [ "$won" = "1" ] || { echo "  ✗ гонка за лок: держателей $won, ожидался ровно 1"; return 1; }
    [ "$stale" = "0" ] || { echo "  ✗ гонка за лок: остались .stale-хвосты ($stale)"; return 1; }
    return 0
  }
  _race_test || fail=1

  ok(){ if [ "$1" -eq 0 ]; then :; else echo "  ✗ $2"; fail=1; fi; }
  local rd; rd="$(cmd_init "$(_slug 'task: "fix" promo\nbug')" 'fix promo bug' '/tmp/repo' 2 'redwork/x')"
  ok $? "init"
  [ -f "$rd/state.json" ]; ok $? "state.json создан"
  [ "$(cmd_get "$rd" '.schema_version')" = "2" ]; ok $? "schema_version=2"
  [ "$(cmd_get "$rd" '.updated_at')" != "null" ]; ok $? "updated_at есть при init (v2)"
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
  [ "$(cmd_get "$rd" '.schema_version')" = "2" ]; ok $? "state.json остался объектом после отказа (не голая строка)"
  [ "$(cmd_get "$rd" '.phase')" = "P5_deploy" ]; ok $? "phase не изменился после отказа"
  # validate_no_secrets: чистая строка ok, секрет — reject
  validate_no_secrets "just a normal task description"; ok $? "чистая строка проходит"
  # секрет split-литералом чтобы не триггерить хук/push-protection
  if validate_no_secrets "key sk-""ABCDEFGHIJ1234567890abcd" 2>/dev/null; then ok 1 "секрет должен reject'иться"; else ok 0 ""; fi
  # heartbeat: любая запись двигает updated_at
  local u1 u2; u1="$(cmd_get "$rd" '.updated_at')"; sleep 1
  _write "$rd" --arg val "P4_finalize_pre" '.phase = $val' >/dev/null; u2="$(cmd_get "$rd" '.updated_at')"
  [ "$u1" != "$u2" ]; ok $? "updated_at двигается на КАЖДОЙ записи (heartbeat не забываем)"
  # phase_status whitelist
  _write "$rd" --arg val "blocked" '.phase_status = $val' >/dev/null; ok $? "phase_status=blocked принят"
  if _write "$rd" --arg val "wat" '.phase_status = $val' >/dev/null 2>&1; then ok 1 "phase_status вне enum должен reject'иться"; else ok 0 ""; fi
  [ "$(cmd_get "$rd" '.phase_status')" = "blocked" ]; ok $? "phase_status не испорчен после отказа"
  # lock/stale
  cmd_lock "$rd" >/dev/null; ok $? "lock"
  if cmd_lock "$rd" >/dev/null 2>&1; then ok 1 "второй lock должен отказать (heartbeat свежий)"; else ok 0 ""; fi
  # РЕГРЕСС: лок с мёртвым pid, но СВЕЖИМ heartbeat = живой run (step.sh его touch'ает) → не отбирать
  echo 999999 > "$rd/.lock/pid"; date +%s > "$rd/.lock/at"
  if cmd_lock "$rd" >/dev/null 2>&1; then ok 1 "мёртвый pid + свежий heartbeat = ЖИВОЙ run, лок не отбирать"; else ok 0 ""; fi
  # протухший heartbeat → reclaim
  echo 0 > "$rd/.lock/at"; cmd_lock "$rd" >/dev/null 2>&1; ok $? "протухший heartbeat → reclaim"
  cmd_touch "$rd"; ok $? "touch обновляет heartbeat"
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
  touch) cmd_touch "${2:?}" ;;
  unlock) cmd_unlock "${2:?}" ;;
  validate-no-secrets) validate_no_secrets "${2:-}" ;;
  health)     cmd_health ;;
  --self-test) self_test ;;
  *) echo "usage: state.sh slug|init|get|set_str|set_json|lock|touch|unlock|health|validate-no-secrets|--self-test" >&2; exit 1 ;;
esac

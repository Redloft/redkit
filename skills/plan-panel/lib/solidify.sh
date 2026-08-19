#!/usr/bin/env bash
# solidify.sh — превращает накопленные методологические находки в правки role-промптов.
#
# ДВА входа:
#   scan  — ledger-driven (НОВОЕ, push-петля): читает feedback/learnings.jsonl, кластеризует по
#           lens_key, отбирает темы с count≥порог, готовит payload для draft-агента. Это то, что
#           гоняет scheduled-solidify. Не требует ручного /panel-feedback.
#   prepare/apply/reject — legacy per-role acceptance flow (ручной feedback/<role>.jsonl).
#
# Реальную LLM-работу (draft диффа role.md) делает Claude/агент; этот скрипт — детерминированная обвязка
# (валидация, кластеризация, versioning, CHANGELOG-провенанс).
#
# Usage:
#   solidify.sh scan [skill_root]                 — ledger-кластеры ≥ порога + затронутые role.md (payload)
#   solidify.sh prepare <role>                    — legacy payload из feedback/<role>.jsonl
#   solidify.sh apply <skill_root> <role> <proposed> [why] [lens_key1,lens_key2] — применить diff
#           + versioning/CHANGELOG + ЗАКРЫТИЕ перечисленных тем (иначе scan предложит их снова)
#   solidify.sh reject <proposed>
set -euo pipefail

CMD="${1:?usage: solidify.sh scan|prepare|apply|reject ...}"
SKILL_ROOT="${PLAN_PANEL_SKILL_ROOT:-$HOME/.claude/skills/plan-panel}"
HISTORY_DIR="$SKILL_ROOT/roles/_history"
CHANGELOG="$HISTORY_DIR/CHANGELOG.md"
# Ф5: список ролей — из реестра-данных, с фолбэком на прежний хардкод (реестра нет/битый).
# Иначе новая роль требовала правки ещё и здесь, а расхождение всплывало только при apply.
_valid_roles() {
  local reg="$SKILL_ROOT/roles/registry.json"
  if [ -f "$reg" ]; then
    local fromreg; fromreg="$(jq -r '[.roles[].name] | join(" ")' "$reg" 2>/dev/null)"
    [ -n "$fromreg" ] && { printf '%s' "$fromreg"; return 0; }
  fi
  printf '%s' "scoper architect qa security frontend backend data ops judge planner"
}
VALID_ROLES="$(_valid_roles)"

_need_role() {
  echo "$VALID_ROLES" | grep -qw "$1" || { echo "✗ invalid role: $1 (valid: $VALID_ROLES)" >&2; exit 1; }
}

# Роли, чьи находки не могут кластеризоваться (канон для роли пуст → критик каждый раз
# именует тему заново → count навсегда 1). Печатается НЕЗАВИСИМО от наличия горячих тем:
# при N=0 этот сигнал нужен даже сильнее — «тем нет» может означать не тишину, а немоту.
_print_orphans() {
  local ROOT="$1" Q="$2"
  local CANON_F="$ROOT/lenses/canon.json"
  [ -f "$CANON_F" ] || return 0
  [ -n "${Q:-}" ] || return 0
  local ORPHANS
  ORPHANS="$(printf '%s' "$Q" | jq -c --slurpfile c "$CANON_F" '
    ([$c[0].lenses[]?.role] | unique) as $covered
    | [ .fresh[]? | select((.role // "") != "") ]
    | group_by(.role)
    | map({role: .[0].role,
           keys_n: length,
           findings_n: (map(.count // 1) | add),
           in_canon: (([.[0].role] - $covered) | length == 0)})
    | map(select(.findings_n >= 3))
    | sort_by(-.findings_n)' 2>/dev/null || echo '[]')"
  [ "$(printf '%s' "$ORPHANS" | jq 'length' 2>/dev/null || echo 0)" != "0" ] || return 0
  echo "=== РОЛИ ВНЕ СЛОВАРЯ (находки копятся, но кластеризоваться НЕ МОГУТ) ==="
  printf '%s' "$ORPHANS" | jq -r '.[] |
    "  · \(.role): \(.findings_n) находок под \(.keys_n) разными ключами · канон для роли: " +
    (if .in_canon then "есть (словарь узок — нужны алиасы/новая линза)" else "ПУСТ → роль структурно вне петли" end)'
  echo "   → правка lenses/canon.json: завести линзы для ролей с пустым каноном."
  echo "   Порог «ключ встретился ≥2 раз» для них недостижим: критик каждый раз именует тему заново."
  echo
}

case "$CMD" in

  scan)
    ROOT="${2:-$SKILL_ROOT}"
    THRESHOLD="${PLAN_PANEL_SOLIDIFY_THRESHOLD:-3}"
    LEDGER_SH="$SKILL_ROOT/lib/ledger.sh"
    CLUSTERS="$(bash "$LEDGER_SH" cluster "$ROOT")"
    HOT="$(printf '%s' "$CLUSTERS" | jq --argjson t "$THRESHOLD" '[.[] | select(.count >= $t)]')"
    N="$(printf '%s' "$HOT" | jq 'length')"
    echo "=== SOLIDIFY SCAN: $ROOT (threshold=$THRESHOLD) ==="
    echo "$(bash "$LEDGER_SH" stat "$ROOT")"
    if [ "$N" = "0" ]; then
      echo "→ нет тем с count≥$THRESHOLD. Нечего solidify (петля копит дальше)."
      # ВАЖНО: сигнал «роль вне словаря» печатаем ДО выхода. Раньше он стоял ниже раннего
      # exit и пропадал ровно в тот момент, когда горячих тем не осталось, — то есть глох
      # тогда, когда «тишина» и «немота» неразличимы. Это тот же класс самоподавляющегося
      # сигнала, который эта петля и лечит.
      _print_orphans "$ROOT" "$(bash "$LEDGER_SH" quarantine "$ROOT" 2>/dev/null || echo '{}')"
      exit 0
    fi
    echo "→ $N тем(ы) превысили порог — кандидаты на правку role-промптов:"
    # ВЕРНУВШИЕСЯ ТЕМЫ (2026-08-19). Тема, которую уже закрывали патчем, и она снова
    # перевалила порог — это НЕ «ещё один пункт в чек-лист», а сигнал, что прошлая клауза
    # закрыла только наблюдённые случаи, а не класс. Диагноз 19.08 по трём таким темам:
    # architect — контракт прописали для границ ВНУТРИ плана, возвращается на внешних
    # писателях и на контракте, меняющемся по scope; qa — пороги DoD для планов и фич,
    # возвращается на коммерческих документах; ops — откат для деплоев и write-путей,
    # возвращается на смене семантики read-пути и на общем gate-скрипте.
    # Драфт-агент ОБЯЗАН видеть этот флаг: для вернувшейся темы правило другое —
    # сначала объясни, почему прошлая формулировка не удержала, потом расширяй класс.
    CLOSED_F="$ROOT/feedback/closed.jsonl"
    if [ -f "$CLOSED_F" ]; then
      printf '%s' "$HOT" | jq -c --slurpfile cl <(jq -c '.' "$CLOSED_F" 2>/dev/null | jq -s '.') '
        ($cl[0] // []) as $closed
        | .[]
        | . as $t
        | ($closed | map(select(.role == $t.role and .lens_key == $t.lens_key)) | sort_by(.closed_at) | last) as $prev
        | if $prev then . + {returning: true, closed_before: $prev.closed_at, closed_why: ($prev.why // "")} else . end'
    else
      printf '%s' "$HOT" | jq -c '.[]'
    fi
    RET_N="$(printf '%s' "$HOT" | jq --slurpfile cl <(jq -c '.' "${CLOSED_F:-/dev/null}" 2>/dev/null | jq -s '.') '
      ($cl[0] // []) as $closed
      | [.[] | select(. as $t | $closed | any(.role == $t.role and .lens_key == $t.lens_key))] | length' 2>/dev/null || echo 0)"
    if [ "${RET_N:-0}" != "0" ]; then
      echo
      echo "⚑ ВЕРНУВШИХСЯ ТЕМ: $RET_N — их уже закрывали патчем, и они снова перевалили порог."
      echo "   Это значит: прошлая клауза закрыла наблюдённые СЛУЧАИ, а не КЛАСС."
      echo "   Для них НЕ дописывать ещё пункт, пока не объяснено, почему прошлая формулировка не удержала."
      echo "   Прошлые формулировки — в roles/_history/<role>.<closed_at>.md (diff против текущего role.md)."
    fi
    echo
    # Для каждой роли из горячих тем — приложить текущий role.md (draft-агенту для diff)
    for role in $(printf '%s' "$HOT" | jq -r '[.[].role] | unique | .[]'); do
      RF="$SKILL_ROOT/roles/${role}.md"
      [ -f "$RF" ] || RF="$ROOT/roles/${role}.md"
      echo "=== CURRENT role.md: $role ($([ -f "$RF" ] && wc -l < "$RF" | tr -d ' ' || echo '?') строк) ==="
      [ -f "$RF" ] && cat "$RF" || echo "(role file не найден: $RF)"
      echo
    done
    # Кандидаты в канон линз: ключи, которые критик вернул как new:* или незнакомые.
    # Это ДРУГОЙ сигнал, чем горячая тема: «словарь пора расширить», а не «правь чеклист».
    # Показываем только свежие (после ввода канона) — исторические одним числом, иначе
    # 244 доканонных ключа утопят настоящих кандидатов.
    Q="$(bash "$LEDGER_SH" quarantine "$ROOT" 2>/dev/null || echo '{}')"
    QF="$(printf '%s' "$Q" | jq '[.fresh[]? | select(.count >= 2)]' 2>/dev/null || echo '[]')"
    QN="$(printf '%s' "$QF" | jq 'length' 2>/dev/null || echo 0)"
    if [ "${QN:-0}" != "0" ]; then
      echo "=== КАНДИДАТЫ В КАНОН ЛИНЗ ($QN, встретились ≥2 раз после $(printf '%s' "$Q" | jq -r '.since // "?"')) ==="
      printf '%s' "$QF" | jq -c '.[]'
      echo "   → это правка lenses/canon.json (новая тема или алиас к существующей), НЕ правка чеклиста."
      echo "   Исторических (до канона, в разбор не берём): $(printf '%s' "$Q" | jq -r '.historical // 0')"
      echo
    fi
    _print_orphans "$ROOT" "${Q:-}"
    echo "💡 Draft-агент: по горячим темам выше предложи МИНИМАЛЬНЫЙ diff к каждому role.md (1-2 пункта чек-листа),"
    echo "   затем 'solidify.sh apply <skill_root> <role> <proposed.md> \"<why>\"' с апрувом пользователя."
    ;;

  prepare)
    ROLE="${2:?need role}"; _need_role "$ROLE"
    ROLE_FILE="$SKILL_ROOT/roles/${ROLE}.md"; FEEDBACK_FILE="$SKILL_ROOT/feedback/${ROLE}.jsonl"
    [ -f "$ROLE_FILE" ] || { echo "✗ role file missing: $ROLE_FILE" >&2; exit 1; }
    [ -f "$FEEDBACK_FILE" ] || { echo "✗ no manual feedback for '$ROLE'. (Авто-петля использует 'scan', не 'prepare'.)" >&2; exit 1; }
    FB_COUNT=$(wc -l < "$FEEDBACK_FILE" | tr -d ' ')
    THRESHOLD="${PLAN_PANEL_SOLIDIFY_THRESHOLD:-10}"
    [ "$FB_COUNT" -ge "$THRESHOLD" ] || { echo "⚠ only $FB_COUNT entries (threshold $THRESHOLD)" >&2; exit 2; }
    echo "=== ROLE: $ROLE ==="; echo "=== CURRENT ROLE.MD ==="; cat "$ROLE_FILE"
    echo; echo "=== FEEDBACK ($FB_COUNT) ==="; cat "$FEEDBACK_FILE"
    ;;

  apply)
    # РОУТИНГ ПО skill_root обязателен — иначе тема из redsemantic/redresearch с role=judge
    # затёрла бы plan-panel/roles/judge.md (cross-skill clobber). Целевой файл должен существовать.
    AROOT="${2:?need skill_root (e.g. ~/.claude/skills/redsemantic)}"
    ROLE="${3:?need role}"; _need_role "$ROLE"
    PROPOSED="${4:?need proposed file}"; WHY="${5:-solidify}"; LENS_CSV="${6:-}"
    AROOT="${AROOT/#\~/$HOME}"
    ROLE_FILE="$AROOT/roles/${ROLE}.md"
    AHIST="$AROOT/roles/_history"; ACHANGELOG="$AHIST/CHANGELOG.md"
    [ -f "$PROPOSED" ] || { echo "✗ proposed missing: $PROPOSED" >&2; exit 1; }
    [ -f "$ROLE_FILE" ] || { echo "✗ prompt-файл не найден: $ROLE_FILE — проверь skill_root+role (у red*-стадий путь может быть stages/<name>/prompt.md, не roles/). НЕ затираю чужой скилл." >&2; exit 1; }
    mkdir -p "$AHIST"
    TS=$(date +%Y-%m-%d_%H-%M-%S)
    cp "$ROLE_FILE" "$AHIST/${ROLE}.${TS}.md"
    cp "$PROPOSED" "$ROLE_FILE"; rm -f "$PROPOSED"
    # CHANGELOG-провенанс в ТОМ ЖЕ скилле (урок живёт В СКИЛЛЕ)
    [ -f "$ACHANGELOG" ] || printf '# applied methodology lessons\n\n' > "$ACHANGELOG"
    printf -- '- **%s** · `%s` · %s (backup: _history/%s.%s.md)\n' "$TS" "$ROLE" "$WHY" "$ROLE" "$TS" >> "$ACHANGELOG"
    echo "✓ applied → $ROLE_FILE (backup _history/${ROLE}.${TS}.md); CHANGELOG обновлён"
    # ЗАКРЫТИЕ ТЕМ. Без него находки, породившие тему, остаются в ledger'е и следующий scan
    # предложит ту же клаузу повторно — петля наматывает один круг вечно (нашла артефактная
    # панель 2026-07-27). Закрытие гасит ТОЛЬКО находки не позже closed_at: если тема всплывёт
    # снова уже после правки, значит клауза не сработала, и это обязано быть видно.
    if [ -n "$LENS_CSV" ]; then
      CLOSED="$AROOT/feedback/closed.jsonl"; mkdir -p "$(dirname "$CLOSED")"
      CLOSED_AT="$(date +%Y-%m-%d_%H-%M-%S)"
      IFS=',' read -r -a _keys <<< "$LENS_CSV"
      for k in "${_keys[@]}"; do
        k="$(printf '%s' "$k" | tr -d '[:space:]')"; [ -n "$k" ] || continue
        jq -nc --arg r "$ROLE" --arg k "$k" --arg at "$CLOSED_AT" --arg why "$WHY" \
          '{role:$r, lens_key:$k, closed_at:$at, why:$why}' >> "$CLOSED"
        echo "  ↳ тема закрыта: ${ROLE}/${k} (до $CLOSED_AT)"
      done
    else
      echo "  ⚠ темы НЕ закрыты (--lens не передан) — следующий scan предложит их снова"
    fi
    ;;

  reject)
    PROPOSED="${2:?need proposed file}"
    [ -f "$PROPOSED" ] && rm -f "$PROPOSED" && echo "✓ proposed отклонён" || echo "(proposed не найден)"
    ;;

  *) echo "✗ unknown: $CMD (scan|prepare|apply|reject)" >&2; exit 1 ;;
esac

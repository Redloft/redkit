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
#   solidify.sh apply <skill_root> <role> <proposed> [why] — применить diff с versioning + CHANGELOG (роутинг по skill_root, без cross-skill clobber)
#   solidify.sh reject <proposed>
set -euo pipefail

CMD="${1:?usage: solidify.sh scan|prepare|apply|reject ...}"
SKILL_ROOT="${PLAN_PANEL_SKILL_ROOT:-$HOME/.claude/skills/plan-panel}"
HISTORY_DIR="$SKILL_ROOT/roles/_history"
CHANGELOG="$HISTORY_DIR/CHANGELOG.md"
VALID_ROLES="scoper architect qa security frontend backend data ops judge planner"

_need_role() {
  echo "$VALID_ROLES" | grep -qw "$1" || { echo "✗ invalid role: $1 (valid: $VALID_ROLES)" >&2; exit 1; }
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
      exit 0
    fi
    echo "→ $N тем(ы) превысили порог — кандидаты на правку role-промптов:"
    echo "$HOT" | jq -c '.[]'
    echo
    # Для каждой роли из горячих тем — приложить текущий role.md (draft-агенту для diff)
    for role in $(printf '%s' "$HOT" | jq -r '[.[].role] | unique | .[]'); do
      RF="$SKILL_ROOT/roles/${role}.md"
      [ -f "$RF" ] || RF="$ROOT/roles/${role}.md"
      echo "=== CURRENT role.md: $role ($([ -f "$RF" ] && wc -l < "$RF" | tr -d ' ' || echo '?') строк) ==="
      [ -f "$RF" ] && cat "$RF" || echo "(role file не найден: $RF)"
      echo
    done
    echo "💡 Draft-агент: по темам выше предложи МИНИМАЛЬНЫЙ diff к каждому role.md (1-2 пункта чек-листа),"
    echo "   затем 'solidify.sh apply <role> <proposed.md> \"<why>\"' с апрувом пользователя."
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
    PROPOSED="${4:?need proposed file}"; WHY="${5:-solidify}"
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
    ;;

  reject)
    PROPOSED="${2:?need proposed file}"
    [ -f "$PROPOSED" ] && rm -f "$PROPOSED" && echo "✓ proposed отклонён" || echo "(proposed не найден)"
    ;;

  *) echo "✗ unknown: $CMD (scan|prepare|apply|reject)" >&2; exit 1 ;;
esac

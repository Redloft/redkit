#!/opt/homebrew/bin/bash
# Архивариус: текст плана / диффа → бриф релевантных фактов RedBrain (work-scope) для
# заземления оценки в plan-panel / finalize. Оркестратор зовёт ЭТО отдельным subprocess
# ДО Workflow() (НЕ import recall.py — сохранить main-thread signal-инвариант хука), а
# результат передаёт как args.memory_brief.
#
# Ключевое: recall.py настроен как УЛЬТРА-консервативный per-prompt хук (deadline 150мс,
# shadow, MAX 3/6). Архивариусу нужен ДРУГОЙ профиль (длинный текст, щедрая латентность,
# полнее ретрив) — задаём теми же env-ручками recall.py, БЕЗ форка логики.
#
# Инварианты: scope work ЖЁСТКО в recall.py (private не подмешивается); fail-open —
# пусто/ошибка/нет мозга → пустой вывод, панель работает как сегодня.
#
# Usage: archivist.sh [planfile]   (нет аргумента → текст на stdin)
set -uo pipefail
RECALL="$HOME/.claude/skills/redbrain/lib/recall.py"
[ -f "$RECALL" ] || exit 0          # мозга/recall нет → тихо пусто (fail-open)
IN="${1:-/dev/stdin}"

BRIEF=$(REDBRAIN_RECALL_SHADOW=0 \
        REDBRAIN_RECALL_DISABLE=0 \
        REDBRAIN_RECALL_DEADLINE_MS="${ARCHIVIST_DEADLINE_MS:-3000}" \
        REDBRAIN_RECALL_MAX_ENTITIES="${ARCHIVIST_MAX_ENTITIES:-12}" \
        REDBRAIN_RECALL_MAX_FACTS="${ARCHIVIST_MAX_FACTS:-40}" \
        REDBRAIN_RECALL_SCORE_FLOOR="${ARCHIVIST_SCORE_FLOOR:-3}" \
        REDBRAIN_RECALL_LOG=0 \
        python3 "$RECALL" --text < "$IN" 2>/dev/null || true)

[ -z "$BRIEF" ] && exit 0            # нечего заземлять → пусто (панель без брифа)
cat <<EOF
=== RedBrain-контекст (автоматический ретрив по памяти Игоря, work-scope) ===
НЕвериф. подсказка: используй, чтобы поймать конфликт с принятыми решениями/граблями и
не переоткрывать известное. Каждый факт с source_doc — открой файл для полного контекста.

$BRIEF
EOF

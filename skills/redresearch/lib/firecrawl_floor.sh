#!/usr/bin/env bash
# firecrawl_floor.sh — pre-run проверка остатка кредитов firecrawl (floor-alert <150).
# Академ-слой (C2) ходит в firecrawl через MCP-инструменты агента (не per-call shell),
# поэтому лимит firecrawl не резервируется budget_guard'ом — вместо этого разовый alert
# перед heavy/ultra-прогоном с academic-scope.
# Ключ 1Password 'Firecrawl' (curl --config, не argv). Fail-open: сбой → exit 0 (не блокируем).
#
# Usage: firecrawl_floor.sh [--threshold N]   # exit 0 всегда; печатает REMAINING/WARN в stderr
set -uo pipefail
THRESH="${FIRECRAWL_FLOOR:-150}"
[ "${1:-}" = "--threshold" ] && THRESH="$2"

if [ -z "${FIRECRAWL_KEY:-}" ]; then
  # capture+validate (как sibling-адаптеры): stdout child захватываем, но НЕ глушим его stderr —
  # там живёт ⚠️/OK-алерт (единственная функция скрипта). op-провал → диагностика + fail-open.
  CHILD="$(op run --env-file=<(printf 'FIRECRAWL_KEY=op://AI-Tokens/Firecrawl/credential\n') -- bash "${BASH_SOURCE[0]}" --threshold "$THRESH")"; rc=$?
  [ "$rc" -ne 0 ] && { echo "firecrawl: op run failed (rc=$rc)" >&2; exit 0; }
  printf '%s\n' "$CHILD"
  exit 0
fi

CFG="$(mktemp)"; chmod 600 "$CFG"; trap 'rm -f "$CFG"' EXIT
printf 'header = "Authorization: Bearer %s"\n' "$FIRECRAWL_KEY" > "$CFG"
RESP="$(curl --silent --max-time 20 --config "$CFG" https://api.firecrawl.dev/v1/team/credit-usage 2>/dev/null || true)"
REM="$(printf '%s' "$RESP" | jq -r '.data.remaining_credits // empty' 2>/dev/null)"
[ -z "$REM" ] && { echo "firecrawl: credit check unavailable (fail-open)" >&2; exit 0; }
# integer-safe: API может вернуть float (149.5) → отбросить дробную часть перед -lt,
# иначе `-lt` падает и молча уходит в OK-ветку, маскируя реально низкий баланс.
REM_INT="${REM%%.*}"
if ! printf '%s' "$REM_INT" | grep -qE '^[0-9]+$'; then
  echo "firecrawl: не смог распарсить остаток ($REM) — проверь вручную" >&2
  printf '%s\n' "$REM"; exit 0
fi
if [ "$REM_INT" -lt "$THRESH" ]; then
  echo "⚠️ firecrawl LOW: $REM credits left (<$THRESH) — academic-слой может исчерпать лимит, подумай про апгрейд" >&2
else
  echo "firecrawl OK: $REM credits" >&2
fi
printf '%s\n' "$REM"
exit 0

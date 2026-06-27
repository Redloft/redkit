#!/usr/bin/env bash
# Acceptance-метрика relevance-gate: доля niche-anchored ключей + доля шума.
# Воспроизводимо считает «до/после» (как мерили redloft-agency: 22% anchored / 22% шум).
# Usage: niche-share.sh <keyword_universe.jsonl> "<anchors|regex>" "<stops|regex>"
# Пример: niche-share.sh run/keyword_universe.jsonl 'бан[ья]|банн|сауна|спа|терм|парил' 'банк|сбербанк|гостиниц|отел|коворкинг|вакансии'
set -u
F="${1:?usage: niche-share.sh <universe.jsonl> <anchors-re> <stops-re>}"
ANCHOR="${2:?anchors regex}"; STOP="${3:?stops regex}"
[ -f "$F" ] || { echo "no file: $F" >&2; exit 1; }
total=$(grep -c . "$F")
[ "$total" -gt 0 ] || { echo "empty universe"; exit 1; }
anchored=$(grep -ciE "$ANCHOR" "$F")
noisy=$(grep -ciE "$STOP" "$F")
pc(){ awk -v a="$1" -v b="$2" 'BEGIN{printf "%.0f", (b? a*100/b : 0)}'; }
echo "universe: $total ключей"
echo "  с niche-анкером: $anchored ($(pc "$anchored" "$total")%)"
echo "  со стоп-словом (шум): $noisy ($(pc "$noisy" "$total")%)"
echo "  acceptance: anchored ≥80% И шум 0% → $([ "$(pc "$anchored" "$total")" -ge 80 ] && [ "$noisy" -eq 0 ] && echo PASS || echo 'NEEDS-WORK')"

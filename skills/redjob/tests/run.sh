#!/opt/homebrew/bin/bash
# redjob shakedown — assert-таблица фикстур + golden-снэпшот живого парка.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"

echo "=== 1. Fixture asserts (класс поломок) ==="
python3 "$HERE/harness.py"
rc=$?

echo
echo "=== 2. Golden-снэпшот живого парка (документ, не регресс-assert) ==="
# дата берётся из окружения (в песочнице Date запрещён) — передай TODAY=YYYY-MM-DD
TODAY="${TODAY:-$(date +%F 2>/dev/null || echo unknown)}"
SNAP="$HERE/golden/live-doctor-$TODAY.txt"
mkdir -p "$HERE/golden"
NO_COLOR=1 python3 "$SKILL/bin/redjob" doctor > "$SNAP" 2>&1
echo "снэпшот: $SNAP"
# Информационно: парк у каждого свой — это документ «что doctor увидел сегодня»,
# не жёсткий assert. Настоящий гейт — фикстурные asserts выше (self-contained).
grep -qE "CRITICAL|WARNING|INFO" "$SNAP" \
  && echo "  ✓ живой парк: doctor отработал, снэпшот записан" \
  || echo "  ⚠ живой парк: пусто (нет своих джоб? прогони 'redjob seed --write')"
for pat in collision-heavy collision-lock lock-group; do
  grep -q "$pat" "$SNAP" && echo "  · найдено: $pat"
done

echo
[ $rc -eq 0 ] && echo "SHAKEDOWN PASS" || echo "SHAKEDOWN FAIL"
exit $rc

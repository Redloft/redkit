#!/usr/bin/env bash
# test-seam-clause.sh — гард на сквозной пункт «шов между ролями» (solidify 2026-08-19).
#
# Зачем отдельный тест: тема judge/judge-covers-for-roles (×11 critical) — про то, что
# проверка, не принадлежащая ни одной роли, тихо выпадает. Сам пункт-лекарство живёт в ОБЩЕМ
# промпте трёх воркфлоу и ровно так же может тихо выпасть при следующей правке промпта.
# Поэтому: определён на верхнем уровне модуля (иначе окажется внутри выражения и не доедет)
# И реально подставлен в промпт роли.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
fail=0
# required=1 — файл обязан существовать; required=0 — ветка может отсутствовать в этой
# установке (артефактная/бизнес-панель не опубликована в redkit), тогда честно пропускаем,
# а не падаем: иначе тест начнёт врать в урезанной копии дерева.
check() {
  local f="$1" label="$2" required="${3:-1}"
  if [ ! -f "$f" ]; then
    if [ "$required" = "1" ]; then echo "  ✗ нет файла: $f"; fail=1
    else echo "  ~ пропуск (ветка отсутствует в этой установке): $label"; fi
    return
  fi
  local def use
  def="$(grep -n '^const SEAM_CLAUSE' "$f" | head -1 | cut -d: -f1)"
  use="$(grep -n 'SEAM_CLAUSE}' "$f" | head -1 | cut -d: -f1)"
  [ -n "$def" ] || { echo "  ✗ $label: SEAM_CLAUSE не объявлен на верхнем уровне (или уехал внутрь выражения)"; fail=1; return; }
  [ -n "$use" ] || { echo "  ✗ $label: SEAM_CLAUSE объявлен, но НЕ подставлен в промпт роли"; fail=1; return; }
  [ "$def" -lt "$use" ] || { echo "  ✗ $label: использование ($use) раньше объявления ($def)"; fail=1; return; }
  node --check "$f" || { echo "  ✗ $label: синтаксис"; fail=1; return; }
  grep -q 'что происходит ПОСЛЕ' "$f" || { echo "  ✗ $label: потерян вопрос «что происходит ПОСЛЕ успеха»"; fail=1; }
  grep -q 'СНАРУЖИ' "$f" || { echo "  ✗ $label: потерян вопрос «что снаружи твоего слоя зависит»"; fail=1; }
}
check "$HERE/../workflow/panel.js"          "panel.js (кодовая панель)"
check "$HERE/../workflow/artifact-panel.js" "artifact-panel.js (бизнес-панель)" 0
check "$HERE/../../finalize/workflow/finalize.js" "finalize.js (ревью кода)"
if [ "$fail" -eq 0 ]; then echo "✓ seam-clause self-test passed (3 воркфлоу: объявлен top-level + подставлен в промпт)"; exit 0
else echo "✗ seam-clause self-test FAILED"; exit 1; fi

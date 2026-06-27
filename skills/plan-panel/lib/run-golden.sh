#!/usr/bin/env bash
# Golden dataset smoke-runner — прогоняет fixtures/golden/* через panel и
# сравнивает с expected.json.
#
# В Phase A эта реализация — placeholder: проверяет ТОЛЬКО валидность fixtures
# (схема expected.json, наличие plan.md, парсимость JSON). Реальный prog'on
# через panel.js будет в Phase B когда есть programmatic invocation Workflow
# tool из shell (сейчас Workflow запускается только из Claude session).
#
# Usage: run-golden.sh [<fixture-name>]
#   Без аргументов — проверка всех fixtures.
#   С аргументом — только конкретный fixture (например `backend-security`).
set -euo pipefail

FIXTURES_DIR="$(cd "$(dirname "$0")/.." && pwd)/fixtures/golden"
TARGET="${1:-}"

if [ ! -d "$FIXTURES_DIR" ]; then
  echo "✗ fixtures dir not found: $FIXTURES_DIR" >&2
  exit 1
fi

declare -i OK=0 FAIL=0
check_fixture() {
  local dir="$1"
  local name
  name=$(basename "$dir")
  printf "%-25s " "$name"

  local plan="$dir/plan.md"
  local expected="$dir/expected.json"
  local errors=()
  [ -f "$plan" ]     || errors+=("missing plan.md")
  [ -f "$expected" ] || errors+=("missing expected.json")
  if [ -f "$expected" ]; then
    jq empty "$expected" 2>/dev/null || errors+=("expected.json не валидный JSON")
    # Required fields
    for f in expected_complexity expected_selected_roles_min expected_verdict; do
      jq -e --arg f "$f" 'has($f)' "$expected" >/dev/null 2>&1 || errors+=("expected.json missing key '$f'")
    done
  fi

  if [ "${#errors[@]}" -eq 0 ]; then
    echo "✓ valid"
    OK+=1
  else
    echo "✗ FAIL"
    for e in "${errors[@]}"; do
      echo "    - $e"
    done
    FAIL+=1
  fi
}

if [ -n "$TARGET" ]; then
  check_fixture "$FIXTURES_DIR/$TARGET"
else
  for dir in "$FIXTURES_DIR"/*/; do
    # Skip README.md if present at top level
    [ -d "$dir" ] || continue
    check_fixture "$dir"
  done
fi

echo
echo "Summary: $OK ok, $FAIL fail"
exit $FAIL

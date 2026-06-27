#!/usr/bin/env bash
# detect-gates.sh — автодетект команд стабилизации (DESIGN /finalize §gates).
# Печатает JSON-массив гейтов в порядке typecheck→lint→build→test.
# Каждый гейт: { name, cmd }. Пустой массив [] = гейты не найдены (review всё равно пойдёт, stable:unknown).
#
# Приоритет источников:
#   1) $CLAUDECORE_PATH/projects/<slug>.md — если есть fenced-блок ```gates ... ``` (KEY=cmd строки)
#   2) package.json scripts (typecheck|tsc, lint, build, test)
#   3) маркеры: Makefile / Cargo.toml / pyproject|pytest / go.mod
#
# Usage:
#   detect-gates.sh <cwd> [project_slug]
#   detect-gates.sh --self-test
set -euo pipefail

detect() {
  local cwd="$1" slug="${2:-}"
  [ -d "$cwd" ] || { echo "[]"; return 0; }
  local gates='[]'
  add() { gates="$(jq -c --arg n "$1" --arg c "$2" '. + [{name:$n,cmd:$c}]' <<<"$gates")"; }

  # 1) projects/<slug>.md gates-блок
  local pmap="${CLAUDECORE_PATH:-}/projects/${slug}.md"
  if [ -n "$slug" ] && [ -f "$pmap" ]; then
    local block
    block="$(awk '/^```gates/{f=1;next}/^```/{f=0}f' "$pmap" 2>/dev/null || true)"
    if [ -n "$block" ]; then
      while IFS='=' read -r k v; do
        k="$(printf '%s' "$k" | sed -E 's/^ +| +$//g')"; v="$(printf '%s' "$v" | sed -E 's/^ +| +$//g')"
        [ -n "$k" ] && [ -n "$v" ] && add "$k" "$v"
      done <<<"$block"
      [ "$gates" != "[]" ] && { echo "$gates"; return 0; }
    fi
  fi

  # 2) package.json scripts
  if [ -f "$cwd/package.json" ]; then
    local pm="npm run"; [ -f "$cwd/pnpm-lock.yaml" ] && pm="pnpm"; [ -f "$cwd/yarn.lock" ] && pm="yarn"
    local has; has() { jq -e --arg s "$1" '.scripts[$s] // empty' "$cwd/package.json" >/dev/null 2>&1; }
    has typecheck && add typecheck "$pm typecheck"
    has lint      && add lint      "$pm lint"
    has build     && add build     "$pm build"
    has test      && add test      "$pm test"
    [ "$gates" != "[]" ] && { echo "$gates"; return 0; }
  fi

  # 3) маркеры экосистем
  [ -f "$cwd/Makefile" ] && grep -qE '^test:' "$cwd/Makefile" 2>/dev/null && add test "make test"
  [ -f "$cwd/Cargo.toml" ]   && { add build "cargo build"; add test "cargo test"; }
  if [ -f "$cwd/pyproject.toml" ] || ls "$cwd"/pytest.ini "$cwd"/setup.cfg >/dev/null 2>&1; then
    command -v ruff >/dev/null 2>&1 && add lint "ruff check ."
    add test "pytest -q"
  fi
  [ -f "$cwd/go.mod" ] && { add build "go build ./..."; add test "go test ./..."; }

  echo "$gates"
}

self_test() {
  local T fail=0; T="$(mktemp -d)"; trap 'rm -rf "$T"' RETURN
  # package.json detection
  mkdir -p "$T/proj"
  cat > "$T/proj/package.json" <<'EOF'
{ "scripts": { "typecheck": "tsc --noEmit", "test": "vitest run", "build": "next build" } }
EOF
  local g; g="$(detect "$T/proj")"
  [ "$(jq 'length' <<<"$g")" -eq 3 ] || { echo "✗ package.json: expected 3 gates, got $(jq 'length' <<<"$g")"; fail=1; }
  [ "$(jq -r '.[0].name' <<<"$g")" = "typecheck" ] || { echo "✗ order: typecheck first"; fail=1; }
  jq -e '.[] | select(.name=="test") | .cmd=="npm run test"' <<<"$g" >/dev/null || { echo "✗ test cmd wrong"; fail=1; }

  # empty dir → []
  mkdir -p "$T/empty"
  [ "$(detect "$T/empty")" = "[]" ] || { echo "✗ empty dir should yield []"; fail=1; }

  # Cargo
  mkdir -p "$T/rust"; echo '[package]' > "$T/rust/Cargo.toml"
  jq -e '.[] | select(.cmd=="cargo test")' <<<"$(detect "$T/rust")" >/dev/null || { echo "✗ cargo test not detected"; fail=1; }

  [ "$fail" -eq 0 ] && { echo "✓ detect-gates self-test passed"; return 0; } || { echo "✗ detect-gates FAILED"; return 1; }
}

case "${1:-}" in
  --self-test) self_test ;;
  "") echo "usage: detect-gates.sh <cwd> [slug] | --self-test" >&2; exit 64 ;;
  *) detect "$@" ;;
esac

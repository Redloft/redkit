#!/usr/bin/env bash
# risk-classify.sh — классификатор риска для гейта деплоя (spec v3 §Risk-классификатор + safety-floors).
# Консервативно: unknown → high. NON-OVERRIDABLE floor-паттерны (юзер может только ДОБАВИТЬ свои,
# не ослабить). Выдаёт JSON {risk_class, reasons[]}. Детерминированный (правила); LLM-слой — поверх (опц).
#
# Usage:
#   risk-classify.sh <changed_files_file> [--tags "migration,auth"] [--max-auto N] [--add-glob substr]...
#   risk-classify.sh --self-test
set -euo pipefail

# floor-паттерны как extended-regex по пути (неотключаемы)
FLOOR_RE='(^|/)migrations?/|(^|/)auth/|payment|\.pem$|\.key$|(^|/)\.env'
HIGH_TAGS_RE='migration|auth|payment|external-integration|breaking-api|breaking_api'

classify() {
  local cf="${1:?changed_files_file}"; shift || true
  local tags="" max_auto=20; local addglobs=()   # без -a: совместимо с bash 3.2 (system bash macOS)
  while [ $# -gt 0 ]; do case "$1" in
    --tags) tags="$2"; shift 2;;
    --max-auto) max_auto="$2"; shift 2;;
    --add-glob) addglobs+=("$2"); shift 2;;
    *) shift;;
  esac; done
  [ -f "$cf" ] || { echo '{"risk_class":"high","reasons":["changed_files отсутствует → unknown=high"]}'; return 0; }

  local reasons=(); local risk="low"
  _bump(){ case "$1" in high) risk=high;; medium) [ "$risk" = high ] || risk=medium;; esac; }

  # floor-globs
  if grep -qiE "$FLOOR_RE" "$cf"; then
    reasons+=("floor-glob hit (migrations/auth/payment/.pem/.key/.env)"); _bump high
  fi
  # доп. пользовательские globs (substring) — только усиливают
  local g; for g in "${addglobs[@]:-}"; do
    [ -n "$g" ] || continue
    if grep -qiF "$g" "$cf"; then reasons+=("add_human_glob hit: $g"); _bump high; fi
  done
  # scope-теги
  if [ -n "$tags" ] && printf '%s' "$tags" | grep -qiE "$HIGH_TAGS_RE"; then
    reasons+=("high-risk scope-tag"); _bump high
  fi
  # размер диффа
  local n; n="$(grep -cve '^$' "$cf" 2>/dev/null || echo 0)"
  if [ "$n" -gt "$max_auto" ]; then reasons+=("changed files $n > max_auto $max_auto"); _bump medium; fi

  [ "${#reasons[@]}" -gt 0 ] || reasons+=("нет high/medium-сигналов → low")
  # собрать JSON
  local rj; rj="$(printf '%s\n' "${reasons[@]}" | jq -R . | jq -s .)"
  jq -nc --arg r "$risk" --argjson reasons "$rj" '{risk_class:$r, reasons:$reasons}'
}

self_test() {
  set +e; local T; T="$(mktemp -d)"; local fail=0
  ok(){ if [ "$1" -eq 0 ]; then :; else echo "  ✗ $2"; fail=1; fi; }
  # low: обычные файлы
  printf 'src/util.ts\nsrc/page.tsx\n' > "$T/low"
  [ "$(classify "$T/low" | jq -r .risk_class)" = "low" ]; ok $? "обычные файлы → low"
  # high: миграция
  printf 'src/db/migrations/001_init.sql\nsrc/x.ts\n' > "$T/mig"
  [ "$(classify "$T/mig" | jq -r .risk_class)" = "high" ]; ok $? "migrations → high"
  # high: auth
  printf 'app/auth/login.ts\n' > "$T/auth"
  [ "$(classify "$T/auth" | jq -r .risk_class)" = "high" ]; ok $? "auth → high"
  # high: payment basename
  printf 'lib/payment_gateway.ts\n' > "$T/pay"
  [ "$(classify "$T/pay" | jq -r .risk_class)" = "high" ]; ok $? "payment → high"
  # high: .env
  printf '.env.production\n' > "$T/env"
  [ "$(classify "$T/env" | jq -r .risk_class)" = "high" ]; ok $? ".env → high"
  # medium: много файлов
  seq 1 30 | sed 's#^#src/f#;s#$#.ts#' > "$T/many"
  [ "$(classify "$T/many" --max-auto 20 | jq -r .risk_class)" = "medium" ]; ok $? "30>20 файлов → medium"
  # high от тега даже на чистых файлах
  [ "$(classify "$T/low" --tags "ui,migration" | jq -r .risk_class)" = "high" ]; ok $? "scope-tag migration → high"
  # unknown → high
  [ "$(classify "$T/nonexistent" | jq -r .risk_class)" = "high" ]; ok $? "нет файла → high (консервативно)"
  # add-glob усиливает
  [ "$(classify "$T/low" --add-glob "page.tsx" | jq -r .risk_class)" = "high" ]; ok $? "add-glob → high"
  rm -rf "$T"
  if [ "$fail" -eq 0 ]; then echo "✓ risk-classify self-test passed"; return 0; else echo "✗ risk-classify self-test FAILED"; return 1; fi
}

case "${1:-}" in
  --self-test) self_test ;;
  "") echo "usage: risk-classify.sh <changed_files_file> [--tags ..] [--max-auto N] [--add-glob ..] | --self-test" >&2; exit 1 ;;
  *) classify "$@" ;;
esac

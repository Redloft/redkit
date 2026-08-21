#!/usr/bin/env bash
# publish-gate — проверка публичной поверхности redkit перед публикацией.
#
# ЗАЧЕМ. redkit публичный, а собирается из ~/.claude/skills, где живут реальные
# данные оператора: боевые IP, имена клиентов, личная почта, домашние пути.
# Один невнимательный `git add` — и они на GitHub. Force-push НЕ спасает:
# GitHub держит объекты живыми через refs/pull/*, помогает только пересоздание
# репозитория. Поэтому ловим ДО пуша.
#
# ЗАПУСК:
#   bash core/publish-gate.sh            # всё, что под git
#   bash core/publish-gate.sh --staged   # только staged (для pre-commit)
#
# Коды выхода: 0 — чисто, 1 — найдены приватные данные.
#
# Повесить на pre-commit:
#   printf '#!/bin/sh\nexec bash core/publish-gate.sh --staged\n' > .git/hooks/pre-commit
#   chmod +x .git/hooks/pre-commit
#
# Совместимость: bash 3.2 (штатный на macOS) — без mapfile и без grep -P.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
LIST="$TMP/files"

if [ "${1:-}" = "--staged" ]; then
  git diff --cached --name-only --diff-filter=ACMR > "$LIST"; SCOPE="staged"
else
  git ls-files > "$LIST"; SCOPE="tracked"
fi
COUNT=$(wc -l < "$LIST" | tr -d ' ')
[ "$COUNT" = "0" ] && { echo "publish-gate: нечего проверять ($SCOPE)"; exit 0; }

fail=0
ALLOW="core/publish-gate.allow"

# Паттерны allowlist готовим один раз. Нет файла или он пуст → фильтрации нет.
ALLOWPAT="$TMP/allowpat"
if [ -f "$ALLOW" ]; then
  grep -vE '^[[:space:]]*(#|$)' "$ALLOW" > "$ALLOWPAT" 2>/dev/null || : > "$ALLOWPAT"
else
  : > "$ALLOWPAT"
fi

# Отфильтровать строки отчёта по allowlist.
# ВАЖНО: grep -v возвращает 1, когда отфильтровано ВСЁ — это успех, не ошибка,
# поэтому никакого «|| откатить», иначе фильтрация молча не применяется.
filter_allowed() {
  [ -s "$ALLOWPAT" ] || return 0
  grep -vE -f "$ALLOWPAT" "$1" > "$1.f" 2>/dev/null
  mv "$1.f" "$1"
}

report() {
  filter_allowed "$2"
  [ -s "$2" ] || { echo "  ✅ $1"; return; }
  echo "  ❌ $1"; sed 's/^/      /' "$2" | head -8; fail=1
}

# ── 0. Сквозной инвариант словаря вердиктов ───────────────────────────────
# verdict-enum-test существует ради того, чтобы переименование вердикта не сломало
# redwork/lib/autonomy-gate.sh (fail-closed по литералу "SHIP"). Без вызывающего это была
# документация, а не защита — ровно класс дефекта «проверка молча пропускается».
VET="$HOME/.claude/skills/plan-panel/lib/verdict-enum-test.sh"
if [ -f "$VET" ]; then
  if bash "$VET" >/dev/null 2>&1; then echo "  ✅ словарь вердиктов цел (verdict-enum-test)"
  else echo "  ❌ verdict-enum-test FAILED — рассинхрон вердиктов, публиковать нельзя"; fail=1; fi
else
  # Отсутствие стража — САМО ПО СЕБЕ отчёт, а не тишина.
  echo "  ⚠️  verdict-enum-test не найден ($VET) — инвариант вердиктов НЕ проверен"
fi

# ── 1. Приватные пути: не должны быть под git вообще ───────────────────────
grep -E '(^|/)(golden/aliases\.txt|redjob/jobs\.yaml|roadmap/|bridge/mac/state/|tests/golden/live-|baseline/)' "$LIST" > "$TMP/paths" 2>/dev/null
report "приватные пути под git" "$TMP/paths"

# ── 2. Контентные категории (ERE, без -P) ─────────────────────────────────
scan() { # scan <заголовок> <ERE>
  : > "$TMP/hits"
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    grep -Iq . "$f" 2>/dev/null || continue          # пропустить бинарники
    grep -nE "$2" "$f" 2>/dev/null | head -2 | sed "s|^|$f:|" >> "$TMP/hits"
  done < "$LIST"
  report "$1" "$TMP/hits"
}

scan "личная почта"          '[A-Za-z0-9._%+-]+@(gmail|yandex|mail|ya|outlook|icloud)\.[a-z]{2,}'
scan "домашний путь оператора" '/Users/[a-zA-Z0-9_.-]+/'

# Имена клиентов, людей и внутренних хостов НЕ хардкодятся здесь: этот файл
# публичный, и такой список сам был бы утечкой. Оператор держит их в
# core/publish-gate.names (в .gitignore), шаблон — publish-gate.names.example.
NAMES_FILE="core/publish-gate.names"
if [ -f "$NAMES_FILE" ]; then
  NAMEPAT=$(grep -vE '^[[:space:]]*(#|$)' "$NAMES_FILE" | paste -sd'|' -)
  if [ -n "$NAMEPAT" ]; then
    scan "приватные имена (клиенты, люди, хосты)" "$NAMEPAT"
  else
    echo "  ⚠️  приватные имена: $NAMES_FILE пуст"
  fi
else
  echo "  ⚠️  приватные имена: нет $NAMES_FILE — проверка ПРОПУЩЕНА"
  echo "      cp core/publish-gate.names.example core/publish-gate.names и заполни"
fi

# ── 3. Публичные IP: находим все, затем вычитаем частные диапазоны ────────
: > "$TMP/hits"
while IFS= read -r f; do
  [ -f "$f" ] || continue
  grep -Iq . "$f" 2>/dev/null || continue
  grep -noE '([0-9]{1,3}\.){3}[0-9]{1,3}' "$f" 2>/dev/null \
    | grep -vE ':(10\.|127\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|169\.254\.|0\.0\.0\.0|255\.255|100\.64\.|8\.8\.8\.8|1\.2\.3\.|9\.0\.0)' \
    | head -2 | sed "s|^|$f:|" >> "$TMP/hits"
done < "$LIST"
report "публичные IP-адреса" "$TMP/hits"

echo
if [ "$fail" -ne 0 ]; then
  echo "publish-gate: НАЙДЕНЫ ПРИВАТНЫЕ ДАННЫЕ — публиковать нельзя."
  echo "Обобщи строку или добавь путь в .gitignore."
  echo "Если уже попало в историю — force-push не поможет, нужно пересоздание репозитория."
  exit 1
fi
echo "publish-gate: чисто ($SCOPE, $COUNT файлов)."

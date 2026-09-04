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
#   bash core/publish-gate.sh            # tracked + untracked (не ignored)
#   bash core/publish-gate.sh --staged   # только staged (для pre-commit)
#   bash core/publish-gate.sh --self-test # негативный/позитивный контроль самого гейта
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

# ── --self-test: контроль самого гейта ────────────────────────────────────
# Проверяем не «есть ли код», а КРАСНЕЕТ ли гейт на подложенной утечке — в том
# числе в untracked-файле. До 04.09.2026 такой тест зеленел бы вхолостую:
# untracked-файлы в область проверки не входили, и гейт печатал «чисто».
# Песочница — отдельный git-репозиторий в mktemp, боевой репо не трогаем.
if [ "${1:-}" = "--self-test" ]; then
  GATE="$PWD/core/publish-gate.sh"
  SB=$(mktemp -d) || exit 1
  # Вывод прогона держим ВНЕ песочницы: файл внутри неё сам стал бы untracked-файлом
  # и сдвинул знаменатель, который мы же и проверяем.
  OUT=$(mktemp) || exit 1
  trap 'rm -rf "$SB" "$OUT"' EXIT
  mkdir -p "$SB/core" && cp "$GATE" "$SB/core/publish-gate.sh"
  git -C "$SB" init -q || exit 1
  # Копия самого гейта в песочнице — не предмет проверки: держим её вне области
  # через .gitignore, иначе тест мерил бы собственный исходник.
  printf 'core/\n' > "$SB/.gitignore"
  # Строку-утечку собираем ИЗ ЧАСТЕЙ: если написать её литералом, этот публичный
  # файл сам стал бы находкой боевого прогона гейта.
  U="/User""s"; WHO="jdoe"
  st_fail=0
  # HOME подменяем, чтобы на вердикт песочницы не влияли реальные скиллы оператора.
  st_run() { ( cd "$SB" && HOME="$SB" bash core/publish-gate.sh ) > "$OUT" 2>&1; echo $?; }
  st_case() { # st_case <имя> <ожидаемый-код> <ожидаемая-подстрока-или-пусто>
    rc=$(st_run)
    if [ "$rc" != "$2" ]; then
      echo "  ❌ $1: код $rc, ожидался $2"; sed 's/^/      /' "$OUT"; st_fail=1; return
    fi
    if [ -n "${3:-}" ] && ! grep -q "$3" "$OUT"; then
      echo "  ❌ $1: в выводе нет «$3»"; sed 's/^/      /' "$OUT"; st_fail=1; return
    fi
    echo "  ✅ $1"
  }

  # 1. НЕГАТИВНЫЙ КОНТРОЛЬ: домашний путь в untracked-файле — гейт обязан покраснеть.
  mkdir -p "$SB/skills/x/fixtures"
  echo "report path: $U/$WHO/work/report.json" > "$SB/skills/x/fixtures/leak.txt"
  st_case "untracked-утечка ловится" 1 "домашний путь"

  # 2. ПОЗИТИВНЫЙ КОНТРОЛЬ: чистый untracked — зелено, и знаменатель его считает
  #    (.gitignore + ok.txt = 2; без untracked-области здесь стояло бы 0).
  rm -f "$SB/skills/x/fixtures/leak.txt"
  printf 'nothing private here\n' > "$SB/skills/x/fixtures/ok.txt"
  st_case "чистый untracked не ложно-красный" 0 "untracked 2"

  # 3. Ignored-файлы вне области: .gitignore — граница публичной поверхности.
  printf 'ignored.txt\n' >> "$SB/.gitignore"
  echo "$U/$WHO/secret" > "$SB/ignored.txt"
  st_case "ignored не проверяется" 0 "untracked 2"

  # 4. Регрессия на старый маршрут: утечка в tracked-файле ловится по-прежнему.
  rm -f "$SB/ignored.txt"
  echo "$U/$WHO/old" > "$SB/tracked-leak.txt"
  git -C "$SB" add -f tracked-leak.txt >/dev/null 2>&1
  git -C "$SB" -c user.email=t@example.invalid -c user.name=t commit -qm x >/dev/null 2>&1
  st_case "tracked-утечка ловится" 1 "домашний путь"

  # 5. Имя файла с кириллицей: git по умолчанию отдаёт его в \NNN-эскейпах, и такой
  #    файл раньше выпадал из сканирования, оставаясь в знаменателе.
  rm -f "$SB/tracked-leak.txt"
  git -C "$SB" rm -q --cached tracked-leak.txt >/dev/null 2>&1
  echo "$U/$WHO/rus" > "$SB/ОСТАТОК.md"
  st_case "не-ASCII имя файла сканируется" 1 "домашний путь"

  echo
  [ "$st_fail" -eq 0 ] && { echo "publish-gate: self-test OK"; exit 0; }
  echo "publish-gate: self-test FAILED"; exit 1
fi

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
LIST="$TMP/files"

# ОБЛАСТЬ ПРОВЕРКИ. Раньше здесь был только `git ls-files` — и новые, ещё не
# закоммиченные файлы гейт не смотрел ВООБЩЕ, печатая при этом «чисто»
# (инцидент 04.09.2026: вендоренные отчёты в skills/redloop/lib/fixtures/reports/
# с домашним путём оператора). Untracked-но-не-ignored файлы — такая же публичная
# поверхность: один `git add .` — и они в коммите. Поэтому проверяем обе категории,
# а в итоговой строке печатаем ЗНАМЕНАТЕЛЬ по каждой: «чисто» обязано говорить,
# что именно проверено.
if [ "${1:-}" = "--staged" ]; then
  git -c core.quotepath=false diff --cached --name-only --diff-filter=ACMR > "$LIST"; SCOPE="staged"
  N_TRACKED=$(wc -l < "$LIST" | tr -d ' ')
  N_UNTRACKED=0
  DENOM="staged $N_TRACKED"
else
  SCOPE="tracked+untracked"
  # core.quotepath=false обязателен: иначе git отдаёт имена с кириллицей в \NNN-эскейпах,
  # `[ -f "$f" ]` не находит файл и он молча выпадает из сканирования, оставаясь в
  # знаменателе. Знаменатель, который считает непроверенное, — та же дыра, что и «чисто».
  git -c core.quotepath=false ls-files > "$TMP/tracked"
  git -c core.quotepath=false ls-files --others --exclude-standard > "$TMP/untracked"
  N_TRACKED=$(wc -l < "$TMP/tracked" | tr -d ' ')
  N_UNTRACKED=$(wc -l < "$TMP/untracked" | tr -d ' ')
  cat "$TMP/tracked" "$TMP/untracked" > "$LIST"
  DENOM="tracked $N_TRACKED, untracked $N_UNTRACKED"
fi
COUNT=$(wc -l < "$LIST" | tr -d ' ')
[ "$COUNT" = "0" ] && { echo "publish-gate: нечего проверять ($DENOM)"; exit 0; }

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

# ── 2.5. Закрытые пути: что решено НЕ публиковать вообще ──────────────────
# Решение 03.09.2026: skills/redloft — собственная методика агентства (пайплайн
# «идея → ТЗ на сайт»), из публичного доступа изъята. Разовой чистки мало:
# синк канон→redkit вернёт каталог обратно молча (канон и репо расходятся в обе
# стороны). Поэтому запрет живёт МЕХАНИЗМОМ здесь, а не памятью человека.
# Список путей — core/publish-gate.deny (glob на строку, # — комментарий).
DENY_FILE="core/publish-gate.deny"
if [ -f "$DENY_FILE" ]; then
  : > "$TMP/denyhits"
  while IFS= read -r pat; do
    case "$pat" in ''|\#*) continue ;; esac
    while IFS= read -r f; do
      case "$f" in $pat) echo "$f: закрытый путь ($pat)" >> "$TMP/denyhits" ;; esac
    done < "$LIST"
  done < "$DENY_FILE"
  report "закрытые пути (публикации не подлежат)" "$TMP/denyhits"
else
  echo "  ⚠️  закрытые пути: нет $DENY_FILE — проверка ПРОПУЩЕНА"
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
  echo "publish-gate: НАЙДЕНЫ ПРИВАТНЫЕ ДАННЫЕ — публиковать нельзя ($DENOM)."
  echo "Обобщи строку или добавь путь в .gitignore."
  echo "Если уже попало в историю — force-push не поможет, нужно пересоздание репозитория."
  exit 1
fi
echo "publish-gate: чисто ($DENOM)."

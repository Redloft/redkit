#!/usr/bin/env bash
# snapshot.sh — захват git diff сессии → secrets-strip → diff.patch + changed_files (DESIGN §0 SNAPSHOT).
# Strip ОБЯЗАТЕЛЕН перед записью (§7.1): сырой diff на диск НЕ попадает.
#
# Usage:
#   snapshot.sh <cwd> <project_dir> <mode> [ref]
#     mode: working (незакоммиченное) | staged | since (требует ref)
#   snapshot.sh --self-test
# Echoes: <changed_file_count>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
STRIP="$HERE/strip-secrets.sh"

snapshot() {
  local cwd="$1" pd="$2" mode="$3" ref="${4:-}"
  [ -d "$cwd/.git" ] || git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1 || { echo "✗ not a git repo: $cwd" >&2; return 2; }
  local diffcmd namescmd
  case "$mode" in
    working) diffcmd=(git -C "$cwd" diff);            namescmd=(git -C "$cwd" diff --name-only) ;;
    staged)  diffcmd=(git -C "$cwd" diff --cached);   namescmd=(git -C "$cwd" diff --cached --name-only) ;;
    since)   [ -n "$ref" ] || { echo "✗ since requires ref" >&2; return 64; }
             diffcmd=(git -C "$cwd" diff "$ref");      namescmd=(git -C "$cwd" diff "$ref" --name-only) ;;
    *) echo "✗ bad mode: $mode" >&2; return 64 ;;
  esac

  local names; names="$("${namescmd[@]}" 2>/dev/null || true)"
  local count; count="$(printf '%s' "$names" | grep -c . || true)"
  if [ "${count:-0}" -eq 0 ]; then echo "0"; return 0; fi

  printf '%s\n' "$names" > "$pd/changed_files.txt"
  # diff → strip → atomic write (сырое НИКОГДА на диск)
  local tmp="$pd/.diff.patch.tmp.$$"
  local raw="$pd/.diff.raw.tmp.$$" full="$pd/.diff.full.tmp.$$" noent="$pd/.diff.noent.tmp.$$"
  # Сырое НИКОГДА не остаётся на диске: чистим на каждом выходе (trap RETURN здесь не годится —
  # он срабатывает, когда local-переменные уже вне области видимости, и падает под set -u).
  _snap_clean() { rm -f "$raw" "$full" "$noent" "$tmp" 2>/dev/null || true; }
  if ! "${diffcmd[@]}" 2>/dev/null > "$raw"; then echo "✗ diff failed → abort, no diff written" >&2; _snap_clean; return 1; fi
  # ── ДВА ПРОХОДА (2026-08-20) ────────────────────────────────────────────────
  # Заголовки дифа (diff --git / --- / +++ / index / @@ / rename / mode / Binary) — машинные
  # метаданные, и Shannon-эвристика съедала в них ИМЕНА ФАЙЛОВ: слэш склеивает сегменты пути
  # в один высокоэнтропийный токен, и роли получали хунки без указания файла. Раньше это чинили
  # удалением "/" из класса символов — но так ломается единственная защита для секретов без
  # известного префикса (AWS secret access key: 40 base64-символов со слэшами). Панель поймала
  # это как critical четырьмя ролями и воспроизвела живьём.
  # Поэтому чиним НА ЭТОМ слое: заголовки — через --no-entropy (паттерны sk-/ghp_/PEM остаются),
  # тело — полным проходом. Защита не ослаблена нигде, имена файлов целы там, где нужны.
  # Склейка по номерам строк безопасна: strip — регексп-замена, число строк не меняет
  # (проверяется в self-test ниже).
  if ! "$STRIP" < "$raw" > "$full"; then echo "✗ strip failed → abort, no diff written" >&2; _snap_clean; return 1; fi
  if ! "$STRIP" --no-entropy < "$raw" > "$noent"; then echo "✗ strip(--no-entropy) failed → abort" >&2; _snap_clean; return 1; fi
  if [ "$(wc -l < "$full")" != "$(wc -l < "$noent")" ]; then
    echo "✗ strip дал разное число строк в двух режимах → abort (склейка небезопасна)" >&2; _snap_clean; return 1
  fi
  # ⚠ Заголовок определяется СОСТОЯНИЕМ, а не регекспом по строке. Наивное `^--- ` матчит
  # не только заголовок: удалённая строка SQL/Lua-комментария `-- key=…` выглядит в дифе как
  # `--- key=…` и уехала бы в --no-entropy, то есть секрет в ней пережил бы редакцию.
  # Проверено живьём 2026-08-20 (нашёл внешний судья, панель из 5 ролей пропустила).
  # Заголовочная зона: от `diff --git` до первого `@@` этого файла. Внутри неё ---/+++/index/
  # mode/rename — метаданные; после @@ и до следующего `diff --git` всё это уже тело.
  awk 'NR==FNR{a[FNR]=$0; next}
       {
         if ($0 ~ /^diff --git /) { inhdr=1; print a[FNR]; next }
         if ($0 ~ /^@@/)          { inhdr=0; print a[FNR]; next }
         if (inhdr && $0 ~ /^(index |--- |\+\+\+ |old mode |new mode |new file mode |deleted file mode |similarity index |dissimilarity index |rename from |rename to |copy from |copy to |Binary files )/)
              print a[FNR];
         else print $0
       }' "$noent" "$full" > "$tmp" || { echo "✗ склейка дифа не удалась → abort" >&2; _snap_clean; return 1; }
  rm -f "$raw" "$full" "$noent"
  mv -f "$tmp" "$pd/diff.patch"
  echo "$count"
}

self_test() {
  local T fail=0; T="$(mktemp -d)"; trap 'rm -rf "$T"' RETURN
  local repo="$T/repo"; mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@t; git -C "$repo" config user.name t
  printf 'base\n' > "$repo/a.txt"; git -C "$repo" add -A; git -C "$repo" commit -qm init
  # незакоммиченное изменение с секретом
  printf 'base\nnew line key=sk-''ABCD1234efgh5678ijkl9012mnop\n' > "$repo/a.txt"
  local pd="$T/run"; mkdir -p "$pd"
  local n; n="$(snapshot "$repo" "$pd" working)"
  [ "$n" = "1" ] || { echo "✗ expected 1 changed file, got $n"; fail=1; }
  [ -f "$pd/diff.patch" ] || { echo "✗ diff.patch not written"; fail=1; }
  grep -Eq 'sk-[A-Za-z0-9]' "$pd/diff.patch" && { echo "✗ secret leaked into diff.patch"; fail=1; }
  grep -q '‹REDACTED' "$pd/diff.patch" || { echo "✗ strip didn't run on diff"; fail=1; }
  grep -qx 'a.txt' "$pd/changed_files.txt" || { echo "✗ changed_files.txt wrong"; fail=1; }
  # ── ИМЕНА ФАЙЛОВ В ЗАГОЛОВКАХ ДИФА (2026-08-19) ─────────────────────────────
  # Дефект: Shannon-эвристика strip-а съедала пути ("/" склеивал сегменты в один
  # высокоэнтропийный токен), и роли /finalize на КАЖДОМ прогоне получали диф, в котором
  # не видно, к какому файлу относится хунк. Проверяем на вложенном пути — плоский a.txt
  # слишком короткий, чтобы поймать регресс.
  mkdir -p "$repo/skills/_shared/external-judge"
  printf 'ok\n' > "$repo/skills/_shared/external-judge/config.sh"
  git -C "$repo" add -A; git -C "$repo" commit -qm nested
  printf 'ok\nchanged\n' > "$repo/skills/_shared/external-judge/config.sh"
  local pd3="$T/run3"; mkdir -p "$pd3"; snapshot "$repo" "$pd3" working >/dev/null
  grep -q 'skills/_shared/external-judge/config.sh' "$pd3/diff.patch" \
    || { echo "✗ путь файла уничтожен strip-ом в заголовке дифа (роли не увидят, что за файл)"; fail=1; }
  grep -q '‹REDACTED' "$pd3/diff.patch" \
    && { echo "✗ ложная редакция в дифе без секретов"; fail=1; }
  # ── ДВА ПРОХОДА: заголовок целый И секрет со слэшем в ТЕЛЕ затёрт ────────────
  # Раньше эти два свойства конфликтовали: чинили заголовки — теряли защиту от секретов
  # со слэшем (AWS-подобных). Теперь оба обязаны держаться одновременно.
  printf 'ok\nkey=wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY\n' > "$repo/skills/_shared/external-judge/config.sh"
  local pd4="$T/run4"; mkdir -p "$pd4"; snapshot "$repo" "$pd4" working >/dev/null
  grep -q 'skills/_shared/external-judge/config.sh' "$pd4/diff.patch" \
    || { echo "✗ два прохода: имя файла в заголовке потеряно"; fail=1; }
  grep -q 'wJalrXUtnFEMI' "$pd4/diff.patch" \
    && { echo "✗ два прохода: секрет со слэшем прошёл в тело дифа"; fail=1; }
  grep -q '‹REDACTED' "$pd4/diff.patch" \
    || { echo "✗ два прохода: секрет не затёрт вовсе"; fail=1; }
  # ── ГЛАВНЫЙ EDGE-CASE ДВУХПРОХОДНОЙ СХЕМЫ (нашёл внешний судья 2026-08-20) ───
  # Удалённая строка SQL/Lua-комментария `-- key=…` выглядит в дифе как `--- key=…`
  # и при регексп-детекции заголовка уезжала в --no-entropy вместе с секретом.
  # Заголовок обязан определяться СОСТОЯНИЕМ (зона от `diff --git` до первого `@@`).
  printf 'base\n-- key=wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY\n' > "$repo/a.txt"
  git -C "$repo" add -A; git -C "$repo" commit -qm sqlcomment
  printf 'base\n' > "$repo/a.txt"      # теперь строка УДАЛЕНА → в дифе станет "--- key=…"
  local pd5="$T/run5"; mkdir -p "$pd5"; snapshot "$repo" "$pd5" working >/dev/null
  grep -q 'wJalrXUtnFEMI' "$pd5/diff.patch" \
    && { echo "✗ секрет в удалённой строке '-- key=' пережил редакцию (заголовок детектится регекспом, а не состоянием)"; fail=1; }
  grep -q '^--- a/a.txt' "$pd5/diff.patch" \
    || { echo "✗ настоящий заголовок --- a/a.txt потерян"; fail=1; }
  # empty diff case
  git -C "$repo" add -A; git -C "$repo" commit -qm change
  local pd2="$T/run2"; mkdir -p "$pd2"
  [ "$(snapshot "$repo" "$pd2" working)" = "0" ] || { echo "✗ clean tree should be 0"; fail=1; }

  [ "$fail" -eq 0 ] && { echo "✓ snapshot self-test passed"; return 0; } || { echo "✗ snapshot FAILED"; return 1; }
}

case "${1:-}" in
  --self-test) self_test ;;
  "") echo "usage: snapshot.sh <cwd> <project_dir> <mode> [ref] | --self-test" >&2; exit 64 ;;
  *) snapshot "$@" ;;
esac

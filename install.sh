#!/usr/bin/env bash
# redkit install — раскладывает core/ → ~/.claude/core и skills/* → ~/.claude/skills/*.
# Симлинки skills/<s>/lib/<kernel> → ../../../core/<file> резолвятся одинаково в репо и после install
# (skills/<s>/lib → ../../../core == ~/.claude/core). Канон-симлинки не переписываются.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CLAUDE="${CLAUDE_DIR:-$HOME/.claude}"
mkdir -p "$CLAUDE/skills" "$CLAUDE/core"

echo "▶ core → $CLAUDE/core"
cp -R "$HERE/core/." "$CLAUDE/core/"
chmod +x "$CLAUDE/core/"*.sh 2>/dev/null || true

echo "▶ skills → $CLAUDE/skills (симлинки сохраняются)"
# ⚠️ rm -rf сносит ВЕСЬ каталог скилла, а накопленные рантайм-данные намеренно в
# .gitignore — то есть их нет в репо, и переустановка их уничтожала. На 2026-08-26 под
# ударом: 116 learnings + 16 closed у plan-panel, 13 версий промптов ролей, feedback
# redloft, redjob/jobs.yaml (24 КБ), redbrain/golden/aliases.txt, bridge/mac/state.
#
# ⚠️ Список НЕ ведём руками. Первая редакция перечисляла (feedback roles/_history) и
# утверждала «ровно то, что .gitignore не публикует» — это было ЛОЖНО: покрыто 2 паттерна
# из 8, jobs.yaml продолжал уничтожаться. Поймано finalize 6d0cc3ba. Теперь спрашиваем
# у самого git: что он игнорирует, то и спасаем — список не может разъехаться с правилом.
STASH="$(mktemp -d)"
# Аварийный выход не должен молча уносить спасённое вместе с собой.
trap 'echo "⚠️  прервано. Спасённые данные: $STASH" >&2' ERR INT TERM

_preserve_list() { # $1=dst — что здесь игнорируется гитом (значит, в репо этого нет)
  local dst="$1"
  [ -d "$dst" ] || return 0
  ( cd "$dst" 2>/dev/null || exit 0
    find . -mindepth 1 \( -type f -o -type d \) -print0 2>/dev/null \
      | git -C "$HERE" check-ignore --stdin -z 2>/dev/null ) || true
}

for s in "$HERE"/skills/*/; do
  name="$(basename "$s")"
  dst="$CLAUDE/skills/$name"

  # 1. спасти всё, что git игнорирует (= чего нет в репо), сохранив пути
  saved=0
  if [ -d "$dst" ]; then
    while IFS= read -r -d '' rel; do
      rel="${rel#./}"
      [ -e "$dst/$rel" ] || continue
      mkdir -p "$STASH/$name/$(dirname "$rel")"
      cp -R "$dst/$rel" "$STASH/$name/$rel" 2>/dev/null && saved=$((saved+1))
    done < <(_preserve_list "$dst")
  fi

  # 2. собрать новое дерево РЯДОМ и подменить атомарно — чтобы не было окна,
  #    в котором старое уже снесено, а новое ещё не разложено.
  rm -rf "$dst.new"
  cp -R "$s" "$dst.new"

  # 3. вернуть спасённое в новое дерево; файлы ИЗ РЕПО не затирать (-n)
  if [ -d "$STASH/$name" ]; then
    ( cd "$STASH/$name" && find . -mindepth 1 -type f -print0 ) 2>/dev/null \
      | while IFS= read -r -d '' f; do
          f="${f#./}"
          mkdir -p "$dst.new/$(dirname "$f")"
          cp -n "$STASH/$name/$f" "$dst.new/$f" 2>/dev/null || true
        done
    [ "$saved" -gt 0 ] && echo "  ↺ сохранено объектов: $saved ($name)"
  fi

  rm -rf "$dst.old" 2>/dev/null || true
  [ -e "$dst" ] && mv "$dst" "$dst.old"
  mv "$dst.new" "$dst"
  rm -rf "$dst.old"

  chmod +x "$dst/lib/"*.sh 2>/dev/null || true
done
trap - ERR INT TERM
rm -rf "$STASH"

echo "▶ runtime-deps check"
miss=0
for s in "$HERE"/skills/*/; do
  d="${s}deps.txt"; [ -f "$d" ] || continue
  while read -r dep; do
    dep="$(printf '%s' "$dep" | sed 's/#.*//;s/[[:space:]]//g')"; [ -n "$dep" ] || continue
    [ -d "$CLAUDE/skills/$dep" ] || { echo "  ⚠ $(basename "$s") → runtime-skill '$dep' не установлен (установи отдельно)"; miss=1; }
  done < "$d"
done
[ "$miss" -eq 0 ] && echo "  ✓ все runtime-deps на месте"

echo
echo "✓ redkit установлен: core + $(find "$HERE/skills" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ') skills в $CLAUDE"
echo "  self-test: bash $CLAUDE/core/test-core.sh && bash $CLAUDE/skills/redwork/lib/test-redwork.sh"

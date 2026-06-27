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
for s in "$HERE"/skills/*/; do
  name="$(basename "$s")"
  rm -rf "$CLAUDE/skills/$name"
  cp -R "$s" "$CLAUDE/skills/$name"
  chmod +x "$CLAUDE/skills/$name/lib/"*.sh 2>/dev/null || true
done

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

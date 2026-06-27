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
  if ! "${diffcmd[@]}" 2>/dev/null | "$STRIP" > "$tmp"; then echo "✗ strip failed → abort, no diff written" >&2; rm -f "$tmp"; return 1; fi
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
  _SK="sk-""ABCD1234efgh5678ijkl9012mnop"  # split literal (push-protection safe)
  printf 'base\nnew line key=%s\n' "$_SK" > "$repo/a.txt"
  local pd="$T/run"; mkdir -p "$pd"
  local n; n="$(snapshot "$repo" "$pd" working)"
  [ "$n" = "1" ] || { echo "✗ expected 1 changed file, got $n"; fail=1; }
  [ -f "$pd/diff.patch" ] || { echo "✗ diff.patch not written"; fail=1; }
  grep -Eq 'sk-[A-Za-z0-9]' "$pd/diff.patch" && { echo "✗ secret leaked into diff.patch"; fail=1; }
  grep -q '‹REDACTED' "$pd/diff.patch" || { echo "✗ strip didn't run on diff"; fail=1; }
  grep -qx 'a.txt' "$pd/changed_files.txt" || { echo "✗ changed_files.txt wrong"; fail=1; }
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

#!/usr/bin/env bash
# atomic-append.sh — crash-safe append-one-line to a JSONL file via
# copy→append→fsync→rename (plan: "*.tmp→fsync→mv"). rename(2) is atomic on a
# single filesystem, so a crash leaves either the old file or the fully-appended
# new one — never a half-written line.
#
# Usage:
#   source lib/atomic-append.sh
#   atomic_append <file> <single-line-string>
#   atomic_write  <file> <multiline-string>      # full-file atomic replace

atomic_append() {
  local file="$1" line="$2"
  local dir tmp; dir=$(dirname "$file")
  tmp="$dir/.$(basename "$file").tmp.$$"
  if [ -f "$file" ]; then cp "$file" "$tmp"; else : > "$tmp"; fi
  printf '%s\n' "$line" >> "$tmp"
  # best-effort durability before the atomic swap
  { command -v sync >/dev/null 2>&1 && sync; } 2>/dev/null || true
  mv -f "$tmp" "$file"
}

atomic_write() {
  local file="$1" content="$2"
  local dir tmp; dir=$(dirname "$file")
  tmp="$dir/.$(basename "$file").tmp.$$"
  printf '%s' "$content" > "$tmp"
  { command -v sync >/dev/null 2>&1 && sync; } 2>/dev/null || true
  mv -f "$tmp" "$file"
}

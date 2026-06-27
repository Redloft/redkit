#!/usr/bin/env bash
# redsemantic run management — list / status / path / cleanup. Pure bash + jq.
# Зеркало redresearch/lib/manage.sh. No agents, no API.
#
# Usage:
#   manage.sh list
#   manage.sh status <slug-or-dirname>
#   manage.sh path   <slug-or-dirname>
#   manage.sh cleanup [--older-than 30d] [--dry-run]
#
# DATA_ROOT honours $REDSEMANTIC_DATA_DIR (same as persist.sh).
set -euo pipefail

DATA_ROOT="${REDSEMANTIC_DATA_DIR:-$HOME/Library/Application Support/redsemantic}"
RUNS="$DATA_ROOT/runs"

cmd="${1:-}"; shift 2>/dev/null || true

_resolve_dir() { # <slug-or-dirname> → run dir path (newest match), or empty
  local q="$1"
  [ -d "$RUNS" ] || return 0
  if [ -d "$RUNS/$q" ]; then printf '%s\n' "$RUNS/$q"; return 0; fi
  ls -1 "$RUNS" 2>/dev/null | grep -E -- "-${q}$" | sort -r | head -1 | while read -r d; do printf '%s\n' "$RUNS/$d"; done
}

case "$cmd" in
  list)
    [ -d "$RUNS" ] || { echo "(no runs yet at $RUNS)"; exit 0; }
    printf '%-32s %-9s %-11s %-9s %s\n' "RUN" "MODE" "STATUS" "PHASE" "TOPIC"
    for d in $(ls -1 "$RUNS" 2>/dev/null | sort -r); do
      sj="$RUNS/$d/status.json"; rs="$RUNS/$d/run-spec.json"
      mode="?"; status="no-status"; ph="?"; topic=""
      if [ -r "$sj" ]; then
        mode=$(jq -r '.mode // "?"' "$sj" 2>/dev/null || echo "?")
        status=$(jq -r '.status // "?"' "$sj" 2>/dev/null || echo "?")
        ph=$(jq -r '.phase // "?"' "$sj" 2>/dev/null || echo "?")
      fi
      [ -r "$rs" ] && topic=$(jq -r '.topic // ""' "$rs" 2>/dev/null | head -c 50 || true)
      printf '%-32s %-9s %-11s %-9s %s\n' "${d:0:32}" "$mode" "$status" "$ph" "$topic"
    done
    ;;

  status)
    [ -n "${1:-}" ] || { echo "usage: manage.sh status <slug-or-dirname>" >&2; exit 64; }
    dir=$(_resolve_dir "$1")
    [ -n "$dir" ] && [ -d "$dir" ] || { echo "✗ no run matching: $1" >&2; exit 1; }
    [ -r "$dir/status.json" ] || { echo "✗ no status.json in $dir" >&2; exit 1; }
    jq . "$dir/status.json"
    pid=$(jq -r '.worker_pid // empty' "$dir/status.json" 2>/dev/null)
    st=$(jq -r '.status // empty' "$dir/status.json" 2>/dev/null)
    if [ "$st" = "running" ]; then
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then echo "→ worker pid $pid ALIVE"
      else echo "→ ⚠️  status=running but worker pid $pid is DEAD → stale (use /redsemantic-resume)"; fi
    fi
    ;;

  path)
    [ -n "${1:-}" ] || { echo "usage: manage.sh path <slug-or-dirname>" >&2; exit 64; }
    dir=$(_resolve_dir "$1")
    [ -n "$dir" ] && [ -d "$dir" ] || { echo "✗ no run matching: $1" >&2; exit 1; }
    printf '%s\n' "$dir"
    ;;

  cleanup)
    DAYS=30; DRY=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --older-than) DAYS="${2%d}"; shift 2 ;;
        --older-than=*) DAYS="${1#*=}"; DAYS="${DAYS%d}"; shift ;;
        --dry-run) DRY=1; shift ;;
        *) echo "unknown cleanup arg: $1" >&2; exit 64 ;;
      esac
    done
    printf '%s' "$DAYS" | grep -qE '^[0-9]+$' || { echo "✗ --older-than expects Nd (e.g. 30d)" >&2; exit 64; }
    [ -d "$RUNS" ] || { echo "(no runs to clean)"; exit 0; }

    echo "Cleanup: runs older than ${DAYS}d in $RUNS$([ "$DRY" -eq 1 ] && echo ' (dry-run)')"
    freed=0; removed=0; kept_running=0
    while IFS= read -r dir; do
      [ -n "$dir" ] || continue
      sj="$dir/status.json"
      if [ -r "$sj" ]; then
        st=$(jq -r '.status // ""' "$sj" 2>/dev/null || true)
        pid=$(jq -r '.worker_pid // empty' "$sj" 2>/dev/null || true)
        if [ "$st" = "running" ] && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
          echo "  keep (running): $(basename "$dir")"; kept_running=$((kept_running+1)); continue
        fi
      fi
      sz=$(du -sk "$dir" 2>/dev/null | cut -f1 || true); sz=${sz:-0}
      if [ "$DRY" -eq 1 ]; then
        echo "  would remove: $(basename "$dir") (${sz}KB)"
      else
        rm -rf "$dir" && echo "  removed: $(basename "$dir") (${sz}KB)"
      fi
      freed=$((freed + sz)); removed=$((removed + 1))
    done < <(find "$RUNS" -maxdepth 1 -mindepth 1 -type d -mtime "+${DAYS}" 2>/dev/null)

    echo "—"
    printf '%s %d run(s), %d MB. Kept %d running.\n' \
      "$([ "$DRY" -eq 1 ] && echo 'Would free' || echo 'Freed')" \
      "$removed" "$((freed / 1024))" "$kept_running"
    ;;

  *)
    echo "usage: manage.sh {list|status <slug>|path <slug>|cleanup [--older-than 30d] [--dry-run]}" >&2
    exit 64
    ;;
esac

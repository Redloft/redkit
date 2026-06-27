#!/usr/bin/env bash
# redreference run management — list / status / path / cleanup / rebuild-index /
# kill. Pure bash + jq, no agents. Skill-specific (not vendored).
#
# Usage:
#   manage.sh list
#   manage.sh status <slug-or-dirname>
#   manage.sh path   <slug-or-dirname>
#   manage.sh cleanup [--older-than 30d] [--prune-screenshots] [--dry-run]
#   manage.sh rebuild-index <slug-or-dirname>     # derivatives ← committed (RUNBOOK#6)
#   manage.sh kill <slug-or-dirname>              # stop a leaked feedback-server by pid
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_ROOT="${REDREFERENCE_DATA_DIR:-$HOME/Library/Application Support/redreference}"
RUNS="$DATA_ROOT/runs"

cmd="${1:-}"; shift 2>/dev/null || true

_resolve_dir() {
  local q="$1"
  # accept an absolute/relative run-dir path directly (robust for callers)
  if [ -d "$q" ] && [ -f "$q/status.json" ]; then printf '%s\n' "$q"; return 0; fi
  [ -d "$RUNS" ] || return 0
  if [ -d "$RUNS/$q" ]; then printf '%s\n' "$RUNS/$q"; return 0; fi
  ls -1 "$RUNS" 2>/dev/null | grep -E -- "-${q}$" | sort -r | head -1 | while read -r d; do printf '%s\n' "$RUNS/$d"; done
}

case "$cmd" in
  list)
    [ -d "$RUNS" ] || { echo "(no runs yet at $RUNS)"; exit 0; }
    printf '%-34s %-9s %-11s %-7s %s\n' "RUN" "MODE" "STATUS" "ROUND" "SLUG"
    for d in $(ls -1 "$RUNS" 2>/dev/null | sort -r); do
      sj="$RUNS/$d/status.json"
      mode="?"; status="no-status"; rnd="?"; slug=""
      if [ -r "$sj" ]; then
        mode=$(jq -r '.mode // "?"' "$sj" 2>/dev/null || echo "?")
        status=$(jq -r '.status // "?"' "$sj" 2>/dev/null || echo "?")
        rnd=$(jq -r '.last_committed_round // "?"' "$sj" 2>/dev/null || echo "?")
        slug=$(jq -r '.slug // ""' "$sj" 2>/dev/null || true)
      fi
      printf '%-34s %-9s %-11s %-7s %s\n' "${d:0:34}" "$mode" "$status" "$rnd" "$slug"
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
    fsp=$(jq -r '.feedback_server.pid // empty' "$dir/status.json" 2>/dev/null)
    if [ "$st" = "running" ]; then
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then echo "→ worker pid $pid ALIVE"
      else echo "→ ⚠️  status=running but worker pid $pid is DEAD → stale (use /redreference-resume)"; fi
    fi
    [ -n "$fsp" ] && kill -0 "$fsp" 2>/dev/null && echo "→ feedback-server pid $fsp ALIVE (manage.sh kill to stop)"
    ;;

  path)
    [ -n "${1:-}" ] || { echo "usage: manage.sh path <slug-or-dirname>" >&2; exit 64; }
    dir=$(_resolve_dir "$1")
    [ -n "$dir" ] && [ -d "$dir" ] || { echo "✗ no run matching: $1" >&2; exit 1; }
    printf '%s\n' "$dir"
    ;;

  rebuild-index)
    [ -n "${1:-}" ] || { echo "usage: manage.sh rebuild-index <slug-or-dirname>" >&2; exit 64; }
    dir=$(_resolve_dir "$1")
    [ -n "$dir" ] && [ -d "$dir" ] || { echo "✗ no run matching: $1" >&2; exit 1; }
    # shellcheck source=/dev/null
    source "$HERE/wal.sh"
    wal_rebuild_index "$dir"
    echo "✅ derivatives rebuilt from committed rounds in $(basename "$dir")"
    ;;

  kill)
    [ -n "${1:-}" ] || { echo "usage: manage.sh kill <slug-or-dirname>" >&2; exit 64; }
    dir=$(_resolve_dir "$1")
    [ -n "$dir" ] && [ -d "$dir" ] || { echo "✗ no run matching: $1" >&2; exit 1; }
    fsp=$(jq -r '.feedback_server.pid // empty' "$dir/status.json" 2>/dev/null)
    if [ -n "$fsp" ] && kill -0 "$fsp" 2>/dev/null; then
      kill "$fsp" 2>/dev/null && echo "stopped feedback-server pid $fsp"
    else
      echo "(no live feedback-server for $1)"
    fi
    # shellcheck source=/dev/null
    source "$HERE/heartbeat.sh"; clear_feedback_server "$dir" 2>/dev/null || true
    ;;

  cleanup)
    DAYS=30; DRY=0; PRUNE_SS=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --older-than) DAYS="${2%d}"; shift 2 ;;
        --older-than=*) DAYS="${1#*=}"; DAYS="${DAYS%d}"; shift ;;
        --prune-screenshots) PRUNE_SS=1; shift ;;
        --dry-run) DRY=1; shift ;;
        *) echo "unknown cleanup arg: $1" >&2; exit 64 ;;
      esac
    done
    printf '%s' "$DAYS" | grep -qE '^[0-9]+$' || { echo "✗ --older-than expects Nd" >&2; exit 64; }
    [ -d "$RUNS" ] || { echo "(no runs to clean)"; exit 0; }

    # storage warning if total > 1GB
    total_kb=$(du -sk "$RUNS" 2>/dev/null | cut -f1 || echo 0)
    [ "${total_kb:-0}" -gt 1048576 ] && echo "⚠️  redreference runs total $((total_kb/1024))MB (>1GB) — consider cleanup"

    if [ "$PRUNE_SS" -eq 1 ]; then
      echo "Pruning screenshots of runs older than ${DAYS}d$([ "$DRY" -eq 1 ] && echo ' (dry-run)')"
      while IFS= read -r dir; do
        [ -n "$dir" ] && [ -d "$dir/screenshots" ] || continue
        if [ "$DRY" -eq 1 ]; then echo "  would prune: $(basename "$dir")/screenshots"
        else rm -rf "$dir/screenshots" && mkdir -p "$dir/screenshots" && echo "  pruned: $(basename "$dir")/screenshots"; fi
      done < <(find "$RUNS" -maxdepth 1 -mindepth 1 -type d -mtime "+${DAYS}" 2>/dev/null)
    fi

    echo "Cleanup: runs older than ${DAYS}d$([ "$DRY" -eq 1 ] && echo ' (dry-run)')"
    removed=0; kept=0
    while IFS= read -r dir; do
      [ -n "$dir" ] || continue
      sj="$dir/status.json"
      if [ -r "$sj" ]; then
        st=$(jq -r '.status // ""' "$sj" 2>/dev/null || true)
        pid=$(jq -r '.worker_pid // empty' "$sj" 2>/dev/null || true)
        if [ "$st" = "running" ] && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
          echo "  keep (running): $(basename "$dir")"; kept=$((kept+1)); continue
        fi
      fi
      if [ "$DRY" -eq 1 ]; then echo "  would remove: $(basename "$dir")"
      else rm -rf "$dir" && echo "  removed: $(basename "$dir")"; fi
      removed=$((removed+1))
    done < <(find "$RUNS" -maxdepth 1 -mindepth 1 -type d -mtime "+${DAYS}" 2>/dev/null)
    printf '%s %d run(s). Kept %d running.\n' "$([ "$DRY" -eq 1 ] && echo 'Would remove' || echo 'Removed')" "$removed" "$kept"
    ;;

  *)
    echo "usage: manage.sh {list|status <slug>|path <slug>|rebuild-index <slug>|kill <slug>|cleanup [--older-than 30d] [--prune-screenshots] [--dry-run]}" >&2
    exit 64
    ;;
esac

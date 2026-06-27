#!/usr/bin/env bash
# redreference state machine: atomic status.json writer + stale detector.
# Single source of truth: status.json. status.last_committed_round is the WAL
# recovery anchor (see lib/wal.sh, plan D1). Skill-specific copy of the
# redresearch heartbeat (different phase/event enums) — NOT vendored.
#
# status.json writes are serialized by a portable mkdir-lock (.status.lockdir).
# This is the status-file equivalent of with-lock.sh; derivative shared files
# (captures-index.json, visual-taste-profile.json) use flock via with-lock.sh.
#
# Usage:
#   source lib/heartbeat.sh
#   init_status <run_dir> <slug> <mode> <run_id>
#   write_status <run_dir> <phase> [status=running] [exit_code=null]
#   read_status <run_dir> <field>
#   set_committed_round <run_dir> <N>
#   set_feedback_server <run_dir> <pid> <port>
#   clear_feedback_server <run_dir>
#   set_stop_reason <run_dir> <reason>
#   set_workflow_id <run_dir> <wf_id>
#   detect_stale <run_dir>  → echo "stale"|"running"|"idle"|"completed"|"failed"

ALLOWED_STATUS="pending running completed failed cancelled interrupted"
ALLOWED_PHASE="init brief hunt curate page round taste render done"
ALLOWED_STOP_REASON="user_done converged round_cap zero_like_streak error no_results"

# ── internal: run a jq-transform on status.json under the mkdir-lock ──
_status_locked_update() {
  # <run_dir> <jq_filter> [jq args...]
  local run_dir="$1"; shift
  local jq_filter="$1"; shift
  local target="$run_dir/status.json" tmp="$run_dir/status.json.tmp.$$"
  local lock_dir="$run_dir/.status.lockdir" attempts=0
  while ! mkdir "$lock_dir" 2>/dev/null; do
    attempts=$((attempts + 1))
    [ $attempts -gt 50 ] && rm -rf "$lock_dir" 2>/dev/null
    sleep 0.1
  done
  local rc=0
  jq "$@" "$jq_filter" "$target" > "$tmp" 2>/dev/null || rc=$?
  [ "$rc" -eq 0 ] && { mv -f "$tmp" "$target" || rc=$?; }
  rm -f "$tmp" 2>/dev/null || true
  rmdir "$lock_dir" 2>/dev/null || true
  return "$rc"
}

init_status() {
  local run_dir="$1" slug="$2" mode="$3" run_id="$4"
  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -n \
    --arg sv "1" --arg slug "$slug" --arg mode "$mode" --arg run_id "$run_id" \
    --arg ts "$ts" --arg pid "$$" \
    '{
      schema_version: ($sv|tonumber),
      run_id: $run_id, slug: $slug, mode: $mode,
      status: "pending", phase: "init",
      current_round: 0, last_committed_round: 0,
      feedback_server: null, stop_reason: null,
      started_at: $ts, last_heartbeat: $ts,
      worker_pid: ($pid|tonumber),
      exit_code: null
    }' > "$run_dir/status.json"
}

write_status() {
  # NB: shell-local is `st`, not `status` — zsh has a read-only `status` var.
  local run_dir="$1" phase="${2:-}" st="${3:-running}" exit_code="${4:-null}"
  echo "$ALLOWED_STATUS" | grep -qw "$st" || { echo "invalid status: $st" >&2; return 2; }
  if [ -n "$phase" ]; then
    echo "$ALLOWED_PHASE" | grep -qw "$phase" || { echo "invalid phase: $phase" >&2; return 2; }
  fi
  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local f='.last_heartbeat=$ts | .status=$st'
  [ -n "$phase" ] && f="$f | .phase=\$phase"
  if [ "$exit_code" != "null" ]; then
    f="$f | .exit_code=(\$ec|tonumber)"
    _status_locked_update "$run_dir" "$f" --arg ts "$ts" --arg st "$st" --arg phase "$phase" --arg ec "$exit_code"
  else
    _status_locked_update "$run_dir" "$f" --arg ts "$ts" --arg st "$st" --arg phase "$phase"
  fi
}

# WAL commit anchor — bump only after round-<N>.committed exists (lib/wal.sh)
set_committed_round() {
  local run_dir="$1" n="$2"
  printf '%s' "$n" | grep -qE '^[0-9]+$' || { echo "set_committed_round: N must be int" >&2; return 2; }
  _status_locked_update "$run_dir" '.last_committed_round=($n|tonumber) | .current_round=($n|tonumber)' --arg n "$n"
}

set_feedback_server() {
  local run_dir="$1" pid="$2" port="$3"
  _status_locked_update "$run_dir" '.feedback_server={pid:($p|tonumber),port:($q|tonumber)}' --arg p "$pid" --arg q "$port"
}

clear_feedback_server() {
  _status_locked_update "$1" '.feedback_server=null'
}

set_stop_reason() {
  local run_dir="$1" reason="$2"
  echo "$ALLOWED_STOP_REASON" | grep -qw "$reason" || { echo "invalid stop_reason: $reason" >&2; return 2; }
  _status_locked_update "$run_dir" '.stop_reason=$r' --arg r "$reason"
}

read_status() {
  jq -r ".$2 // empty" "$1/status.json" 2>/dev/null
}

set_workflow_id() {
  local run_dir="$1" wf_id="$2"
  [ -f "$run_dir/status.json" ] || { echo "set_workflow_id: no status.json" >&2; return 1; }
  _status_locked_update "$run_dir" '.workflow_run_id=$w' --arg w "$wf_id"
}

detect_stale() {
  local run_dir="$1"
  [ -f "$run_dir/status.json" ] || { echo "missing"; return; }
  local st pid hb mode
  st=$(jq -r '.status' "$run_dir/status.json" 2>/dev/null)
  pid=$(jq -r '.worker_pid' "$run_dir/status.json" 2>/dev/null)
  hb=$(jq -r '.last_heartbeat' "$run_dir/status.json" 2>/dev/null)
  mode=$(jq -r '.mode' "$run_dir/status.json" 2>/dev/null)
  case "$st" in
    completed|failed|cancelled|interrupted) echo "$st"; return ;;
    pending) echo "idle"; return ;;
    running) ;;
    *) echo "unknown"; return ;;
  esac
  if [ -z "$pid" ] || [ "$pid" = "null" ] || ! kill -0 "$pid" 2>/dev/null; then
    echo "stale"; return
  fi
  # heartbeat freshness — petля вкуса interactive, so threshold generous (gap: backpressure)
  local now hb_ts age max
  now=$(date +%s)
  hb_ts=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$hb" "+%s" 2>/dev/null || echo 0)
  age=$(( now - hb_ts ))
  case "$mode" in
    lite) max=600 ;;
    *) max=3600 ;;   # interactive rounds: user may take a while — 60 min
  esac
  if [ "$age" -gt "$max" ]; then echo "stale"; else echo "running"; fi
}

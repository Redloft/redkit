#!/usr/bin/env bash
# C2 (state machine) atomic status.json writer + stale detector.
# Single source of truth: status.json. write_status защищён mkdir-локом.
# Зеркало redresearch/lib/heartbeat.sh; отличается набором фаз.
#
# Usage:
#   source lib/heartbeat.sh
#   init_status <run_dir> <slug> <mode> <run_id>
#   write_status <run_dir> <phase> [status=running] [exit_code=null]
#   read_status <run_dir> <field>
#   detect_stale <run_dir>  → echo "stale"|"running"|"idle"|"completed"|"failed"

ALLOWED_STATUS="pending running completed failed cancelled interrupted"
ALLOWED_PHASE="init scope seed harvest cluster structure judge render done"

init_status() {
  local run_dir="$1" slug="$2" mode="$3" run_id="$4"
  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -n \
    --arg sv "1" \
    --arg slug "$slug" --arg mode "$mode" --arg run_id "$run_id" \
    --arg ts "$ts" --arg pid "$$" \
    '{
      schema_version: ($sv|tonumber),
      run_id: $run_id, slug: $slug, mode: $mode,
      status: "pending", phase: "init",
      started_at: $ts, last_heartbeat: $ts,
      worker_pid: ($pid|tonumber),
      exit_code: null
    }' > "$run_dir/status.json"
}

write_status() {
  # NB: shell-local is `st`, not `status` — zsh has a read-only special var
  # named `status` (=$?), and this lib is `source`d by the caller under zsh.
  local run_dir="$1" phase="${2:-}" st="${3:-running}" exit_code="${4:-null}"
  local target="$run_dir/status.json"
  local tmp="$target.tmp.$$"

  echo "$ALLOWED_STATUS" | grep -qw "$st" || { echo "invalid status: $st" >&2; return 2; }
  if [ -n "$phase" ]; then
    echo "$ALLOWED_PHASE" | grep -qw "$phase" || { echo "invalid phase: $phase" >&2; return 2; }
  fi

  # Portable atomic lock via mkdir (POSIX, works on macOS without flock)
  local lock_dir="$run_dir/.status.lockdir"
  local attempts=0
  while ! mkdir "$lock_dir" 2>/dev/null; do
    attempts=$((attempts + 1))
    if [ $attempts -gt 50 ]; then
      rm -rf "$lock_dir" 2>/dev/null
    fi
    sleep 0.1
  done
  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local jq_filter='.last_heartbeat = $ts | .status = $status'
  [ -n "$phase" ] && jq_filter="$jq_filter | .phase = \$phase"
  local rc=0
  if [ "$exit_code" != "null" ]; then
    jq_filter="$jq_filter | .exit_code = (\$ec|tonumber)"
    jq --arg ts "$ts" --arg status "$st" --arg phase "$phase" --arg ec "$exit_code" \
      "$jq_filter" "$target" > "$tmp" || rc=$?
  else
    jq --arg ts "$ts" --arg status "$st" --arg phase "$phase" \
      "$jq_filter" "$target" > "$tmp" || rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    mv -f "$tmp" "$target" || rc=$?
  fi
  rm -f "$tmp" 2>/dev/null || true
  rmdir "$lock_dir" 2>/dev/null || true
  return "$rc"
}

read_status() {
  local run_dir="$1" field="$2"
  jq -r ".$field // empty" "$run_dir/status.json" 2>/dev/null
}

# F7 idempotency: persist the Workflow runId so /redsemantic-resume can
# re-invoke with resumeFromRunId — the Workflow tool then returns cached results
# for completed agent() calls and only re-runs the interrupted/remaining ones.
set_workflow_id() {
  local run_dir="$1" wf_id="$2"
  local target="$run_dir/status.json" tmp="$run_dir/status.json.wf.$$"
  [ -f "$target" ] || { echo "set_workflow_id: no status.json" >&2; return 1; }
  jq --arg w "$wf_id" '.workflow_run_id = $w' "$target" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$target" || { rm -f "$tmp" 2>/dev/null; return 1; }
}

# Returns: "running" (pid alive + status=running)
#          "stale" (status=running but pid dead OR last_heartbeat too old)
#          "completed"|"failed"|"cancelled"|"interrupted"|"idle"
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

  local now hb_ts age max
  now=$(date +%s)
  hb_ts=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$hb" "+%s" 2>/dev/null || echo 0)
  age=$(( now - hb_ts ))
  case "$mode" in
    lite) max=120 ;;
    standard) max=300 ;;
    heavy) max=900 ;;
    *) max=600 ;;
  esac
  if [ "$age" -gt "$max" ]; then
    echo "stale"
  else
    echo "running"
  fi
}

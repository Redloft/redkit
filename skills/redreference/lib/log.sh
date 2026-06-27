#!/usr/bin/env bash
# log.sh — structured JSONL event log for redreference (plan D5/D8).
# Single writer per run dir. Append-only. Allowlisted event_type. Every line
# passes scrub_secrets (sanitize.sh) so no credential text ever reaches run.log.
#
# Usage:
#   source lib/log.sh
#   log_init <run_dir> <run_id>
#   log_event <event_type> [k=v ...]
#
# event_type allowlist (plan D5/D8):
#   run_start run_end resume
#   adapter_start adapter_ok adapter_error          (adapter_ok carries latency_ms)
#   robots_blocked fixture_schema_drift card_invalid
#   round_start round_commit                         (round_commit carries flock_wait_ms)
#   taste_update zero_like_streak
#   feedback_server_start feedback_server_stop
#   screenshot_budget_hit index_rebuilt workflow_stop secrets_check

# self-dir, portable across bash (BASH_SOURCE) and zsh (sourced $0)
_LOG_HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=/dev/null
source "$_LOG_HERE/sanitize.sh"

REDREFERENCE_LOG_DIR=""
REDREFERENCE_RUN_ID=""

log_init() {
  REDREFERENCE_LOG_DIR="$1"
  REDREFERENCE_RUN_ID="$2"
  [ -d "$REDREFERENCE_LOG_DIR" ] || { echo "log_init: run dir missing" >&2; return 1; }
  : > "$REDREFERENCE_LOG_DIR/run.log"   # truncate — owner of the run starts fresh
}

# log_attach — attach to an EXISTING run.log without truncating (append-only).
# For subcommands (round.sh next/ingest) that run as separate processes from the
# run owner, so round_start/round_commit reach run.log instead of vanishing.
# Reads run_id from status.json. Idempotent; never resets the log.
log_attach() {
  local run_dir="$1"
  [ -d "$run_dir" ] || return 0
  REDREFERENCE_LOG_DIR="$run_dir"
  REDREFERENCE_RUN_ID=$(jq -r '.run_id // empty' "$run_dir/status.json" 2>/dev/null || echo "")
  [ -f "$run_dir/run.log" ] || : > "$run_dir/run.log"   # create if owner hasn't yet, never truncate existing
  return 0
}

log_event() {
  local event_type="$1"; shift
  case "$event_type" in
    run_start|run_end|resume|\
    adapter_start|adapter_ok|adapter_error|\
    robots_blocked|fixture_schema_drift|card_invalid|\
    round_start|round_commit|taste_update|zero_like_streak|\
    feedback_server_start|feedback_server_stop|\
    screenshot_budget_hit|index_rebuilt|workflow_stop|secrets_check) ;;
    *) echo "log_event: invalid event_type=$event_type" >&2; return 2 ;;
  esac
  # Not attached → silent no-op (return 0). Previously echoed to STDOUT, which
  # polluted callers' protocol output (QUERY=/STOP=). Logging is best-effort.
  [ -n "$REDREFERENCE_LOG_DIR" ] || return 0

  local jq_args=(
    -nc
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    --arg run_id "$REDREFERENCE_RUN_ID"
    --arg event_type "$event_type"
  )
  local jq_obj='{ts: $ts, run_id: $run_id, event_type: $event_type'
  local kv key val
  for kv in "$@"; do
    key="${kv%%=*}"; val="${kv#*=}"
    if printf '%s' "$val" | grep -qE '^-?[0-9]+(\.[0-9]+)?$'; then
      jq_args+=(--argjson "$key" "$val")
    else
      jq_args+=(--arg "$key" "$val")
    fi
    jq_obj+=", $key: \$$key"
  done
  jq_obj+='}'

  jq "${jq_args[@]}" "$jq_obj" 2>/dev/null | scrub_secrets >> "$REDREFERENCE_LOG_DIR/run.log"
}

log_time_start() { date +%s%3N 2>/dev/null || echo 0; }
log_time_ms() { local start="$1"; echo $(( $(date +%s%3N 2>/dev/null || echo 0) - start )); }

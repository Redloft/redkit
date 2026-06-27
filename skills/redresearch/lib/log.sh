#!/usr/bin/env bash
# C3 (F10) Structured JSONL event log for redresearch worker.
# Single writer per run dir (worker only). Append-only. Allowlist event_type.
#
# Usage:
#   source lib/log.sh
#   log_init <run_dir> <run_id>
#   log_event <event_type> [k=v ...]
#
# Allowed event_type: phase_start, phase_done, phase_error,
#   child_spawn, child_exit, heartbeat_miss, tool_call, secrets_check,
#   notify_sent, run_start, run_end, resume

REDRESEARCH_LOG_DIR=""
REDRESEARCH_RUN_ID=""

log_init() {
  REDRESEARCH_LOG_DIR="$1"
  REDRESEARCH_RUN_ID="$2"
  [ -d "$REDRESEARCH_LOG_DIR" ] || { echo "log_init: run dir missing"; return 1; }
  : > "$REDRESEARCH_LOG_DIR/run.log"  # truncate at init
}

# Secrets scrubber — never let raw cookie/key/token text into run.log
_log_scrub() {
  # mask common token prefixes + cookie-like blobs
  sed -E \
    -e 's/(sk-[A-Za-z0-9_-]{8,})/sk-***REDACTED***/g' \
    -e 's/(AIza[A-Za-z0-9_-]{8,})/AIza***REDACTED***/g' \
    -e 's/(ghp_[A-Za-z0-9_-]{8,})/ghp_***REDACTED***/g' \
    -e 's/(op:\/\/[A-Za-z0-9/_.-]+)/op:\/\/***REDACTED***/g' \
    -e 's/(eyJ[A-Za-z0-9_-]{20,})/eyJ***REDACTED***/g' \
    -e 's/("Authorization": *"[^"]+")/"Authorization":"***REDACTED***"/g'
}

log_event() {
  local event_type="$1"; shift
  case "$event_type" in
    phase_start|phase_done|phase_error|child_spawn|child_exit|\
    heartbeat_miss|tool_call|secrets_check|notify_sent|run_start|\
    run_end|resume) ;;
    *) echo "log_event: invalid event_type=$event_type" >&2; return 2 ;;
  esac
  [ -n "$REDRESEARCH_LOG_DIR" ] || { echo "log_event: log_init not called"; return 1; }

  # Build jq args dynamically from kv pairs
  local jq_args=(
    -nc
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    --arg run_id "$REDRESEARCH_RUN_ID"
    --arg event_type "$event_type"
  )
  local jq_obj='{ts: $ts, run_id: $run_id, event_type: $event_type'
  local kv key val
  for kv in "$@"; do
    key="${kv%%=*}"; val="${kv#*=}"
    # numeric detect (heuristic)
    if printf '%s' "$val" | grep -qE '^-?[0-9]+(\.[0-9]+)?$'; then
      jq_args+=(--argjson "$key" "$val")
    else
      jq_args+=(--arg "$key" "$val")
    fi
    jq_obj+=", $key: \$$key"
  done
  jq_obj+='}'

  jq "${jq_args[@]}" "$jq_obj" 2>/dev/null | _log_scrub >> "$REDRESEARCH_LOG_DIR/run.log"
}

# Convenience: time a section
log_time_start() { date +%s%3N; }
log_time_ms() { local start="$1"; echo $(( $(date +%s%3N) - start )); }

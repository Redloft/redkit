#!/usr/bin/env bash
# workflow/worker.sh — background worker PARENT WRAPPER for heavy/ultra runs.
#
# Closes:
#   C2  SIGKILL recovery — worker_pid in status.json is THIS process ($$).
#       Parent wraps the child runner: `wait $child; write_status failed exit=$?`.
#       • SIGKILL of CHILD   → parent gets rc, writes definitive status (works).
#       • SIGKILL of PARENT  → no trap can run; status.json keeps a dead worker_pid,
#                              so the NEXT /research call detects stale via kill -0.
#   W1  Worker↔Workflow contract — explicit exit-code table (below).
#
# ─── EXIT CODES (W1) ───────────────────────────────────────────────
#   0    completed ok
#   1    generic failure (child exited non-zero, unclassified)
#   2    BUSY — another live worker already holds this run's lock
#   3    run-spec.json present but schema-invalid
#   4    --run-dir missing/not-a-dir, or run-spec.json missing/unreadable
#   64   usage error (bad/absent args)            (EX_USAGE)
#   137  child died on SIGKILL (128+9) — propagated verbatim
#   143  worker itself caught SIGTERM (128+15) — status marked failed first
# ───────────────────────────────────────────────────────────────────
#
# Usage:
#   worker.sh --run-dir <dir>
#
# The child runner is pluggable via $RESEARCH_RUNNER_CMD (used by smoke tests).
# Default child = lib/research-runner.py (Phase B). If the runner is absent it
# simply exits non-zero and the wrapper records `failed` — the contract holds.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ─── arg parse ───
RUN_DIR=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --run-dir) RUN_DIR="${2:-}"; shift 2 || { echo "✗ --run-dir needs a value" >&2; exit 64; } ;;
    --run-dir=*) RUN_DIR="${1#*=}"; shift ;;
    -h|--help) echo "usage: worker.sh --run-dir <dir>"; exit 0 ;;
    *) echo "✗ unknown arg: $1" >&2; exit 64 ;;
  esac
done
[ -n "$RUN_DIR" ] || { echo "usage: worker.sh --run-dir <dir>" >&2; exit 64; }
[ -d "$RUN_DIR" ] || { echo "✗ run dir not found: $RUN_DIR" >&2; exit 4; }

SPEC="$RUN_DIR/run-spec.json"
[ -r "$SPEC" ] || { echo "✗ missing run-spec.json in $RUN_DIR" >&2; exit 4; }

# ─── validate spec (C2 + A2.1): required fields, mode enum, slug regex ───
if ! jq -e '
      (.run_id|type=="string" and (.|length>0))
  and (.slug|type=="string" and test("^[a-z0-9-]{1,60}$"))
  and (.mode|. as $m | ["lite","standard","heavy","ultra"]|index($m)!=null)
  and (.topic|type=="string" and (.|length>0))
' "$SPEC" >/dev/null 2>&1; then
  echo "✗ run-spec.json failed schema validation (need run_id, slug, mode∈{lite,standard,heavy,ultra}, topic)" >&2
  exit 3
fi

RUN_ID=$(jq -r '.run_id' "$SPEC")
SLUG=$(jq -r '.slug'   "$SPEC")
MODE=$(jq -r '.mode'   "$SPEC")

# ─── libs ───
# shellcheck source=../lib/heartbeat.sh
source "$SKILL_DIR/lib/heartbeat.sh"
# shellcheck source=../lib/log.sh
source "$SKILL_DIR/lib/log.sh"

# ─── BUSY guard (exit 2): atomic create-or-steal-stale pid lock ───
# The main lock holds ONLY a pid (per design). Distinct from heartbeat's
# .status.lockdir (which serialises individual write_status transactions).
LOCK="$RUN_DIR/.lock"
release_lock() { [ -f "$LOCK" ] && [ "$(cat "$LOCK" 2>/dev/null)" = "$$" ] && rm -f "$LOCK" 2>/dev/null || true; }

if ! ( set -o noclobber; printf '%s\n' "$$" > "$LOCK" ) 2>/dev/null; then
  other="$(cat "$LOCK" 2>/dev/null || true)"
  if [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then
    echo "✗ BUSY: worker pid $other already running for $RUN_DIR" >&2
    exit 2
  fi
  # holder is dead → steal the lock
  printf '%s\n' "$$" > "$LOCK"
fi

# ─── status + log init (worker_pid := $$, the C2 parent) ───
init_status "$RUN_DIR" "$SLUG" "$MODE" "$RUN_ID"
log_init   "$RUN_DIR" "$RUN_ID"
log_event  run_start mode="$MODE"

# ─── C2 trap fabric ───────────────────────────────────────────────
# _finalized: "" until we write a definitive status. Guards against the
# EXIT trap double-writing after an explicit completed/failed write.
_child_pid=""
_finalized=""

on_exit() {
  # Always release the lock. If we somehow exit without a definitive
  # status (unexpected `set -e` abort), record failed so the run never
  # lingers as "running" with a live-but-confused pid.
  if [ -z "$_finalized" ]; then
    write_status "$RUN_DIR" "" failed 1 2>/dev/null || true
    log_event run_end status=failed reason=unexpected_exit 2>/dev/null || true
  fi
  release_lock
}
on_term() {
  # Graceful signal: tear down child, let on_exit mark failed.
  [ -n "$_child_pid" ] && kill "$_child_pid" 2>/dev/null || true
  exit 143
}
trap on_exit EXIT
trap on_term INT TERM

# ─── spawn child runner (pluggable) ───
write_status "$RUN_DIR" scope running
RUNNER_CMD="${RESEARCH_RUNNER_CMD:-python3 \"$SKILL_DIR/lib/research-runner.py\" --run-dir \"$RUN_DIR\"}"

# Spawn in an explicit subshell with inherited traps DISARMED. A bare
# `eval ... &` would inherit our EXIT trap + `set -e`; when the child dies on a
# signal, the backgrounded subshell runs on_exit while unwinding and clobbers
# the propagated 137 into a generic code. Disarming keeps `wait` honest.
# shellcheck disable=SC2086
( trap - EXIT INT TERM; eval "$RUNNER_CMD" ) &
_child_pid=$!
log_event child_spawn pid="$_child_pid"

# Capture rc safely under `set -e` (a failing `wait` must NOT abort us here).
rc=0
wait "$_child_pid" || rc=$?
log_event child_exit exit_code="$rc"

# ─── definitive status (disarm the "unexpected exit" path first) ───
trap - INT TERM
if [ "$rc" -eq 0 ]; then
  write_status "$RUN_DIR" done completed 0
  _finalized="completed"
  log_event run_end status=completed
  exit 0
elif [ "$rc" -ge 128 ]; then
  # child died on a signal (137 = SIGKILL). Record + propagate verbatim.
  write_status "$RUN_DIR" "" failed "$rc"
  _finalized="failed"
  log_event run_end status=failed exit_code="$rc"
  exit "$rc"
else
  write_status "$RUN_DIR" "" failed "$rc"
  _finalized="failed"
  log_event run_end status=failed exit_code="$rc"
  exit 1
fi

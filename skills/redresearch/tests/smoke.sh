#!/usr/bin/env bash
# W5 — redresearch smoke suite. NO live API, hermetic (isolated DATA_DIR).
# Covers: persist.sh, heartbeat (init→completed, stale detect, concurrent writes,
# atomic JSON), log.sh (JSONL valid, secrets scrub, event allowlist),
# worker.sh (W1 exit codes + C2 SIGKILL recovery + BUSY + stale-steal),
# manage.sh (C5 cleanup + running-guard).
#
# Run: bash tests/smoke.sh   → exit 0 if all pass.
set -u

SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$(mktemp -d)"
export REDRESEARCH_DATA_DIR="$SANDBOX/data"
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
no()  { echo "  ✗ $1"; FAIL=$((FAIL+1)); }
eq()  { [ "$2" = "$3" ] && ok "$1 ($3)" || no "$1 — expected '$2' got '$3'"; }
rc_is(){ local e="$1" a="$2" l="$3"; [ "$e" = "$a" ] && ok "$l (rc=$a)" || no "$l — expected rc $e got $a"; }

source "$SKILL/lib/heartbeat.sh"
source "$SKILL/lib/log.sh"

newrun() { # <slug> → echo run_dir
  local out; out=$("$SKILL/lib/persist.sh" "$1"); printf '%s' "${out%|*}"
}

echo "── persist.sh ──"
RD=$(newrun smoke-ok)
[ -d "$RD/sources" ] && [ -d "$RD/phases" ] && ok "creates run dir + subdirs" || no "run dir layout"
"$SKILL/lib/persist.sh" "Bad Slug!" >/dev/null 2>&1; rc_is 1 $? "rejects invalid slug"
( CLAUDECORE_PATH="$REDRESEARCH_DATA_DIR" REDRESEARCH_DATA_DIR="$REDRESEARCH_DATA_DIR/inside" \
  "$SKILL/lib/persist.sh" guard-test >/dev/null 2>&1 ); rc_is 2 $? "Yandex.Disk residency guard (C1)"

echo "── heartbeat ──"
RID=$(uuidgen | tr 'A-Z' 'a-z')
init_status "$RD" smoke-ok lite "$RID"
eq "init → pending/init" "pending" "$(read_status "$RD" status)"
write_status "$RD" hunt running
eq "write → running phase=hunt" "hunt" "$(read_status "$RD" phase)"
eq "detect_stale alive→running" "running" "$(detect_stale "$RD")"
# dead worker pid → stale
jq '.worker_pid=999999' "$RD/status.json" > "$RD/s.tmp" && mv "$RD/s.tmp" "$RD/status.json"
eq "detect_stale dead-pid→stale" "stale" "$(detect_stale "$RD")"
write_status "$RD" done completed 0
eq "write → completed" "completed" "$(read_status "$RD" status)"
eq "  exit_code=0" "0" "$(read_status "$RD" exit_code)"
eq "detect_stale completed→completed" "completed" "$(detect_stale "$RD")"
set_workflow_id "$RD" "wf_smoke123"
eq "set_workflow_id (F7) persists" "wf_smoke123" "$(read_status "$RD" workflow_run_id)"
# 10 concurrent writes → still valid JSON, lock not leaked
RD2=$(newrun concurrent); init_status "$RD2" concurrent lite "$RID"
for i in $(seq 1 10); do write_status "$RD2" hunt running & done; wait
jq -e . "$RD2/status.json" >/dev/null 2>&1 && ok "10 concurrent writes → valid JSON" || no "concurrent JSON corrupt"
[ -d "$RD2/.status.lockdir" ] && no "lockdir leaked" || ok "lockdir cleaned after writes"

echo "── log.sh ──"
log_init "$RD" "$RID"
log_event run_start mode=lite
log_event tool_call note="sk-abcdefgh12345678" key="AIzaSyABCDEFGH1234"
log_event bogus_event_type foo=bar 2>/dev/null; rc_is 2 $? "event_type allowlist rejects bogus"
jq -e . "$RD/run.log" >/dev/null 2>&1 && ok "run.log is valid JSONL" || no "run.log invalid JSONL"
S=$(grep -cE 'sk-abcdefgh|AIzaSyABCDEFGH' "$RD/run.log" 2>/dev/null || true); eq "secrets scrubbed (raw count)" "0" "$S"
grep -q 'REDACTED' "$RD/run.log" && ok "scrubber left REDACTED marker" || no "no REDACTED marker"
grep -q 'bogus_event_type' "$RD/run.log" && no "bogus event leaked into log" || ok "bogus event not written"

echo "── worker.sh (W1 + C2) ──"
W="$SKILL/workflow/worker.sh"
"$W" >/dev/null 2>&1; rc_is 64 $? "no args → 64 usage"
"$W" --run-dir "$SANDBOX/nope" >/dev/null 2>&1; rc_is 4 $? "missing run-dir → 4"
RW=$(newrun worker); "$W" --run-dir "$RW" >/dev/null 2>&1; rc_is 4 $? "missing run-spec → 4"
echo '{"bad":1}' > "$RW/run-spec.json"; "$W" --run-dir "$RW" >/dev/null 2>&1; rc_is 3 $? "invalid spec → 3"
jq -nc --arg id "$RID" '{run_id:$id,slug:"worker",mode:"heavy",topic:"smoke"}' > "$RW/run-spec.json"
RESEARCH_RUNNER_CMD='true' "$W" --run-dir "$RW" >/dev/null 2>&1; rc_is 0 $? "child ok → 0"
eq "  status=completed" "completed" "$(jq -r .status "$RW/status.json")"
RESEARCH_RUNNER_CMD='exit 5' "$W" --run-dir "$RW" >/dev/null 2>&1; rc_is 1 $? "child rc=5 → 1 generic"
eq "  status=failed" "failed" "$(jq -r .status "$RW/status.json")"
KS="$SANDBOX/killself.sh"; printf '#!/usr/bin/env bash\nkill -KILL $$\n' > "$KS"; chmod +x "$KS"
RESEARCH_RUNNER_CMD="bash '$KS'" "$W" --run-dir "$RW" >/dev/null 2>&1; rc_is 137 $? "child SIGKILL → 137 (C2)"
eq "  status=failed exit=137" "137" "$(jq -r .exit_code "$RW/status.json")"
# BUSY: a live holder owns the lock
sleep 20 & H=$!; printf '%s\n' "$H" > "$RW/.lock"
RESEARCH_RUNNER_CMD='true' "$W" --run-dir "$RW" >/dev/null 2>&1; rc_is 2 $? "live lock → 2 BUSY"
kill "$H" 2>/dev/null; rm -f "$RW/.lock"
# stale lock (dead pid) is stolen
echo 999999 > "$RW/.lock"
RESEARCH_RUNNER_CMD='true' "$W" --run-dir "$RW" >/dev/null 2>&1; rc_is 0 $? "stale lock stolen → 0"

echo "── manage.sh (C5) ──"
M="$SKILL/lib/manage.sh"
"$M" list >/dev/null 2>&1; rc_is 0 $? "list ok"
"$M" status worker >/dev/null 2>&1; rc_is 0 $? "status by slug"
# backdate the worker run; verify cleanup dry-run flags it, real run removes it
touch -t "$(date -v-90d +%Y%m%d%H%M 2>/dev/null || date -d '90 days ago' +%Y%m%d%H%M)" "$RW" 2>/dev/null || true
"$M" cleanup --older-than 30d --dry-run 2>&1 | grep -q 'would remove' && ok "cleanup dry-run flags old run" || no "cleanup dry-run"
N_BEFORE=$(ls -1 "$REDRESEARCH_DATA_DIR/runs" | wc -l | tr -d ' ')
"$M" cleanup --older-than 30d >/dev/null 2>&1
N_AFTER=$(ls -1 "$REDRESEARCH_DATA_DIR/runs" | wc -l | tr -d ' ')
[ "$N_AFTER" -lt "$N_BEFORE" ] && ok "cleanup removed old run (${N_BEFORE} -> ${N_AFTER})" || no "cleanup removed nothing"

echo ""
echo "════════ $PASS passed, $FAIL failed ════════"
[ "$FAIL" -eq 0 ]

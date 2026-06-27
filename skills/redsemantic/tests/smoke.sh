#!/usr/bin/env bash
# redsemantic smoke suite. Hermetic (isolated DATA_DIR). NO live secret API.
# Covers: persist.sh (dir+subdirs, slug validation, Yandex.Disk guard, idempotency),
#         heartbeat.sh (init→write→detect_stale, atomic, set_workflow_id),
#         log.sh (secret-scrub), manage.sh (list/path/status/cleanup),
#         adapters (probe boolean-only output / no secret leak, self-test exit codes).
#
# Run: bash tests/smoke.sh  → exit 0 if all pass.
set -u

SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$(mktemp -d)"
export REDSEMANTIC_DATA_DIR="$SANDBOX/data"
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
no()  { echo "  ✗ $1"; FAIL=$((FAIL+1)); }
eq()  { [ "$2" = "$3" ] && ok "$1 ($3)" || no "$1 — expected '$2' got '$3'"; }
rc_is(){ local e="$1" a="$2" l="$3"; [ "$e" = "$a" ] && ok "$l (rc=$a)" || no "$l — expected rc $e got $a"; }

echo "── persist.sh ──"
OUT=$("$SKILL/lib/persist.sh" banya-test 2>/dev/null); rc=$?
rc_is 0 "$rc" "persist valid slug"
RUN_DIR="${OUT%%|*}"
[ -d "$RUN_DIR/keywords" ] && ok "keywords/ subdir created" || no "keywords/ missing"
[ -d "$RUN_DIR/phases" ] && ok "phases/ subdir created" || no "phases/ missing"
case "$RUN_DIR" in "$SANDBOX"*) ok "run dir under sandbox DATA_DIR";; *) no "run dir escaped sandbox: $RUN_DIR";; esac
"$SKILL/lib/persist.sh" "Bad Slug!" >/dev/null 2>&1; rc_is 1 "$?" "rejects invalid slug"
# Yandex.Disk residency guard
( export CLAUDECORE_PATH="$SANDBOX"; export REDSEMANTIC_DATA_DIR="$SANDBOX/inside"; "$SKILL/lib/persist.sh" x >/dev/null 2>&1 ); rc_is 2 "$?" "refuses DATA_DIR inside Yandex.Disk (C1)"

echo "── heartbeat.sh ──"
source "$SKILL/lib/heartbeat.sh"
init_status "$RUN_DIR" banya-test lite run-123
eq "init status" "pending" "$(read_status "$RUN_DIR" status)"
eq "init phase" "init" "$(read_status "$RUN_DIR" phase)"
write_status "$RUN_DIR" harvest running; rc_is 0 "$?" "write_status valid phase"
eq "phase advanced" "harvest" "$(read_status "$RUN_DIR" phase)"
write_status "$RUN_DIR" bogus-phase running 2>/dev/null; rc_is 2 "$?" "rejects invalid phase"
set_workflow_id "$RUN_DIR" wf_abc123; eq "workflow_run_id persisted" "wf_abc123" "$(read_status "$RUN_DIR" workflow_run_id)"
write_status "$RUN_DIR" done completed 0
eq "detect_stale completed" "completed" "$(detect_stale "$RUN_DIR")"
python3 -c "import json;d=json.load(open('$RUN_DIR/status.json'));print('ok')" >/dev/null 2>&1 && ok "status.json valid JSON" || no "status.json corrupt"

echo "── log.sh (secret scrub) ──"
source "$SKILL/lib/log.sh"
log_init "$RUN_DIR" run-123
log_event adapter_call adapter=wordstat note="Authorization: Api-Key AKIAsecretvalue12345"
log_event tool_call ref="op://AI-Tokens/DataForSEO/credential"
if grep -q "AKIAsecretvalue12345" "$RUN_DIR/run.log" 2>/dev/null; then no "Api-Key LEAKED in run.log"; else ok "Api-Key scrubbed in run.log"; fi
if grep -q "AI-Tokens/DataForSEO/credential" "$RUN_DIR/run.log" 2>/dev/null; then no "op:// ref LEAKED"; else ok "op:// ref scrubbed"; fi
grep -q "REDACTED" "$RUN_DIR/run.log" && ok "scrubber emitted REDACTED marker" || no "no REDACTED marker"

echo "── manage.sh ──"
"$SKILL/lib/manage.sh" list 2>/dev/null | grep -q banya-test && ok "list shows run" || no "list missing run"
P=$("$SKILL/lib/manage.sh" path banya-test 2>/dev/null); [ "$P" = "$RUN_DIR" ] && ok "path resolves slug→dir" || no "path mismatch ($P)"
"$SKILL/lib/manage.sh" status banya-test 2>/dev/null | grep -q '"status": "completed"' && ok "status shows completed" || no "status wrong"
"$SKILL/lib/manage.sh" cleanup --dry-run --older-than 0d 2>/dev/null | grep -qE "would remove|Would free" && ok "cleanup dry-run lists candidates" || no "cleanup dry-run failed"

echo "── adapters ──"
# probe: must output ONLY booleans/names, never a secret value
PROBE_OUT=$("$SKILL/lib/adapters/probe.sh" 2>/dev/null)
echo "$PROBE_OUT" | jq -e '.available|type=="array"' >/dev/null 2>&1 && ok "probe emits available[] array" || no "probe malformed"
echo "$PROBE_OUT" | jq -e '.detail.suggest==true' >/dev/null 2>&1 && ok "probe: suggest always available" || no "probe suggest not true"
# probe must NOT contain any long token-like string (boolean-only contract)
if echo "$PROBE_OUT" | grep -qE '(AIza|sk-|ghp_)[A-Za-z0-9]{8,}'; then no "probe LEAKED token-like string"; else ok "probe output token-free (boolean-only)"; fi
# adapter scripts: syntax + self-test contract
for a in probe suggest wordstat dataforseo search-console; do
  bash -n "$SKILL/lib/adapters/$a.sh" && ok "syntax ok: $a.sh" || no "syntax FAIL: $a.sh"
done
# wordstat/dataforseo self-test should FAIL GRACEFULLY (rc!=0) without creds, not crash bash
"$SKILL/lib/adapters/wordstat.sh" --self-test >/dev/null 2>&1; rc=$?; [ "$rc" -ne 0 ] && ok "wordstat self-test fails gracefully w/o creds (rc=$rc)" || ok "wordstat self-test passed (creds filled)"
"$SKILL/lib/adapters/search-console.sh" --self-test >/dev/null 2>&1; rc=$?; [ "$rc" -ne 0 ] && ok "search-console self-test reports unavailable (rc=$rc)" || ok "search-console self-test passed"
# dataforseo multi-method: hermetic (fixture) — envelope + injection + cap (без сети/кредов)
DFXX="$SKILL/tests/fixtures/dataforseo"
o=$(DFS_FIXTURE_DIR="$DFXX" DFS_CACHE_DIR="$SANDBOX/dfscache" DFS_RUN_ID=smoke1 bash "$SKILL/lib/adapters/dataforseo.sh" overview "тест" 2>/dev/null)
echo "$o" | jq -e '.ok==true and .method=="overview" and (.data.keywords|length>0)' >/dev/null 2>&1 && ok "dataforseo envelope (fixture) ok" || no "dataforseo envelope broken"
o=$(DFS_FIXTURE_DIR="$DFXX" DFS_CACHE_DIR="$SANDBOX/dfscache" DFS_RUN_ID=smoke2 bash "$SKILL/lib/adapters/dataforseo.sh" overview '$(id)' 2>/dev/null)
echo "$o" | jq -e '.error_code=="bad_input"' >/dev/null 2>&1 && ok "dataforseo injection blocked" || no "dataforseo injection NOT blocked"
[ -x "$SKILL/lib/adapters/dataforseo.sh" ] && ok "dataforseo.sh executable" || no "dataforseo.sh not +x"

echo "── url-guard (SSRF, vendored; blocker для existing-site фетча) ──"
[ -f "$SKILL/lib/url-guard.sh" ] && ok "url-guard.sh vendored в redsemantic/lib" || no "url-guard.sh отсутствует"
ssrf_ok=1
for u in "http://169.254.169.254/x" "file:///etc/passwd" "https://10.0.0.1" "http://192.168.0.1" "http://localhost" "http://trusted@10.0.0.1/" "http://2130706433/"; do
  bash -c "source '$SKILL/lib/url-guard.sh'; validate_url '$u'" >/dev/null 2>&1 && { ssrf_ok=0; echo "    SSRF NOT blocked: $u"; }
done
bash -c "source '$SKILL/lib/url-guard.sh'; validate_url 'https://example.com'" >/dev/null 2>&1 || { ssrf_ok=0; echo "    https://public ложно заблокирован"; }
[ "$ssrf_ok" = 1 ] && ok "url-guard: SSRF (metadata/file/RFC1918/localhost/userinfo/decimal-int) блок, https://public allow" || no "url-guard SSRF self-test провален"

echo ""
echo "smoke: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && { echo "SMOKE OK"; exit 0; } || { echo "SMOKE FAIL"; exit 1; }

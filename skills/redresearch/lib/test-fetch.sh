#!/usr/bin/env bash
# test-fetch.sh — hermetic (no-network) tests for the tiered fetch adapter.
# Covers: exit-code contract, url-guard SSRF block, deps-missing, --deep/--no-deep
# contradiction, challenge-marker detection, redirect SSRF re-validation, proxy
# redaction, 429 no-escalate, and the F6 "no body on stdout failure" rule.
#
# Strategy: bash drives fetch.sh for the wrapper-level exit codes; a stubbed
# fake `curl_cffi` module (injected via PYTHONPATH) drives fetch_tiered.py for
# the network paths — so nothing leaves the machine.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="${PARSING_VENV:-$HOME/.claude/parsing-venv}/bin/python"
FETCH="$HERE/fetch.sh"
TIERED="$HERE/fetch_tiered.py"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok: $1"; }
no(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
expect_rc(){ # <expected> <actual> <label>
  if [ "$1" = "$2" ]; then ok "$3 (rc=$2)"; else no "$3 (expected rc=$1, got $2)"; fi
}

[ -x "$PY" ] || { echo "SKIP: parsing venv not at $PY"; exit 0; }

# Keep the main suite hermetic: disable auto-proxy globally (it would shell out
# to the real `op read`). A dedicated section below re-enables it with a stub.
export CFFI_AUTOPROXY=0

echo "== wrapper (fetch.sh) exit-code contract =="
bash "$FETCH" >/dev/null 2>&1; expect_rc 64 $? "no args -> usage 64"
bash "$FETCH" "http://localhost/x" >/dev/null 2>&1; expect_rc 2 "$?" "localhost -> SSRF block 2"
bash "$FETCH" "http://169.254.169.254/latest/" >/dev/null 2>&1; expect_rc 2 "$?" "cloud-metadata -> SSRF block 2"
bash "$FETCH" "file:///etc/passwd" >/dev/null 2>&1; expect_rc 2 "$?" "file:// scheme -> block 2"
PARSING_VENV=/nonexistent-venv bash "$FETCH" "https://example.com" >/dev/null 2>&1; expect_rc 3 "$?" "missing venv -> deps 3"

echo "== argparse mutual exclusion =="
"$PY" "$TIERED" --deep --no-deep "https://example.com" >/dev/null 2>&1; expect_rc 64 "$?" "--deep + --no-deep -> usage 64"

echo "== unit: pure functions =="
"$PY" - "$TIERED" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ft", sys.argv[1])
ft = importlib.util.module_from_spec(spec); spec.loader.exec_module(ft)
fails = 0
def check(cond, label):
    global fails
    print(("  ok: " if cond else "  FAIL: ") + label)
    if not cond: fails += 1
# challenge detection
check(ft._looks_like_challenge(403, "<html>ok</html>"), "403 status = challenge")
check(ft._looks_like_challenge(200, "<title>Just a moment...</title>"), "CF marker = challenge")
check(not ft._looks_like_challenge(200, "<p>real content</p>"), "clean 200 != challenge")
check(not ft._looks_like_challenge(429, "<p>slow down</p>"), "429 != challenge (rate-limit path)")
# proxy redaction
red = ft._redact("ProxyError http://user:secret@proxy.io:8080 refused")
check("secret" not in red and "<redacted>" in red, "proxy creds redacted")
# extraction
md = ft._extract("<html><body><article><h1>Hi</h1><p>Body text here.</p></article></body></html>", "https://x.test")
check("Body text here" in md, "extract pulls main content")
sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] && ok "unit functions" || no "unit functions"

echo "== light tier via stubbed curl_cffi (no network) =="
STUB="$(mktemp -d)"
mkdir -p "$STUB/curl_cffi"
cat > "$STUB/curl_cffi/__init__.py" <<'PY'
import os
class _Resp:
    def __init__(self, status, text, headers=None):
        self.status_code = status; self.text = text; self.headers = headers or {}
class _Req:
    def get(self, url, **kw):
        mode = os.environ.get("STUB_MODE", "ok")
        if mode == "ok":
            return _Resp(200, "<html><body><article><p>Stub content body.</p></article></body></html>")
        if mode == "challenge":
            return _Resp(403, "<title>Just a moment...</title>")
        if mode == "rate":
            return _Resp(429, "slow down")
        if mode == "redirect_evil":
            return _Resp(302, "", {"location": "http://169.254.169.254/latest/meta-data/"})
        return _Resp(200, "")
requests = _Req()
PY
run_stub(){ STUB_MODE="$1" PYTHONPATH="$STUB" "$PY" "$TIERED" --no-deep --json "${2:-https://example.com}" 2>"$STUB/err" >"$STUB/out"; echo $?; }

rc=$(run_stub ok);        expect_rc 0 "$rc" "stub ok -> 0"
grep -q "Stub content body" "$STUB/out" && ok "stub ok content on stdout" || no "stub ok content on stdout"
grep -q '"ok": true' "$STUB/err" && ok "stub ok meta ok:true" || no "stub ok meta"

rc=$(run_stub challenge); expect_rc 1 "$rc" "stub challenge (--no-deep) -> 1"
[ ! -s "$STUB/out" ] && ok "F6: no body on stdout when blocked" || no "F6: stdout must be empty on failure"

rc=$(run_stub rate);      expect_rc 1 "$rc" "stub 429 -> 1 (no escalate)"
grep -q "rate_limited" "$STUB/err" && ok "429 meta rate_limited" || no "429 meta rate_limited"

rc=$(run_stub redirect_evil); expect_rc 2 "$rc" "redirect to metadata IP -> SSRF block 2"
grep -q "ssrf_blocked" "$STUB/err" && ok "redirect SSRF meta flag" || no "redirect SSRF meta flag"
rm -rf "$STUB"

echo "== deep tier via stubbed cloakbrowser (no network) =="
DSTUB="$(mktemp -d)"
mkdir -p "$DSTUB/cloakbrowser"
# minimal curl_cffi stub so the light tier (if reached) doesn't hit the network
mkdir -p "$DSTUB/curl_cffi"
cat > "$DSTUB/curl_cffi/__init__.py" <<'PY'
class _R:
    status_code=200; text="<html><p>x</p></html>"; headers={}
class _Req:
    def get(self,u,**k): return _R()
requests=_Req()
PY
cat > "$DSTUB/cloakbrowser/__init__.py" <<'PY'
import os
class _Req:
    def __init__(self,url,rtype="document"): self.url=url; self.resource_type=rtype
class _Route:
    def __init__(self,url,rtype="document"): self.request=_Req(url,rtype)
    def continue_(self): pass
    def abort(self): raise Exception("net::ERR_ABORTED")
class _Resp:
    def __init__(self,s): self.status=s
class _Page:
    def __init__(self): self._h=None
    def route(self,pat,h):
        if os.environ.get("STUB_ROUTE_FAIL"): raise Exception("routing unsupported")
        self._h=h
    def goto(self,url,timeout=None):
        if self._h:
            sub=os.environ.get("STUB_SUB_URL")
            if sub:
                try: self._h(_Route(sub,"image"))   # subresource: abort must NOT kill nav
                except Exception: pass
            nav=os.environ.get("STUB_DEEP_NAV",url)
            self._h(_Route(nav,"document"))          # nav: abort propagates (raises)
        if os.environ.get("STUB_GOTO_RAISE"): raise Exception("net::ERR_TIMED_OUT")
        return _Resp(int(os.environ.get("STUB_DEEP_STATUS","200")))
    def wait_for_load_state(self,*a,**k): pass
    def content(self): return "<html><body><article><p>Deep stub content.</p></article></body></html>"
class _Browser:
    def new_page(self): return _Page()
    def close(self): pass
def launch(**kw):
    if os.environ.get("STUB_PROXY_REJECT") and "proxy" in kw: raise TypeError("proxy= unsupported")
    return _Browser()
PY
run_deep(){ PYTHONPATH="$DSTUB" "$PY" "$TIERED" --deep --json "$@" >"$DSTUB/out" 2>"$DSTUB/err"; echo $?; }

rc=$(run_deep "https://example.com"); expect_rc 0 "$rc" "deep ok -> 0"
grep -q "Deep stub content" "$DSTUB/out" && ok "deep ok content on stdout" || no "deep ok content on stdout"

rc=$(STUB_DEEP_NAV="http://169.254.169.254/latest/" run_deep "https://example.com"); expect_rc 2 "$rc" "deep nav to metadata IP -> SSRF block 2"
grep -q "ssrf_blocked" "$DSTUB/err" && ok "deep SSRF meta flag" || no "deep SSRF meta flag"

rc=$(STUB_ROUTE_FAIL=1 run_deep "https://example.com"); expect_rc 1 "$rc" "deep route-guard install fail -> fail-closed (not 0)"
grep -q "route-guard install failed" "$DSTUB/err" && ok "deep route-fail reason" || no "deep route-fail reason"

rc=$(STUB_PROXY_REJECT=1 run_deep --proxy "http://user:secret@px.io:8080" "https://example.com"); expect_rc 0 "$rc" "deep proxy-reject -> fallback ok 0"
grep -q '"proxy_applied": false' "$DSTUB/err" && ok "deep proxy_applied:false in meta" || no "deep proxy_applied:false in meta"
! grep -q "secret" "$DSTUB/err" && ok "deep proxy warn redacts creds" || no "deep proxy warn leaked creds"
! grep -q "secret" "$DSTUB/out" && ok "deep proxy creds absent from stdout" || no "deep proxy creds in stdout"

# subresource block on SUCCESS path -> observability flag, still ok:0
rc=$(STUB_SUB_URL="http://169.254.169.254/x.png" run_deep "https://example.com"); expect_rc 0 "$rc" "deep subresource block + ok nav -> 0"
grep -q "ssrf_subresource_blocked" "$DSTUB/err" && ok "deep subresource observability flag" || no "deep subresource observability flag"

# subresource block + UNRELATED nav timeout -> rc 1 (NOT false rc=2). The misattribution fix.
rc=$(STUB_SUB_URL="http://169.254.169.254/x.png" STUB_GOTO_RAISE=1 run_deep "https://example.com"); expect_rc 1 "$rc" "subresource block + nav timeout -> rc 1 (not false SSRF 2)"
! grep -q "ssrf_blocked" "$DSTUB/err" && ok "no false ssrf_blocked on subresource+timeout" || no "false ssrf_blocked on subresource+timeout"
rm -rf "$DSTUB"

echo "== light tier proxy_applied + --timeout validation =="
STUB2="$(mktemp -d)"; mkdir -p "$STUB2/curl_cffi"
cat > "$STUB2/curl_cffi/__init__.py" <<'PY'
class _Resp:
    status_code=200; text="<html><body><article><p>ok body.</p></article></body></html>"; headers={}
class _Req:
    def get(self,u,**k): return _Resp()
requests=_Req()
PY
PYTHONPATH="$STUB2" "$PY" "$TIERED" --no-deep --json --proxy "http://u:p@px.io:9" "https://example.com" 2>"$STUB2/err" >/dev/null
grep -q '"proxy_applied": true' "$STUB2/err" && ok "light proxy_applied:true in meta" || no "light proxy_applied:true in meta"
rm -rf "$STUB2"
"$PY" "$TIERED" --timeout 0 "https://example.com" >/dev/null 2>&1; expect_rc 64 "$?" "--timeout 0 -> usage 64"

echo "== fetch.sh --deep + SSRF wrapper path =="
bash "$FETCH" --deep "http://169.254.169.254/latest/" >/dev/null 2>&1; expect_rc 2 "$?" "fetch.sh --deep metadata IP -> block 2"

echo "== direct python entry-URL guard (vendored-invocation defense) =="
"$PY" "$TIERED" --no-deep "http://169.254.169.254/latest/" >/dev/null 2>&1; expect_rc 2 "$?" "direct python metadata IP -> entry guard 2"

echo "== auto-proxy on block (stubbed op + proxy-aware curl_cffi) =="
APSTUB="$(mktemp -d)"
# stub `op`: `op read <ref>` prints a fake proxy URL
mkdir -p "$APSTUB/bin"
cat > "$APSTUB/bin/op" <<'SH'
#!/usr/bin/env bash
[ "$1" = "read" ] && { echo "socks5h://u:p@fake.proxy:1002"; exit 0; }
exit 0
SH
chmod +x "$APSTUB/bin/op"
# stub curl_cffi (python): challenge when NO proxy, real content WHEN proxy set
mkdir -p "$APSTUB/curl_cffi"
cat > "$APSTUB/curl_cffi/__init__.py" <<'PY'
class _R:
    def __init__(s, status, text): s.status_code=status; s.text=text; s.headers={}
class _Req:
    def get(s, url, **kw):
        if kw.get("proxies"):   # proxied retry → success
            return _R(200, "<html><body><article><p>Proxied content OK.</p></article></body></html>")
        return _R(403, "<title>Just a moment...</title>")   # direct → blocked
requests=_Req()
PY
# url-guard must pass; _resolve_autoproxy uses env CFFI_PROXY first OR op read.
# Force the op-read path by leaving CFFI_PROXY unset, enabling autoproxy, op on PATH.
rc=$(CFFI_AUTOPROXY=1 PATH="$APSTUB/bin:$PATH" PYTHONPATH="$APSTUB" "$PY" "$TIERED" --no-deep --json "https://example.com" 2>"$APSTUB/err" >"$APSTUB/out"; echo $?)
expect_rc 0 "$rc" "auto-proxy: blocked direct → retry via proxy → 0"
grep -q "Proxied content OK" "$APSTUB/out" && ok "auto-proxy served proxied content" || no "auto-proxy content missing"
grep -q '"autoproxy": true' "$APSTUB/err" && ok "auto-proxy meta flag set" || no "auto-proxy meta flag missing"
grep -qi "auto-proxy" "$APSTUB/err" && ok "auto-proxy stderr notice" || no "auto-proxy notice missing"
# SECRET must NOT leak: the stub proxy creds (u:p@fake.proxy) absent from out/err
! grep -q "fake.proxy" "$APSTUB/out" && ok "auto-proxy: cred absent from stdout" || no "auto-proxy cred LEAKED to stdout"
! grep -q "fake.proxy" "$APSTUB/err" && ok "auto-proxy: cred absent from stderr" || no "auto-proxy cred LEAKED to stderr"
# disabled path: CFFI_AUTOPROXY=0 → stays blocked → exit 1
rc=$(CFFI_AUTOPROXY=0 PATH="$APSTUB/bin:$PATH" PYTHONPATH="$APSTUB" "$PY" "$TIERED" --no-deep --json "https://example.com" >/dev/null 2>&1; echo $?)
expect_rc 1 "$rc" "auto-proxy disabled (CFFI_AUTOPROXY=0) → stays blocked → 1"

echo "== playbook self-tuning (host that blocks direct → proxy-first after learning) =="
PBSTATE="$(mktemp -d)"
pbrun(){ CFFI_AUTOPROXY=1 REDFETCH_STATE="$PBSTATE/s" PATH="$APSTUB/bin:$PATH" PYTHONPATH="$APSTUB" "$PY" "$TIERED" --no-deep --json "https://blocky.test/p" 2>&1 >/dev/null; }
out1=$(pbrun); out3=$(pbrun; pbrun)   # 3 runs total
echo "$out1" | grep -qi "auto-proxy" && ok "run1 used auto-proxy (not yet learned)" || no "run1 should auto-proxy"
last=$(pbrun)
echo "$last" | grep -qi "playbook: host blocks direct" && ok "after learning → proxy-first (direct skipped)" || no "playbook proxy-first did not trigger"
[ -f "$PBSTATE/s/playbook.json" ] && grep -q '"direct_blocked"' "$PBSTATE/s/playbook.json" && ok "playbook.json persisted with counters" || no "playbook.json missing"
[ -f "$PBSTATE/s/telemetry.jsonl" ] && ok "telemetry.jsonl written" || no "telemetry.jsonl missing"
# REDFETCH_NO_LEARN=1 → no state written
PBOFF="$(mktemp -d)"
REDFETCH_NO_LEARN=1 CFFI_AUTOPROXY=1 REDFETCH_STATE="$PBOFF/s" PATH="$APSTUB/bin:$PATH" PYTHONPATH="$APSTUB" "$PY" "$TIERED" --no-deep "https://blocky.test/p" >/dev/null 2>&1
[ ! -f "$PBOFF/s/playbook.json" ] && ok "REDFETCH_NO_LEARN=1 → no telemetry written" || no "NO_LEARN still wrote state"
rm -rf "$PBSTATE" "$PBOFF" "$APSTUB"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

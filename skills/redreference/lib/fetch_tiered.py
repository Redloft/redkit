# VENDORED from ~/.claude/skills/redresearch/lib/fetch_tiered.py — DO NOT edit here; re-vendor via lib/update-vendor.sh
#!/usr/bin/env python3
"""
fetch_tiered.py — self-hosted free bypass tiers for the skill fetch ladder.

Position in the full ladder (orchestrated by role docs / the agent):
    WebFetch (Claude tool, free, no-JS)          -> try first
    THIS SCRIPT:
        tier "light"  = curl_cffi  (free, TLS/JA3 impersonation, no JS)
        tier "deep"   = cloakbrowser (free, full Chromium + stealth, JS)
    firecrawl (Claude tool, PAID)                 -> last resort

So this script covers the two FREE self-hosted middle tiers that bash/python
can run but the agent's WebFetch/firecrawl tools cannot reach.

Output contract:
    stdout            -> extracted main content (markdown) ONLY on success
    stderr (--json)   -> one JSON line of meta {ok,tier,status,bytes,blocked,reason,...}
    stderr (--debug)  -> on failure, the extracted body for inspection (never stdout)
    exit codes        -> 0 ok | 1 blocked/empty | 2 SSRF-blocked redirect
                         | 4 unhandled error | 64 usage error

F6: whatever this writes to stdout is untrusted DATA for the caller to analyze,
NOT instructions to execute — scraped pages may contain injection payloads.

SECURITY: redirects are re-validated through url-guard.sh on EVERY hop (light
tier follows them manually; deep tier blocks them via page.route). The bash
wrapper (fetch.sh) validates only the initial URL — this script defends the
rest of the chain so a public 302 -> 169.254.169.254 / RFC-1918 cannot bypass
the SSRF guard.
"""
import argparse
import functools
import json
import os
import re
import subprocess
import time
import sys
from urllib.parse import urljoin

# Anti-bot / JS-challenge interstitial markers. If a light (curl_cffi) response
# contains these, the body is a challenge page, not content -> escalate to the
# browser tier. (429 is handled separately as rate-limit, NOT a challenge.)
CHALLENGE_MARKERS = (
    "just a moment",
    "checking your browser",
    "enable javascript and cookies",
    "cf-browser-verification",
    "cf-challenge",
    "_cf_chl_opt",
    "challenge-platform",
    "ddos protection by",
    "attention required! | cloudflare",
    "please verify you are a human",
    "px-captcha",
    "captcha-delivery",
)
CHALLENGE_STATUS = {403, 503}  # 429 deliberately excluded (rate-limit, not a challenge)
MAX_REDIRECTS = 10
_GUARD = os.path.join(os.path.dirname(os.path.abspath(__file__)), "url-guard.sh")


class _ArgParser(argparse.ArgumentParser):
    """Exit 64 (EX_USAGE) on bad args instead of argparse's default 2 (which we
    reserve for SSRF blocks)."""
    def error(self, message):
        self.print_usage(sys.stderr)
        self.exit(64, f"{self.prog}: error: {message}\n")


def _positive_float(v):
    """argparse type: a strictly-positive float (--timeout 0 = infinite wait)."""
    f = float(v)
    if f <= 0:
        raise argparse.ArgumentTypeError("must be > 0")
    return f


def _redact(s):
    """Strip user:pass@ creds from any proxy URL embedded in a string before it
    reaches stderr / meta / the transcript."""
    return re.sub(r"://[^/@\s]+@", "://<redacted>@", str(s))


# Default 1Password reference for the auto-proxy credential (overridable via env).
_AUTOPROXY_REF = "op://AI-Tokens/Evomi Residential Proxy/credential"


def _resolve_autoproxy():
    """Return a proxy URL for the auto-on-block retry, or None.
    Order: env CFFI_PROXY (already injected by op run) → `op read` of the
    1Password ref. Disabled by CFFI_AUTOPROXY=0. The secret stays in-process
    (never printed). Returns None if disabled / op unavailable / not found."""
    if os.environ.get("CFFI_AUTOPROXY", "1") == "0":
        return None
    env_p = os.environ.get("CFFI_PROXY")
    if env_p:
        return env_p
    ref = os.environ.get("CFFI_PROXY_REF", _AUTOPROXY_REF)
    try:
        r = subprocess.run(["op", "read", ref], capture_output=True, text=True, timeout=15)
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip()
    except Exception:
        pass
    return None


# ── Self-tuning telemetry + per-host playbook ────────────────────────────────
# Append-only telemetry of fetch outcomes + a per-host strategy cache so the
# ladder learns: hosts that reliably block direct are fetched via proxy FIRST
# (skipping the doomed ~30s direct attempt). Best-effort: never breaks a fetch.
# Disable writes with REDFETCH_NO_LEARN=1. State dir via $REDFETCH_STATE.
_STATE_DIR = os.environ.get("REDFETCH_STATE", os.path.join(os.path.expanduser("~"), ".cache", "redfetch"))
_PLAYBOOK = os.path.join(_STATE_DIR, "playbook.json")
_TELEMETRY = os.path.join(_STATE_DIR, "telemetry.jsonl")


def _host(url):
    try:
        from urllib.parse import urlsplit
        return (urlsplit(url).hostname or "").lower()
    except Exception:
        return ""


def _playbook_load():
    try:
        with open(_PLAYBOOK) as f:
            return json.load(f)
    except Exception:
        return {}


def _playbook_hint(host):
    """Return 'proxy_first' if this host has reliably blocked direct and never
    succeeded direct (so skip the wasted direct attempt)."""
    h = _playbook_load().get(host or "")
    if not h:
        return None
    if h.get("direct_blocked", 0) >= 2 and h.get("direct_ok", 0) == 0:
        return "proxy_first"
    return None


def _record(host, tier, proxied, ok, status, blocked):
    """Best-effort: append telemetry + update the per-host playbook counters."""
    if not host or os.environ.get("REDFETCH_NO_LEARN") == "1":
        return
    try:
        import fcntl
        os.makedirs(_STATE_DIR, exist_ok=True)
        rec = {"host": host, "tier": tier, "proxied": bool(proxied), "ok": bool(ok),
               "status": status, "blocked": bool(blocked), "t": int(time.time())}
        with open(os.path.join(_STATE_DIR, ".lock"), "w") as lk:
            fcntl.flock(lk, fcntl.LOCK_EX)
            with open(_TELEMETRY, "a") as f:
                f.write(json.dumps(rec, ensure_ascii=False) + "\n")
            pb = _playbook_load()
            h = pb.setdefault(host, {"direct_ok": 0, "direct_blocked": 0, "proxy_ok": 0, "proxy_blocked": 0})
            h[("proxy" if proxied else "direct") + ("_ok" if ok else "_blocked")] += 1
            h["last_tier"] = tier
            h["last_t"] = int(time.time())
            if len(pb) > 500:  # cap: drop oldest hosts
                for k in sorted(pb, key=lambda k: pb[k].get("last_t", 0))[:len(pb) - 500]:
                    pb.pop(k, None)
            tmp = _PLAYBOOK + ".tmp"
            with open(tmp, "w") as f:
                json.dump(pb, f, ensure_ascii=False)
            os.replace(tmp, _PLAYBOOK)
    except Exception:
        pass  # telemetry must never break fetching


# Caveat: lru_cache is process-scoped. A DNS-rebinding attack could in theory
# reuse a cached True for a hostname that rebinds to a private IP mid-session.
# Accepted: the cache lives only for one short-lived fetch process, and for
# hostname→IP defense url-guard.sh must be run with REDLOFT_URL_GUARD_RESOLVE=1.
@functools.lru_cache(maxsize=256)
def _guard_ok(url):
    """True if url passes url-guard.sh (SSRF). Cached per-URL. Fails CLOSED:
    if the guard is missing or errors unexpectedly we block (return False),
    except rc!=0 with a clear BLOCKED reason which is the normal deny path."""
    if not os.path.exists(_GUARD):
        return False
    try:
        r = subprocess.run(["bash", _GUARD, url], capture_output=True, timeout=10)
        return r.returncode == 0
    except Exception:
        return False


def _looks_like_challenge(status, html):
    if status in CHALLENGE_STATUS:
        return True
    low = (html or "")[:6000].lower()
    return any(m in low for m in CHALLENGE_MARKERS)


def _extract(html, url):
    """HTML -> markdown main content via trafilatura; raw-strip fallback."""
    try:
        import trafilatura
        md = trafilatura.extract(
            html, url=url, output_format="markdown",
            include_links=True, include_tables=True, favor_recall=True,
        )
        if md and md.strip():
            return md.strip()
    except Exception:
        pass
    text = re.sub(r"(?is)<(script|style|noscript).*?</\1>", " ", html or "")
    text = re.sub(r"(?s)<[^>]+>", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text


def fetch_light(url, impersonate, timeout, proxy):
    """Tier 1 — curl_cffi with browser TLS/JA3 impersonation. No JS.
    Follows redirects MANUALLY, re-validating every hop through url-guard."""
    try:
        from curl_cffi import requests as creq
    except ImportError:
        return None, {"tier": "light", "ok": False, "reason": "curl_cffi not installed"}
    proxies = {"http": proxy, "https": proxy} if proxy else None
    current = url
    try:
        for _ in range(MAX_REDIRECTS + 1):
            r = creq.get(
                current, impersonate=impersonate, timeout=timeout,
                proxies=proxies, allow_redirects=False,
            )
            if 300 <= r.status_code < 400 and r.headers.get("location"):
                nxt = urljoin(current, r.headers["location"])
                if not _guard_ok(nxt):
                    return None, {"tier": "light", "ok": False, "blocked": True,
                                  "ssrf_blocked": True,
                                  "reason": f"redirect to SSRF-blocked host: {_redact(nxt)}"}
                current = nxt
                continue
            break
        else:
            return None, {"tier": "light", "ok": False,
                          "reason": f"too many redirects (>{MAX_REDIRECTS})"}
    except Exception as e:
        return None, {"tier": "light", "ok": False, "reason": f"curl_cffi error: {_redact(e)}"}

    if r.status_code == 429:
        return None, {"tier": "light", "status": 429, "ok": False, "blocked": False,
                      "rate_limited": True, "reason": "rate-limited (429)"}
    html = r.text or ""
    blocked = _looks_like_challenge(r.status_code, html)
    meta = {"tier": "light", "status": r.status_code, "bytes": len(html),
            "blocked": blocked, "proxy_applied": bool(proxy),
            "ok": not blocked and bool(html.strip())}
    return html, meta


def fetch_deep(url, timeout, humanize, proxy):
    """Tier 2 — cloakbrowser (stealth Chromium). Renders JS, beats challenges.
    EVERY in-browser request (navigation, redirect, AND subresource) is
    re-validated via page.route — SSRF defense. Fails CLOSED: if the route
    guard cannot be installed, we abort rather than fetch unguarded."""
    try:
        from cloakbrowser import launch
    except ImportError:
        return None, {"tier": "deep", "ok": False,
                      "reason": "cloakbrowser not installed (pip install cloakbrowser)"}
    proxy_applied = bool(proxy)
    launch_kwargs = {"humanize": humanize}
    if proxy:
        launch_kwargs["proxy"] = {"server": proxy}
    browser = None
    # Track navigation blocks and subresource blocks SEPARATELY: a blocked
    # subresource must NOT be misread as a navigation SSRF if goto later fails
    # for an unrelated reason (e.g. timeout).
    blocked = {"nav_url": None, "sub_url": None}
    try:
        try:
            browser = launch(**launch_kwargs)
        except TypeError as e:
            # cloakbrowser build may not accept proxy=; warn (creds redacted) and retry plain
            if proxy:
                proxy_applied = False
                sys.stderr.write(f"WARN: deep-tier proxy not applied ({_redact(e)}); "
                                 f"continuing WITHOUT proxy — real IP may be exposed\n")
                browser = launch(humanize=humanize)
            else:
                raise
        page = browser.new_page()

        # SSRF guard on EVERY in-browser request (block-by-default for all
        # resource types — img/script/css/font/ws to a private IP are blocked
        # too, not just document/xhr/fetch). Non-network schemes are allowed.
        def _route(route):
            req = route.request
            req_url = req.url
            if req_url.startswith(("data:", "blob:", "about:")):
                return route.continue_()
            if not _guard_ok(req_url):
                if getattr(req, "resource_type", "") in ("document", "navigation"):
                    blocked["nav_url"] = req_url
                else:
                    blocked["sub_url"] = req_url
                return route.abort()
            return route.continue_()
        try:
            page.route("**/*", _route)
        except Exception as e:
            # FAIL CLOSED — without the route guard, in-browser redirects/
            # subresources to private IPs are unguarded. Do not proceed.
            return None, {"tier": "deep", "ok": False,
                          "reason": f"route-guard install failed (SSRF protection unavailable): {_redact(e)}"}

        # split the budget: navigation 70%, settle 30% (avoids worst-case 2x)
        try:
            resp = page.goto(url, timeout=int(timeout * 1000 * 0.7))
        except Exception as e:
            # Only treat as SSRF if the NAVIGATION itself was guard-aborted; a
            # mere subresource block + unrelated goto failure must not become rc=2.
            if blocked["nav_url"] is not None:
                return None, {"tier": "deep", "ok": False, "blocked": True,
                              "ssrf_blocked": True,
                              "reason": f"navigation blocked by SSRF guard: {_redact(blocked['nav_url'])}"}
            return None, {"tier": "deep", "ok": False, "reason": f"cloakbrowser error: {_redact(e)}"}
        status = resp.status if resp is not None else 0
        try:
            page.wait_for_load_state("networkidle", timeout=int(timeout * 1000 * 0.3))
        except Exception:
            pass
        html = page.content()
    except Exception as e:
        return None, {"tier": "deep", "ok": False, "reason": f"cloakbrowser error: {_redact(e)}"}
    finally:
        if browser is not None:
            try:
                browser.close()
            except Exception:
                pass
    is_chal = _looks_like_challenge(status, html)
    nav_failed = status == 0
    meta = {"tier": "deep", "status": status, "bytes": len(html or ""),
            "blocked": is_chal, "proxy_applied": proxy_applied,
            "ok": not is_chal and not nav_failed and bool((html or "").strip())}
    if nav_failed:
        meta["nav_failed"] = True
    # Observability: the page rendered OK but a subresource was SSRF-blocked.
    if blocked["sub_url"] is not None:
        meta["ssrf_subresource_blocked"] = True
        meta["ssrf_blocked_url_sample"] = _redact(blocked["sub_url"])
    return html, meta


def main():
    ap = _ArgParser(description="Tiered free bypass fetcher (curl_cffi -> cloakbrowser).")
    ap.add_argument("url")
    tier = ap.add_mutually_exclusive_group()
    tier.add_argument("--deep", action="store_true", help="skip light tier, go straight to stealth browser")
    tier.add_argument("--no-deep", action="store_true", help="light tier only; never launch the browser")
    ap.add_argument("--impersonate", default="chrome", help='curl_cffi target: chrome|safari|safari_ios|chrome124 (default chrome=latest)')
    ap.add_argument("--timeout", type=_positive_float, default=30.0,
                    help="per-tier timeout in seconds, > 0 (default 30)")
    ap.add_argument("--proxy", default=None, help="http(s) proxy URL (inject via op run, never hardcode)")
    ap.add_argument("--humanize", action="store_true", help="cloakbrowser human-like input timing")
    ap.add_argument("--json", action="store_true", help="emit meta JSON line to stderr")
    ap.add_argument("--debug", action="store_true", help="on failure, dump extracted body to stderr")
    ap.add_argument("--no-autoproxy", action="store_true",
                    help="disable the auto-retry-via-residential-proxy on a detected block")
    args = ap.parse_args()

    # Dual-layer SSRF: fetch.sh guards the entry URL, but guard it here too so
    # direct/vendored invocations of this script are not unprotected.
    if not _guard_ok(args.url):
        if args.json:
            sys.stderr.write(json.dumps(
                {"ok": False, "ssrf_blocked": True,
                 "reason": f"entry URL blocked by url-guard: {_redact(args.url)}"},
                ensure_ascii=False) + "\n")
        else:
            sys.stderr.write(f"BLOCKED by url-guard (entry URL): {_redact(args.url)}\n")
        return 2

    host = _host(args.url)
    # Explicit proxy from --proxy OR env CFFI_PROXY. Prefer env: a secret in argv
    # (--proxy <url>) shows in ps/procfs; CFFI_PROXY does not.
    explicit_proxy = args.proxy or os.environ.get("CFFI_PROXY")
    html, meta = (None, {})
    auto_proxy = None  # residential proxy resolved on a block; carried to deep tier
    if not args.deep:
        # PLAYBOOK: if this host has reliably blocked direct before, skip the
        # doomed direct attempt and go via the residential proxy first.
        first_proxy = explicit_proxy
        pre_proxied = False
        if not explicit_proxy and not args.no_autoproxy and _playbook_hint(host) == "proxy_first":
            pp = _resolve_autoproxy()
            if pp:
                sys.stderr.write("playbook: host blocks direct — going via proxy first\n")
                first_proxy = pp
                pre_proxied = True

        html, meta = fetch_light(args.url, args.impersonate, args.timeout, first_proxy)
        _record(host, "light", bool(first_proxy), meta.get("ok"), meta.get("status"), meta.get("blocked"))
        if meta.get("ok"):
            return _emit(html, meta, args)
        # SSRF redirect block or rate-limit: do NOT waste the browser tier
        if meta.get("ssrf_blocked"):
            return _fail(html, meta, args, exit_code=2)
        if meta.get("rate_limited"):
            return _fail(html, meta, args, exit_code=1)
        # AUTO-PROXY: light tier was blocked (challenge/403/503/empty) → retry
        # ONCE through the residential proxy (curl_cffi supports it; this is the
        # tier where the proxy works). Skip if we already went via proxy first.
        if not explicit_proxy and not pre_proxied and not args.no_autoproxy:
            auto_proxy = _resolve_autoproxy()
            if auto_proxy:
                sys.stderr.write("auto-proxy: light tier blocked — retrying via residential proxy\n")
                h2, m2 = fetch_light(args.url, args.impersonate, args.timeout, auto_proxy)
                m2["autoproxy"] = True
                _record(host, "light", True, m2.get("ok"), m2.get("status"), m2.get("blocked"))
                if m2.get("ok"):
                    return _emit(h2, m2, args)
                if m2.get("ssrf_blocked"):
                    return _fail(h2, m2, args, exit_code=2)
                html, meta = h2, m2  # carry the proxied attempt's meta forward

    if not args.no_deep:
        # Carry the residential proxy into the deep tier too (don't silently drop
        # it on escalation). NOTE: cloakbrowser/Playwright can't auth socks5 — so
        # a socks5 auto-proxy won't actually apply in deep; documented in FETCH.md.
        deep_proxy = explicit_proxy or auto_proxy
        d_html, d_meta = fetch_deep(args.url, args.timeout, args.humanize, deep_proxy)
        _record(host, "deep", bool(deep_proxy), d_meta.get("ok"), d_meta.get("status"), d_meta.get("blocked"))
        if d_meta.get("ok"):
            return _emit(d_html, d_meta, args)
        if d_meta.get("ssrf_blocked"):
            return _fail(d_html, d_meta, args, exit_code=2)
        # preserve BOTH tiers' diagnostics rather than discarding light meta
        fail_meta = {"ok": False, "tiers": [m for m in (meta, d_meta) if m]}
        return _fail(d_html or html, fail_meta, args, exit_code=1)

    return _fail(html, {"ok": False, **meta}, args, exit_code=1)


def _emit(html, meta, args):
    text = _extract(html, args.url)
    if args.json:
        sys.stderr.write(json.dumps({**meta, "extracted_bytes": len(text)}, ensure_ascii=False) + "\n")
    sys.stdout.write(text)
    return 0


def _fail(html, meta, args, exit_code):
    if args.json:
        sys.stderr.write(json.dumps(meta, ensure_ascii=False) + "\n")
    # F6: never write (possibly prompt-injected) challenge bodies to stdout.
    if args.debug and html:
        sys.stderr.write("\n--- DEBUG body ---\n" + _extract(html, args.url) + "\n")
    return exit_code


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception as e:  # unhandled -> distinct hard-error exit code
        sys.stderr.write(f"fetch_tiered: unhandled error: {_redact(e)}\n")
        sys.exit(4)

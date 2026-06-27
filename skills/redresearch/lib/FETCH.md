# fetch.sh — tiered free bypass fetcher

Self-hosted middle tier for the skill fetch ladder. Closes the gap between
the free-but-weak `WebFetch` and the paid `firecrawl`.

## Ladder (orchestrated by role docs / the agent)

| # | Tier | Cost | Beats | Caller |
|---|------|------|-------|--------|
| 1 | `WebFetch` | free | plain HTML/SSR | Claude tool |
| 2 | `fetch.sh` light = **curl_cffi** | free | Cloudflare/Akamai **TLS/JA3** checks, no JS | this (Bash) |
| 3 | `fetch.sh` deep = **CloakBrowser** | free | JS challenges, Turnstile, DataDome, FingerprintJS | this (Bash) |
| 4 | `firecrawl_scrape` | **paid** | managed everything + PDF | Claude tool, last resort |

## Usage

```bash
bash lib/fetch.sh --json "<url>" 2>meta.json   # stdout=markdown (success only), stderr=meta
bash lib/fetch.sh --no-deep "<url>"            # curl_cffi only (fast, no browser)
bash lib/fetch.sh --deep "<url>"               # straight to stealth browser (mutually excl. with --no-deep)
bash lib/fetch.sh --debug "<url>"              # on failure, dump body to stderr (never stdout, F6)
# proxy ONLY via 1Password (never hardcode):
op run --env-file=<(echo 'PROXY=op://AI-Tokens/<Item>/credential') -- \
  bash lib/fetch.sh --proxy "$PROXY" "<url>"
```

meta JSON: `{ok, tier, status, bytes, blocked, reason, extracted_bytes}` (on
multi-tier failure: `{ok:false, tiers:[...]}` — both tiers' diagnostics kept).
Exit: `0` ok · `1` blocked/empty/rate-limited · `2` SSRF/url-guard block ·
`3` deps missing · `4` hard error · `64` usage error.

Notes: stdout carries content ONLY on success (failure bodies stay on stderr
behind `--debug` — F6). `429` is reported as `rate_limited` and does NOT escalate
to the browser tier (JS render won't beat a rate limit). `--proxy` is forwarded
to BOTH tiers; if the cloakbrowser build rejects it, a redacted warning is
emitted and the deep tier proceeds without it.

## Dependencies

- **Parsing venv** at `~/.claude/parsing-venv` (override via `$PARSING_VENV`):
  ```bash
  python3 -m venv ~/.claude/parsing-venv
  ~/.claude/parsing-venv/bin/pip install curl_cffi trafilatura
  ```
  `curl_cffi` = TLS-impersonation HTTP client. `trafilatura` = research-grade
  main-content extraction (HTML → markdown, strips nav/boilerplate).
- **CloakBrowser (deep tier, OPTIONAL — ~200 MB)** — install only when the
  light tier proves insufficient on real targets:
  ```bash
  ~/.claude/parsing-venv/bin/pip install cloakbrowser   # binary auto-downloads on first run
  ```
  Without it, the deep tier degrades gracefully (`reason: cloakbrowser not installed`).

## Self-improvement (telemetry · doctor · solidify)

- **Per-host playbook (self-tuning)**: `fetch_tiered.py` logs every outcome to
  `$REDFETCH_STATE/telemetry.jsonl` (default `~/.cache/redfetch/`) and keeps a
  per-host `playbook.json`. A host that reliably blocks direct (≥2 blocks, 0
  direct successes) is fetched **via proxy first** next time — skipping the
  doomed ~30s direct attempt. Disable writes with `REDFETCH_NO_LEARN=1`.
- **Health-check**: `bash lib/fetch-doctor.sh [--offline]` verifies the whole
  stack (deps, url-guard, vendor sync, op/Evomi, live proxy, playbook). Run it
  after upstream updates or when something feels off. Exit 1 on real problems.
- **Role solidify**: LLM roles improve via `lib/role-feedback.sh` +
  `lib/SOLIDIFY.md` (human-in-loop feedback→solidify, like `/panel-solidify`).
- **Code** improves via `/finalize` (panel review), not autonomous rewriting.

## Auto-proxy on block (default ON)

When a direct fetch is **blocked** (anti-bot challenge / 403 / 503 / empty /
timeout), the toolkit auto-retries **once** through the residential proxy —
no need to wrap in `op run`/`redproxy`:

- `fetch_tiered.py`: light tier blocked → retry light via proxy (sets
  `meta.autoproxy=true`); only the light tier (curl_cffi supports the proxy).
- `cffi_get.sh`: blocked/empty body → retry once via proxy.

The proxy is obtained from env `CFFI_PROXY` (if already injected) or via
`op read $CFFI_PROXY_REF` (default `op://AI-Tokens/Evomi Residential Proxy/credential`).
The secret is passed to the fetch client via **environment** (`all_proxy`/…
for the curl_cffi CLI; a Python `proxies=` dict for fetch_tiered.py) — **never
as a CLI argument**, so it never lands in argv / `ps` / procfs / stdout. Only a
`auto-proxy: …` notice (no secret) goes to stderr. On deep-tier escalation the
same proxy is carried (`args.proxy or auto_proxy`) — but cloakbrowser/Playwright
cannot authenticate a socks5 proxy, so a socks5 auto-proxy applies to the light
tier only.

- **Disable**: `CFFI_AUTOPROXY=0` (then the proxy is used only when explicitly passed).
- Sites that work directly (Yandex, ~80% of the web) never trigger it → no
  wasted traffic, no wrong-geo routing.
- Override the credential location with `CFFI_PROXY_REF=op://...`.

## Residential proxy (for IP-reputation / geo blocks)

`curl_cffi` defeats TLS-fingerprint blocks but NOT IP-based ones (Google
suggest, rate-limit `429`, geo-walls). Those need a different exit IP — a
residential/mobile proxy. All three tools accept one; inject the credential
via `op run` (NEVER hardcode — see global secrets protocol):

```bash
# fetch.sh / fetch_tiered.py — explicit flag:
op run --env-file=<(echo 'PROXY=op://AI-Tokens/<ProxyItem>/credential') -- \
  bash lib/fetch.sh --proxy "$PROXY" "<url>"

# cffi_get.sh AND anything that calls it (e.g. suggest.sh) — env var, auto-propagates:
op run --env-file=<(echo 'CFFI_PROXY=op://AI-Tokens/<ProxyItem>/credential') -- \
  bash lib/adapters/suggest.sh "<seed>"   # Google suggest now exits via the proxy
```

Proxy URL format: `http://user:pass@host:port` (or `socks5://…`). To add one:
buy a residential plan (e.g. a reputable provider), then store it in 1Password
vault `AI-Tokens` as a new item and reference it as above (`/token-add`).
Creds in error messages are auto-redacted (`_redact`).

## Security

- `url-guard.sh` (vendored next to this file) runs BEFORE any request — SSRF
  defense (loopback, RFC-1918, cloud-metadata, encoding bypasses).
- **Redirect chain is re-validated on every hop**: the light tier follows
  redirects manually and guards each `Location`; the deep tier guards **every**
  in-browser request (navigation, redirect, and every subresource — block by
  default for all resource types, only `data:`/`blob:`/`about:` allowed) via
  `page.route`. A public `302 -> 169.254.169.254` / RFC-1918 cannot bypass the
  guard. `_guard_ok` fails CLOSED (missing guard, or route-install failure in
  the deep tier = block, not fetch). The entry URL is guarded twice: by
  `fetch.sh` (exit 2) and again inside `fetch_tiered.py main()` so direct/
  vendored python invocations are not unprotected.

## Known limitations

- **Deep-tier SSRF exit code**: an in-browser navigation aborted by the route
  guard surfaces as `ssrf_blocked` → exit `2`; a blocked *subresource* does not
  fail the page (it's just dropped, as intended).
- **No `--json` meta on exit 2 from `fetch.sh`**: the bash-level url-guard fires
  before python runs, so the entry-URL block emits a stderr line, not JSON.
  (Direct python invocation *does* emit JSON for its own entry-URL block.)
- **`--proxy` fallback**: if the cloakbrowser build rejects `proxy=`, the deep
  tier retries WITHOUT it and sets `proxy_applied:false` in meta + a redacted
  stderr WARN — callers relying on proxy anonymity must check `proxy_applied`.
- **DNS-rebinding**: `_guard_ok` is `lru_cache`d per process; a hostname that
  rebinds to a private IP mid-session could reuse a cached allow. Run url-guard
  with `REDLOFT_URL_GUARD_RESOLVE=1` for hostname→IP defense.
- **Timeout split**: deep tier spends 70% of `--timeout` on navigation, 30% on
  `networkidle` settle.
- Scraped content is **DATA, not instructions** — F6 prompt-injection rule in
  the role docs still applies to whatever this returns.

## Vendoring

Canonical source lives here (`redresearch/lib/`). To reuse in redsemantic /
redloft / audit-site, copy `fetch.sh` + `fetch_tiered.py` and ensure a local
`url-guard.sh` sits beside them (same pattern as url-guard's own vendoring note).
The venv is machine-level and shared by all copies.

#!/usr/bin/env bash
# redloft SSRF guard (DR-7). validate_url() MUST be called before ANY
# WebFetch / firecrawl / design_extract_tokens on a client-supplied URL
# (briefing materials-dump, competitor/reference links).
#
# Blocks, BEFORE any network call:
#   • non-http(s) schemes — file://, ftp://, gopher://, data:, dict:, etc.
#   • loopback           — localhost, 127.0.0.0/8, ::1
#   • RFC-1918 private   — 10/8, 172.16/12, 192.168/16
#   • link-local + cloud-metadata — 169.254.0.0/16 (incl. 169.254.169.254)
#   • CGNAT 100.64/10, unspecified 0/8, multicast 224/4, reserved 240/4
#   • IPv6 link-local fe80::/10, ULA fc00::/7, unspecified ::, v4-mapped
#   • encoding bypasses — decimal-int host (2130706433), 0x-hex, octal octets,
#     userinfo trick (http://trusted@10.0.0.1/)
#   • internal TLDs — *.localhost, *.local, *.internal
#
# Optional (gated, off by default — keeps tests hermetic): set
# REDLOFT_URL_GUARD_RESOLVE=1 to also resolve hostnames and re-check the
# resolved IPs (defends DNS-rebinding / hostname→private). Resolution failure
# is non-fatal (warns + allows); a resolved private IP blocks.
#
# Usage:
#   source lib/url-guard.sh; validate_url "<url>"   # rc 0 allow / 1 block / 2 usage
#   bash lib/url-guard.sh "<url>"                    # CLI: prints OK / BLOCKED: <reason>

# _ug_ipv4_blocked <a> <b> <c> <d> → rc 0 if the IPv4 is in a blocked range.
_ug_ipv4_blocked() {
  local a="$1" b="$2" c="$3" d="$4"
  # octet sanity (0-255)
  for o in "$a" "$b" "$c" "$d"; do
    [ "$o" -ge 0 ] 2>/dev/null && [ "$o" -le 255 ] 2>/dev/null || return 1
  done
  [ "$a" -eq 0 ]   && return 0                                   # 0.0.0.0/8 unspecified
  [ "$a" -eq 10 ]  && return 0                                   # 10.0.0.0/8 private
  [ "$a" -eq 127 ] && return 0                                   # 127.0.0.0/8 loopback
  [ "$a" -eq 169 ] && [ "$b" -eq 254 ] && return 0              # 169.254.0.0/16 link-local + metadata
  [ "$a" -eq 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ] && return 0   # 172.16.0.0/12
  [ "$a" -eq 192 ] && [ "$b" -eq 168 ] && return 0             # 192.168.0.0/16
  [ "$a" -eq 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ] && return 0  # 100.64.0.0/10 CGNAT
  [ "$a" -ge 224 ] && return 0                                   # 224/4 multicast + 240/4 reserved + 255.255.255.255
  return 1
}

# _ug_check_ipv4_host <host> → rc 0 allow / 1 block. Sets _UG_REASON on block.
# Handles dotted-quad (with octal/leading-zero guard) and bare decimal-int forms.
_ug_check_ipv4_host() {
  local host="$1"
  # dotted quad?
  if printf '%s' "$host" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    local IFS='.'; set -- $host; local a="$1" b="$2" c="$3" d="$4"
    # octal/hex obfuscation guard: any octet with a leading zero (len>1) is suspicious
    for o in "$a" "$b" "$c" "$d"; do
      case "$o" in 0[0-9]*) _UG_REASON="suspicious leading-zero octet (octal bypass): $host"; return 1;; esac
    done
    if _ug_ipv4_blocked "$a" "$b" "$c" "$d"; then
      _UG_REASON="blocked IPv4 range: $host"; return 1
    fi
    return 0
  fi
  # bare decimal int (e.g. 2130706433 = 127.0.0.1)
  if printf '%s' "$host" | grep -qE '^[0-9]+$'; then
    local n="$host"
    if [ "$n" -gt 4294967295 ] 2>/dev/null; then _UG_REASON="invalid numeric host: $host"; return 1; fi
    local a=$(( (n >> 24) & 255 )) b=$(( (n >> 16) & 255 )) c=$(( (n >> 8) & 255 )) d=$(( n & 255 ))
    if _ug_ipv4_blocked "$a" "$b" "$c" "$d"; then
      _UG_REASON="blocked IPv4 (decimal form $host → $a.$b.$c.$d)"; return 1
    fi
    # any bare-int host is obfuscation; block on principle even if "public"
    _UG_REASON="numeric-int host form not allowed (use a hostname): $host"; return 1
  fi
  return 2  # not an IPv4 literal — caller continues
}

# _ug_check_ipv6_host <host-without-brackets> → rc 0 allow / 1 block.
_ug_check_ipv6_host() {
  local h; h=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
  case "$h" in
    ::1)        _UG_REASON="IPv6 loopback ::1"; return 1 ;;
    ::)         _UG_REASON="IPv6 unspecified ::"; return 1 ;;
    fe[89ab]*)  _UG_REASON="IPv6 link-local fe80::/10"; return 1 ;;   # fe80–febf
    fc*|fd*)    _UG_REASON="IPv6 ULA fc00::/7"; return 1 ;;
  esac
  # embedded dotted IPv4 (v4-mapped like ::ffff:127.0.0.1) — extract + check
  local v4
  v4=$(printf '%s' "$h" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)
  if [ -n "$v4" ]; then
    _ug_check_ipv4_host "$v4"; local rc=$?
    [ "$rc" -eq 1 ] && return 1
  fi
  # v4-mapped in HEX form (::ffff:7f00:1 == 127.0.0.1) — the dotted check above
  # misses it. Extract the trailing two hex groups, fold to a dotted quad, recheck.
  case "$h" in
    *::ffff:*)
      local hx="${h##*::ffff:}"
      if printf '%s' "$hx" | grep -qE '^[0-9a-f]{1,4}:[0-9a-f]{1,4}$'; then
        local g1="${hx%%:*}" g2="${hx##*:}"
        local n1=$((16#$g1)) n2=$((16#$g2))
        local d="$(((n1>>8)&255)).$((n1&255)).$(((n2>>8)&255)).$((n2&255))"
        _ug_check_ipv4_host "$d"; [ $? -eq 1 ] && { _UG_REASON="IPv6 v4-mapped (hex ::ffff:) -> $d"; return 1; }
      fi
      ;;
  esac
  return 0
}

# validate_url <url> → rc 0 allow / 1 block / 2 usage. Reason on stderr when blocked.
validate_url() {
  _UG_REASON=""
  local url="${1:-}"
  [ -n "$url" ] || { echo "validate_url: usage: validate_url <url>" >&2; return 2; }

  # 1) scheme allowlist (case-insensitive)
  local scheme; scheme=$(printf '%s' "$url" | sed -nE 's,^([A-Za-z][A-Za-z0-9+.-]*):.*,\1,p' | tr 'A-Z' 'a-z')
  case "$scheme" in
    http|https) ;;
    "") echo "BLOCKED: no scheme (relative/opaque URL not allowed): $url" >&2; return 1 ;;
    *)  echo "BLOCKED: scheme '$scheme' not allowed (http/https only): $url" >&2; return 1 ;;
  esac

  # 2) authority = between '://' and the next '/', '?' or '#'
  local authority; authority=$(printf '%s' "$url" | sed -nE 's,^[A-Za-z][A-Za-z0-9+.-]*://([^/?#]*).*,\1,p')
  [ -n "$authority" ] || { echo "BLOCKED: empty authority: $url" >&2; return 1; }

  # 3) strip userinfo (everything up to and including the LAST '@') — defeats
  #    http://trusted.com@10.0.0.1/ where the real host is after '@'
  local hostport="${authority##*@}"

  # 4) split host / port; handle [IPv6]:port and bare IPv6
  local host
  case "$hostport" in
    \[*\]*) host="${hostport#\[}"; host="${host%%\]*}" ;;   # [::1]:80 → ::1
    *)
      if printf '%s' "$hostport" | grep -qE '^[0-9a-fA-F:]+:[0-9a-fA-F]+:' ; then
        host="$hostport"                                      # bare IPv6 (heuristic: ≥2 colons)
      else
        host="${hostport%%:*}"                                # host:port → host
      fi
      ;;
  esac
  host=$(printf '%s' "$host" | tr 'A-Z' 'a-z')
  [ -n "$host" ] || { echo "BLOCKED: empty host: $url" >&2; return 1; }

  # 5) hex-encoded host (0x..) — reject outright (obfuscation)
  case "$host" in
    0x*|*.0x*) echo "BLOCKED: hex-encoded host (obfuscation): $host" >&2; return 1 ;;
  esac

  # 6) IPv6 literal?
  if printf '%s' "$host" | grep -q ':'; then
    if ! _ug_check_ipv6_host "$host"; then
      echo "BLOCKED: $_UG_REASON ($url)" >&2; return 1
    fi
  else
    # 7) IPv4 literal / numeric form?
    _ug_check_ipv4_host "$host"; local rc=$?
    if [ "$rc" -eq 1 ]; then echo "BLOCKED: $_UG_REASON ($url)" >&2; return 1; fi
    if [ "$rc" -eq 2 ]; then
      # 8) hostname — block internal names
      case "$host" in
        localhost|*.localhost|*.local|*.internal)
          echo "BLOCKED: internal hostname: $host" >&2; return 1 ;;
      esac
      # 9) optional DNS resolution (gated; off in hermetic tests)
      if [ "${REDLOFT_URL_GUARD_RESOLVE:-0}" = "1" ]; then
        local ips
        ips=$(python3 - "$host" <<'PY' 2>/dev/null
import socket, sys
try:
    infos = socket.getaddrinfo(sys.argv[1], None)
    print("\n".join(sorted({i[4][0] for i in infos})))
except Exception:
    sys.exit(3)
PY
        )
        if [ -n "$ips" ]; then
          local ip
          while IFS= read -r ip; do
            [ -n "$ip" ] || continue
            if printf '%s' "$ip" | grep -q ':'; then
              _ug_check_ipv6_host "$ip" || { echo "BLOCKED: hostname $host resolves to private $ip" >&2; return 1; }
            else
              _ug_check_ipv4_host "$ip" >/dev/null 2>&1
              [ $? -eq 1 ] && { echo "BLOCKED: hostname $host resolves to private $ip" >&2; return 1; }
            fi
          done <<EOF
$ips
EOF
        else
          echo "warn: could not resolve $host — allowing (literal checks passed)" >&2
        fi
      fi
    fi
  fi

  return 0
}

# CLI entry — `bash lib/url-guard.sh <url>`. Detect executed-vs-sourced in a way
# that works under BOTH bash and zsh (this lib is `source`d under zsh by callers,
# where BASH_SOURCE is unset — a naive ${BASH_SOURCE:-$0} check would misfire).
_ug_sourced=1
if [ -n "${ZSH_VERSION:-}" ]; then
  case "${ZSH_EVAL_CONTEXT:-}" in *:file*) _ug_sourced=1 ;; *) _ug_sourced=0 ;; esac
elif [ -n "${BASH_VERSION:-}" ]; then
  [ "${BASH_SOURCE[0]}" = "$0" ] && _ug_sourced=0 || _ug_sourced=1
fi
if [ "$_ug_sourced" -eq 0 ]; then
  if validate_url "${1:-}"; then echo "OK: ${1:-}"; exit 0; else exit 1; fi
fi
unset _ug_sourced

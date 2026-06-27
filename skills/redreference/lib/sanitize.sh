#!/usr/bin/env bash
# sanitize.sh — two defenses, plan D3 + judge#3 (F6 prompt-injection):
#
#  strip_instructions <text>  — neutralize scraped strings (title/author/tags)
#    BEFORE they enter an agent prompt: truncate → strip injection patterns →
#    wrap in DATA_START…DATA_END delimiters. Roles MUST treat everything inside
#    the delimiters as inert data, never as instructions.
#
#  scrub_secrets              — stdin→stdout filter that redacts credential-shaped
#    tokens so nothing secret ever lands in run.log. Uses perl (BSD sed on macOS
#    lacks \b and reliable case-insensitive PCRE). The exact pattern is the
#    plan-D3 regex; tests assert scrub→0 on a Thum.io/Evomi-token fixture.

STRIP_MAXLEN="${REDREFERENCE_STRIP_MAXLEN:-280}"

strip_instructions() {
  local raw="$1"
  # 1. truncate
  raw="${raw:0:$STRIP_MAXLEN}"
  # 2. strip injection patterns (case-insensitive) — collapse to a marker
  raw=$(printf '%s' "$raw" | perl -pe '
    s/\bignore (all |previous |above )?(instructions|prompts?)\b/[stripped]/gi;
    s/\b(system|assistant|user)\s*:/[stripped]/gi;
    s/<\/?(system|instructions?|prompt)>/[stripped]/gi;
    s/\b(disregard|forget) (the |all )?(above|previous|prior)\b/[stripped]/gi;
    s/```[a-z]*//gi;                # markdown fences that could frame commands
    s/[\r\n]+/ /g;                  # no newlines inside a data field
  ')
  # 3. wrap in inert delimiters
  printf 'DATA_START %s DATA_END' "$raw"
}

scrub_secrets() {
  perl -pe '
    s{(sk-[A-Za-z0-9]{16,})}{sk-***REDACTED***}gi;
    s{(AIza[0-9A-Za-z_\-]{16,})}{AIza***REDACTED***}gi;
    s{(ghp_[A-Za-z0-9]{16,})}{ghp_***REDACTED***}gi;
    s{(op://[^\s"]+)}{op://***REDACTED***}gi;
    s{(eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+)}{eyJ***REDACTED***}gi;
    s{(socks5h?://[^\s@]+@)}{socks5://***REDACTED***@}gi;
    s{([?&](?:token|key|api_key)=)[^&\s"]+}{${1}***REDACTED***}gi;
    s{\b([0-9a-f]{32,})\b}{***REDACTED-HEX***}gi;
  '
}

# allow standalone use: `sanitize.sh strip "<text>"` / `... | sanitize.sh scrub`
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    strip) shift; strip_instructions "$*" ;;
    scrub) scrub_secrets ;;
    *) echo "usage: sanitize.sh {strip <text>|scrub <stdin}" >&2; exit 64 ;;
  esac
fi

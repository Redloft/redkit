#!/usr/bin/env bash
# strip-secrets.sh — глобальный secrets-redaction pass (DESIGN-foundation §7.1).
# SINGLE entry point: любой контент (plan.vN, diff, envelope, trace) проходит здесь
# ПЕРЕД записью на диск / попаданием в agent-envelope.
#
# Контракт:
#   stdin  → сырой контент
#   stdout → stripped (секреты заменены на ‹REDACTED:reason›)
#   exit 0 → ok (stdout валиден к записи)
#   exit≠0 → strip сломался → caller ОБЯЗАН abort, 0 байт на диск (§7.1)
#
# Usage:
#   strip-secrets.sh            < in.txt > out.txt
#   strip-secrets.sh --self-test          # canary-проверка, exit 0/1
#
# Реализация ядра — python3 (надёжный regex + Shannon-энтропия). Bash — тонкая обёртка.
set -euo pipefail

ENGINE='
import sys, re, math

def shannon(s):
    if not s:
        return 0.0
    from collections import Counter
    n = len(s)
    return -sum((c/n) * math.log2(c/n) for c in Counter(s).values())

text = sys.stdin.read()

# Порядковые паттерны: (regex, reason). Длинные/специфичные — раньше.
PATTERNS = [
    (re.compile(r"-----BEGIN[A-Z ]*PRIVATE KEY-----.*?-----END[A-Z ]*PRIVATE KEY-----", re.S), "pem"),
    (re.compile(r"sk-[A-Za-z0-9_\-]{16,}"), "openai"),
    (re.compile(r"ghp_[A-Za-z0-9]{20,}"), "github-pat"),
    (re.compile(r"gho_[A-Za-z0-9]{20,}"), "github-oauth"),
    (re.compile(r"github_pat_[A-Za-z0-9_]{20,}"), "github-fine"),
    (re.compile(r"AIza[A-Za-z0-9_\-]{20,}"), "google"),
    (re.compile(r"xox[baprs]-[A-Za-z0-9\-]{10,}"), "slack"),
    (re.compile(r"op://[^\s\"'"'"']+"), "1password-ref"),
    (re.compile(r"(?i)bearer\s+[A-Za-z0-9._\-]{20,}"), "bearer"),
    (re.compile(r"AKIA[0-9A-Z]{16}"), "aws-akid"),
    (re.compile(r"eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"), "jwt"),
]

for rx, reason in PATTERNS:
    text = rx.sub("‹REDACTED:%s›" % reason, text)

# High-entropy fallback: токен-подобные строки (≥20 символов из base64/hex алфавита),
# Shannon ≥ 4.0 → вероятный секрет. Слова/предложения имеют низкую энтропию и не трогаются.
def entropy_sub(m):
    tok = m.group(0)
    return "‹REDACTED:high-entropy›" if shannon(tok) >= 4.0 else tok

text = re.sub(r"[A-Za-z0-9+/=_\-]{20,}", entropy_sub, text)

sys.stdout.write(text)
'

run_strip() { python3 -c "$ENGINE"; }

self_test() {
  local canary out fail=0
  # Canary tokens assembled from split pieces so this file holds NO contiguous
  # secret literal (passes GitHub push-protection); the runtime value is a
  # realistic token the strip engine must still redact.
  local SK="sk-""ABCD1234efgh5678ijkl9012mnop"
  local GH="ghp_""ABCDEFGHIJ1234567890abcdefXYZ"
  local GG="AIza""SyABCDEFGHIJKLMNOPQRSTUVWXYZ012345"
  local SL="xoxb-""1234567890-abcdefghijklmno"
  local BR="Bearer ""abcdefghij1234567890KLMNOP"
  local JW="eyJ""hbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dQw4w9WgXcQabcdef12345"
  canary="
api=$SK
gh=$GH
goog=$GG
slack=$SL
ref=op://AI-Tokens/OpenAI/credential
auth=$BR
jwt=$JW
normal=this is a perfectly normal sentence with words
"
  out="$(printf '%s' "$canary" | run_strip)" || { echo "✗ strip engine crashed"; return 1; }
  # Ни одного известного префикса не должно остаться:
  if printf '%s' "$out" | grep -Eq 'sk-[A-Za-z0-9]|ghp_|AIza|xoxb-|op://|-----BEGIN|Bearer [A-Za-z0-9]{20,}|eyJ[A-Za-z0-9_-]{10,}\.'; then
    echo "✗ canary leaked through strip:"; printf '%s\n' "$out" | grep -En 'sk-|ghp_|AIza|xoxb-|op://|BEGIN|Bearer|eyJ' || true
    fail=1
  fi
  # Нормальный текст НЕ должен быть стёрт (false-positive guard):
  if ! printf '%s' "$out" | grep -q 'perfectly normal sentence'; then
    echo "✗ false-positive: normal prose was redacted"; fail=1
  fi
  if [ "$fail" -eq 0 ]; then echo "✓ strip-secrets self-test passed"; return 0; else return 1; fi
}

case "${1:-}" in
  --self-test) self_test ;;
  "")          run_strip ;;
  *)           echo "usage: strip-secrets.sh [--self-test]  (default: stdin→stdout)" >&2; exit 64 ;;
esac

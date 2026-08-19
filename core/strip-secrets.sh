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
#   strip-secrets.sh --no-entropy < in.txt > out.txt   # только паттерны, без Shannon-эвристики
#   strip-secrets.sh --self-test          # canary-проверка, exit 0/1
#
# --no-entropy: для МАШИННЫХ полей (run_id, ts, entry_point и пр.), где Shannon-fallback даёт
# чистый false positive. Проверено 2026-07-27: uuid и `<ts>-<slug>` затираются как high-entropy,
# из-за чего 3 из 71 записи ledger'а потеряли run_id. Паттерн-редакция (sk-/ghp_/PEM/...) при
# этом ОСТАЁТСЯ — режим ослабляет только эвристику, не отключает защиту.
# НЕ применять к свободному тексту (observation, gaps, plan) — там энтропия и ловит утечки.
#
# Реализация ядра — python3 (надёжный regex + Shannon-энтропия). Bash — тонкая обёртка.
set -euo pipefail

ENGINE='
import sys, re, math

NO_ENTROPY = "--no-entropy" in sys.argv[1:]

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
# ВАЖНО: "=" исключён из общего класса символов (оставлен только как base64-паддинг ≤2 хвостовых
# символа). Иначе `key=value`-присваивания (python kwargs типа node_tags=marketing_no_lifecycle)
# склеиваются в один токен через "=" и энтропия склейки пересекает порог 4.0, хотя каждая часть
# по отдельности — обычный snake_case-идентификатор. Найдено 2026-07-28.
#
# "/" исключён по ТОЙ ЖЕ причине (2026-08-19): слэш склеивал сегменты пути в один длинный токен.
# Замерено: "b/commands/plan-review" → 4.00, "a/skills/_shared/external-judge/config" → 4.19
# (оба выше порога), а их сегменты по отдельности — 2.75–3.47, то есть обычные слова.
# Последствие было тихим и крупным: snapshot.sh гонит через strip ВЕСЬ git diff, и заголовки
# `diff --git a/… b/…`, `---`, `+++` теряли имена файлов — роли /finalize на каждом прогоне
# читали диф, в котором не видно, к какому файлу относится хунк. Часть путей уцелевала
# (".../lib/ledger" = 3.56 < 4.0), из-за чего дефект выглядел случайным.
# Защита не ослаблена: base64-блоб со слэшем распадается на сегменты, и длинный сегмент
# (≥20 символов) по-прежнему ловится эвристикой, а ключи известных форматов — паттернами.
def entropy_sub(m):
    tok = m.group(0)
    return "‹REDACTED:high-entropy›" if shannon(tok) >= 4.0 else tok

if not NO_ENTROPY:
    text = re.sub(r"[A-Za-z0-9+_\-]{20,}={0,2}(?![A-Za-z0-9+=_\-])", entropy_sub, text)

sys.stdout.write(text)
'

run_strip() { python3 -c "$ENGINE" "$@"; }

self_test() {
  local canary out fail=0
  canary='
api=sk-''ABCD1234efgh5678ijkl9012mnop
gh=ghp_''ABCDEFGHIJ1234567890abcdefXYZ
goog=AIza''SyABCDEFGHIJKLMNOPQRSTUVWXYZ012345
slack=xoxb-''1234567890-abcdefghijklmno
ref=op://AI-Tokens/OpenAI/credential
auth=Bearer ''abcdefghij1234567890KLMNOP
jwt=eyJ''hbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dQw4w9WgXcQabcdef12345
normal=this is a perfectly normal sentence with words
'
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
  # ── ПУТИ ФАЙЛОВ (2026-08-19) ────────────────────────────────────────────────
  # Регресс-гард на дефект, из-за которого /finalize на КАЖДОМ прогоне отдавал ролям
  # диф с уничтоженными именами файлов (snapshot.sh гонит весь diff через strip).
  local paths_ok=1 pth
  for pth in "diff --git a/commands/plan-review.md b/commands/plan-review.md" \
             "+++ b/skills/_shared/external-judge/config.sh" \
             "--- a/skills/plan-panel/lib/ledger.sh" \
             "ENTRY=\"\$PROJECT_DIR/learnings.entry.json\""; do
    [ "$(printf '%s' "$pth" | run_strip)" = "$pth" ] || { echo "✗ путь съеден энтропией: $pth"; paths_ok=0; }
  done
  [ "$paths_ok" -eq 1 ] || fail=1
  # Обратная сторона: защита от секретов НЕ ослаблена исключением "/" из класса.
  local b64slash="QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVowMTIzNDU2Nzg5/YWJjZGVmZ2hpamtsbW5vcA=="
  printf '%s' "$b64slash" | run_strip | grep -q 'REDACTED' || { echo "✗ base64-блок со слэшем прошёл насквозь"; fail=1; }
  printf '%s' "op://AI-Tokens/OpenAI/credential" | run_strip | grep -q 'REDACTED' || { echo "✗ op://-ссылка прошла насквозь"; fail=1; }
  # ИЗВЕСТНЫЙ ОСТАТОК (не регресс, зафиксирован осознанно): секрет БЕЗ известного префикса,
  # искусственно нарезанный слэшами на куски <20 символов, эвристику пройдёт. Реальные форматы
  # (base64-блоб, JWT, PEM, sk-/ghp_/AIza/xox) ловятся паттернами либо длиной сегмента.
  # Отдельно: длинный hex-токен эвристику не ловил и ДО этой правки (энтропия hex ≈3.7 < 4.0).

  # false-positive guard: обычный python kwarg key=snake_case_value НЕ должен быть стёрт
  # (регрессия 2026-07-28: "=" в классе символов склеивал key=value в один high-entropy токен)
  local kwarg
  kwarg="$(printf 'node_tags=marketing_no_lifecycle' | run_strip)" || { echo "✗ kwarg-strip crashed"; return 1; }
  if ! printf '%s' "$kwarg" | grep -q 'node_tags=marketing_no_lifecycle'; then
    echo "✗ false-positive: kwarg-присваивание node_tags=marketing_no_lifecycle затёрто как high-entropy"; fail=1
  fi
  # --no-entropy: машинные id уцелели, но паттерн-редакция НЕ ослабла
  local ne
  ne="$(printf 'id=7c1e0a94-3b52-4d6f-9a08-2fe1b7d4c6a3 ts=2026-07-27_17-28-41-panel-v2 key=sk-''ABCD1234efgh5678ijkl9012mnop' | run_strip --no-entropy)" \
    || { echo "✗ --no-entropy crashed"; return 1; }
  if ! printf '%s' "$ne" | grep -q '7c1e0a94-3b52-4d6f-9a08-2fe1b7d4c6a3'; then
    echo "✗ --no-entropy: uuid всё равно затёрт"; fail=1
  fi
  if ! printf '%s' "$ne" | grep -q '2026-07-27_17-28-41-panel-v2'; then
    echo "✗ --no-entropy: ts-slug всё равно затёрт"; fail=1
  fi
  if printf '%s' "$ne" | grep -q 'sk-ABCD'; then
    echo "✗ --no-entropy ОСЛАБИЛ паттерн-редакцию: openai-ключ утёк"; fail=1
  fi
  # дефолтный режим на том же входе обязан затереть uuid (иначе флаг бессмыслен)
  if printf 'id=7c1e0a94-3b52-4d6f-9a08-2fe1b7d4c6a3' | run_strip | grep -q '7c1e0a94-3b52'; then
    echo "✗ дефолтный режим перестал ловить high-entropy"; fail=1
  fi
  if [ "$fail" -eq 0 ]; then echo "✓ strip-secrets self-test passed (patterns + entropy + --no-entropy)"; return 0; else return 1; fi
}

case "${1:-}" in
  --self-test)  self_test ;;
  --no-entropy) run_strip --no-entropy ;;
  "")           run_strip ;;
  *)            echo "usage: strip-secrets.sh [--no-entropy|--self-test]  (default: stdin→stdout)" >&2; exit 64 ;;
esac

#!/usr/bin/env bash
# engines/exa.sh — SourceEngine-адаптер для Exa (нейро/семантический поиск).
# Контракт SourceEngine (единый для всех движков source-hunter, plan-panel 2026-07-20):
#   stdin:  <query-строка>
#   stdout: {"engine":"exa","status":"ok|partial|failed","results":[{url,title,snippet,score,source_id}]}
#   НИКОГДА не бросает (fail-open): сеть/ключ/парс-сбой → status:"failed", results:[] , exit 0.
# Приватность: query проходит fail-closed scrub ДО отправки (как cross-model). Ключ — в 1Password,
#   в curl --config (не в argv/ps), без -v/2>&1 (secrets protocol).
#
# Usage:
#   echo "<query>" | engines/exa.sh [--num N] [--type neural|keyword|auto]
#   engines/exa.sh --self-test-offline     # парсинг фикстуры без сети (exit 0/1)
set -uo pipefail
SCRUB="$HOME/.claude/skills/_shared/external-judge/scrub.sh"
NUM=10; TYPE="neural"; SELFTEST=0
while [ $# -gt 0 ]; do case "$1" in
  --num) NUM="$2"; shift 2;;
  --type) TYPE="$2"; shift 2;;
  --self-test-offline) SELFTEST=1; shift;;
  *) shift;;
esac; done

# Нормализатор ответа Exa → контракт SourceEngine (общий для live и self-test).
_exa_parse() { # stdin: raw Exa json ; stdout: results[] json
  jq -c '[.results[]? | {
    url: .url,
    title: (.title // ""),
    snippet: ((.text // .summary // "") | .[0:300]),
    score: (.score // 0),
    source_id: "exa"
  }]' 2>/dev/null || echo '[]'
}

if [ "$SELFTEST" = 1 ]; then
  FIX='{"results":[{"url":"https://arxiv.org/abs/2301.01234","title":"A Paper","text":"long text here","score":0.83},{"url":"https://example.com/x","title":"X","score":0.5}]}'
  OUT="$(printf '%s' "$FIX" | _exa_parse)"
  n="$(printf '%s' "$OUT" | jq 'length' 2>/dev/null)"
  first_src="$(printf '%s' "$OUT" | jq -r '.[0].source_id' 2>/dev/null)"
  snip_ok="$(printf '%s' "$OUT" | jq -e '.[0].snippet|length>0' >/dev/null 2>&1 && echo 1 || echo 0)"
  if [ "$n" = "2" ] && [ "$first_src" = "exa" ] && [ "$snip_ok" = "1" ]; then
    echo "✓ exa adapter offline self-test passed"; exit 0
  else echo "✗ exa offline self-test FAILED (n=$n src=$first_src snip=$snip_ok)"; exit 1; fi
fi

# fail-open: reason в stderr (без query/ключа) для observability, контрактный JSON в stdout, exit 0
fail() { [ -n "${1:-}" ] && echo "exa: $1" >&2; printf '{"engine":"exa","status":"failed","results":[]}\n'; exit 0; }

# defense-in-depth: явно выключенный движок не делает платный вызов (тумблер читает и адаптер, не только caller)
[ "${EXA_ENABLE:-1}" = "0" ] && fail "disabled (EXA_ENABLE=0)"

QUERY="$(cat)"; [ -n "$QUERY" ] || fail "empty query"

# privacy: scrub query (fail-closed — при блоке/сбое НЕ отправляем)
if [ -f "$SCRUB" ]; then
  Q="$(printf '%s' "$QUERY" | bash "$SCRUB" 2>/dev/null)"; rc=$?
  [ "$rc" -ne 0 ] && fail "scrub blocked/failed (rc=$rc)"
  QUERY="$Q"
else fail "scrubber missing"; fi

# инъекция ключа: op run в дочерний процесс с ЗАХВАТОМ (не exec) — падение op (токен/item/PATH)
# не должно нарушать fail-open: невалидный/пустой вывод дочернего → контрактный fail().
if [ -z "${EXA_API_KEY:-}" ]; then
  CHILD="$(op run --env-file=<(printf 'EXA_API_KEY=op://AI-Tokens/Exa API/credential\n') -- bash "${BASH_SOURCE[0]}" --num "$NUM" --type "$TYPE" <<<"$QUERY" 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ] || ! printf '%s' "$CHILD" | jq -e '.status' >/dev/null 2>&1; then
    fail "op run failed (rc=$rc)"
  fi
  printf '%s\n' "$CHILD"; exit 0
fi

# бюджет-гард: pessimistic reserve ДО вызова (rc=3 over-budget → fail; rc=1 ошибка → fail-open, не блокируем)
BG="$(dirname "${BASH_SOURCE[0]}")/../budget_guard.py"
if [ -f "$BG" ]; then
  python3 "$BG" reserve exa >/dev/null 2>&1; brc=$?
  [ "$brc" = "3" ] && fail "over budget (EXA_BUDGET_USD_DAY)"
  [ "$brc" = "1" ] && echo "exa: budget-guard error (unmetered spend, fail-open)" >&2
fi

CFG="$(mktemp)"; RESP="$(mktemp)"; chmod 600 "$CFG" "$RESP"
trap 'rm -f "$CFG" "$RESP"' EXIT
printf 'header = "x-api-key: %s"\n' "$EXA_API_KEY" > "$CFG"
PAYLOAD="$(jq -nc --arg q "$QUERY" --argjson n "$NUM" --arg t "$TYPE" \
  '{query:$q, numResults:$n, type:$t, contents:{text:{maxCharacters:800}}}')"
HTTP="$(curl --silent --show-error --max-time 40 --proto '=https' --tlsv1.2 --config "$CFG" \
  -H "Content-Type: application/json" -o "$RESP" -w '%{http_code}' \
  -d "$PAYLOAD" https://api.exa.ai/search 2>/dev/null || true)"
[ "$HTTP" = "200" ] || fail "HTTP $HTTP"
RESULTS="$(_exa_parse < "$RESP")"
[ -n "$RESULTS" ] || RESULTS='[]'
jq -nc --argjson r "$RESULTS" '{engine:"exa", status:"ok", results:$r}'

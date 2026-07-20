#!/usr/bin/env bash
# engines/tavily.sh — SourceEngine-адаптер для Tavily (LLM-native быстрый поиск + синтез-ответ).
# Тот же контракт SourceEngine, что exa.sh/perplexity.sh: stdin=query → stdout {engine,status,results[]},
# fail-open, scrub перед egress, ключ 1Password 'Tavily API' (TAVILY_API_KEY), curl --config.
# Бонус: Tavily возвращает готовый .answer — кладём его в results[0] как source_id:"tavily-answer"
# (для quick-режима redresearch), обычные результаты — source_id:"tavily".
#
# Usage: echo "<query>" | engines/tavily.sh [--depth basic|advanced] [--max N] [--answer]
#        engines/tavily.sh --self-test-offline
set -uo pipefail
SCRUB="$HOME/.claude/skills/_shared/external-judge/scrub.sh"
DEPTH="basic"; MAX=8; WANT_ANSWER="true"; SELFTEST=0
while [ $# -gt 0 ]; do case "$1" in
  --depth) DEPTH="$2"; shift 2;;
  --max) MAX="$2"; shift 2;;
  --answer) WANT_ANSWER="true"; shift;;
  --no-answer) WANT_ANSWER="false"; shift;;
  --self-test-offline) SELFTEST=1; shift;;
  *) shift;;
esac; done

# rank-based score по позиции (как perplexity) — score engine-local; + опциональный answer первым.
_tav_parse() { # stdin: raw tavily json ; stdout: results[]
  jq -c '
    (if (.answer|type=="string") and (.answer|length>0)
       then [{url:"", title:"Tavily answer", snippet:(.answer|.[0:600]), score:1.0, source_id:"tavily-answer"}]
       else [] end)
    +
    ((.results // []) as $r | ($r|length) as $n |
      [ $r | to_entries[] | {url:.value.url, title:(.value.title//""),
        snippet:((.value.content//"")|.[0:300]),
        score:(.value.score // (1 - (.key/([$n,1]|max)))), source_id:"tavily"} ])
  ' 2>/dev/null || echo '[]'
}

if [ "$SELFTEST" = 1 ]; then
  FIX='{"answer":"short synthesized answer","results":[{"url":"https://a/1","title":"T1","content":"c1","score":0.9},{"url":"https://b/2","title":"T2","content":"c2","score":0.7}]}'
  OUT="$(printf '%s' "$FIX" | _tav_parse)"
  n="$(printf '%s' "$OUT" | jq 'length' 2>/dev/null)"
  has_ans="$(printf '%s' "$OUT" | jq -e 'any(.[]; .source_id=="tavily-answer")' >/dev/null 2>&1 && echo 1 || echo 0)"
  res_src="$(printf '%s' "$OUT" | jq -r '[.[]|select(.source_id=="tavily")]|.[0].source_id' 2>/dev/null)"
  if [ "$n" = "3" ] && [ "$has_ans" = "1" ] && [ "$res_src" = "tavily" ]; then
    echo "✓ tavily adapter offline self-test passed"; exit 0
  else echo "✗ tavily offline self-test FAILED (n=$n ans=$has_ans res=$res_src)"; exit 1; fi
fi

fail() { [ -n "${1:-}" ] && echo "tavily: $1" >&2; printf '{"engine":"tavily","status":"failed","results":[]}\n'; exit 0; }

[ "${TAVILY_ENABLE:-1}" = "0" ] && fail "disabled (TAVILY_ENABLE=0)"

QUERY="$(cat)"; [ -n "$QUERY" ] || fail "empty query"
if [ -f "$SCRUB" ]; then
  Q="$(printf '%s' "$QUERY" | bash "$SCRUB" 2>/dev/null)"; rc=$?; [ "$rc" -ne 0 ] && fail "scrub blocked/failed (rc=$rc)"; QUERY="$Q"
else fail "scrubber missing"; fi

# op run с захватом (не exec) — падение op не нарушает fail-open
if [ -z "${TAVILY_API_KEY:-}" ]; then
  CHILD="$(op run --env-file=<(printf 'TAVILY_API_KEY=op://AI-Tokens/Tavily API/credential\n') -- bash "${BASH_SOURCE[0]}" --depth "$DEPTH" --max "$MAX" $([ "$WANT_ANSWER" = false ] && echo --no-answer) <<<"$QUERY" 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ] || ! printf '%s' "$CHILD" | jq -e '.status' >/dev/null 2>&1; then
    fail "op run failed (rc=$rc)"
  fi
  printf '%s\n' "$CHILD"; exit 0
fi

# бюджет-гард: pessimistic reserve ДО вызова (rc=3 over → fail; rc=1 ошибка → fail-open)
BG="$(dirname "${BASH_SOURCE[0]}")/../budget_guard.py"
if [ -f "$BG" ]; then
  python3 "$BG" reserve tavily >/dev/null 2>&1; brc=$?
  [ "$brc" = "3" ] && fail "over budget (TAVILY_BUDGET_USD_DAY)"
  [ "$brc" = "1" ] && echo "tavily: budget-guard error (unmetered spend, fail-open)" >&2
fi

CFG="$(mktemp)"; RESP="$(mktemp)"; chmod 600 "$CFG" "$RESP"
trap 'rm -f "$CFG" "$RESP"' EXIT
printf 'header = "Authorization: Bearer %s"\n' "$TAVILY_API_KEY" > "$CFG"
PAYLOAD="$(jq -nc --arg q "$QUERY" --arg d "$DEPTH" --argjson m "$MAX" --argjson a "$WANT_ANSWER" \
  '{query:$q, search_depth:$d, max_results:$m, include_answer:$a}')"
HTTP="$(curl --silent --show-error --max-time 30 --proto '=https' --tlsv1.2 --config "$CFG" \
  -H "Content-Type: application/json" -o "$RESP" -w '%{http_code}' \
  -d "$PAYLOAD" https://api.tavily.com/search 2>/dev/null || true)"
[ "$HTTP" = "200" ] || fail "HTTP $HTTP"
RESULTS="$(_tav_parse < "$RESP")"; [ -n "$RESULTS" ] || RESULTS='[]'
jq -nc --argjson r "$RESULTS" '{engine:"tavily", status:"ok", results:$r}'

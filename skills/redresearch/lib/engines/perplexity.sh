#!/usr/bin/env bash
# engines/perplexity.sh — SourceEngine-адаптер для Perplexity Sonar (grounding-поиск с цитатами).
# Тот же контракт SourceEngine, что exa.sh: stdin=query → stdout {engine,status,results[]}, fail-open.
# Приватность: query через fail-closed scrub. Ключ 1Password 'Perplexity API' (PPLX_API_KEY), curl --config.
#
# Usage: echo "<query>" | engines/perplexity.sh [--model sonar|sonar-pro]
#        engines/perplexity.sh --self-test-offline
set -uo pipefail
SCRUB="$HOME/.claude/skills/_shared/external-judge/scrub.sh"
MODEL="sonar"; SELFTEST=0
while [ $# -gt 0 ]; do case "$1" in
  --model) MODEL="$2"; shift 2;;
  --self-test-offline) SELFTEST=1; shift;;
  *) shift;;
esac; done

# Sonar отдаёт .search_results[] (новый формат) ИЛИ .citations[] (старый, только url).
# score: rank-based псевдо-релевантность (1 - idx/n) по позиции цитаты — не хардкод 0, иначе
# Perplexity систематически проигрывает merge против Exa. score — engine-local (см. README).
_pplx_parse() { # stdin: raw pplx json ; stdout: results[]
  jq -c 'def rank(arr; f): (arr|length) as $n | [arr | to_entries[] | (f + {score: (1 - (.key/([$n,1]|max)))})];
         if (.search_results|type=="array") then
           rank(.search_results; {url:.value.url, title:(.value.title//""), snippet:((.value.snippet//"")|.[0:300]), source_id:"perplexity"})
         elif (.citations|type=="array") then
           rank(.citations; {url:.value, title:"", snippet:"", source_id:"perplexity"})
         else [] end' 2>/dev/null || echo '[]'
}

if [ "$SELFTEST" = 1 ]; then
  FIX='{"search_results":[{"url":"https://a.com/1","title":"T1","snippet":"s1"},{"url":"https://b.com/2","title":"T2","snippet":"s2"}]}'
  OUT="$(printf '%s' "$FIX" | _pplx_parse)"
  FIX2='{"citations":["https://c.com/3"]}'; OUT2="$(printf '%s' "$FIX2" | _pplx_parse)"
  n="$(printf '%s' "$OUT" | jq 'length' 2>/dev/null)"; s="$(printf '%s' "$OUT" | jq -r '.[0].source_id' 2>/dev/null)"
  n2="$(printf '%s' "$OUT2" | jq 'length' 2>/dev/null)"
  if [ "$n" = "2" ] && [ "$s" = "perplexity" ] && [ "$n2" = "1" ]; then
    echo "✓ perplexity adapter offline self-test passed"; exit 0
  else echo "✗ perplexity offline self-test FAILED (n=$n s=$s n2=$n2)"; exit 1; fi
fi

fail() { [ -n "${1:-}" ] && echo "perplexity: $1" >&2; printf '{"engine":"perplexity","status":"failed","results":[]}\n'; exit 0; }

[ "${PPLX_ENABLE:-1}" = "0" ] && fail "disabled (PPLX_ENABLE=0)"

QUERY="$(cat)"; [ -n "$QUERY" ] || fail "empty query"
if [ -f "$SCRUB" ]; then
  Q="$(printf '%s' "$QUERY" | bash "$SCRUB" 2>/dev/null)"; rc=$?; [ "$rc" -ne 0 ] && fail "scrub blocked/failed (rc=$rc)"; QUERY="$Q"
else fail "scrubber missing"; fi

# op run с захватом (не exec): падение op не должно нарушать fail-open
if [ -z "${PPLX_API_KEY:-}" ]; then
  CHILD="$(op run --env-file=<(printf 'PPLX_API_KEY=op://AI-Tokens/Perplexity API/credential\n') -- bash "${BASH_SOURCE[0]}" --model "$MODEL" <<<"$QUERY" 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ] || ! printf '%s' "$CHILD" | jq -e '.status' >/dev/null 2>&1; then
    fail "op run failed (rc=$rc)"
  fi
  printf '%s\n' "$CHILD"; exit 0
fi

# бюджет-гард: pessimistic reserve ДО вызова (rc=3 over → fail; rc=1 ошибка → fail-open)
BG="$(dirname "${BASH_SOURCE[0]}")/../budget_guard.py"
if [ -f "$BG" ]; then
  python3 "$BG" reserve perplexity >/dev/null 2>&1; brc=$?
  [ "$brc" = "3" ] && fail "over budget (PPLX_BUDGET_USD_DAY)"
  [ "$brc" = "1" ] && echo "perplexity: budget-guard error (unmetered spend, fail-open)" >&2
fi

CFG="$(mktemp)"; RESP="$(mktemp)"; chmod 600 "$CFG" "$RESP"
trap 'rm -f "$CFG" "$RESP"' EXIT
printf 'header = "Authorization: Bearer %s"\n' "$PPLX_API_KEY" > "$CFG"
PAYLOAD="$(jq -nc --arg m "$MODEL" --arg q "$QUERY" \
  '{model:$m, messages:[{role:"user",content:("Найди авторитетные первоисточники по: "+$q)}]}')"
HTTP="$(curl --silent --show-error --max-time 60 --proto '=https' --tlsv1.2 --config "$CFG" \
  -H "Content-Type: application/json" -o "$RESP" -w '%{http_code}' \
  -d "$PAYLOAD" https://api.perplexity.ai/chat/completions 2>/dev/null || true)"
[ "$HTTP" = "200" ] || fail "HTTP $HTTP"
RESULTS="$(_pplx_parse < "$RESP")"; [ -n "$RESULTS" ] || RESULTS='[]'
jq -nc --argjson r "$RESULTS" '{engine:"perplexity", status:"ok", results:$r}'

#!/usr/bin/env bash
# Wordstat adapter — Yandex Cloud Search API v2 (/v2/wordstat). Частотность +
# ассоциации (topRequests). Секрет (Api-Key) и folderId инъектятся ТОЛЬКО через
# `op run` в дочерний процесс. 🔒 Без `-v`/`2>&1` (Api-Key не должен утечь в логи).
#
# Auth: header `Authorization: Api-Key $YANDEX_AI_API_KEY`; folderId в теле.
# Item: AI-Tokens/"Yandex Wordstat API" (credential + folder_id).
#
# Usage:
#   wordstat.sh <phrase> [--region 213] [--num 50]
#   wordstat.sh --self-test
#
# Output (stdout): JSON { source:"wordstat", seed, region, keywords:[{phrase, freq}] }
set -euo pipefail

VAULT="AI-Tokens"; ITEM="Yandex Wordstat API"
ENDPOINT="https://searchapi.api.cloud.yandex.net/v2/wordstat/topRequests"
ENVFILE=$(printf 'YANDEX_AI_API_KEY=op://%s/%s/credential\nYANDEX_FOLDER_ID=op://%s/%s/folder_id\n' "$VAULT" "$ITEM" "$VAULT" "$ITEM")

PHRASE="${1:-}"; REGION="213"; NUM="50"

if [ "$PHRASE" = "--self-test" ]; then
  # Минимальный вызов; проверяем только наличие topRequests в ответе (без -v/stderr).
  resp=$(op run --env-file=<(printf '%s' "$ENVFILE") -- bash -c '
    curl -s --max-time 15 -X POST "'"$ENDPOINT"'" \
      -H "Authorization: Api-Key $YANDEX_AI_API_KEY" \
      -H "Content-Type: application/json" \
      -d "{\"phrase\":\"сайт для бани\",\"numPhrases\":3,\"regions\":[\"213\"],\"folderId\":\"$YANDEX_FOLDER_ID\"}"
  ' 2>/dev/null) || { echo "✗ wordstat self-test: op run failed (креды заполнены?)"; exit 1; }
  if printf '%s' "$resp" | jq -e '.totalCount or .results or .associations' >/dev/null 2>&1; then
    n=$(printf '%s' "$resp" | jq -r '((.results // [])|length) + ((.associations // [])|length)')
    tc=$(printf '%s' "$resp" | jq -r '.totalCount // "?"')
    echo "✅ wordstat self-test OK (results+associations: $n; totalCount: $tc)"; exit 0
  else
    code=$(printf '%s' "$resp" | jq -r '.code // .message // (.error|tostring) // "unexpected response"' 2>/dev/null)
    echo "✗ wordstat self-test failed: $code"; exit 1
  fi
fi

[ -n "$PHRASE" ] || { echo "usage: wordstat.sh <phrase> [--region 213] [--num 50]" >&2; exit 64; }
shift || true
while [ "$#" -gt 0 ]; do
  case "$1" in
    --region) REGION="$2"; shift 2 ;;
    --num) NUM="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done

# Тело без folderId — передаём в child через env (не через хрупкий вложенный
# квотинг). folderId добавляет jq внутри child из $YANDEX_FOLDER_ID.
export WS_BODY="$(jq -nc --arg p "$PHRASE" --argjson n "$NUM" --arg r "$REGION" \
  '{phrase:$p, numPhrases:$n, regions:[$r]}')"

resp=$(op run --env-file=<(printf '%s' "$ENVFILE") -- bash -c '
  body="$(jq -nc --argjson b "$WS_BODY" --arg f "$YANDEX_FOLDER_ID" "\$b + {folderId:\$f}")"
  curl -s --max-time 30 -X POST "'"$ENDPOINT"'" \
    -H "Authorization: Api-Key $YANDEX_AI_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$body"
' 2>/dev/null) || { echo '{"source":"wordstat","error":"op run failed","keywords":[]}'; exit 0; }

# count приходит строкой (int64) — приводим к числу. Мёржим results (фразы с
# запросом) + associations (ассоциации), дедуп по нормализованной фразе.
printf '%s' "$resp" | jq -c --arg seed "$PHRASE" --arg region "$REGION" '
  (((.results // []) + (.associations // []))
    | map({phrase:.phrase, freq:((.count // "0")|tonumber)})
    | unique_by(.phrase|ascii_downcase|gsub("\\s+";" "))) as $kw
  | {source:"wordstat", seed:$seed, region:$region,
     total_count:(.totalCount // null), keyword_count:($kw|length), keywords:$kw}
' 2>/dev/null || echo '{"source":"wordstat","error":"parse failed","keywords":[]}'

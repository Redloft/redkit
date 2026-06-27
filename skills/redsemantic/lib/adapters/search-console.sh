#!/usr/bin/env bash
# Search Console adapter — реальные запросы из выдачи (Search Analytics API).
# ТОЛЬКО для СУЩЕСТВУЮЩИХ верифицированных сайтов. OAuth2 refresh-token flow:
# адаптер сам минтит короткоживущий access_token из refresh_token (не хранит
# истекающий токен). Все секреты через `op run`. 🔒 Без `-v`/`2>&1`.
#
# Item: AI-Tokens/"Google Search Console":
#   client_id[text] · client_secret[concealed] · credential[concealed]=refresh_token · site_url[text]
# Scope: https://www.googleapis.com/auth/webmasters.readonly
#
# Usage:
#   search-console.sh [site_url] [--days 90] [--rows 250]   # site_url опц.: иначе из item
#   search-console.sh --self-test
#
# Output (stdout): JSON { source:"search-console", site, keywords:[{phrase, freq:clicks, impressions, position}] }
set -euo pipefail

VAULT="AI-Tokens"; ITEM="Google Search Console"
API="https://www.googleapis.com/webmasters/v3"
PLACEHOLDER="ЗАПОЛНИ-В-1PASSWORD"
ENVFILE=$(printf 'GSC_CLIENT_ID=op://%s/%s/client_id\nGSC_CLIENT_SECRET=op://%s/%s/client_secret\nGSC_REFRESH_TOKEN=op://%s/%s/credential\n' \
  "$VAULT" "$ITEM" "$VAULT" "$ITEM" "$VAULT" "$ITEM")

# site_url: не секрет — читаем из item (arg переопределяет)
_item_site() {
  op item get "$ITEM" --vault "$VAULT" --format json 2>/dev/null \
    | jq -r '(.fields[]?|select(.label=="site_url")|.value)//""' 2>/dev/null || echo ""
}
_creds_ready() {
  local v
  for f in client_id credential; do
    v=$(op item get "$ITEM" --vault "$VAULT" --format json 2>/dev/null | jq -r --arg l "$f" '(.fields[]?|select(.label==$l)|.value)//""' 2>/dev/null)
    [ -n "$v" ] && [ "$v" != "$PLACEHOLDER" ] || return 1
  done
  return 0
}

SITE=""; DAYS="90"; ROWS="250"; SELFTEST=0
# первый arg: --self-test | site_url (позиционный) | флаг (тогда site из item)
case "${1:-}" in
  --self-test) SELFTEST=1; shift ;;
  --*|"") ;;                       # флаг или пусто → site_url возьмём из item
  *) SITE="$1"; shift ;;           # позиционный site_url
esac

if ! op item get "$ITEM" --vault "$VAULT" --format json >/dev/null 2>&1; then
  [ "$SELFTEST" -eq 1 ] && { echo "⚠️  search-console: item '$ITEM' не заведён (опционально)"; exit 3; }
  echo '{"source":"search-console","error":"no credential item (optional adapter)","keywords":[]}'; exit 0
fi
if ! _creds_ready; then
  [ "$SELFTEST" -eq 1 ] && { echo "⚠️  search-console: креды '$ITEM' не заполнены (client_id/refresh_token = плейсхолдеры). Адаптер пропускается."; exit 3; }
  echo '{"source":"search-console","error":"credentials not filled (optional)","keywords":[]}'; exit 0
fi

# parse remaining flags
while [ "$#" -gt 0 ]; do
  case "$1" in
    --days) DAYS="$2"; shift 2 ;;
    --rows) ROWS="$2"; shift 2 ;;
    --self-test) SELFTEST=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done

# mint access_token from refresh_token, then call GSC — всё внутри одного child.
run_gsc() { # $1 = inner curl command building on $ACCESS
  op run --env-file=<(printf '%s' "$ENVFILE") -- bash -c '
    ACCESS="$(curl -s --max-time 15 -X POST "https://oauth2.googleapis.com/token" \
      -d "client_id=$GSC_CLIENT_ID" -d "client_secret=$GSC_CLIENT_SECRET" \
      -d "refresh_token=$GSC_REFRESH_TOKEN" -d "grant_type=refresh_token" | jq -r ".access_token // empty")"
    [ -n "$ACCESS" ] || { echo "{\"error\":\"token refresh failed\"}"; exit 0; }
    '"$1"'
  ' 2>/dev/null
}

if [ "$SELFTEST" -eq 1 ]; then
  resp=$(run_gsc 'curl -s --max-time 15 -H "Authorization: Bearer $ACCESS" "'"$API"'/sites"') \
    || { echo "✗ search-console self-test: op run failed"; exit 1; }
  if printf '%s' "$resp" | jq -e '.siteEntry' >/dev/null 2>&1; then
    n=$(printf '%s' "$resp" | jq -r '.siteEntry|length')
    echo "✅ search-console self-test OK (refresh→access ok; $n verified properties)"; exit 0
  elif printf '%s' "$resp" | jq -e '.error' >/dev/null 2>&1; then
    echo "✗ search-console self-test: $(printf '%s' "$resp" | jq -r '.error|if type=="object" then (.message//tostring) else tostring end')"; exit 1
  else
    echo "✗ search-console self-test: 0 verified properties (добавь сайт в GSC) или scope без webmasters"; exit 1
  fi
fi

[ -n "$SITE" ] || SITE="$(_item_site)"
[ -n "$SITE" ] && [ "$SITE" != "$PLACEHOLDER" ] || { echo '{"source":"search-console","error":"no site_url (arg or item field)","keywords":[]}'; exit 0; }

end=$(date -u +%Y-%m-%d)
start=$(date -u -v-"${DAYS}"d +%Y-%m-%d 2>/dev/null || date -u -d "-${DAYS} days" +%Y-%m-%d)
enc_site=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$SITE")
export GSC_QBODY="$(jq -nc --arg s "$start" --arg e "$end" --argjson rows "$ROWS" \
  '{startDate:$s, endDate:$e, dimensions:["query"], rowLimit:$rows}')"

resp=$(run_gsc 'curl -s --max-time 30 -H "Authorization: Bearer $ACCESS" -H "Content-Type: application/json" \
  -X POST "'"$API"'/sites/'"$enc_site"'/searchAnalytics/query" -d "$GSC_QBODY"') \
  || { echo '{"source":"search-console","error":"op run failed","keywords":[]}'; exit 0; }

printf '%s' "$resp" | jq -c --arg site "$SITE" '
  if .rows then
    {source:"search-console", site:$site, keyword_count:(.rows|length),
     keywords:(.rows | map({phrase:.keys[0], freq:(.clicks//0), impressions:(.impressions//0), position:(.position//null)}))}
  else
    {source:"search-console", error:(.error.message // (.error|tostring) // "no rows"), keywords:[]}
  end
' 2>/dev/null || echo '{"source":"search-console","error":"parse failed","keywords":[]}'

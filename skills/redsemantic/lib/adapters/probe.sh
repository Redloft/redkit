#!/usr/bin/env bash
# redsemantic capability probe. Контракт: docs/probe-contract.md.
#   presence (default): какие credential-поля заполнены (дёшево, без сети).
#   --smoke: лёгкий data-запрос под region/site → returns_data per-adapter
#            (отличает «credentialed» от «реально вернул данные»).
#
# 🔒 НИКОГДА не печатает значения секретов (presence — boolean; smoke — rc + свой reason,
# без raw-ответа API, особенно GSC/PII). Не использует `op read`/`--reveal`/`-v`.
#
# Usage: probe.sh [--names]
#        probe.sh --smoke [--region <r>] [--site <url>] [--names]
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT="AI-Tokens"
PLACEHOLDER="ЗАПОЛНИ-В-1PASSWORD"

NAMES=0; SMOKE=0; REGION="Москва"; SITE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --names) NAMES=1; shift ;;
    --smoke) SMOKE=1; shift ;;
    --region) REGION="${2:-Москва}"; shift 2 ;;
    --site) SITE="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

_field_set() {
  local item="$1" label="$2" v
  v=$(op item get "$item" --vault "$VAULT" --format json 2>/dev/null \
        | jq -r --arg l "$label" '(.fields[]?|select(.label==$l)|.value) // ""' 2>/dev/null) || v=""
  if [ -n "$v" ] && [ "$v" != "$PLACEHOLDER" ]; then echo "true"; else echo "false"; fi
}

# ── presence (credentialed) ──
suggest_ok=true
ws_cred=$(_field_set "Yandex Wordstat API" "credential"); ws_folder=$(_field_set "Yandex Wordstat API" "folder_id")
[ "$ws_cred" = "true" ] && [ "$ws_folder" = "true" ] && wordstat_ok=true || wordstat_ok=false
dfs_login=$(_field_set "DataForSEO" "login"); dfs_pass=$(_field_set "DataForSEO" "API password")
[ "$dfs_login" = "true" ] && [ "$dfs_pass" = "true" ] && dataforseo_ok=true || dataforseo_ok=false
gsc_cid=$(_field_set "Google Search Console" "client_id"); gsc_rt=$(_field_set "Google Search Console" "credential")
[ "$gsc_cid" = "true" ] && [ "$gsc_rt" = "true" ] && gsc_ok=true || gsc_ok=false

# ── smoke (returns_data) — только при --smoke ──
# каждый: echo "<returns_data:true|false>\t<reason>"
_smoke_suggest() { bash "$DIR/suggest.sh" --self-test >/dev/null 2>&1 && echo "true	ok" || echo "false	suggest endpoint не ответил"; }
_smoke_wordstat() {
  [ "$wordstat_ok" = "true" ] || { echo "false	credential не заполнен"; return; }
  bash "$DIR/wordstat.sh" --self-test >/dev/null 2>&1 && echo "true	topRequests ok" || echo "false	Wordstat не вернул данные"
}
_smoke_dataforseo() {
  [ "$dataforseo_ok" = "true" ] || { echo "false	credential не заполнен"; return; }
  if ! bash "$DIR/dataforseo.sh" --geo-check "$REGION" >/dev/null 2>&1; then
    echo "false	'$REGION': keyword/SERP заблокирован (Google Ads-санкции) — DataForSEO для РФ не даёт данных; on-page/tech работают"
    return
  fi
  bash "$DIR/dataforseo.sh" --probe >/dev/null 2>&1 && echo "true	data-эндпоинт доступен (verified+funded)" || echo "false	аккаунт не verified / нет баланса"
}
# нормализация хоста: strip scheme / sc-domain: / www. / trailing slash, lowercase
_host() { printf '%s' "$1" | tr 'A-Z' 'a-z' | sed -E 's#^https?://##; s#^sc-domain:##; s#^www\.##; s#/.*$##'; }
_smoke_gsc() {
  [ "$gsc_ok" = "true" ] || { echo "false	credential не заполнен"; return; }
  # property-match: GSC привязан к КОНКРЕТНОМУ сайту; для existing-site (--site) он
  # бесполезен/вреден, если bound-property ≠ site прогона (иначе чужие запросы текут в семантику).
  if [ -n "$SITE" ]; then
    local bound bh sh
    bound=$(op item get "Google Search Console" --vault "$VAULT" --format json 2>/dev/null | jq -r '(.fields[]?|select(.label=="site_url")|.value)//""')
    bh=$(_host "$bound"); sh=$(_host "$SITE")
    if [ -n "$bh" ] && [ -n "$sh" ] && [ "$bh" != "$sh" ]; then
      echo "false	GSC привязан к '$bound' ≠ site прогона ($sh) — привяжи property $sh к OAuth-аккаунту (search.google.com), иначе чужие запросы"
      return
    fi
  fi
  bash "$DIR/search-console.sh" --self-test >/dev/null 2>&1 && echo "true	property привязана, sites доступны" || echo "false	property не привязана к OAuth / 0 verified sites — привяжи в search.google.com"
}

smoke_json=""
returns_any=0
if [ "$SMOKE" = "1" ]; then
  _kv() { local cred="$1" line="$2"; local rd="${line%%	*}" reason="${line#*	}"
    jq -nc --argjson c "$cred" --argjson r "$rd" --arg reason "$reason" '{credentialed:$c, returns_data:$r, reason:$reason}'; }
  s_sg=$(_kv true "$(_smoke_suggest)")
  s_ws=$(_kv "$wordstat_ok" "$(_smoke_wordstat)")
  s_df=$(_kv "$dataforseo_ok" "$(_smoke_dataforseo)")
  s_gsc=$(_kv "$gsc_ok" "$(_smoke_gsc)")
  smoke_json=$(jq -nc --argjson sg "$s_sg" --argjson ws "$s_ws" --argjson df "$s_df" --argjson gsc "$s_gsc" \
    '{suggest:$sg, wordstat:$ws, dataforseo:$df, "search-console":$gsc}')
  # returns_any из готового JSON (НЕ из subshell-инкремента — терялся)
  [ "$(printf '%s' "$smoke_json" | jq '[.[]|.returns_data]|any')" = "true" ] && returns_any=1
fi

# ── --names ──
if [ "$NAMES" = "1" ]; then
  if [ "$SMOKE" = "1" ]; then
    printf '%s\n' "$smoke_json" | jq -r 'to_entries|map(select(.value.returns_data))|map(.key)|join(" ")'
  else
    avail=(); [ "$suggest_ok" = true ] && avail+=(suggest); [ "$wordstat_ok" = true ] && avail+=(wordstat)
    [ "$dataforseo_ok" = true ] && avail+=(dataforseo); [ "$gsc_ok" = true ] && avail+=("search-console")
    printf '%s\n' "${avail[*]}"
  fi
  exit 0
fi

# ── full JSON ──
avail=(); [ "$suggest_ok" = true ] && avail+=(suggest); [ "$wordstat_ok" = true ] && avail+=(wordstat)
[ "$dataforseo_ok" = true ] && avail+=(dataforseo); [ "$gsc_ok" = true ] && avail+=("search-console")
jq -nc \
  --argjson suggest "$suggest_ok" --argjson wordstat "$wordstat_ok" \
  --argjson dataforseo "$dataforseo_ok" --argjson gsc "$gsc_ok" \
  --argjson list "$(printf '%s\n' "${avail[@]:-}" | jq -R . | jq -sc 'map(select(length>0))')" \
  --argjson smoke "${smoke_json:-null}" \
  '{available:$list, detail:{suggest:$suggest, wordstat:$wordstat, dataforseo:$dataforseo, "search-console":$gsc}}
   + (if $smoke then {smoke:$smoke} else {} end)'

# exit protocol (smoke)
if [ "$SMOKE" = "1" ]; then [ "$returns_any" = "1" ] && exit 0 || exit 2; fi
exit 0

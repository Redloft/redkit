#!/usr/bin/env bash
# DataForSEO multi-method adapter (Phase 1, v2). Контракт: docs/adapter-contract.md.
# Единый envelope, cost-cap (mkdir-lock, atomic), кэш, SSRF+injection guard,
# netrc (нет кредов в ps aux), exit-семантика, fixtures для hermetic-тестов.
#
# 🔒 Секреты только через `op run` + --netrc-file. Без `-v`/`2>&1`/`curl -u`.
# _call() работает в ТЕКУЩЕЙ оболочке (НЕ через $()), чтобы _RESP/_CACHE_HIT
# и cap-exit не терялись в подоболочке.
set -uo pipefail

VAULT="AI-Tokens"; ITEM="DataForSEO"
SCHEMA_VERSION=1
API_HOST="api.dataforseo.com"
API_BASE="https://$API_HOST/v3"

# ── config (env) ──
DFS_RUN_ID="${DFS_RUN_ID:-$$}"
DFS_MAX_CALLS="${DFS_MAX_CALLS:-50}"
DFS_MAX_COST_USD="${DFS_MAX_COST_USD:-}"        # пусто = без лимита
DFS_DAILY_HARD="${DFS_DAILY_HARD:-}"
DFS_DAILY_SOFT="${DFS_DAILY_SOFT:-}"
DFS_CACHE_DIR="${DFS_CACHE_DIR:-$HOME/.cache/dataforseo}"
DFS_PROJECT_SLUG="${DFS_PROJECT_SLUG:-shared}"
DFS_DISABLED="${DFS_DISABLED:-}"
DFS_METHODS_ENABLED="${DFS_METHODS_ENABLED:-}"  # пусто = все
DFS_FIXTURE_DIR="${DFS_FIXTURE_DIR:-}"
DFS_RECORD="${DFS_RECORD:-}"
# ⚠️ Россия НЕ поддерживается DataForSEO (Google Ads-санкции): Labs+SERP отклоняют
# RU-локацию (40501). DataForSEO = только non-RU. Дефолт — US/en; RU-проекты на Wordstat.
LANGN="${DFS_LANG:-English}"; LOCN="${DFS_LOCATION:-United States}"

CAP_DIR="${TMPDIR:-/tmp}/dfs-cap"
PII_METHODS=" ranked competitors onpage ai-vis tech business "
_CACHE_HIT=false
_RESP=""

# ── envelope ──
_emit_err() { jq -nc --arg m "$1" --arg c "$2" --arg msg "${3:-}" \
  '{ok:false,source:"dataforseo",method:$m,error_code:$c,error_message:$msg}'; }
_err() { _emit_err "$1" "$2" "${3:-}"; exit 1; }          # top-level (current shell)
_ok()  { jq -nc --arg m "$1" --argjson d "$2" --argjson sv "$SCHEMA_VERSION" \
  --argjson cost "${3:-0}" --argjson ch "${4:-false}" \
  '{ok:true,source:"dataforseo",method:$m,schema_version:$sv,cost_estimate:$cost,cache_hit:$ch,data:$d}'; exit 0; }

# ── validation / injection guard ──
_validate_keyword() { case "$1" in *'$'*|*'`'*|*';'*|*'|'*|*'&'*|*'<'*|*'>'*|*'('*|*')'*|*'{'*|*'}'*|*'"'*|*'\'*) return 1;; *) [ -n "$1" ];; esac; }
_validate_domain()  { printf '%s' "$1" | grep -qiE '^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$'; }
_validate_url() {
  printf '%s' "$1" | grep -qiE '^https://' || return 1
  if [ -f "$HOME/.claude/skills/redloft/lib/url-guard.sh" ]; then
    ( source "$HOME/.claude/skills/redloft/lib/url-guard.sh" >/dev/null 2>&1; validate_url "$1" >/dev/null 2>&1 )
  else
    case "$1" in *127.0.0.1*|*localhost*|*169.254.*|*//10.*|*192.168.*) return 1;; *) return 0;; esac
  fi
}

# ── geo-routing: keyword/SERP/Labs данные недоступны для РФ/РБ (Google Ads-санкции);
# On-Page/Backlinks (URL/domain) — geo-независимы. Оркестратор роутит RU→Wordstat. ──
# Явные классы [Мм] — кириллица не сворачивается grep -i в C-локали macOS.
DFS_UNSUPPORTED_GEO_RE="${DFS_UNSUPPORTED_GEO_RE:-russia|russian federation|belarus|[Рр]осси|[Мм]оскв|[Сс]анкт|[Пп]етербург|[Сс][Пп][Бб]|[Бб]еларус|[Мм]инск}"
_geo_keyword_supported() { # <location/region> → 0 supported, 1 not
  printf '%s' "$1" | grep -qiE "$DFS_UNSUPPORTED_GEO_RE" && return 1 || return 0
}
_geo_guard() { # <method> <location> — _err при недоступности (без billable-вызова)
  _geo_keyword_supported "$2" || _err "$1" geo_unsupported "DataForSEO не имеет keyword/SERP-данных для '$2' (Google Ads-санкции). Для РФ — Wordstat; On-Page/Backlinks работают."
}

# ── float helpers ──
_fadd() { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{printf "%.6f", a+b}'; }
_fgt()  { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{exit !(a>b)}'; }

# ── cost-cap: atomic read-check-incr-write под mkdir-lock. sets _RESP+return1 при превышении ──
_cap_check_and_incr() { # <method> <cost>
  local method="$1" cost="$2"
  mkdir -p "$CAP_DIR" 2>/dev/null
  local lock="$CAP_DIR/.lock" run_f="$CAP_DIR/run-$DFS_RUN_ID"
  local day; day="$(date +%Y-%m-%d)"; local daily_f="$DFS_CACHE_DIR/spend-$day.tally"
  mkdir -p "$DFS_CACHE_DIR" 2>/dev/null; chmod 700 "$DFS_CACHE_DIR" 2>/dev/null || true
  local n=0
  while ! mkdir "$lock" 2>/dev/null; do n=$((n+1)); [ "$n" -gt 100 ] && rm -rf "$lock" 2>/dev/null; sleep 0.05; done
  local rcalls rcost; read -r rcalls rcost < "$run_f" 2>/dev/null || { rcalls=0; rcost=0; }
  [ -n "${rcalls:-}" ] || rcalls=0; [ -n "${rcost:-}" ] || rcost=0
  local dcost; dcost=$(awk -F'\t' '{s+=$3} END{printf "%.6f", s+0}' "$daily_f" 2>/dev/null || echo 0)
  local fail=""
  [ "$((rcalls+1))" -gt "$DFS_MAX_CALLS" ] && fail="per-run call cap $DFS_MAX_CALLS reached"
  [ -z "$fail" ] && [ -n "$DFS_MAX_COST_USD" ] && _fgt "$(_fadd "$rcost" "$cost")" "$DFS_MAX_COST_USD" && fail="per-run cost cap \$$DFS_MAX_COST_USD reached"
  [ -z "$fail" ] && [ -n "$DFS_DAILY_HARD" ] && _fgt "$(_fadd "$dcost" "$cost")" "$DFS_DAILY_HARD" && fail="daily hard cap \$$DFS_DAILY_HARD reached"
  if [ -n "$fail" ]; then rmdir "$lock" 2>/dev/null; _RESP="$(_emit_err "$method" cap_exceeded "$fail")"; return 1; fi
  printf '%s %s\n' "$((rcalls+1))" "$(_fadd "$rcost" "$cost")" > "$run_f"
  printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$method" "$cost" "$DFS_RUN_ID" >> "$daily_f"
  local newd; newd=$(_fadd "$dcost" "$cost")
  rmdir "$lock" 2>/dev/null
  [ -n "$DFS_DAILY_SOFT" ] && _fgt "$newd" "$DFS_DAILY_SOFT" && echo "DFS_ALERT daily spend \$$newd > soft \$$DFS_DAILY_SOFT" >&2
  printf 'DFS_COST {"method":"%s","cost_estimate":%s,"cache_hit":false,"run_total":%s,"run_calls":%s}\n' \
    "$method" "$cost" "$(_fadd "$rcost" "$cost")" "$((rcalls+1))" >&2
  return 0
}

# ── cache ──
_cache_dir_for() { case "$PII_METHODS" in *" $1 "*) echo "$DFS_CACHE_DIR/$DFS_PROJECT_SLUG";; *) echo "$DFS_CACHE_DIR/shared";; esac; }
_cache_key() { printf '%s' "$*" | shasum -a 256 | cut -d' ' -f1; }
_cache_ttl() { case "$1" in serp|ai-vis) echo 86400;; ranked|onpage|competitors) echo 259200;; *) echo 604800;; esac; }
_cache_get() { local d; d="$(_cache_dir_for "$1")"; local f="$d/$2.json" m="$d/$2.meta"
  [ -f "$f" ] && [ -f "$m" ] || return 1
  local ca ttl; ca=$(jq -r '.cached_at//0' "$m" 2>/dev/null); ttl=$(jq -r '.ttl//0' "$m" 2>/dev/null)
  [ "$(( $(date +%s) - ca ))" -lt "$ttl" ] || return 1
  cat "$f"; }
_cache_put() { local d; d="$(_cache_dir_for "$1")"; mkdir -p "$d" 2>/dev/null; chmod 700 "$DFS_CACHE_DIR" "$d" 2>/dev/null || true
  printf '%s' "$3" > "$d/$2.json"
  jq -nc --argjson t "$(_cache_ttl "$1")" --argjson c "$(date +%s)" '{cached_at:$c,ttl:$t,status_code:20000}' > "$d/$2.meta"; }

# ── live call (op run + netrc; нет кредов в argv/ps) ──
_live() { export DFS_URLPATH="$1" DFS_BODY="$2" DFS_VERB="${3:-POST}"
  op run --env-file=<(printf 'DFS_LOGIN=op://%s/%s/login\nDFS_API_PASS=op://%s/%s/API password\n' "$VAULT" "$ITEM" "$VAULT" "$ITEM") -- bash -c '
    set +x
    nf=$(mktemp); chmod 600 "$nf"
    printf "machine '"$API_HOST"' login %s password %s\n" "$DFS_LOGIN" "$DFS_API_PASS" > "$nf"
    if [ "$DFS_VERB" = "GET" ]; then
      out=$(curl -s --max-time 40 --netrc-file "$nf" "'"$API_BASE"'$DFS_URLPATH")
    else
      out=$(curl -s --max-time 40 --netrc-file "$nf" -H "Content-Type: application/json" -X POST "'"$API_BASE"'$DFS_URLPATH" -d "$DFS_BODY")
    fi
    rc=$?; rm -f "$nf"; printf "%s" "$out"; exit $rc
  ' 2>/dev/null; }

# ── core (current shell): cap → cache → fixture|live → status. sets _RESP/_CACHE_HIT; return 0/1 ──
_call() { # <method> <urlpath> <body> <cost> <ckargs> [verb]
  local method="$1" urlpath="$2" body="$3" cost="$4" ckargs="$5" verb="${6:-POST}"
  _CACHE_HIT=false; _RESP=""
  [ -n "$DFS_DISABLED" ] && { _RESP="$(_emit_err "$method" disabled 'DFS_DISABLED set')"; return 1; }
  if [ -n "$DFS_METHODS_ENABLED" ]; then case ",$DFS_METHODS_ENABLED," in *",$method,"*) ;; *) _RESP="$(_emit_err "$method" disabled 'not in DFS_METHODS_ENABLED')"; return 1;; esac; fi
  local key; key="$(_cache_key "$method|$ckargs")"
  local cached; if cached="$(_cache_get "$method" "$key")"; then _CACHE_HIT=true; _RESP="$cached"; return 0; fi
  _cap_check_and_incr "$method" "$cost" || return 1     # sets _RESP on cap
  if [ -n "$DFS_FIXTURE_DIR" ]; then
    [ -f "$DFS_FIXTURE_DIR/$method.json" ] || { _RESP="$(_emit_err "$method" parse_error "no fixture $method.json")"; return 1; }
    _RESP="$(cat "$DFS_FIXTURE_DIR/$method.json")"
  else
    _RESP="$(_live "$urlpath" "$body" "$verb")" || { _RESP="$(_emit_err "$method" timeout 'curl failed')"; return 1; }
  fi
  [ -n "$_RESP" ] || { _RESP="$(_emit_err "$method" parse_error 'empty response')"; return 1; }
  # top-level статус (auth/account)
  local status; status="$(printf '%s' "$_RESP" | jq -r '.status_code // empty' 2>/dev/null)"
  if [ "$status" != "20000" ]; then
    local sm; sm="$(printf '%s' "$_RESP" | jq -r '.status_message // "non-20000"' 2>/dev/null)"
    _RESP="$(_emit_err "$method" "api_${status:-unknown}" "$sm")"; return 1
  fi
  # task-level статус (DataForSEO отдаёт 20000 наверху даже при ошибке задачи)
  local tstatus; tstatus="$(printf '%s' "$_RESP" | jq -r '.tasks[0].status_code // empty' 2>/dev/null)"
  if [ -n "$tstatus" ] && [ "$tstatus" != "20000" ]; then
    local tsm; tsm="$(printf '%s' "$_RESP" | jq -r '.tasks[0].status_message // "task error"' 2>/dev/null)"
    _RESP="$(_emit_err "$method" "api_${tstatus}" "$tsm")"; return 1
  fi
  [ -n "$DFS_RECORD" ] && [ -n "$DFS_FIXTURE_DIR" ] && printf '%s' "$_RESP" > "$DFS_FIXTURE_DIR/$method.json"
  _cache_put "$method" "$key" "$_RESP"
  return 0
}

# helper: run _call; on failure print _RESP + exit
_run() { _call "$@" || { printf '%s' "$_RESP"; exit 1; }; }

# ── body builders ──
_body_kw_single() { jq -nc --arg k "$1" --arg ln "$LANGN" --arg loc "$LOCN" --argjson lim "${2:-100}" '[{keyword:$k,language_name:$ln,location_name:$loc,limit:$lim,include_seed_keyword:true}]'; }
_body_kw_array()  { jq -nc --argjson ks "$1" --arg ln "$LANGN" --arg loc "$LOCN" '[{keywords:$ks,language_name:$ln,location_name:$loc}]'; }
_body_target()    { jq -nc --arg t "$1" --arg ln "$LANGN" --arg loc "$LOCN" --argjson lim "${2:-100}" '[{target:$t,language_name:$ln,location_name:$loc,limit:$lim}]'; }
_csv_to_json()    { printf '%s' "$1" | jq -Rc 'split(",")|map(gsub("^\\s+|\\s+$";""))|map(select(length>0))'; }

# ── methods ──
# парсер: первый позиционный = subject; флаги --limit/--region/--live
_subject=""; _limit=100; _region=""; _serp_live=""
_parse_args() { _subject="${1:-}"; shift || true; _limit=100; _region=""; _serp_live=""
  while [ "$#" -gt 0 ]; do case "$1" in
    --limit) _limit="${2:-100}"; shift 2 || shift;;
    --region) _region="${2:-}"; shift 2 || shift;;
    --live) _serp_live=1; shift;;
    *) shift;; esac; done; }

m_related() { _parse_args "$@"; _validate_keyword "$_subject" || _err related bad_input "invalid keyword"; _geo_guard related "$LOCN"
  _run related /dataforseo_labs/google/related_keywords/live "$(_body_kw_single "$_subject" "$_limit")" 0.02 "$_subject|$_limit|$LOCN"
  _ok related "$(printf '%s' "$_RESP" | jq -c '{keywords:[.tasks[]?.result[]?.items[]?.keyword_data|{phrase:.keyword,freq:(.keyword_info.search_volume//null),intent:(.search_intent_info.main_intent//null)}]}')" 0.02 "$_CACHE_HIT"; }

m_suggestions() { _parse_args "$@"; _validate_keyword "$_subject" || _err suggestions bad_input "invalid keyword"; _geo_guard suggestions "$LOCN"
  _run suggestions /dataforseo_labs/google/keyword_suggestions/live "$(_body_kw_single "$_subject" "$_limit")" 0.02 "$_subject|$_limit|$LOCN"
  _ok suggestions "$(printf '%s' "$_RESP" | jq -c '{keywords:[.tasks[]?.result[]?.items[]?.keyword_data|{phrase:.keyword,freq:(.keyword_info.search_volume//null),intent:(.search_intent_info.main_intent//null)}]}')" 0.02 "$_CACHE_HIT"; }

m_overview() { _validate_keyword "${1:-}" || _err overview bad_input "invalid keywords"; _geo_guard overview "$LOCN"; local ks; ks="$(_csv_to_json "$1")"; [ "$(printf '%s' "$ks"|jq 'length')" -gt 0 ] || _err overview bad_input "no keywords"
  _run overview /dataforseo_labs/google/keyword_overview/live "$(_body_kw_array "$ks")" 0.015 "$1|$LOCN"
  _ok overview "$(printf '%s' "$_RESP" | jq -c '{keywords:[.tasks[]?.result[]?.items[]?|{phrase:.keyword,freq:(.keyword_info.search_volume//null),difficulty:(.keyword_properties.keyword_difficulty//null),intent:(.search_intent_info.main_intent//null)}]}')" 0.015 "$_CACHE_HIT"; }

m_intent() { _validate_keyword "${1:-}" || _err intent bad_input "invalid keywords"; _geo_guard intent "$LOCN"; local ks; ks="$(_csv_to_json "$1")"; [ "$(printf '%s' "$ks"|jq 'length')" -gt 0 ] || _err intent bad_input "no keywords"
  _run intent /dataforseo_labs/google/search_intent/live "$(_body_kw_array "$ks")" 0.005 "$1|$LOCN"
  _ok intent "$(printf '%s' "$_RESP" | jq -c '{keywords:[.tasks[]?.result[]?.items[]?|{phrase:.keyword,intent:(.keyword_intent.label//null)}]}')" 0.005 "$_CACHE_HIT"; }

m_volume() { _validate_keyword "${1:-}" || _err volume bad_input "invalid keywords"; _geo_guard volume "$LOCN"; local ks; ks="$(_csv_to_json "$1")"; [ "$(printf '%s' "$ks"|jq 'length')" -gt 0 ] || _err volume bad_input "no keywords"
  _run volume /keywords_data/google_ads/search_volume/live "$(_body_kw_array "$ks")" 0.01 "$1|$LOCN"
  _ok volume "$(printf '%s' "$_RESP" | jq -c '{keywords:[.tasks[]?.result[]?|{phrase:.keyword,freq:(.search_volume//null)}]}')" 0.01 "$_CACHE_HIT"; }

m_ranked() { _parse_args "$@"; _validate_domain "$_subject" || _err ranked bad_input "invalid domain"; _geo_guard ranked "$LOCN"
  _run ranked /dataforseo_labs/google/ranked_keywords/live "$(_body_target "$_subject" "$_limit")" 0.02 "$_subject|$_limit|$LOCN"
  _ok ranked "$(printf '%s' "$_RESP" | jq -c --arg d "$_subject" '{domain:$d,items:[.tasks[]?.result[]?.items[]?|{phrase:.keyword_data.keyword,freq:(.keyword_data.keyword_info.search_volume//null),position:(.ranked_serp_element.serp_item.rank_absolute//null),url:(.ranked_serp_element.serp_item.url//null)}]}')" 0.02 "$_CACHE_HIT"; }

m_competitors() { _parse_args "$@"; _validate_domain "$_subject" || _err competitors bad_input "invalid domain"; _geo_guard competitors "$LOCN"
  _run competitors /dataforseo_labs/google/competitors_domain/live "$(_body_target "$_subject" "$_limit")" 0.02 "$_subject|$LOCN"
  _ok competitors "$(printf '%s' "$_RESP" | jq -c --arg d "$_subject" '{domain:$d,items:[.tasks[]?.result[]?.items[]?|{competitor_domain:.domain,intersections:(.intersections//null),avg_position:(.avg_position//null)}]}')" 0.02 "$_CACHE_HIT"; }

m_serp() { _parse_args "$@"; _validate_keyword "$_subject" || _err serp bad_input "invalid keyword"
  local loc="${_region:-$LOCN}"; _geo_guard serp "$loc"
  local body; body="$(jq -nc --arg k "$_subject" --arg ln "$LANGN" --arg loc "$loc" '[{keyword:$k,language_name:$ln,location_name:$loc,depth:20}]')"
  _run serp /serp/google/organic/live/advanced "$body" 0.002 "$_subject|$loc"
  _ok serp "$(printf '%s' "$_RESP" | jq -c --arg k "$_subject" '{keyword:$k,results:[.tasks[]?.result[]?.items[]?|select(.type=="organic")|{type:.type,position:.rank_absolute,title:.title,url:.url}],paa:[.tasks[]?.result[]?.items[]?|select(.type=="people_also_ask")|.items[]?.title],featured:[.tasks[]?.result[]?.items[]?|select(.type=="featured_snippet")|.title]}')" 0.002 "$_CACHE_HIT"; }

m_onpage() { _validate_url "$1" || _err onpage ssrf_blocked "url not https/public: $1"
  local body; body="$(jq -nc --arg u "$1" '[{url:$u,enable_javascript:false}]')"
  _run onpage /on_page/instant_pages "$body" 0.000125 "$1"
  _ok onpage "$(printf '%s' "$_RESP" | jq -c --arg u "$1" '{url:$u,onpage_score:(.tasks[]?.result[]?.items[]?.onpage_score//null),checks:(.tasks[]?.result[]?.items[]?.checks//{})}')" 0.000125 "$_CACHE_HIT"; }

m_tech() { _validate_domain "$1" || _err tech bad_input "invalid domain"   # geo-независим (по домену)
  _run tech /domain_analytics/technologies/domain_technologies/live "$(jq -nc --arg t "$1" '[{target:$t}]')" 0.011 "$1"
  _ok tech "$(printf '%s' "$_RESP" | jq -c --arg d "$1" '{domain:$d, technologies:(.tasks[0].result[0].technologies // {}), groups:(.tasks[0].result[0].technologies|keys? // [])}')" 0.011 "$_CACHE_HIT"; }

m_business() { _parse_args "$@"; _validate_keyword "$_subject" || _err business bad_input "invalid query"   # Maps SERP — geo-restricted
  local loc="${_region:-$LOCN}"; _geo_guard business "$loc"
  local body; body="$(jq -nc --arg k "$_subject" --arg ln "$LANGN" --arg loc "$loc" '[{keyword:$k,language_name:$ln,location_name:$loc,depth:20}]')"
  _run business /serp/google/maps/live/advanced "$body" 0.002 "$_subject|$loc"
  _ok business "$(printf '%s' "$_RESP" | jq -c --arg k "$_subject" '{query:$k, listings:[.tasks[0].result[0].items[]?|select(.type=="maps_search")|{title:.title,rating:(.rating.value//null),reviews:(.rating.votes_count//null),address:.address,domain:.domain}]}')" 0.002 "$_CACHE_HIT"; }

m_ai_vis() { [ -n "$DFS_FIXTURE_DIR" ] || _err ai-vis not_implemented "ai-vis exploratory: только fixture-mode в Phase 1"
  _run ai-vis /ai_optimization/ai_keyword_data/keywords_search_volume/live "{}" 0.01 "$1"
  _ok ai-vis "$(printf '%s' "$_RESP" | jq -c --arg t "$1" '{target:$t,citations:(.tasks[]?.result//[])}')" 0.01 "$_CACHE_HIT"; }

# ── probe ── auth+balance (user_data, free) И реальный data-access (cheapest serp,
# ~$0.0006; до верификации аккаунт даёт 40104 без списания). verified = data-endpoint 20000.
m_probe() {
  if [ -n "$DFS_FIXTURE_DIR" ]; then
    local r; r="$(cat "$DFS_FIXTURE_DIR/probe.json" 2>/dev/null || echo '{}')"
    local b; b="$(printf '%s' "$r" | jq -r '.tasks[0].result[0].money.balance // 0' 2>/dev/null)"
    [ "$(printf '%s' "$r" | jq -r '.status_code//empty')" = "20000" ] && _fgt "$b" 0 \
      && { jq -nc --argjson b "$b" '{ok:true,dataforseo_ok:true,dataforseo_funded:true,dataforseo_verified:true,dataforseo_balance:$b}'; exit 0; } \
      || { jq -nc '{ok:false,dataforseo_verified:false,error_code:"not_verified"}'; exit 1; }
  fi
  local ud; ud="$(_live /appendix/user_data "" GET)" || { echo '{"ok":false,"dataforseo_ok":false,"error_code":"timeout"}'; exit 1; }
  local ustatus bal; ustatus="$(printf '%s' "$ud" | jq -r '.status_code//empty' 2>/dev/null)"
  bal="$(printf '%s' "$ud" | jq -r '.tasks[0].result[0].money.balance // 0' 2>/dev/null)"
  local auth_ok=false funded=false; [ "$ustatus" = "20000" ] && auth_ok=true; _fgt "$bal" 0 && funded=true
  # реальный data-access ping (cheapest)
  local ping pstatus; ping="$(_live /serp/google/organic/live/regular '[{"keyword":"test","language_name":"English","location_name":"United States","depth":1}]')"
  pstatus="$(printf '%s' "$ping" | jq -r '.status_code//empty' 2>/dev/null)"
  if [ "$pstatus" = "20000" ]; then
    jq -nc --argjson b "$bal" '{ok:true,dataforseo_ok:true,dataforseo_funded:true,dataforseo_verified:true,dataforseo_balance:$b,note:"ready"}'; exit 0
  else
    local pmsg; pmsg="$(printf '%s' "$ping" | jq -r '.status_message // "data endpoint not ready"' 2>/dev/null)"
    jq -nc --argjson ao "$auth_ok" --argjson fu "$funded" --argjson b "${bal:-0}" --arg ps "${pstatus:-none}" --arg msg "$pmsg" \
      '{ok:false,dataforseo_ok:$ao,dataforseo_funded:$fu,dataforseo_verified:false,dataforseo_balance:$b,error_code:("data_"+$ps),error_message:$msg}'; exit 1
  fi
}

# ── geo-check (для оркестратора: роутинг RU→Wordstat vs intl→DataForSEO) ──
m_geo_check() {
  local loc="$1" sup
  if _geo_keyword_supported "$loc"; then sup=true; else sup=false; fi
  jq -nc --arg l "$loc" --argjson s "$sup" \
    '{location:$l, supported_keyword:$s, note:(if $s then "keyword/SERP available" else "keyword/SERP NOT available (sanctions); RU→Wordstat; On-Page/Backlinks work" end)}'
  [ "$sup" = true ] && exit 0 || exit 1
}

# ── dispatch ──
usage() { echo "usage: dataforseo.sh <related|suggestions|volume|overview|intent|ranked|competitors|serp|onpage|tech|business|ai-vis> <args> | --probe | --geo-check <region> | <keyword>(alias related)" >&2; exit 64; }
[ "$#" -ge 1 ] || usage
M="$1"; shift || true
case "$M" in
  --probe|--self-test) m_probe ;;
  --geo-check) m_geo_check "${1:-}" ;;
  related) m_related "$@" ;;
  suggestions) m_suggestions "$@" ;;
  overview) m_overview "$@" ;;
  intent) m_intent "$@" ;;
  volume) m_volume "$@" ;;
  ranked) m_ranked "$@" ;;
  competitors) m_competitors "$@" ;;
  serp) m_serp "$@" ;;
  onpage) m_onpage "$@" ;;
  tech) m_tech "$@" ;;
  business) m_business "$@" ;;
  ai-vis) m_ai_vis "$@" ;;
  -*) usage ;;
  *) echo "DFS_DEPRECATED: bare keyword → method 'related'" >&2; m_related "$M" "$@" ;;
esac

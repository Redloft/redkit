#!/usr/bin/env bash
# round.sh — the taste loop orchestrator (plan Stage D, "докрутка петли").
# Ties adapters + WAL + page + taste into one repeatable cycle with REAL
# cross-round dedup (WAL captures-index), a per-round size cap, and an anchored
# brief so query-expansion stays on the user's stated style.
#
#   round.sh start  <brief>                     → make a run, store the brief, echo RUN_DIR
#   round.sh next   <run_dir> <round_n> [page]  → fetch+dedup+cap → WAL pending → build page
#                                                  echoes PAGE=/NONCE=/QUERY=/COUNT=
#   round.sh ingest <run_dir> <round_n> <answers.json>
#                                                → validate → WAL answers+commit → taste update
#                                                  echoes summary + NEXT_QUERY + STOP
#
# Interactive transport is caller-driven (Claude opens the page / takes pasted
# JSON). Adapters used: arena.sh (live). Add more adapters in _fetch_round.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/heartbeat.sh"
# shellcheck source=/dev/null
source "$HERE/wal.sh"
# shellcheck source=/dev/null
source "$HERE/log.sh" 2>/dev/null || true

ROUND_SIZE="${REDREFERENCE_ROUND_SIZE:-12}"

_slug() { printf '%s' "$1" | head -c 200 | python3 -c "
import sys,re
T={'а':'a','б':'b','в':'v','г':'g','д':'d','е':'e','ё':'yo','ж':'zh','з':'z','и':'i','й':'y','к':'k','л':'l','м':'m','н':'n','о':'o','п':'p','р':'r','с':'s','т':'t','у':'u','ф':'f','х':'kh','ц':'ts','ч':'ch','ш':'sh','щ':'sch','ъ':'','ы':'y','ь':'','э':'e','ю':'yu','я':'ya'}
s=sys.stdin.read().lower().strip(); s=''.join(T.get(c,c) for c in s)
print(re.sub(r'[^a-z0-9]+','-',s).strip('-')[:40] or 'vkus')"; }

# fetch raw cards for a query (one card JSON per line). REDREFERENCE_MOCK_RAW=<file>
# bypasses the network (hermetic tests). Intent routes the adapter pool (P2):
#   site → galleries lead (Awwwards/Behance) — commercial websites/landings/apps
#   mood → Are.na leads (more channels) — moodboards / textures / brand aesthetics
# Counts are the lever; round-robin in dedup-cards.py keeps the mix balanced.
_fetch_round() {   # <query> <round_n> <page> <intent>
  local q="$1" rn="$2" page="$3" intent="${4:-site}"
  if [ -n "${REDREFERENCE_MOCK_RAW:-}" ] && [ -f "$REDREFERENCE_MOCK_RAW" ]; then
    cat "$REDREFERENCE_MOCK_RAW"; return 0
  fi
  local ar aw be
  case "$intent" in
    mood) ar=3; aw=4; be=4 ;;   # Are.na n_channels=3 (capped), galleries secondary
    *)    ar=2; aw=8; be=8 ;;   # site default: galleries lead, Are.na light
  esac
  bash "$HERE/adapters/arena.sh"    search "$q" "$rn" "$ar" "$page" 2>/dev/null || true
  bash "$HERE/adapters/awwwards.sh" search "$q" "$rn" "$aw" "$page" 2>/dev/null || true
  bash "$HERE/adapters/behance.sh"  search "$q" "$rn" "$be" "$page" 2>/dev/null || true
  # (design-inspiration MCP is added caller-side: caller pipes its parse output here)
}

# resolve_query — single source of truth for the round's anchor (plan 1.4).
# Priority: steer.txt (P5 mid-loop override) > brief-keys.json query_tags (P1
# distillation) > brief.txt (legacy raw brief). Echoes the anchor string.
resolve_query() {  # <run_dir>  (each level trimmed; whitespace-only → next level)
  local rd="$1" v
  _trim() { tr -s ' \t\r\n' ' ' | sed 's/^ *//; s/ *$//'; }
  if [ -s "$rd/steer.txt" ]; then
    v=$(_trim < "$rd/steer.txt"); [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  fi
  local bk="$rd/brief-keys.json"
  if [ -f "$bk" ]; then
    v=$(jq -r 'if (.query_tags|type=="array") and ([.query_tags[]|select(type=="string" and (gsub("^\\s+|\\s+$";"")|length)>0)]|length>0) then ([.query_tags[]|select(type=="string" and (gsub("^\\s+|\\s+$";"")|length)>0)]|join(" ")) else empty end' "$bk" 2>/dev/null)
    if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
    echo "round.sh: brief-keys.json present but query_tags empty/invalid → falling back to raw brief" >&2
  fi
  v=$(_trim < "$rd/brief.txt" 2>/dev/null)
  [ -n "$v" ] && printf '%s' "$v" || printf 'design reference'
}

# _read_intent — validated intent for source-routing (default site).
_read_intent() {  # <run_dir>
  local bk="$1/brief-keys.json"
  [ -f "$bk" ] || { echo site; return 0; }
  local it; it=$(jq -r '.intent // "site"' "$bk" 2>/dev/null)
  case "$it" in
    site|mood) printf '%s' "$it" ;;
    *) echo "round.sh: brief-keys.json invalid intent '$it' → site" >&2; printf 'site' ;;
  esac
}

case "${1:-}" in
  start)
    BRIEF="${2:-}"; [ -n "$BRIEF" ] || { echo "usage: round.sh start <brief>" >&2; exit 64; }
    SLUG=$(_slug "$BRIEF")
    OUT=$(bash "$HERE/persist.sh" "$SLUG"); RUN_DIR="${OUT%|*}"
    RUN_ID=$(uuidgen | tr 'A-Z' 'a-z')
    init_status "$RUN_DIR" "$SLUG" "standard" "$RUN_ID"
    log_init "$RUN_DIR" "$RUN_ID" 2>/dev/null || true; log_event run_start 2>/dev/null || true
    printf '%s' "$BRIEF" > "$RUN_DIR/brief.txt"
    wal_recover "$RUN_DIR" 2>/dev/null || true
    echo "RUN_DIR=$RUN_DIR"
    ;;

  next)
    RUN_DIR="${2:-}"; RN="${3:-1}"; PAGE="$RN"; STEER=""
    [ -d "$RUN_DIR" ] || { echo "usage: round.sh next <run_dir> <round_n> [page] [--steer \"<dir>\"]" >&2; exit 64; }
    shift 3 2>/dev/null || true
    while [ "$#" -gt 0 ]; do      # optional: [page] and/or --steer "<dir>" (P5)
      case "$1" in
        --steer) STEER="${2:-}"; shift 2 ;;
        ''|*[!0-9]*) shift ;;
        *) PAGE="$1"; shift ;;
      esac
    done
    # P5 mid-loop steer: override the query for THIS and following rounds until reset
    [ -n "$STEER" ] && { printf '%s' "$STEER" > "$RUN_DIR/steer.txt"; echo "STEERED=$STEER" >&2; }
    log_attach "$RUN_DIR" 2>/dev/null || true
    INTENT=$(_read_intent "$RUN_DIR")
    ANCHOR=$(resolve_query "$RUN_DIR")           # steer > brief-keys > brief.txt (P1)
    # query: round 1 = anchor (distilled keys / steer / brief); later = taste-expansion off the anchor
    if [ "$RN" -le 1 ]; then QUERY="$ANCHOR"; else QUERY=$(node "$HERE/taste.js" query "$RUN_DIR" "$ANCHOR" 2>/dev/null || printf '%s' "$ANCHOR"); fi
    [ -n "$QUERY" ] || QUERY="$ANCHOR"

    IDX="$RUN_DIR/captures/captures-index.json"; [ -f "$IDX" ] || echo '{}' > "$IDX"
    CAP="$RUN_DIR/captures/captures.jsonl"
    MAXID=$( [ -f "$CAP" ] && jq -s 'if length>0 then (max_by(.id).id) else 0 end' "$CAP" 2>/dev/null || echo 0 ); MAXID=${MAXID:-0}

    RAW=$(_fetch_round "$QUERY" "$RN" "$PAGE" "$INTENT")
    # P6: top-up a thin round BEFORE showing — accumulate RAW across up to 2 extra
    # pages, then ONE final dedup (consistent global-id assignment). MOCK disables
    # top-up (hermeticity). The intermediate dedups only count; output discarded.
    _dedup_count() { printf '%s' "$1" | IDX="$IDX" MAXID="$MAXID" CAP_N="$ROUND_SIZE" RN="$RN" python3 "$HERE/dedup-cards.py" 2>/dev/null | grep -c . || true; }
    MIN="${REDREFERENCE_ROUND_MIN:-6}"
    if [ -z "${REDREFERENCE_MOCK_RAW:-}" ]; then
      topup=0
      while [ "$(_dedup_count "$RAW")" -lt "$MIN" ]; do
        [ "$topup" -ge 2 ] && { echo "COUNT_BELOW_MIN=$(_dedup_count "$RAW")" >&2; break; }
        topup=$((topup + 1))
        MORE=$(_fetch_round "$QUERY" "$RN" $((PAGE + topup)) "$INTENT")
        [ -n "$MORE" ] && RAW="$RAW
$MORE" || break
      done
    fi
    # final single dedup vs committed index + within-batch, cap, assign global ids
    ROUND_CARDS="$RUN_DIR/page/round-${RN}-cards.jsonl"; mkdir -p "$RUN_DIR/page"
    printf '%s' "$RAW" | IDX="$IDX" MAXID="$MAXID" CAP_N="$ROUND_SIZE" RN="$RN" \
      python3 "$HERE/dedup-cards.py" > "$ROUND_CARDS"
    COUNT=$(wc -l < "$ROUND_CARDS" | tr -d ' ')

    # validate each, drop invalid (CARD_INVALID), keep the rest
    : > "$ROUND_CARDS.ok"
    while IFS= read -r c; do [ -n "$c" ] || continue
      if printf '%s' "$c" | node "$HERE/validate-card.js" >/dev/null 2>&1; then printf '%s\n' "$c" >> "$ROUND_CARDS.ok"
      else log_event card_invalid 2>/dev/null || true; fi
    done < "$ROUND_CARDS"
    mv "$ROUND_CARDS.ok" "$ROUND_CARDS"
    COUNT=$(wc -l < "$ROUND_CARDS" | tr -d ' ')
    [ "$COUNT" -ge 1 ] || { echo "QUERY=$QUERY"; echo "INTENT=$INTENT"; echo "COUNT=0"; echo "(no fresh cards — broaden brief or try later)"; exit 0; }

    # WAL: open the round, stage the cards
    NONCE=$(uuidgen | tr 'A-Z' 'a-z')
    wal_begin "$RUN_DIR" "$RN" "$NONCE" 2>/dev/null || { wal_rollback "$RUN_DIR" "$RN"; wal_begin "$RUN_DIR" "$RN" "$NONCE"; }
    while IFS= read -r c; do [ -n "$c" ] && wal_card "$RUN_DIR" "$RN" "$c"; done < "$ROUND_CARDS"

    PAGE_HTML="$RUN_DIR/page/round-${RN}.html"
    node "$HERE/build-page.js" --cards "$ROUND_CARDS" --out "$PAGE_HTML" --round "$RN" --nonce "$NONCE" >/dev/null
    log_event round_start round="$RN" cards="$COUNT" 2>/dev/null || true
    echo "QUERY=$QUERY"
    echo "INTENT=$INTENT"
    echo "NONCE=$NONCE"
    echo "COUNT=$COUNT"
    echo "PAGE=$PAGE_HTML"
    ;;

  ingest)
    RUN_DIR="${2:-}"; RN="${3:-1}"; ANS="${4:-}"
    [ -d "$RUN_DIR" ] && [ -f "$ANS" ] || { echo "usage: round.sh ingest <run_dir> <round_n> <answers.json>" >&2; exit 64; }
    log_attach "$RUN_DIR" 2>/dev/null || true
    # validate answers; drop invalid
    OKN=0; BADN=0
    while IFS= read -r a; do [ -n "$a" ] || continue
      if printf '%s' "$a" | node "$HERE/validate-card.js" --feedback >/dev/null 2>&1; then
        wal_answer "$RUN_DIR" "$RN" "$a"; OKN=$((OKN+1))
      else BADN=$((BADN+1)); fi
    done < <(jq -c '.answers[]' "$ANS")
    wal_commit "$RUN_DIR" "$RN" 2>/dev/null
    node "$HERE/taste.js" update "$RUN_DIR" "$RN" >/dev/null
    log_event round_commit round="$RN" answers="$OKN" 2>/dev/null || true
    ANCHOR=$(resolve_query "$RUN_DIR")           # distilled keys / steer / brief
    PROF="$RUN_DIR/captures/taste-profile.json"
    # P3: resolve card_id → title/ref_url from the round's cards so likes are
    # legible without digging round-*.jsonl (dedup/cap reshuffle ids).
    RC="$RUN_DIR/page/round-${RN}-cards.jsonl"
    if [ -f "$RC" ]; then
      echo "VOTED:"
      jq -c '.answers[]|select(.verdict!="skip" and .verdict!=null)' "$ANS" 2>/dev/null | while IFS= read -r a; do
        cid=$(printf '%s' "$a" | jq -r '.card_id'); v=$(printf '%s' "$a" | jq -r '.verdict')
        ttl=$(jq -r --argjson id "$cid" 'select(.id==$id)|.title' "$RC" 2>/dev/null | head -1)
        ref=$(jq -r --argjson id "$cid" 'select(.id==$id)|.ref_url' "$RC" 2>/dev/null | head -1)
        printf '  #%s [%s] %s — %s\n' "$cid" "$v" "${ttl:-?}" "${ref:-?}"
      done
    fi
    # actual committed rounds → stop streak boundary (P7, fixes off-by-one)
    CR=$(ls "$RUN_DIR"/phases/round-*.committed.jsonl 2>/dev/null | sed -E 's/.*round-([0-9]+)\.committed.*/\1/' | sort -n | paste -sd, -)
    echo "INGESTED=$OKN INVALID=$BADN"
    echo "LIKES=$(jq -r '.likes' "$PROF") PRIORITY=$(jq -c '.priority_cards' "$PROF") ANTI=$(jq -r '.anti_references|length' "$PROF")"
    echo "UX_PREF=$(jq -r '.ux_pref' "$PROF") UI_PREF=$(jq -r '.ui_pref' "$PROF")"
    echo "NEXT_QUERY=$(node "$HERE/taste.js" query "$RUN_DIR" "$ANCHOR" 2>/dev/null)"
    echo "STOP=$(node "$HERE/taste.js" stop "$RUN_DIR" "$RN" --committed-rounds "${CR:-}" 2>/dev/null)"
    ;;

  *)
    echo "usage: round.sh {start <brief>|next <run_dir> <round_n> [page]|ingest <run_dir> <round_n> <answers.json>}" >&2
    exit 64
    ;;
esac

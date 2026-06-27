#!/usr/bin/env bash
# adapters/behance.sh — Class-B scraper adapter for Behance project search.
# Adobe closed the public API (~2020); the search page embeds the full store
# state as JSON in <script type="application/json" id="beconfig-store_state">,
# projects under .search.projects.search.nodes[] (24/page). No GraphQL needed.
#
# Endpoint reality (verified 2026-06-11):
#   GET https://www.behance.net/search/projects?search=<q>[&sort=...] → 200 via
#   cffi_get (autoproxy/redproxy kicks in on IP-block). &page= is DEAD (infinite
#   scroll) — depth across rounds comes from rotating &sort= by page number:
#   1 → relevance (default) · 2 → published_date · 3 → appreciations · then
#   repeat (cross-round dedup is the caller's job via WAL captures-index).
#
# Subcommands (fetch separated from parse → hermetic smoke):
#   behance.sh extract <search.html>              # HTML → fixture JSON {nodes:[...]}
#   behance.sh parse   <fixture.json> [round=1]   # pure: fixture → card lines
#   behance.sh search  "<query>" [round=1] [n_cards=12] [page=1]   # live
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$(cd "$HERE/.." && pwd)"

# search-page HTML (file arg) → {nodes:[...]} subtree of the embedded store state
_extract() {      # <search.html>
  python3 - "$1" <<'PYEOF'
import sys, re, json
s = open(sys.argv[1], encoding="utf-8", errors="replace").read()
m = re.search(r'<script type="application/json" id="beconfig-store_state">(.*?)</script>', s, re.S)
if not m:
    print(json.dumps({"nodes": []})); sys.exit(0)
try:
    d = json.loads(m.group(1))
    nodes = d["search"]["projects"]["search"]["nodes"]
except (json.JSONDecodeError, KeyError, TypeError):
    nodes = []
print(json.dumps({"nodes": nodes}, ensure_ascii=False))
PYEOF
}

# fixture JSON {nodes:[...]} (stdin) → normalized card lines
_parse() {        # <round>
  local round="$1"
  jq -c --argjson round "$round" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    def hex2: . | floor | if . < 0 then 0 elif . > 255 then 255 else . end
      | [(. / 16 | floor), (. % 16)]
      | map(if . < 10 then 48 + . else 87 + . end) | implode;
    [ (.nodes // [])[]
      | select(((.url // "") | test("^https://")) and (.isPrivate != true))
      | ((.covers.size_808.url // .covers.size_404.url
          // (.covers.allAvailable // [] | .[0].url) // .covers.size_115.url // "")) as $thumb
      | select($thumb | test("^https://"))
      | {
          source: "behance",
          source_url: .url,
          ref_url: .url,
          title: (((.name // "") | tostring | gsub("[\r\n]+";" ") | .[0:280])
                  | (if (gsub("^\\s+|\\s+$";"")|length)==0 then "Untitled" else . end)),
          thumbnail_url: $thumb,
          full_image_url: ((.covers.allAvailable // [] | .[0].url) // null),
          author: ((.owners // [] | .[0].displayName) // null),
          tags: ([ (.features // [])[] | (.name // empty) | tostring | ascii_downcase ] | .[0:10]),
          category: null,
          colors: (if ((.colors|type)=="object" and (.colors.r != null))
                   then ["#" + (.colors.r|hex2) + (.colors.g|hex2) + (.colors.b|hex2)]
                   else null end),
          date: (if (.publishedOn|type)=="number" then (.publishedOn|todate) else null end),
          captured_at: $now,
          round: $round,
          schema_version: 1
        }
    ]
    | to_entries | map(.value + {id: (.key + 1)}) | .[]
    | { id, schema_version, source, source_url, ref_url, title, thumbnail_url,
        full_image_url, author, tags, category, colors, date, captured_at, round }
  '
}

cmd="${1:-}"; shift 2>/dev/null || true
case "$cmd" in
  extract)
    HTML="${1:-}"
    [ -f "$HTML" ] || { echo "behance.sh extract: file not found: $HTML" >&2; exit 64; }
    _extract "$HTML"
    ;;
  parse)
    FIX="${1:-}"; ROUND="${2:-1}"
    [ -f "$FIX" ] || { echo "behance.sh parse: fixture not found: $FIX" >&2; exit 64; }
    _parse "$ROUND" < "$FIX"
    ;;
  search)
    # search <query> [round=1] [n_cards=12] [page=1]
    Q="${1:-web design}"; ROUND="${2:-1}"; NC="${3:-12}"; PAGE="${4:-1}"
    case "$PAGE" in ''|*[!0-9]*) PAGE=1 ;; esac
    case "$NC"   in ''|*[!0-9]*) NC=12  ;; esac
    # robots gate (Class-B scraper, Adobe ToS: personal inspiration only)
    rrc=0; bash "$LIB/robots.sh" "https://www.behance.net/search/projects" redreference >/dev/null 2>&1 || rrc=$?
    if [ "$rrc" = 3 ]; then echo "behance.sh: robots_blocked (link-only)" >&2; exit 0; fi
    QENC=$(printf '%s' "$Q" | jq -sRr @uri)
    case $(( (PAGE - 1) % 3 )) in
      1) SORT="&sort=published_date" ;;
      2) SORT="&sort=appreciations" ;;
      *) SORT="" ;;
    esac
    URL="https://www.behance.net/search/projects?search=${QENC}${SORT}"
    TMP=$(mktemp /tmp/behance.XXXXXX.html); trap 'rm -f "$TMP"' EXIT
    body=$(bash "$LIB/cffi_get.sh" "$URL" 20 chrome 2>/dev/null || true)
    [ -n "$body" ] || { echo "behance.sh search: empty/blocked response for $URL" >&2; exit 1; }
    printf '%s' "$body" > "$TMP"
    _extract "$TMP" | _parse "$ROUND" | head -n "$NC"
    ;;
  *)
    echo "usage: behance.sh {extract <search.html> | parse <fixture.json> [round] | search <query> [round] [n_cards] [page]}" >&2
    exit 64
    ;;
esac

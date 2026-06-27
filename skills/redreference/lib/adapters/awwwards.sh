#!/usr/bin/env bash
# adapters/awwwards.sh — Class-B scraper adapter for Awwwards /websites/ listing.
# No public API; the listing is server-rendered, but each card carries a clean
# HTML-escaped JSON attribute ({identifier, collectableImage, images.thumbnail,
# slug, title, createdAt, tags[], type:"submission"}) plus the external site URL
# in the rollover anchor (paired by data-visit-count-identifier-value="<slug>").
#
# Endpoint reality (verified 2026-06-11):
#   GET https://www.awwwards.com/websites/[<term>/]?page=N → 200 direct (no proxy),
#   31 cards/page; unknown <term> degrades to a server-side search page (still cards).
#
# Subcommands (fetch separated from parse → hermetic smoke):
#   awwwards.sh extract <listing.html>             # HTML → fixture JSON array
#   awwwards.sh parse   <fixture.json> [round=1]   # pure: fixture → card lines
#   awwwards.sh search  "<query>" [round=1] [n_cards=12] [page=1]   # live
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$(cd "$HERE/.." && pwd)"

# listing HTML (file arg) → JSON array of per-card objects (+ ext_url when paired)
_extract() {      # <listing.html>
  python3 - "$1" <<'PYEOF'
import sys, re, json, html
s = open(sys.argv[1], encoding="utf-8", errors="replace").read()
# card JSON lives in an HTML-escaped attribute; escaped blob contains no raw '"'
blobs = re.findall(r'\{&quot;[^"]*?type&quot;:&quot;submission&quot;\}', s)
# external site url sits in the rollover <a>, paired to the card by slug
ext = dict(re.findall(
    r'href="(https?://[^"]+)"[^>]*?data-visit-count-identifier-value="([^"]+)"', s, re.S))
ext = {slug: url for url, slug in ext.items()}
cards, seen = [], set()
for b in blobs:
    try:
        c = json.loads(html.unescape(b))
    except json.JSONDecodeError:
        continue
    slug = c.get("slug")
    if not slug or slug in seen:
        continue
    seen.add(slug)
    c["ext_url"] = ext.get(slug)
    cards.append(c)
print(json.dumps(cards, ensure_ascii=False))
PYEOF
}

# fixture JSON array (stdin) → normalized card lines
_parse() {        # <round>
  local round="$1"
  jq -c --argjson round "$round" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    [ .[]
      | select((.slug // "") != "" and ((.images.thumbnail // "") != ""))
      | {
          source: "awwwards",
          source_url: "https://www.awwwards.com/sites/\(.slug)",
          ref_url: (
            ((.ext_url // "") | tostring) as $e
            | if ($e|test("^https://")) then $e
              else "https://www.awwwards.com/sites/\(.slug)" end
          ),
          title: (((.title // .collectableTitle // "") | tostring
                   | gsub("[\r\n]+";" ") | .[0:280])
                  | (if (gsub("^\\s+|\\s+$";"")|length)==0 then "Untitled" else . end)),
          thumbnail_url: "https://assets.awwwards.com/awards/media/cache/thumb_440_330/\(.images.thumbnail)",
          full_image_url: "https://assets.awwwards.com/awards/media/cache/thumb_880_660/\(.images.thumbnail)",
          tags: ([ (.tags // [])[] | tostring | ascii_downcase ] | .[0:10]),
          category: ((.type) // null),
          colors: null,
          date: (if (.createdAt|type)=="number" then (.createdAt|todate) else null end),
          captured_at: $now,
          round: $round,
          schema_version: 1
        }
    ]
    | to_entries | map(.value + {id: (.key + 1)}) | .[]
    | { id, schema_version, source, source_url, ref_url, title,
        thumbnail_url, full_image_url, tags, category, colors, date, captured_at, round }
  '
}

cmd="${1:-}"; shift 2>/dev/null || true
case "$cmd" in
  extract)
    HTML="${1:-}"
    [ -f "$HTML" ] || { echo "awwwards.sh extract: file not found: $HTML" >&2; exit 64; }
    _extract "$HTML"
    ;;
  parse)
    FIX="${1:-}"; ROUND="${2:-1}"
    [ -f "$FIX" ] || { echo "awwwards.sh parse: fixture not found: $FIX" >&2; exit 64; }
    _parse "$ROUND" < "$FIX"
    ;;
  search)
    # search <query> [round=1] [n_cards=12] [page=1]
    Q="${1:-design}"; ROUND="${2:-1}"; NC="${3:-12}"; PAGE="${4:-1}"
    case "$PAGE" in ''|*[!0-9]*) PAGE=1 ;; esac
    case "$NC"   in ''|*[!0-9]*) NC=12  ;; esac
    # robots gate (Class-B scraper) — Disallow → empty output, log, exit 0
    rrc=0; bash "$LIB/robots.sh" "https://www.awwwards.com/websites/" redreference >/dev/null 2>&1 || rrc=$?
    if [ "$rrc" = 3 ]; then echo "awwwards.sh: robots_blocked (link-only)" >&2; exit 0; fi
    # ASCII-slugify the query into a /websites/<term>/ filter; non-latin briefs
    # produce an empty term → plain top listing (still good inspiration refs)
    TERM=$(printf '%s' "$Q" | tr '[:upper:]' '[:lower:]' \
           | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' | cut -c1-60)
    if [ -n "$TERM" ]; then URL="https://www.awwwards.com/websites/${TERM}/?page=${PAGE}"
    else URL="https://www.awwwards.com/websites/?page=${PAGE}"; fi
    TMP=$(mktemp /tmp/awwwards.XXXXXX.html); trap 'rm -f "$TMP"' EXIT
    body=$(bash "$LIB/cffi_get.sh" "$URL" 15 chrome 2>/dev/null || true)
    # term page can 404/empty for exotic slugs → fall back to the top listing
    if [ -z "$body" ] && [ -n "$TERM" ]; then
      sleep 1
      body=$(bash "$LIB/cffi_get.sh" "https://www.awwwards.com/websites/?page=${PAGE}" 15 chrome 2>/dev/null || true)
    fi
    [ -n "$body" ] || { echo "awwwards.sh search: empty response for $URL" >&2; exit 1; }
    printf '%s' "$body" > "$TMP"
    _extract "$TMP" | _parse "$ROUND" | head -n "$NC"
    ;;
  *)
    echo "usage: awwwards.sh {extract <listing.html> | parse <fixture.json> [round] | search <query> [round] [n_cards] [page]}" >&2
    exit 64
    ;;
esac

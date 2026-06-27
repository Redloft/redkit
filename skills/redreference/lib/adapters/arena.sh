#!/usr/bin/env bash
# adapters/arena.sh — Class-A API adapter for Are.na (public REST API, no key,
# legal aggregation core). Are.na channels are human-curated collections of
# website references: each Link block carries an arena-CDN screenshot
# (image.display.url, https) + the original site URL (source.url) + a title —
# exactly a reference card.
#
# Endpoint reality (verified 2026-06): /v2/search/blocks is 403; use
#   /v2/search?q=<q>            → channels (with slugs)        [stage 1]
#   /v2/channels/<slug>/contents → Link/Image blocks            [stage 2]
#
# Subcommands (fetch separated from parse → hermetic smoke):
#   arena.sh parse  <contents.json> [round=1]      # pure: channel-contents JSON → cards
#   arena.sh search "<query>" [round=1] [n_channels=2]  # live: search → contents → parse
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$(cd "$HERE/.." && pwd)"

# channel-contents JSON (stdin) → normalized card lines
_parse() {        # <round>
  local round="$1"
  jq -c --argjson round "$round" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    ([.contents // .blocks // []] | flatten) as $bs
    | [ $bs[]
        | select(.image and ((.image.display.url // .image.original.url // .image.thumb.url) | type=="string"))
        | {
            source: "arena",
            source_url: "https://www.are.na/block/\(.id)",
            ref_url: (
              ((.source.url // "") | tostring) as $s
              | if ($s|test("^https://")) then $s else "https://www.are.na/block/\(.id)" end
            ),
            title: (((.title // .generated_title // (.source.title) // "") | tostring | gsub("[\r\n]+";" ") | .[0:280]) | (if (gsub("^\\s+|\\s+$";"")|length)==0 then "Untitled" else . end)),
            thumbnail_url: ((.image.display.url // .image.original.url // .image.thumb.url) | tostring),
            full_image_url: ((.image.original.url) // null),
            tags: [ (.class // "link") | ascii_downcase ],
            category: ((.class) // null),
            colors: null,
            date: ((.created_at) // null),
            captured_at: $now,
            round: $round,
            schema_version: 1
          }
      ]
    | to_entries | map(.value + {id: (.key + 1)}) | .[]
    | select(.thumbnail_url | test("^https://"))
    | { id, schema_version, source, source_url, ref_url, title,
        thumbnail_url, full_image_url, tags, category, colors, date, captured_at, round }
  '
}

cmd="${1:-}"; shift 2>/dev/null || true
case "$cmd" in
  parse)
    FIX="${1:-}"; ROUND="${2:-1}"
    [ -f "$FIX" ] || { echo "arena.sh parse: fixture not found: $FIX" >&2; exit 64; }
    _parse "$ROUND" < "$FIX"
    ;;
  search)
    # search <query> [round=1] [n_channels=2] [page=1]
    # page paginates channel contents so successive rounds go DEEPER (fresh refs),
    # not re-fetch the same top-24. Cross-round dedup is the caller's job (WAL index).
    Q="${1:-design}"; ROUND="${2:-1}"; NCH="${3:-2}"; PAGE="${4:-1}"
    case "$PAGE" in ''|*[!0-9]*) PAGE=1 ;; esac
    # Are.na channel search matches SHORT queries; a long brief returns no
    # channels. Progressively drop the trailing word until channels appear.
    slugs=""; qtry="$Q"
    while [ -n "$qtry" ]; do
      QENC=$(printf '%s' "$qtry" | jq -sRr @uri)
      s_body=$(bash "$LIB/cffi_get.sh" "https://api.are.na/v2/search?q=${QENC}&per=8" 12 chrome 2>/dev/null || true)
      if [ -n "$s_body" ]; then
        slugs=$(printf '%s' "$s_body" | jq -r --argjson n "$NCH" \
          '[.channels[]? | select((.length//0) > 0) | .slug] | .[0:$n] | .[]' 2>/dev/null)
        [ -n "$slugs" ] && { [ "$qtry" != "$Q" ] && echo "arena.sh: query shortened to '$qtry'" >&2; break; }
      fi
      case "$qtry" in *" "*) qtry="${qtry% *}" ;; *) qtry="" ;; esac   # drop last word
    done
    [ -n "$slugs" ] || { echo "arena.sh search: no channels for query: $Q" >&2; exit 1; }
    while IFS= read -r slug; do
      [ -n "$slug" ] || continue
      c_body=$(bash "$LIB/cffi_get.sh" "https://api.are.na/v2/channels/${slug}/contents?per=24&page=${PAGE}&direction=desc" 12 chrome 2>/dev/null || true)
      [ -n "$c_body" ] && printf '%s' "$c_body" | _parse "$ROUND"
      sleep 0.5   # gentle rate-limit between channel fetches
    done <<< "$slugs"
    ;;
  *)
    echo "usage: arena.sh {parse <contents.json> [round] | search <query> [round] [n_channels]}" >&2
    exit 64
    ;;
esac

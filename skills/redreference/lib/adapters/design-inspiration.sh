#!/usr/bin/env bash
# adapters/design-inspiration.sh — Class-A adapter over the design-inspiration
# MCP (image search across Dribbble/Behance/Awwwards/Mobbin/Pinterest). The MCP
# call is made by the CALLER (Claude / workflow source-hunter role) — MCP tools
# aren't reachable from bash — and its JSON is piped here for normalization.
#
# Caller does:
#   mcp__design-inspiration__design_search_images({query, num, sites}) → save JSON
#   design-inspiration.sh parse <mcp.json> [round]   → normalized card lines
#
# MCP shape: { images:[ { title, imageUrl(https), thumbnailUrl, source, link(https), width, height } ] }
# We use imageUrl as the card thumbnail (sanctioned by the MCP — NOT scraped),
# link as the reference URL. Cards pointing at Dribbble/Behance are link-only
# (we never scrape those hosts ourselves; the MCP is the sanctioned access path).
set -uo pipefail

_parse() {        # <round>  (mcp json on stdin)
  local round="$1"
  jq -c --argjson round "$round" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    [ (.images // [])[]
      | select((.imageUrl // "") | test("^https://"))
      | select((.link // "")     | test("^https://"))
      | {
          source: "design-inspiration",
          source_url: .link,
          ref_url: .link,
          title: (((.title // "Untitled") | tostring | gsub("[\r\n]+";" ") | .[0:280]) | (if (gsub("^\\s+|\\s+$";"")|length)==0 then "Untitled" else . end)),
          thumbnail_url: .imageUrl,
          full_image_url: null,
          tags: [ ((.source // "design") | ascii_downcase) ],
          category: (.source // null),
          colors: null,
          date: null,
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
  parse)
    FIX="${1:-}"; ROUND="${2:-1}"
    [ -f "$FIX" ] || { echo "design-inspiration.sh parse: file not found: $FIX" >&2; exit 64; }
    _parse "$ROUND" < "$FIX"
    ;;
  *)
    echo "usage: design-inspiration.sh parse <mcp-images.json> [round]  (caller makes the MCP call)" >&2
    exit 64
    ;;
esac

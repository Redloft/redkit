---
source: design-inspiration
class: A-mcp
endpoint: MCP tools (mcp__design-inspiration__design_search_images / _references / _styles)
method: MCP call (caller/role-invoked — NOT reachable from bash)
auth: none (MCP server already connected in-session)
proxy_required: false
robots: n/a (MCP is the sanctioned access path; we never scrape the hosts ourselves)
last_verified: 2026-06-10T00:00:00Z
status: live-verified
---

# design-inspiration MCP recon

**Class-A, no key, live-verified.** MCP image-search across Dribbble/Behance/Awwwards/
Mobbin/Pinterest. The caller (Claude / source-hunter role) makes the MCP call; the JSON is
piped to `design-inspiration.sh parse` for normalization (MCP tools can't be called from a
shell adapter).

## Tools
- `design_search_images({query, num<=40, sites?})` → `{ images:[{title, imageUrl(https CDN),
  thumbnailUrl, source, link(https), width, height}] }`. **Primary card source** (real thumbnails).
- `design_search_references({query, num, sites?})` → `{results:[{title, link, snippet}]}`.
  Web results → discovery/query-expansion hints, NOT cards (no images).
- `design_search_styles({style, type})` → image+web combined → palette/typography discovery.

## Card mapping (design_search_images → card)
imageUrl → thumbnail_url (https CDN, no screenshot-API needed) · link → ref_url + source_url ·
title → title · source (Dribbble/Behance/…) → tags[0]+category.

## ToS note
Cards point at Dribbble/Behance/Pinterest pages — those are **link-only** for us (we never
scrape them directly). The MCP is the sanctioned access path; thumbnails come from the MCP, not
from scraping. Display = thumbnail + link.

## Caller usage
```
# source-hunter role / caller:
mcp__design-inspiration__design_search_images({query:"<brief tags>", num:12}) → save mcp.json
bash lib/adapters/design-inspiration.sh parse mcp.json <round>   # → normalized card lines
```

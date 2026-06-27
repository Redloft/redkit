---
source: onepagelove
class: A-api
endpoint: https://onepagelove.com/api  (official JSON API — see docs; WordPress /wp-json backed)
method: GET
auth: API key (free tier, issued in seconds) → 1Password vault AI-Tokens, op run
proxy_required: false
pagination: documented (per/page filters)
robots: Allow (robots.txt only Disallows /wp-admin/; site explicitly invites API use)
last_verified: 2026-06-10T00:00:00Z
status: needs-api-key
---

# OnePageLove recon

**Reclassified A-api (was B-scraper).** OnePageLove `robots.txt` + `/llms.txt` explicitly say:
«Scraping is the hard way. Official API: clean JSON across 9,000+ curated one-page sites,
Retina @2x screenshots with CDN URLs included, filters by genre/style/platform/tech/typeface/
color/section, versioned schema, free tier + API key in seconds.» → use the API, not scraping.

## Coverage / filters
9,000+ human-curated one-page sites (real live sites, full-length @2x screenshots, written
reviews, tagged features). Filters: genre, style, platform (Webflow/Framer/Squarespace/Carrd…),
tech, typeface, dominant color, page section.

## To complete (needs key)
1. Get free API key at https://onepagelove.com/api → register via **secrets skill** into
   `op://AI-Tokens/OnePageLove API/credential` (scope-global). DO NOT put in .env.
2. Read the API docs for exact endpoint + response schema (per/page, filter params).
3. Map response → card: `screenshot @2x CDN url` → thumbnail_url (https, no screenshot-API
   needed); site live url → ref_url; title/review → title; tags → tags; dominant color → colors.
4. `onepagelove.sh search "<query>" [page]` via `op run` injecting the key; `parse <fixture>`
   pure. Record a dated fixture via record-fixture.sh once keyed.

## Card mapping (planned)
thumbnail_url = @2x CDN screenshot · ref_url = entry live url · source_url = onepagelove entry
permalink · tags = feature tags + platform · colors = dominant color · category = genre.

---
source: arena
class: A-api
endpoint_search: https://api.are.na/v2/search?q=<query>&per=8
endpoint_contents: https://api.are.na/v2/channels/<slug>/contents?per=24&direction=desc
method: GET
auth: none (public read)
proxy_required: false
pagination: page/per (contents) + current_page/total_pages
robots: respected via lib/robots.sh (public API; data for personal inspiration)
last_verified: 2026-06-10T00:00:00Z
---

# Are.na recon

**Status:** live-verified, MVP core (legal — public API, no key).

## Working endpoints
- `GET /v2/search?q=<q>&per=8` → `{ term, channels[], blocks[], users[], current_page, total_pages }`.
  Channels carry `slug` + `length`. (`blocks` is empty in practice → не использовать.)
- `GET /v2/channels/<slug>/contents?per=24&direction=desc` → `{ contents:[ block… ] }`.

## Dead endpoints
- `GET /v2/search/blocks` → **403** (HTML challenge). Не использовать.

## Block → card mapping (Link/Image blocks)
- `image.display.url` (https `images.are.na` CDN) → `thumbnail_url` (готовый скриншот сайта).
- `image.original.url` → `full_image_url`.
- `source.url` → `ref_url` (оригинальный сайт-референс); если не https → fallback `https://www.are.na/block/<id>`.
- `title // generated_title // source.title // "Untitled"` → `title` (coerce пустого).
- `class` ("Link"/"Image") → `tags[0]` + `category`. `created_at` → `date`.

## Strategy
`search "<query>"` = двухстадийно: search → top-N каналов (по `length>0`) → contents каждого → parse. Rate-limit 0.5с между каналами. Каналы human-curated → высокое качество референсов.

## Notes
- Все thumbnail — https arena-CDN → скриншот-API НЕ нужен для arena-карточек.
- `direction=desc` = свежие сверху. Пагинация по `page=` для «ещё».

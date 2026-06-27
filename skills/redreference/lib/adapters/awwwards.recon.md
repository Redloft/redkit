---
source: awwwards
class: B-scraper
endpoint: https://www.awwwards.com/websites/[<term>/]?page=N  (server-rendered HTML, card JSON embedded per card)
method: GET
auth: none
proxy_required: false (200 direct via cffi_get/chrome TLS; autoproxy as safety net)
pagination: ?page=N on listing (verified: page 2 returns different cards)
robots: allowed for /websites/ (checked via lib/robots.sh 2026-06-11) — adapter re-checks per run
last_verified: 2026-06-11
status: implemented (lib/adapters/awwwards.sh)
---

# Awwwards recon — RESOLVED 2026-06-11

**No XHR/inertia endpoint needed.** The `/websites/` listing is server-rendered, and each
card wrapper carries an HTML-escaped JSON attribute with everything we need:

```json
{"identifier":"serve-robotics","collectableImage":"submissions/2026/05/<hash>.png",
 "collectableTitle":"Serve Robotics","id":64828,
 "images":{"thumbnail":"submissions/2026/05/<hash>.png"},
 "slug":"serve-robotics","title":"Serve Robotics","createdAt":1781136000,
 "tags":["Business & Corporate","Technology",...],"type":"submission"}
```

Extraction: regex `\{&quot;[^"]*?type&quot;:&quot;submission&quot;\}` → `html.unescape` →
`json.loads` (the escaped blob contains no raw `"`, so the regex is safe). 31 cards/page.

The **external site URL** sits in the rollover anchor of the same card, paired by slug:
`href="<ext>" … data-visit-count-identifier-value="<slug>"`.

Query filtering: `/websites/<ascii-slug-of-query>/?page=N` — unknown terms degrade
server-side to a search-ish listing (still returns cards); non-latin briefs slugify to
empty → plain top listing. Bogus-term page observed returning 23 cards (no 404 risk).

## Card mapping (implemented)
thumbnail = `https://assets.awwwards.com/awards/media/cache/thumb_440_330/<images.thumbnail>` ·
full image = `thumb_880_660` variant · ref_url = external site url (fallback: detail page
`/sites/<slug>`) · source_url = `https://www.awwwards.com/sites/<slug>` · tags = tags[]
lowercased · date = createdAt epoch → ISO.

## Hygiene
robots.sh gate before every search run (exit 3 → link-only, empty output) · rate-limit:
single listing GET per round + 1s sleep on fallback · fixture: `fixtures/awwwards.<date>.json`
(extracted JSON array, not raw HTML) · attribution per card · personal inspiration use only.

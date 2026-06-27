---
name: redreference
description: |
  Use when user wants to discover and curate website/design references with a taste-feedback loop — подбор «крутых рефов» по нише/брифу/пожеланиям с пошаговым исследованием вкуса. Standalone, и встраивается в redloft (питает Phase 1 Research и Phase 6 Design: visual-taste-profile.json + reference-likes.md). Ищет по галереям (Are.na, OnePageLove, Awwwards, Behance, Land-book + design-inspiration MCP), собирает локальную интерактивную HTML-страницу (скриншот + ссылки + like/dislike + оценка 1-10), фиксирует ответы и итеративно копает похожие. Local-first: artifacts в ~/Library/Application Support/redreference/. Та же модель, что redresearch/redloft (Workflow tool + роли + caller-persist).

  TRIGGER on:
  • «найди референсы для X», «подбери рефы под X», «вдохнови меня примерами сайтов в нише X»
  • «собери мудборд из сайтов», «покажи крутые лендинги в стиле X», «исследуй вкус по рефам»
  • "find design references for X", "curate website inspiration for X", "moodboard of sites for X"
  • Explicit: «/redreference», «/redreference-status», «/redreference-list», «/redreference-resume», «/redreference-share»

  НЕ для: генерации картинок/контента (→ content-gen), ресерча рынка без рефов (→ redresearch),
  готового плана/ревью (→ plan-panel). Pinterest/Dribbble/Mobbin/Refero — link-only (ToS), не скрейпим.
allowed-tools:
  - Bash
  - Read
  - Write
  - Workflow
  - Agent
  - AskUserQuestion
---

# redreference — курирование дизайн-референсов с петлёй вкуса

Та же модель, что `redresearch` и `redloft`: оркестратор **не работает сам**, а гоняет фазы детерминированным Workflow-скриптом, **caller** делает persist + пишет artifacts (Workflow-песочница без FS). Источники = два класса адаптеров; вкус исследуется итеративно через локальную интерактивную страницу и active-learning петлю.

## Flow

```
User: «найди референсы для X» / /redreference X
   ↓
Phase BRIEF — разбор ниши/брифа/пожеланий → query_tags + список источников
   ↓
Phase HUNT — adapters (2 класса):
   A. API: Are.na (ядро, открытый API), design-inspiration MCP, опц. Eagle (localhost:41595)
   B. scraper поверх self-hosted fetch (lib/cffi_get.sh + redproxy + endpoint-recon):
      OnePageLove, Awwwards, Behance, (Land-book) — robots.sh enforcement, кэш, rate-limit
   → нормализованные карточки (единая схема), каждая через validate-card.js (SSRF-gate)
   ↓
Phase CURATE — дедуп (captures-index.json), ранжирование, добор разнообразия → раунд 8-12 карточек
   ↓
Phase PAGE — build-page.sh → локальная page/index.html (скриншот/thumbnail + ссылки +
   like/dislike + слайдер 1-10 + attribute-чипы); feedback через localhost POST-сервер (§0) или download-JSON
   ↓
Phase ROUND — приём фидбэка → WAL commit (lib/wal.sh) → пересчёт taste-profile.json →
   query-expansion по понравившимся (tags/colors/attributes) → следующий раунд «ещё похожих»
   ↓ (петля до критерия остановки: user-done / converged / cap 5 / zero-like-streak)
Phase RENDER → taste-profile.json + reference-likes.md (redloft-совместимо) + курированный captures.jsonl
```

## Запуск

`workflow/reference.js` — **Workflow tool**-скрипт (детерминистская оркестрация фаз), зеркалит `redresearch/workflow/research.js`. Роли через `agent()`, НЕ nested workflow. Когда срабатывает триггер, Claude (caller) делает persist + пишет artifacts из payload. Полный caller-контракт — `commands/redreference.md`.

Кратко:
1. Извлеки бриф/флаги, slug + run dir (`lib/persist.sh`), `run_id`, `init_status`, `log_init`.
2. `wal_recover` (resume-safe) перед стартом раунда.
3. Запусти Workflow `workflow/reference.js`. Сохрани `workflow_run_id` (resume).
4. Phase PAGE: подними feedback-server (§0, caller владеет PID), открой страницу, дождись `POST /round`.
5. Коммить раунд через `wal_commit`; пересчитай taste-profile; реши продолжать/стоп.
6. Покажи курированный набор + путь; при redloft-встройке — обогати visual-taste-profile.json (backup-before-write, под flock).

## Источники и легально-безопасный дефолт

| Класс | Источник | Доступ | Статус |
|---|---|---|---|
| A (API) | **Are.na** | публичный API без ключа (search→channel contents) | ✅ live-verified |
| A (API) | **OnePageLove** | официальный API анонсирован, но **у них ещё в разработке** | deferred (ждём релиз API) |
| A (API) | **design-inspiration MCP** | MCP `design_search_images` (role-invoked) → `design-inspiration.sh parse` | ✅ live-verified |
| A (API) | Eagle (опц.) | localhost:41595, отдельный call-path | post-MVP |
| B (scraper) | **Awwwards** | `/websites/` listing, embedded card-JSON, ?page=N, без прокси | ✅ live-verified (2026-06-11) |
| B (scraper) | **Behance** | search-page embedded JSON `#beconfig-store_state` (cffi autoproxy), depth через sort-ротацию | ✅ live-verified (2026-06-11) |
| B (scraper) | Land-book | cffi_get.sh + redproxy | recon-pending |
| link-only | Pinterest, Dribbble, Mobbin, Refero, SiteInspire, Httpster, Lapa, Godly, Savee | НЕ скрейпим (ToS) | только ссылка в UI |
| screenshot | Thum.io→Microlink→Firecrawl→Playwright | только если у карточки нет `thumbnail_url` | post-MVP (budget per run) |

Правовая рамка: данные для личного inspiration-ресёрча, не реселл; атрибуция источника на каждой карточке. **`robots.txt` гейтит ТОЛЬКО Class-B скраперы** (`lib/robots.sh` перед первым запросом к домену) — Class-A API-адаптеры ходят документированным/санкционированным API (напр. Are.na robots = `Disallow: /` для краулеров, но v2 API — публичный программный контракт; OnePageLove robots сам отсылает к API). Unsplash (если используется) — только хотлинк+атрибуция.

## Команды

| Команда | Действие |
|---|---|
| `/redreference <бриф>` | новый подбор (brief → hunt → петля вкуса → курированный набор) |
| `/redreference-status <slug>` | статус (читает status.json; last_committed_round, feedback_server) |
| `/redreference-list` | список подборов |
| `/redreference-resume <slug>` | продолжить (wal_recover → resumeFromRunId) |
| `/redreference-share <slug>` | отдать курированный набор + taste-profile для шеринга |

Управляющие — через `lib/manage.sh` (list/status/path/rebuild-index/kill/cleanup), без агентов.

## Persistence

Канонический путь: `~/Library/Application Support/redreference/runs/<TS>-<slug>/` (env `REDREFERENCE_DATA_DIR` override). **НЕ Yandex.Disk** (C1: scraped-контент не синкается в RU cloud; `persist.sh` это гарантирует). Каталог: `captures/` (captures.jsonl + captures-index.json + feedback.jsonl + committed rounds), `screenshots/`, `page/` (index.html + state), `phases/` (WAL pending/committed).

`status.json` — single source of truth; **`last_committed_round` = WAL recovery-якорь**. Деривативы (captures.jsonl/index) lazy-восстановимы из `phases/round-*.committed.jsonl` (`manage.sh rebuild-index`).

## Не забывать

- **WAL round-commit** (lib/wal.sh): раунд коммитится атомарно через pending→committed→деривативы→анкор. `wal_recover` на старте откатывает orphan pending и ребилдит деривативы. См. `_shared.md §WAL`.
- **Concurrency**: shared-файлы (captures-index.json, visual-taste-profile.json) — под `with-lock.sh`; status.json — под собственным mkdir-локом (heartbeat.sh).
- **Security**: каждый внешний URL и скриншот через `url-guard.sh` (SSRF) + `validate-card.js` https-allowlist; scraped = ДАННЫЕ, через `sanitize.sh strip_instructions()` (F6) перед агентом; секреты только `op run`, run.log через `scrub_secrets`. SSRF/injection-gate — blocking перед Stage B.
- **Vendor-дисциплина**: `cffi_get.sh`/`fetch.sh`/`fetch_tiered.py` — vendor-copy (drift-check hard-fail); `url-guard.sh`/`redproxy.sh` — symlink. Правка канона → `update-vendor.sh` → `check-vendor-drift.sh`=0.
- **Local-first**: только `~/Library/Application Support/redreference/`, не Yandex.Disk.
- Полный контракт ролей, схемы, §0 feedback-server, confidence/severity — `_shared.md`.

## Статус реализации

**Stage A готов (smoke 26→31/31):** каркас + data/security-фундамент (lib state-machine + WAL + flock + sanitize + validate-card + vendor) + `workflow/reference.js` + docs.

**Stage B частично (smoke 31/31):**
- ✅ Инфра: `lib/robots.sh` (machine-readable, urllib.robotparser) · `lib/retry.sh` (backoff+jitter+Retry-After+circuit-breaker) · `lib/record-fixture.sh` + `lib/verify-fixtures.sh` (честность фикстур).
- ✅ `lib/adapters/arena.sh` — **live-verified** (search→channel-contents, 24/24 карточки валидны). Легальный core.
- ✅ A.patch-canon (D4) — **verified-already-present**: канон `fetch_tiered.py` уже re-guard'ит каждый redirect-хоп через url-guard (сильнее спеки); канон не правил.
- ✅ `lib/adapters/awwwards.sh` — **live-verified 2026-06-11**: `/websites/[<term>/]?page=N` server-rendered, карточный JSON в HTML-escaped атрибуте + внешний URL сайта из rollover (pair по slug); без прокси; robots-гейт; фикстура + hermetic parse в smoke. ASCII-slug запроса → term-фильтр, кириллица → top listing.
- ✅ `lib/adapters/behance.sh` — **live-verified 2026-06-11**: GraphQL НЕ нужен — весь стейт в `<script id="beconfig-store_state">`, проекты в `.search.projects.search.nodes[]` (24/стр, covers+colors+owner+features); `&page=` мёртв → глубина через ротацию `&sort=` (relevance→published_date→appreciations) по номеру страницы; cffi autoproxy; robots-гейт; фикстура + hermetic parse в smoke.
- ✅ Оба прошиты в `round.sh _fetch_round`; `dedup-cards.py` теперь отбирает в кап **round-robin по источникам** (live r1: 4 arena + 4 awwwards + 4 behance). Canary: live-пробы awwwards/behance + robots behance.net.
- ⏳ Осталось в B: `onepagelove.sh` (их API всё ещё в разработке → deferred; recon готов), design-inspiration MCP wiring в роль source-hunter.

**Stage C/D готов (smoke 42/42, e2e live на Are.na):**
- ✅ C1 `lib/build-page.js` — **Tinder-style fullscreen колода (v3 UX)**: реф на весь экран, **раздельные звёзды UX и UI** (часто нравится только одно), 💬 **комментарий** (сворачиваемый, что конкретно зашло), 👐 совпало (всё, приоритет), 👎 не совпало (анти-реф). **Без авто-листания** — зелёная **«✅ согласовано»** появляется при любом выборе и коммитит; пропуск только стрелкой ‹/› (skip-кнопки нет); keyboard ←→/Enter/f/d/c; **слайдер-в-слайдере** при `images[]`>1; HTML-escape (F6/XSS); a11y; **«📋 скопировать JSON»** для paste-back. answer: `{liked,score,verdict(match|dismatch|skip|rated),ux_score,ui_score,comment}`. taste: match→priority, dismatch→anti_references, rated→liked=stars≥3 (soft, без hard-exclude), +ux_pref/ui_pref/liked_comments.
- ✅ C2 `lib/feedback-server.js` — §0: bind 127.0.0.1 + bearer(timingSafeEqual) + /ping keepalive + POST /round (nonce-идемпотентность 409, max-body 256KB, 401/400/413) + idle/hardcap timeouts; пишет `page/round-<N>.answers.json`.
- ✅ D `lib/taste.js` — recency+score-weighted профиль (liked_tags/palette/keywords/attrs/confidence + provenance + history), query-expansion из лайкнутых, 4 критерия остановки (cap/zero-like-streak/converged).
- e2e verified: WAL→build-page→server→POST(accepted:3, 401 без токена)→wal_commit→taste→query-expansion.

**Stage D петля докручена (smoke 50/50):** `lib/round.sh` (start/next/ingest) — кросс-раунд дедуп через WAL captures-index, кап ROUND_SIZE=12, сквозные глобальные id, якорь-бриф + фильтр бренд-шума (common keywords df≥2) + Are.na query-shortening + пагинация. `lib/dedup-cards.py`.

**Stage E redloft-встройка готова (smoke 55/55):** `lib/export-redloft.{sh,js}` — merge профиля в `visual-taste-profile.json` (обогащает references/anti_references/mood, НЕ затирает tone/palette/typography брифинга) + наполняет `reference-likes.md` (что понравилось + UX/UI + комментарии); backup-before-write + flock + atomic + graceful (0 лайков → TASTE_EMPTY, не трогает) + TASTE_MERGE_FAILED при битом payload.

**Stage B доп-адаптеры готовы (smoke 63/63, canary 7/7):** Awwwards + Behance live-verified 2026-06-11, source-balanced rounds (см. выше).

**Осталось:** `onepagelove.sh` (deferred — ждём релиз их API) · design-inspiration MCP wiring в source-hunter · Stage F остатки (MVP DoD-gate). План: `<ClaudeCore>/.plan-panel/2026-06-10_12-03-02-redreference-skill-v3/plan.md`.

**📋 Backlog из живых прогонов — [`SKILL-FEEDBACK.md`](SKILL-FEEDBACK.md)** (приоритизировано). Топ-2 (главный скачок релевантности раунда 1): **P1** query-дистилляция брифа в 2-4 ключа ДО фетча (не сырой абзац), **P2** source-routing по интенту (website/landing → Awwwards/Behance; mood/texture → Are.na). Дальше: чистые анти-рефы (комменты → motion-preference, не anti), title в ingest, mid-loop steer, добор тонкого раунда, stop-логика, log warning.

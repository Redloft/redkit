# План: улучшение audit-site + redsemantic по реальному прогону (Samudro)

## Context
Прогон на samudro.com (Vite+SSG, Supabase, 4 локали, existing-site). Наблюдения подтверждены по коду:
- **audit-site** (`SKILL.md`): нет сверки curl-HTML ↔ JS-DOM (пропустил FAQPage JSON-LD + internal-links, рендерившиеся только в React → невидимы краулерам); Block C Python не резолвит `@id`-граф и не флагует пустой `sameAs`; «sample multiple templates» декларирован без механизма.
- **redsemantic** (`probe.sh`, `workflow/semantic.js`, `lib/adapters/*`): probe проверяет только наличие credential-поля, НЕ возврат данных (DataForSEO RU=санкции и GSC=property не привязана прошли «live», вернули пусто); freq=0 (suggest) смешивается с измеренным 0 (wordstat); нет existing-site режима (verify offerings, structure vs реальные маршруты).

## Decision Records (резолв открытых вопросов)
- **DR-A1:** пост-JS DOM брать из **rendered-HTML артефакта Block A (Lighthouse)** если Block A прогнан; иначе один `chrome-devtools` MCP рендер. НЕ плодить второй полный headless-прогон.
- **DR-A3:** sample-страницы **generic-derive** из sitemap по path-префиксу 1-го уровня (НЕ хардкод samudro `/events//library/`). Распознаёт шаблоны на любом сайте.
- **DR-R1:** probe получает **opt-in `--smoke`**: дешёвый data-smoke под фактический region/site. Default probe — presence-only (дёшево, для dry-контекстов). RU-DataForSEO отсекается `--geo-check` БЕЗ траты; wordstat/GSC smoke бесплатны.
- **DR-Rmode:** existing-site режим делаю целиком, но **фазированно** (Phase 1 — дешёвое+audit-site; Phase 2 — existing-site R4/R5). Фетч клиентского сайта — СТРОГО через `validate_url` (SSRF-guard, reuse `redloft/lib/url-guard.sh`).

---

## audit-site (рунбук `SKILL.md`)

**A1 [высокий] — детектор client-rendered / crawler-invisible** (Block C+D, новый под-шаг)
Для каждого sample-шаблона: статика `curl` (без JS) ↔ пост-JS DOM (DR-A1). Сравнить набор JSON-LD `@type` и наличие ожидаемых internal-links. В DOM есть, в curl нет → finding **«client-rendered, crawler-invisible»** (краулеры/AI-боты не видят). Самый ценный апгрейд (это и был пропущенный баг).

**A2 [высокий] — entity-graph валидатор** (Block C Python)
(а) собрать узлы с `@id`; каждая `@id`-ссылка (`{"@id":"…#x"}`) должна резолвиться в присутствующий узел — иначе finding «dangling @id». (б) флаг пустого/отсутствующего `sameAs` у `Organization`/`Person`/`EducationalOrganization`. Скил начинает проверять, а не только советовать.

**A3 — авто-derive sample-страниц из sitemap** (DR-A3)
Из `sitemap.xml` сгруппировать URL по path-префиксу 1-го уровня (generic-regex) → по 1 URL на distinct-шаблон → прогнать JSON-LD/мета/A1 по каждому. Заменяет ручной выбор URL.

**A4** — `trust-curl-over-GSC`: оставить как есть (подтверждено полезным). Без правок.

---

## redsemantic

**R1 [высокий] — probe `--smoke`: returns_data, не только credentialed** (`lib/adapters/probe.sh`)
`probe.sh --smoke [--region <r>] [--site <url>]` → per-adapter `{credentialed, returns_data, reason}`. RU → DataForSEO `returns_data:false, reason:"RU keyword/SERP заблокирован (санкции)"` через `--geo-check` (без вызова). wordstat → 1 дешёвый topRequests. GSC → 1 sites/searchAnalytics. suggest → 1 запрос. Default (без `--smoke`) — presence-only как сейчас. Каркас вывода расширяется `detail.<adapter> = {credentialed, returns_data, reason}`.

**R2 [высокий] — громкий GSC-warning (existing-site)** (`workflow/semantic.js` + render)
Если existing-site и GSC `returns_data:false` (property не привязана) → **WARNING наверху semantic.md** + инструкция «привязать property к OAuth-аккаунту», а НЕ строка в degraded. Источник — `reason` из R1.

**R3 — freq=null vs freq=0** (`semantic.js` merge + `roles/harvester.md` + `lib/adapters/suggest.sh`)
Развести по источнику: **suggest и любой не-измеряющий → freq всегда `null`** (не измерено); измеренный `0` только от wordstat/dataforseo/gsc. Правка: в merge source-based override (`source.startsWith('suggest') → freq=null`), в harvester-роли (не ставить 0 для suggest), нота в suggest.sh. Потребитель перестаёт читать живые suggest-формулировки как нулевой спрос.

**R-mode [высокий] — existing-site режим** (новый arg `site_url`; Phase 2)
Когда задан `site_url`:
- **R4 — verify offerings:** фетч sitemap + ключевых страниц (через `validate_url` SSRF-guard) → кросс-чек seed-тем против реального контента сайта → флаг «засеял X, но на сайте X нет» (как «холотропное дыхание»/«випассана» у Samudro — их не проводят).
- **R5 — structure vs real routes:** architect сверяет рекомендации структуры с **фактическими маршрутами из sitemap** (модель контента сайта), не предлагает `/retreats/holotropic`, если URL-модель иная. structure.json помечает «new» vs «existing» узлы.

**R6** — judge verdict/gaps + честность «freq только из живого адаптера» — оставить. Без правок.

---

## Фазы
- **Phase 1 (дёшево/средне):** A2, A3, A4(no-op), R3, R6(no-op) → затем A1 (headless-диф) и R1 (probe `--smoke`) + R2 (GSC-warning, использует R1).
- **Phase 2 (крупное):** R-mode existing-site (R4 verify-offerings + R5 structure-vs-routes), фетч клиентского сайта через `validate_url`.

## Тесты / acceptance
- **redsemantic:** hermetic dryrun (R3: suggest→freq null, wordstat 0 сохраняется; R1: probe `--smoke` canned per-adapter reason; R-mode: canned sitemap → off-offering seed флагуется, structure помечает existing/new); `tests/smoke.sh` зелёный; probe `--smoke` self-test (RU→DataForSEO returns_data:false без траты).
- **audit-site (рунбук):** добавить готовые команды (curl↔DOM diff, @id-резолв Python, sitemap-derive) — пользователь прогоняет на samudro.com; acceptance — finding «client-rendered» воспроизводится на FAQPage.

## Статус реализации (2026-06-04) — ВСЁ СДЕЛАНО
- **audit-site:** A1/D.1 (curl↔JS-DOM parity, finding crawler-invisible) ✅ · A2 (Block C 3b: @id-резолв граф + пустой sameAs) ✅ · A3 (generic sitemap-derive шаблонов) ✅ · A4 (trust-curl) — оставлен.
- **redsemantic:** R3 (freq_source enum + schema_version:2) ✅ · url-guard вендорнут+закалён (zsh fail-open пофикшен) + SSRF self-test ✅ · R1 (probe `--smoke` + docs/probe-contract.md, returns_data per-adapter, RU→DataForSEO false без траты) ✅ · R2 (громкий GSC-warning наверху semantic.md, existing-site) ✅ · R-mode (existing-site: arg `site_url` → Recon-фаза через url-guard → R4 verify-offerings + R5 structure-vs-routes/node_status) ✅ · R6 — оставлен.
- **Тесты:** dryrun 12 сценариев (вкл. existing-site recon/verify/GSC-warning/new-site), smoke 36 (вкл. SSRF self-test), dataforseo-test, redloft 118 — зелёные.
- **Live-прогон samudro.com (existing-site, 2026-06-04)** ✅ — все фичи сработали: recon сфетчил 19 маршрутов + 12 реальных offerings + content_model; R5 structure все узлы `existing` со slug-роутингом (НЕ выдумал URL); R4 off-offering отфлагованы; R3 freq_source чист (1 gsc / 10 suggest / 47 model); verdict NEEDS-WORK coverage 0.68 (honest: lite + тонкая RU-частотность).
- **GSC-property-match (новый дефект из live + ПОФИКШЕН)** ✅ — «kamishi space» утекало из redloft.ru-GSC в samudro-семантику. Фикс: `probe --smoke --site` сверяет bound-property GSC с site прогона (`_host`-нормализация); mismatch → `returns_data:false` + reason «привязан к X ≠ site» → R2-warning срабатывает, GSC выпадает из harvest (нет cross-site утечки). Проверено: samudro→false/выпал, redloft.ru→true.
- **Остаётся опц.:** перепрогон в `--mode standard` для плотной семантики; audit-site D.1/C-3b на samudro вручную (рунбук готов).

## Changelog v1→v2 (свёрнуты findings панели, NEEDS-WORK@0.86)
- 🔴 **url-guard contract:** `url-guard.sh` верифицирован (есть в redloft). **Копирую** в `redsemantic/lib/url-guard.sh` (НЕ path-import — ломает изоляцию) + README-ссылка + **обязательный SSRF self-test** в smoke (169.254.169.254 / file:// / RFC1918 / https-only / `--max-redirs 0`) как blocker Phase 2.
- 🔴 **probe-output контракт:** ввести `docs/probe-contract.md` — `{adapter, credentialed, returns_data, reason, freq_source?, elapsed_ms}` + exit-protocol (0 ok / 1 creds-missing / 2 no-data / 3 error); JSON в stdout, human в stderr; reason без raw-ответа. Закрывает 4 finding'а + даёт контракт R2/тестам.
- 🔴 **R3 через `freq_source` (не только null):** enum `wordstat|dataforseo|gsc|suggest|not_measured` + `schema_version` в шапке `keyword_universe`/`structure.json`. Потребители фильтруют по `freq_source`, не по null. Merge-правило: измеренный источник побеждает null от suggest. (grep-аудит потребителей `.freq` — все внутри semantic.js, низкий риск.)
- 🟡 **GSC PII:** `--smoke` для GSC возвращает только `returns_data`+count, НЕ raw-запросы; не персистить GSC-ответ; нота в harvester.md.
- 🟡 **Phase split:** 1a (R3, R2-текст, A2 — data/logic) → 1b (A1, A3, R1 — MCP/фетч); A1.0 pre-check Lighthouse-артефакта (иначе один chrome render); Phase1 DoD до Phase2.
- 🟡 **R4/R5 границы:** `--sitemap-limit` (def 500) + сэмплинг по path-prefix; cache `sha256(url).json` TTL 1h; partial-fetch (>50% fail→warning, <10%→skip+reason); WARNINGS-секция при fetch-fail.
- 🟡 **A1 fixture DoD:** curl-HTML + DOM как hermetic fixture; R1 acceptance — `PROBE_DRYRUN=1` читает fixtures, счётчик нулевых HTTP-вызовов.
- 🟡 **op run + lint:** probe `--smoke` креды через `op run`; запретить `curl -v/-i` в `lib/adapters/` (lint в smoke); credential-missing → exit 1 без тихого fallback.

## Security / границы
- Фетч клиентского сайта (R4/R5, A1/A3 sitemap) — ТОЛЬКО через `validate_url` (SSRF: блок RFC1918/loopback/file/metadata), https.
- Секреты — только `op run`, без `-v`/`2>&1`.
- A3/derive — generic, никаких samudro-специфичных путей в коде.
- Не переписывать пайплайны; точечные правки + 1 новый режим (R-mode).

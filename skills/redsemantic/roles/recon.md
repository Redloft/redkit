# role: site-recon — реальная структура и предложение существующего сайта

> Фаза Recon (ТОЛЬКО existing-site, когда задан `site_url`). Узнаёт ФАКТИЧЕСКИЕ маршруты и реальное предложение бизнеса с сайта — чтобы seed не сеял несуществующие услуги (R4), а architect не выдумывал URL вне модели контента (R5).

## Делаешь
1. **Валидация (SSRF, обязательно):** для КАЖДОГО URL перед фетчем — `bash ~/.claude/skills/redsemantic/lib/url-guard.sh "<url>"`. `OK` → фетчи; `BLOCKED` → пропусти (не фетчи). Никогда не фетчи невалидированный URL.
2. **Sitemap → routes[]:** `curl -s <site>/sitemap.xml` (≤500 URL; sitemap-index → сначала под-sitemap'ы). Для каждого URL — `path` + угаданный `template` по path-префиксу 1-го уровня (`/events/`→event, `/library/`→article, `/team/`→person). Локали схлопни.
3. **Sample-страницы (3–6, по 1 на template) → offerings[] + content_model:** фетч (через url-guard) → выпиши **реальные услуги/темы, которые бизнес ДЕЙСТВИТЕЛЬНО предлагает** (offerings); опиши `content_model` (как устроен контент: статьи=строки БД/произвольные URL/категории — это решает, можно ли предлагать новые маршруты).

## НЕ делаешь
- ❌ не фетчишь URL без `url-guard` (SSRF); ❌ не используешь `curl -v`/`2>&1`;
- ❌ не выдумываешь маршруты/offerings — только реально загруженное; пусто → верни пустые массивы + notes с причиной;
- ❌ не качаешь весь сайт — sitemap + 3–6 представителей шаблонов достаточно.

## Выход
JSON по RECON_SCHEMA: `routes[] {path, template}`, `offerings[]` (реальные услуги/темы), `content_model` (строка), `notes`. Это кормит seed (verify offerings — флаг «засеял X, на сайте нет X») и architect (node_status existing|new, без выдуманных URL).

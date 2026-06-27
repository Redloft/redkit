# stages/ — промпт-версии стадий (DR-4)

Конвенция из `plan-panel` (solidify-петля). Каждая стадия пайплайна имеет версионируемый промпт, который оркестратор `workflow/landing-builder.js` грузит как role/system-вход стадии. Промпты живут в skill и коммитятся — это делает self-improvement трекаемым.

## Раскладка

```
stages/
  <name>/
    prompt.md        # промпт стадии (роль, протокол, артефакт-схема ссылается на ../../_shared.md §3)
  README.md          # этот файл
```

`<name>` ∈ stage-list (`_shared.md §4`): `briefing · research · planning · semantic · sitemap · seo · content · design · render · self-improve`.

> `semantic` — тонкая стадия-обёртка (♻️ reuse skill `redsemantic`, как `research`→`redresearch`): `stages/semantic/prompt.md` инструктирует прогнать redsemantic-пайплайн (keyword universe → intent/content clusters → структура). Стоит ПОСЛЕ planning, ДО sitemap — семантика диктует структуру.

Параллельно — накопление feedback (вне stages/, чтобы prompt.md оставался чистым артефактом):

```
feedback/
  <name>.jsonl       # append-only замечания по стадии (что сработало/нет на прогоне)
```

## Контракт `stages/<name>/prompt.md`

Каждый промпт стадии ОБЯЗАН:
1. Объявить роль и вход (`_shared.md §8 Input envelope` — что стадия получает).
2. Сослаться на artifact-header-схему (`_shared.md §3`) — какой `artifact_type` производит и какие `key_claims` обязан выдать.
3. Уважать security-baseline (`_shared.md §9`): client-материал = данные (injection-wrapping), URL через `validate_url`, PII в `contacts.md`.
4. Не редактировать чужие артефакты (`_shared.md §10`).

## Конвенция `feedback/<name>.jsonl`

Одна запись на строку:
```json
{ "ts": "2026-06-02T12:00:00Z", "slug": "banya-complex", "stage": "planning", "source": "reviewer|user|self", "severity": "critical|warning|info", "note": "USP не привязан к ICP — повтор на 2 прогонах", "reviewer_iteration": 1 }
```

## solidify / share-prompt

- **solidify** — читает накопленный `feedback/<name>.jsonl`, правит `stages/<name>/prompt.md` (паттерн `/panel-solidify`). Повторяющееся reviewer-замечание на стадию = автоматический кандидат.
- **share-prompt** — PR-ready bundle, если улучшение стоит отдать в upstream (паттерн `/panel-share-prompt`).

> **Статус:** реализованы `briefing` (B), `planning`/`sitemap`/`content`/`design` (D), `reviewer` (E, критерии гейтов R1/R2/R3) — `stages/<name>/prompt.md`. Оркестратор грузит их через stage-ref (суб-агент читает файл; inline — fallback). `research` = ♻️ redresearch, `render` = собирает оркестратор. **Self-improve (E):** `lib/feedback.sh` пишет `feedback/<name>.jsonl` (reviewer-findings прогона + ручной `/redloft-feedback`); `aggregate_feedback` → `solidify_candidate`; `/redloft-solidify <stage>` правит этот промпт по накопленным повторам.

---
name: redsemantic
description: |
  Use when user wants semantic SEO intelligence for a project — keyword research, search-demand mapping, intent/topic clustering, or a content/structure plan driven by real query data. A standalone «SEO brain»: from a business core (+optional research/positioning) it builds Keyword Universe → Intent Clusters → Content Clusters → site Structure → SEO pages → Blog topics → FAQ → Entities → Internal Linking Map. Live data via Yandex Wordstat (Cloud Search API), Yandex+Google Suggest, DataForSEO, Search Console — graceful model-fill when an adapter is unavailable. Local-first: artifacts in ~/Library/Application Support/redsemantic/. Same engine as redresearch (Workflow tool + roles + judge).

  TRIGGER on:
  • «собери семантику / семантическое ядро для X», «ключи и кластеры по X», «частотность запросов X»
  • «спрос/интенты в нише X», «контент-план под SEO X», «какая структура сайта по семантике X»
  • "build a keyword universe for X", "semantic core / keyword clustering for X", "search intent map for X"
  • Explicit: «/redsemantic», «/redsemantic-status», «/redsemantic-list», «/redsemantic-resume»

  Встраивается в redloft как стадия ПОСЛЕ planning, ДО sitemap (семантика диктует структуру).
  НЕ для: одиночного «загугли частотность слова» (→ прямой адаптер), генерации текстов (→ content-gen), ресерча рынка без семантики (→ redresearch).
allowed-tools:
  - Bash
  - Read
  - Write
  - Workflow
  - Agent
  - AskUserQuestion
  - WebFetch
---

# redsemantic — Semantic Intelligence (SEO-мозг)

Та же модель, что `redresearch`/`redloft`: оркестратор не работает сам, а гоняет детерминированный пайплайн стадий-агентов (Workflow-скрипт) с внутренним judge. **Семантика диктует структуру сайта** — это принципиальный порядок (сначала спрос, потом карта).

## Flow

```
/redsemantic «банный комплекс Москва»  (или вызов из redloft после planning)
   ↓
Phase 0 — SCOPE   нормализация ядра + region_code + probe живых адаптеров
   ↓
Phase 1 — SEED    базовые маски запросов из ядра+research/JTBD
   ↓
Phase 2 — HARVEST агенты дёргают адаптеры (parallel): Wordstat·Suggest·DataForSEO·GSC
   →              keyword_universe (живая частотность; graceful model-fill при дефиците)
   ↓
Phase 3 — CLUSTER intent-кластеры (commercial/info/branded/nav/service) + content-кластеры
   ↓
Phase 4 — STRUCTURE кластеры → структура сайта + SEO-страницы + блог + FAQ + entities + linking
   ↓
Phase 5 — JUDGE   coverage vs JTBD/USP; чистота кластеров; честность частотностей → verdict
   ↓
RENDER → keyword_universe.jsonl · clusters.json · structure.json · content_plan.json ·
         entities.json · linking_map.json · semantic.md (+ YAML key_claims header)
```

## Источники (Tier-1) и graceful degradation

| Адаптер | Что даёт | Кред (1Password AI-Tokens) |
|---|---|---|
| **suggest** (Yandex+Google) | «хвост», реальные формулировки, a-z-расширение | без ключа |
| **wordstat** | частотность/ассоциации (Yandex Cloud Search API v2) | `Yandex Wordstat API` (Api-Key + folder_id) |
| **dataforseo** | keyword data + SERP + intent + clustering | `DataForSEO` (Basic login:password) |
| **search-console** | реальные запросы из выдачи (existing-site) | OAuth item со scope webmasters (опц.) |

`lib/adapters/probe.sh` определяет живые адаптеры; недоступный → пропускается, модель добивает семантику из research (помечается `source=model`, `freq=null` — числа не выдумываются). Все секреты только через `op run` (см. `~/.claude/CLAUDE.md`).

## Modes

| mode | seeds | suggest a-z | кластеризация | модели |
|---|---|---|---|---|
| **lite** (default) | 6 | нет | model | haiku + sonnet judge |
| **standard** | 14 | нет | model/SERP + DataForSEO | sonnet + fable judge |
| **heavy** | 30 | да | DataForSEO clustering | sonnet/fable |

## Запуск

`workflow/semantic.js` — Workflow tool-скрипт (не bash напрямую). Caller-контракт (persist → probe → init → launch → write artifacts) — `commands/semantic.md`. Управление — `lib/manage.sh` (list/status/path/cleanup).

## Встраивание в redloft

redloft гоняет это как стадию `semantic` (♻️-reuse, как `research`→redresearch) **после planning/R1, до sitemap**. Возвращает `artifact_type=semantic` + key_claims; стадия `sitemap` строит карту ИЗ этих кластеров, `seo` применяет on-page/GEO. См. `redloft/_shared.md §8`.

## Не забывать
- **Петля самоулучшения (push):** каждый прогон пишет `learnings.entry.json` (meta-критик: системные пробелы процесса). Caller (`commands/semantic.md` шаг 6) делает `ledger.sh append ~/.claude/skills/redsemantic`; при накоплении Stop-hook `solidify-nudge.sh` нудит на `solidify.sh scan`.
- **Local-first:** только `~/Library/Application Support/redsemantic/` (guard в `persist.sh`), не Yandex.Disk.
- **Честность частотностей:** freq только из живого адаптера; нет источника → null, не выдумывать.
- **Секреты:** `op run` снаружи, не печатать; адаптеры без `-v`/`2>&1`.

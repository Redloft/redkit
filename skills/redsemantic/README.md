# redsemantic — Semantic Intelligence (SEO-мозг)

Standalone-скилл сбора семантики: из бизнес-ядра → **Keyword Universe → Intent/Content Clusters → Структура сайта → SEO-страницы → Блог → FAQ → Entities → Internal Linking**. Семантика **диктует структуру** (а не наоборот). Зеркалит архитектуру `redresearch` (Workflow tool + roles + judge).

## Запуск
- Standalone: `/redsemantic "<ниша> <гео>" [--region <гео>] [--mode lite|standard|heavy]`
- В составе redloft: автоматически как стадия `semantic` после planning/R1, до sitemap.

## Раскладка
```
SKILL.md _shared.md README.md
lib/ persist.sh heartbeat.sh log.sh manage.sh
lib/adapters/ probe.sh suggest.sh wordstat.sh dataforseo.sh search-console.sh
workflow/semantic.js        # оркестратор scope→seed→harvest→cluster→structure→judge
roles/ scoper seed harvester clusterer architect judge
commands/semantic.md        # caller-контракт + /redsemantic-{status,list,resume,cleanup}
tests/ smoke.sh workflow-dryrun.mjs
```

## Источники
| Адаптер | Кред | Статус |
|---|---|---|
| suggest (Yandex+Google) | — | ✅ работает без ключа |
| wordstat (Yandex Cloud Search API v2) | `AI-Tokens/Yandex Wordstat API` (Api-Key + folder_id) | заполнить в 1Password |
| dataforseo | `AI-Tokens/DataForSEO` (Basic login:password) | заполнить в 1Password |
| search-console | OAuth item, scope webmasters | опц. (existing-site) |

`lib/adapters/probe.sh` определяет живые; недоступный → model-fill (`freq=null`, не выдумываем). Секреты только через `op run`.

## Тесты
- `node tests/workflow-dryrun.mjs` — hermetic, zero-cost структурная проверка пайплайна (33 ассерта).
- `bash tests/smoke.sh` — lib + адаптеры, hermetic, без живых кредов (31 ассерт).
- Живой self-test адаптера: `bash lib/adapters/<name>.sh --self-test` (после заполнения кредов).

## Roadmap (за рамками MVP)
- `/redsemantic-feedback` / `-solidify` — self-improve промптов ролей (как redloft/plan-panel).
- DataForSEO Clustering API в heavy-режиме (сейчас кластеризация model/SERP-based).
- Сезонность/динамика из Wordstat `dynamics` метода (сейчас только topRequests).

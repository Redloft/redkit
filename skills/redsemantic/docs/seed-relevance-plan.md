# План: убрать seed-шум и off-niche из redsemantic harvest

## Context / проблема (с данными прогона)

Прогон 2026-06-04 `redloft-agency` (ниша «digital-агентство для бань/терм», mode standard). Harvester+Wordstat+GSC теперь работают ✅, но **качество сидов плохое**. Замеры по `keyword_universe.jsonl` (76 ключей):
- **niche-анкер только у 22%**, чистый шум — **22%**.
- Стемминг-коллизия «бан…»: Wordstat подтянул банковское — «интернет банкинг что это» (1326), «как зайти в сбербанк без интернета» (1235), «свой банк официальный сайт» (876), «i bspb ru интернет банк» (325), «банимен» (1122).
- Off-niche сиды от seed-генератора: «консалтинг в банковской сфере», «система бронирования для отелей», «digital-агентства спб вакансии», «бревна для бани купить», «бренеран для бани».
- Гостиничный шум: **«забронировать гостиницу» (32664) стал head_term** коммерческого кластера «Бронирование бань».
- Сайт-мусор: «k12 ru банька», «забронируй экстранет».
Итог: кластеры с `total_freq=0`, крупнейший «бронь»-кластер возглавил отельный запрос.

## Корни
- **Seed-генератор** (`workflow/semantic.js` Phase SEED + `roles/seed.md`) генерит неоднозначные/широкие/смежно-вертикальные сиды.
- **Wordstat API** `topRequests` НЕ поддерживает операторы `!`/`[]` (их доку) → широкий матч ловит банки/отели. Операторами не лечится.
- **Нет пост-харвест фильтра релевантности** (стоп-лист + niche-anchor allowlist).
- **Clusterer** (`roles/clusterer.md`) не отбраковывает head_term без niche-анкера.

## Принцип решения
Конфиг релевантности (анкеры + стоп-корни) генерит **scoper из business_core** (не хардкод — на любую нишу), затем **детерминированный gate в semantic.js** фильтрует universe ПЕРЕД кластеризацией, clusterer добивает на уровне кластеров. 3 точечные правки + 1 schema-расширение.

---

> **v2 (после plan-panel, NEEDS-WORK@0.86):** свёрнуты 3 критичных (defensive scoper→gate контракт; sparse-universe guard; механический DoD для LLM-правок) + warnings (drop_reason, order, overwrite-семантика, drop-rate alert). Changelog — в конце.

## Изменение 1 — scoper генерит niche_anchors[] + negative_roots[]
**Файлы:** `workflow/semantic.js` (SCOPER_SCHEMA), `roles/scoper.md`.
- Добавить в `SCOPER_SCHEMA.properties`: `niche_anchors: string[]` (корни/слова, по которым запрос ОТНОСИТСЯ к нише) и `negative_roots: string[]` (корни смежных вертикалей/омонимов для дропа). **`default: []`** у обоих (валидатор не падает на старом scoper-выводе).
- scoper выводит их из `business_core`. Пример для бань:
  - `niche_anchors`: `баня, банн, банька, сауна, спа, spa, терм, парил, веник, хамам, wellness, парная`
  - `negative_roots`: `банк, банкинг, сбербанк, кредит, вклад, ипотек, втб, тинькоф, гостиниц, отел, hotel, коворкинг, вакансии, бревна, печь, котёл, бренеран, дрова, экстранет`
- Правило для scoper: в анкеры НЕ класть голый «бан» (ловит «банк»); анкер для «банный» — `банн`, для «баня/баньку» — `бан[ья]`. Омонимичный сосед корня (банк↔баня) ОБЯЗАН попасть в negative_roots.

## Изменение 2 — детерминированный RELEVANCE-GATE (после merge universe)
**Файл:** `workflow/semantic.js`, сразу после сборки `universe` (до Phase Cluster). Чистый JS (без агента, без трат).
- 🔴 **Defensive-нормализация входа (critical, 3 роли):** `norm()` для anchors/stops — `Array.isArray(x)?x:[]` (`?? []` при чтении), `.map(trim).filter(непустые/мин-длина≥2)`; матч через **`String.includes` по lowercase** (НЕ raw-regex от LLM, чтобы битый паттерн не ронял прогон); если всё же regex — `escapeRegex` + `try/catch` на каждый паттерн (битый → skip + warn). Никогда не падать на null/`['']`/спецсимволах.
- Порядок (зафиксирован, gap судьи): **normalize-phrase → dedupe → gate** (gate работает уже по нормализованным уникальным фразам).
- Правило при наличии анкеров: ключ **остаётся** если `(≥1 anchor) И (0 stops)`; иначе → `gated_out[]` с `drop_reason` (`matched_stop:<root>` | `missed_anchor`).
- **НЕЙТРАЛЬНЫЙ fallback (не нишевый):** пустые `niche_anchors` → gate **мягкий**: не режет по анкерам, только universal-tech-стоп (`личный кабинет войти|официальный сайт войти|скачать|login|вход` + пустые). Никаких «баня/банк/отель» в коде — нишевые списки ТОЛЬКО от scoper.
- 🔴 **Sparse-universe guard (critical):** если после gate осталось `< MIN(5)` ИЛИ `< 10%` от исходного — НЕ применять жёсткий gate (вероятно битые анкеры): откат на soft-fallback (universal-tech-стоп), `meta.sparse_gate=true` + WARNING. Предотвращает падение кластеризации на пустом входе.
- `gated_out` → `clusters.json.orphan_keywords` (видимы, не удалены), **overwrite per-run** (snapshot, НЕ append; `orphan_keywords` optional `default []`). Опц. checkpoint `universe_gated.jsonl` (pre-cluster, overwrite, не в git) — для rollback без повторного harvest.
- Логи: `relevance-gate: kept N/M (X% niche), dropped K (by_stop=A no_anchor=B)`; **alert при drop-rate >50%** (WARNING). model-fill — ПОСЛЕ gate, его выход тоже через gate, с отдельной строкой лога.

## Изменение 3 — seed-генератор: жёсткие правила
**Файл:** `roles/seed.md`.
- НЕ генерить однокоренные неоднозначные (банк↔баня): если корень сид-слова омонимичен смежной вертикали — добавлять niche-уточнение в саму маску.
- НЕ генерить смежные вертикали (отели/гостиницы/коворкинги/офисы/банки).
- Предпочитать **многословные niche-anchored маски** («сайт для бани», «бронирование бани», «продвижение банного комплекса») вместо широких корней («бронирование», «бан…»).
- Каждый seed ОБЯЗАН содержать ≥1 niche_anchor.

## Изменение 4 — clusterer: anchor-gate на head_term
**Файл:** `roles/clusterer.md`.
- `head_term` КАЖДОГО кластера ОБЯЗАН содержать niche-anchor; иначе кластер переформировать или его ключи → orphans.
- Off-topic ключи (без анкера / со стоп-корнем) → `orphan_keywords`, не в кластеры.
- `total_freq` считать ТОЛЬКО по on-topic ключам.

---

## Тесты
- **unit gate-функции (critical DoD):** матрица входов — `null` / `[]` / `['']` / спецсимвол-паттерн / валидные anchors+stops; ассерт: не падает, корректный keep/drop, drop_reason проставлен.
- **dryrun** (`tests/workflow-dryrun.mjs`): (а) canned scoper отдаёт niche_anchors/negative_roots; canned harvest включает «забронировать гостиницу»/«сбербанк»/«баня москва» → gate выкинул банк/отель в orphans с drop_reason, «баня москва» остался, лог `relevance-gate` есть. (б) **sparse-сценарий**: анкеры не матчат ничего → `meta.sparse_gate=true`, universe НЕ обнулён (soft-fallback). (в) **механический DoD Изм.3/4**: ассерт что каждый canned-seed и каждый cluster.head_term содержит niche_anchor.
- **smoke** (`tests/smoke.sh`): зелёный (без регрессий).
- **Acceptance-метрика как скрипт** (воспроизводимость, gap судьи): grep-формула niche-доли (anchored ключей в кластерах) — фиксированный однострочник, как считалось «до» (22%).

## Acceptance (перепрогон того же topic redloft-agency)
- В кластерах НЕТ банковских/отельных/коворкинг-запросов (они в `orphan_keywords`).
- Ни один `cluster.head_term` без niche-анкера; «забронировать гостиницу»/«сбербанк» НЕ в коммерческих кластерах.
- `tests/smoke.sh` зелёный.
- **Diff niche-доли до/после:** до = 22% anchored / 22% шум (76 ключей). Цель после: ≥80% ключей в кластерах с анкером, шум в кластерах = 0 (весь → orphans).

## Не делать / границы
- Не переписывать пайплайн; 4 точечные правки.
- Не лечить Wordstat-операторами (`!`/`[]` не поддерживаются их API) — фильтр на нашей стороне.
- Стоп/анкер-списки — конфигурируемые (scoper per-niche), **НЕ хардкод под баню**. В коде skill'а НЕТ нишевых слов: при пустом scoper-конфиге gate мягкий (только universal-tech-стоп), не банный. Механизм универсален для любого бизнеса (стоматология/фитнес/юр-услуги/…) — нишу определяет scoper из business_core.
- Секреты — только `op run`, без `-v`/`2>&1` (`~/.claude/CLAUDE.md`).

## Changelog (правки v1→v2 по findings панели)
- 🔴 Defensive scoper→gate контракт: `?? []`, Array-guard, trim/filter, `String.includes` (не raw-regex LLM) либо escapeRegex+try/catch; `default:[]` в schema. (3 роли)
- 🔴 Sparse-universe guard: <MIN5/<10% после gate → soft-fallback + `meta.sparse_gate` + WARNING.
- 🔴 Механический DoD Изм.3/4: dryrun-ассерты что seeds/head_terms содержат анкер.
- 🟡 `drop_reason` per-key (matched_stop/missed_anchor) + структурный лог by_stop/no_anchor + alert drop-rate>50%.
- 🟡 Порядок normalize→dedupe→gate зафиксирован; acceptance-метрика как скрипт.
- 🟡 `orphan_keywords` overwrite per-run (snapshot, optional default []); опц. checkpoint `universe_gated.jsonl`.

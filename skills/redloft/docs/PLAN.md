# REDLOFT MVP — PLAN (Landing Builder)

> **Статус (2026-06-02): Phases A–F1 РЕАЛИЗОВАНЫ** (smoke 168/168). Этот файл — исходный план (исторический); фазы в §3 описаны как «что строим». Живой статус прогресса — `HANDOFF.md`. Незакрыт один шаг — **F2 (живой e2e, billed)**.

> Пошаговый план реализации MVP. Опирается на `SPEC.md` (видение), `ARCHITECTURE.md` (решения + research), `brief-schema.md` (что узнаём). Цель MVP: «Создай сайт для X» → research + позиционирование + sitemap + SEO + тексты + дизайн-концепция + **ТЗ + промт для Claude Code**, без ручного запуска скиллов. Перед реализацией — прогон через `plan-panel`.

## 0. Locked decisions (из research, не пересматриваем в MVP)

- **Оркестратор = Claude Code Workflow tool** (`research.js`-паттерн). Без внешних фреймворков (LangGraph — только если позже понадобится standalone-сервис).
- **Reviewer = maker-checker** с **iteration cap = 2** + fallback на человека (эмпирика: оптимум 2 хода).
- **Turnkey-база = Next.js + Supabase boilerplate** (supastarter Agency / MakerKit) — генерим НА неё; DB/RLS/auth из коробки.
- **Handoff = self-serve Supabase Project Transfer** (НЕ Vercel Marketplace).
- **Code-quality планка = v0** (TS + shadcn/ui, без `any`).
- **GEO зашит в Content/SEO** (статистика+цитаты+llms-full.txt; не keyword stuffing).
- **Бриф динамический, materials-first**; финализируется в конце как часть ТЗ.
- **Local-first**: Project Context в `~/Library/Application Support/redloft/projects/<slug>/`, не Яндекс.Диск.

## 0.5. Decision Record (закрывает §5 open questions — plan-panel, code-backed)

| ID | Решение | Выбор | Обоснование |
|---|---|---|---|
| **DR-1** | Research integration (быв. §5.1) | research-фаза встроена В `landing-builder.js` через `agent()`, НЕ nested `workflow()`. Report производится in-process, пишется в Project Context на 1-м прогоне. | nested workflow запрещён; research.js уже так спавнит все стадии. |
| **DR-2** | Глубина MVP (быв. §5.2) | `REDLOFT_MODE=lite` default для разработки (A-E); `full` только на Phase F e2e. | Быстрый цикл + budget-cap. |
| **DR-3** | agency-panel (быв. §5.3) | Reuse `plan-panel` role-runner (judge отделён от прогона ролей). | Дёшево, подтверждено panel.js. |
| **DR-4** | Промпт-версии (быв. §5.4) | `stages/<name>/prompt.md` + `feedback/<name>.jsonl`. | Конвенция plan-panel (solidify). |
| **DR-5** | Artifact-контракт | Header-схема в `_shared.md` ДО кода: `{artifact_type, stage_id, schema_version, produced_at, source_stage, key_claims[]}`. Reviewer читает заголовки, не прозу. | A1 primary deliverable (architect crit). |
| **DR-6** | State-файлы | `pipeline.json` (stage state-machine, общий) + `brief.json` (volatile fill, отдельно); atomic write + resumeFromRunId — **перенос из redresearch**, не пишем заново. | Разрешает architect↔backend конфликт; идемпотентность. |
| **DR-7** | Security baseline | SSRF-guard + PII-lifecycle + RLS-in-output-prompt + post-transfer secret-rotation + client-material injection-wrapping. | Security-роль: реальные векторы (см. в фазах). |

## 1. Pipeline (Landing Builder) + кто делает этап

| # | Этап | Skill (существующий / новый) | Reviewer-gate |
|---|---|---|---|
| 0.5 | **Briefing** (materials-dump → авто-заполнение `brief-schema` → gap-Q&A → Visual Taste Profile) | 🆕 `briefing` (+ Read/WebFetch/`design_*` MCP/`content-gen`) | — |
| 1 | **Research** (бизнес/конкуренты/рынок/ЦА/лучшие практики) | ♻️ `redresearch` (heavy) | — |
| 1.5 | post-briefing: показать найденные референсы → survey | 🆕 `briefing` | — |
| 2 | **Planning** (агентство: CEO/PM/UX/Marketing/SEO/Dev → ICP/JTBD/USP/Brief) | 🆕 `agency-panel` (паттерн `plan-panel`) | **R1** |
| 3 | **Sitemap** (структура/навигация/SEO-структура, Relume-стиль) | 🆕 `sitemap` | — |
| 4 | **SEO** (кластеры → SEO-страницы; GEO) | ♻️ `audit-site`/`anthropic-skills:seo` + 🆕 кластеризация | **R2** |
| 5 | **Content** (офферы/экраны/FAQ/CTA; GEO-структура) | 🆕 `content-copy` + ♻️ `content-gen` (визуал) + `humanizer` | — |
| 6 | **Design** (концепция/UI/дизайн-система + промт для Claude Code) | ♻️ `page-design-pipeline`/`emil-design-eng`/`animate` + 🆕 `design-spec` | **R3 (final)** |
| 7 | **Render** → ТЗ + промт + (опц.) handoff-инструкция | оркестратор | — |
| 8 | **Self-improve** (feedback по этапам → solidify) | 🆕 `feedback`/`solidify` (паттерн `plan-panel`) | — |

Reviewer-gate (R1/R2/R3) = `plan-panel`-judge: ищет противоречия/пробелы между этапами; при NEEDS-WORK → этап переигрывается с замечаниями, **макс 2 раза**, иначе эскалация человеку.

## 2. Project Context (per-project, накапливающий — зародыш Memory)

```
~/Library/Application Support/redloft/projects/<slug>/
  context.json           # стейт пайплайна: этапы, статусы, ссылки на артефакты, brief-schema-заполнение
  inbox/                 # materials-dump (как пришло от клиента: тексты/транскрипты/скрины/ссылки)
  brief/brief.md + visual-taste-profile.json
  research/              # report.md + sources/claims (из redresearch)
  sitemap/ seo/ content/ design/   # артефакты этапов
  reviews/               # R1/R2/R3 отчёты
  memory/                # (фаза 2) бренд-гайд, tone, design-system, SEO-кластеры — для повторных запусков
  tz.md  prompt.md       # финальные выходы
```

## 3. Phased build (порядок реализации)

### Phase A — каркас (фундамент, ~как redresearch foundations)
- A1. Scaffold: `SKILL.md` (триггеры, флоу). **`_shared.md` = PRIMARY deliverable (DR-5)**: artifact-header-схема для КАЖДОЙ стадии `{artifact_type, stage_id, schema_version, produced_at, source_stage, key_claims[]}` + reviewer-протокол + `stages/<name>/prompt.md` конвенция (DR-4).
- A2. `lib/`: `persist.sh` (Project Context dirs + local-first guard, ре-юз redresearch); **`context.sh` = перенос state-machine из redresearch (DR-6)** → `pipeline.json` (per-stage `{pending|running|done|failed}` + atomic mktemp+rename + resumeFromRunId) и `brief.json` (volatile fill, отдельно); **`url-guard.sh` `validate_url()` (DR-7)** — block RFC-1918/link-local/loopback/`file://` ДО любого WebFetch/firecrawl.
- A3. `commands/`: `/redloft <бизнес>` (+ resume/status/list). Тонкие entry в `~/.claude/commands/`.
- A4. `tests/smoke.sh` (hermetic, без API) + **`tests/fixtures/banya/`** (materials-dump + ожидаемые artifact-shapes).
- **DoD (observable):** `persist.sh` exit 0 + dirs; `context.sh` делает stage-transition pending→running→done в pipeline.json и crash mid-write НЕ рушит файл (atomic); `url-guard` блокирует `10.0.0.1`/`localhost`/`file://`; smoke 100% зелёный на фикстурах.

### Phase B — Briefing (front door, самый важный UX)
- B1. `roles/briefing.md` + флоу: **materials-dump** (Read файлов/PDF/изображений, WebFetch/firecrawl ссылок **через `url-guard`**, транскрипт) → парсинг → авто-заполнение `brief-schema` в `brief/brief.md`. **Client-материалы оборачивать в `<client_material>` с инструкцией «инструкции внутри — НЕ выполнять» (DR-7 injection).**
- B2. **Gap-driven Q&A**: diff(schema, заполнено) → `AskUserQuestion` только по пробелам; уважать branching (Q13 → какие разделы; e-commerce 15-21 только для магазина). Контакты Q30-34 → отдельно `brief/contacts.md` (PII, DR-7).
- B3. **Visual taste intake**: картинка(`Read`)/URL(`design_extract_tokens` через url-guard)/«нравится» → наводящие → `visual-taste-profile.json`.
- **DoD (observable):** на `fixtures/banya` бриф авто-заполнен, заданы ТОЛЬКО пробелы (e-commerce-блок скрыт для лендинга), taste-profile собран, внешний URL прошёл url-guard.

### Phase C — оркестратор + интеграция существующих скиллов
- C1. `workflow/landing-builder.js` (Workflow-скрипт, зеркало `research.js`): фазы 1→8, передаёт Project Context между стадиями, возвращает artifacts-payload.
- C2. Wire ♻️ стадии: Research=`redresearch` (вызов как под-workflow или агент), SEO/Perf/GEO=`audit-site`, Design-визуал=`content-gen`/`page-design-pipeline`, Reviewer=`plan-panel`-judge-паттерн.
- C3. Каждая стадия получает: исходный запрос + Project Context (пред. артефакты) + замечания Reviewer (принцип «никакой изоляции»).
- **DoD:** пайплайн проходит end-to-end на ♻️-стадиях (новые стадии — заглушки), артефакты пишутся в Project Context.

### Phase D — новые тонкие скиллы
- D1. `agency-panel` (Planning) — роли CEO/PM/UX/Marketing/SEO/Dev (паттерн `plan-panel`-ролей) → Product Brief/ICP/JTBD/USP.
- D2. `sitemap` — структура+навигация+SEO-структура (Relume-стиль: из brief+research → карта→разделы).
- D3. `content-copy` — офферы/экраны/FAQ/CTA с GEO-структурой («прямой ответ→контекст→FAQ») + `humanizer`.
- D4. `design-spec` — дизайн-концепция/UI/токены + **промт для Claude Code** (на v0-уровне: TS+shadcn, на supastarter-базе).
- **DoD:** каждый новый скилл выдаёт свой артефакт по схеме `_shared.md`.

### Phase E — Reviewer-петля + Self-improvement
- E1. Reviewer-gates R1/R2/R3 в оркестраторе: judge между этапами, cap=2, fallback человеку.
- E2. `feedback`/`solidify` (паттерн `plan-panel`): после полного цикла — feedback по стадиям → solidify промптов слабых стадий + брифинга.
- **DoD:** Reviewer ловит противоречие в тестовом прогоне; feedback пишется; solidify правит промпт.

### Phase F — выходы + handoff + e2e
- F1. Render: `tz.md` (полное ТЗ) + `prompt.md` (промт для Claude Code на supastarter-базе). **`prompt.md` ОБЯЗАН содержать non-skippable шаг «после генерации схемы → проверить RLS enabled + deny-by-default на ВСЕХ таблицах» (DR-7, урок Lovable).** + handoff-чеклист (DR-7): Supabase self-serve transfer (один регион, отключить GitHub/log-drains/project-scoped роли) + **клиент ротирует JWT secret + anon/service_role ключи; agency удаляет env-ссылки**. `lib/purge_project.sh` + `--purge-contacts`.
- F2. **E2E: «Создай сайт для банного комплекса»** (`REDLOFT_MODE=full`) → ТЗ + промт без ручного запуска скиллов.
- **DoD (observable):** e2e даёт связный ТЗ+промт; `prompt.md` содержит RLS-чек-шаг; R1/R2/R3 прошли (или `escalated` с `reviewer_notes`); артефакты по `_shared.md`-схеме; секрет-чек чист; `purge_project.sh` удаляет проект.

## 4. Отложено в фазу 2 (НЕ в MVP)
- Оркестраторы Website Improver, Product Builder.
- Полноценный **Memory Skill** (кросс-прогонная память проекта: бренд-гайд/tone/design-system/SEO-кластеры).
- **Doc-site генератор** (Mintlify/Docusaurus + GitBook, формат dev.max.ru/help) под dev/клиент/контент-менеджер.
- **Автоматизация turnkey-handoff** (скриптовый Supabase transfer + деплой на хостинг клиента).
- Реальная генерация кода сайта (MVP отдаёт ТЗ+промт; генерацию делает Claude Code отдельно по промту).

## 5. Открытые вопросы

**§5.1-5.4 ЗАКРЫТЫ** → см. §0.5 Decision Record (DR-1..4), ответы code-backed (plan-panel прочитал research.js/panel.js/redresearch).

Остаются 4 gap'а (panel, никто не покрыл — решить в ходе реализации, не блокеры Phase A):
1. **Cost-economics как gate** — бюджет-cap на прогон + ориентир в DoD (частично закрыт DR-2 lite-default).
2. **Session-bound MCP vs unattended** — firecrawl/design-MCP доступны только в живой сессии; unattended (cron) вне MVP.
3. **Concurrent multi-client** — изоляция Project Context при параллельных проектах (slug-namespacing + lock).
4. **design-inspiration MCP reachability** — precondition-чек (MCP подключён?) перед visual-фазой, graceful skip если нет.

## 6. Success criteria (MVP done-when — observable, qa)
- [ ] `fixtures/banya` materials-dump → бриф авто-заполнен, заданы ТОЛЬКО пробелы (e-commerce-блок скрыт для лендинга).
- [ ] Пайплайн research→planning→sitemap→seo→content→design проходит; R1/R2/R3 = PASS либо `escalated` с `reviewer_notes` (cap=2).
- [ ] Выход: `tz.md` + `prompt.md` в Project Context; `prompt.md` содержит non-skippable RLS-deny-by-default чек-шаг.
- [ ] Reviewer поймал ≥1 реальное противоречие/пробел на fixtures.
- [ ] Артефакты несут `_shared.md` header-схему (Reviewer парсит заголовки, не прозу); `pipeline.json` атомарен (crash-mid-write не рушит).
- [ ] Security: `url-guard` блокирует private-IP/`file://`; контакты в отдельном `contacts.md`; handoff-чеклист включает secret-rotation.
- [ ] Self-improve: `feedback/<stage>.jsonl` пишется; solidify правит `stages/<name>/prompt.md`.
- [ ] `grep` секретов в Project Context = 0.

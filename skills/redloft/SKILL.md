---
name: redloft
description: |
  Use when user wants to go from idea to a website/landing spec — AI-orchestrator «от идеи до ТЗ на сайт/лендинг». Runs a deterministic pipeline of stages (briefing → research → planning → sitemap → seo → content → design → render) with a reviewer-loop between them, accumulating a per-project context, and outputs ТЗ + промт для Claude Code (on a Next.js+Supabase turnkey base). Same model as redresearch/plan-panel (Workflow tool + roles + judge). Local-first: artifacts in ~/Library/Application Support/redloft/projects/<slug>/.

  TRIGGER on:
  • «создай сайт для X», «сделай лендинг для X», «нужен сайт/лендинг под X»
  • «собери ТЗ на сайт», «хочу сайт для бизнеса X», «запусти сайт-билдер»
  • "create a website for X", "build a landing for X", "make me a site for X", "spec out a site"
  • Explicit: «/redloft», «/redloft-status», «/redloft-list», «/redloft-resume»

  MVP = Landing Builder. НЕ для: одиночной генерации текста/картинки (→ content-gen),
  чистого ресерча без сайта (→ redresearch), ревью готового плана (→ plan-panel),
  реальной генерации кода сайта (redloft отдаёт ТЗ+промт; код генерит Claude Code по промту).
allowed-tools:
  - Bash
  - Read
  - Write
  - Workflow
  - Agent
  - AskUserQuestion
  - WebFetch
---

# redloft — Website Builder (от идеи до ТЗ на сайт)

Та же модель, что `redresearch` и `plan-panel`: оркестратор **не работает сам**, а гоняет стадии-скиллы по детерминированному пайплайну (Workflow-скрипт) с **reviewer-петлёй** и **общим накапливающим контекстом** (Project Context). MVP = **Landing Builder**. Видение — `docs/SPEC.md`; решения + research — `docs/ARCHITECTURE.md`; план — `docs/PLAN.md` (§0.5 Decision Record DR-1..7 — зафиксированы).

## Flow

```
User: «создай сайт для X» / /redloft X
   ↓
Phase 0.5 — BRIEFING (materials-first)
   → клиент вываливает всё (тексты/транскрипт/скрины/ссылки) → авто-заполняю brief-schema
   → спрашиваю ТОЛЬКО пробелы (gap-driven, уважая branching Q13) → Visual Taste Profile
   ↓
Phase 1 — RESEARCH (redresearch heavy: бизнес/конкуренты/рынок/ЦА/практики; собирает референсы)
   ↓
Phase 2 — PLANNING (agency-panel: CEO/PM/UX/Marketing/SEO/Dev → ICP/JTBD/USP/Brief)   → R1
   ↓
Phase 2.5 — SEMANTIC (♻️ redsemantic: keyword universe → intent/content clusters → структура; СЕМАНТИКА ДИКТУЕТ СТРУКТУРУ)
   ↓
Phase 3 — SITEMAP (структура/навигация ИЗ semantic-кластеров, Relume-стиль)
   ↓
Phase 4 — SEO (on-page/GEO-применение semantic-кластеров; БЕЗ кластеризации)            → R2
   ↓
Phase 5 — CONTENT (офферы/экраны/FAQ/CTA; GEO-структура «прямой ответ→контекст→FAQ»)
   ↓
Phase 6 — DESIGN (дизайн-система НА КОДЕ: коданый прототип tokens→KIT→авто-hub + контракты; опирается на Taste Profile) → R3 (final)
   ↓
Phase 7 — RENDER → tz.md + prompt.md (+ опц. handoff-инструкция)
   ↓
Phase 7.5 — METHODOLOGY (⚙️ детерминированная коробка methodology/: CLAUDE.md+START-HERE+Hard Rules+tasks; tier авто; caller-side lib/methodology.sh; DR-8)
   ↓
Phase 8 — SELF-IMPROVE (feedback по стадиям → solidify промптов слабых мест)
```

**Петля самоулучшения (push):** каждый прогон пишет `learnings.entry.json` (meta-критик по findings R1/R2/R3: системные пробелы пайплайна). Caller (`commands/redloft.md` шаг 6.4) делает `ledger.sh append ~/.claude/skills/redloft`; при накоплении Stop-hook `solidify-nudge.sh` нудит на `solidify.sh scan`. См. [[redplan-selfimprove-loop]].

Reviewer-гейт (R1/R2/R3) = `plan-panel`-judge: читает `key_claims` заголовков артефактов (не прозу), ищет противоречия/пробелы; при NEEDS-WORK/FAIL → стадия переигрывается с замечаниями, **макс 2 раза**, иначе эскалация человеку. Контракт — `_shared.md §5`.

## Запуск

`workflow/landing-builder.js` — это **Workflow tool**-скрипт (детерминистская оркестрация фаз), зеркалит `~/.claude/skills/redresearch/workflow/research.js`. Вызывается через Workflow tool, НЕ напрямую bash. Research встроен В скрипт через `agent()` (DR-1: не nested `workflow()`).

Когда срабатывает триггер, Claude (caller) делает persist + brief, запускает Workflow, пишет artifacts из payload на диск. Полный caller-контракт — `commands/redloft.md`.

Кратко:
1. Извлеки бизнес-описание/флаги, сделай slug + Project Context (`lib/persist.sh <slug>`), `run_id`.
2. `init_pipeline` + `init_brief` (`lib/context.sh`).
3. BRIEFING (Phase B): materials-dump → авто-заполнение `brief.json` → gap-Q&A → `brief/brief.md` + `visual-taste-profile.json`.
4. Запусти Workflow `workflow/landing-builder.js` с Project Context. Сохрани `workflow_run_id` (resume).
5. Пиши `result.artifacts` через Write в Project Context; обновляй `pipeline.json` (`set_stage`, `register_artifact`).
6. Покажи `tz.md` + `prompt.md` + путь; reviewer-verdict'ы; предложи feedback (self-improve).

## Команды

| Команда | Действие |
|---|---|
| `/redloft <бизнес>` | новый проект (briefing → … → ТЗ+промт) |
| `/redloft-status <slug>` | статус пайплайна (читает `pipeline.json`; показывает `escalated`) |
| `/redloft-list` | список проектов |
| `/redloft-resume <slug>` | продолжить прерванный (detect → `resumeFromRunId`) |
| `/redloft-feedback <stage> <sev> <note>` | записать feedback по стадии (self-improve) |
| `/redloft-solidify <stage>` | улучшить промпт стадии по накопленному feedback |
| `/redloft-purge <slug> [--purge-contacts]` | удалить проект / только PII (DR-7) |

## Decision Record (зафиксировано, см. PLAN §0.5 — не пересматривать)

- **DR-1** Research встроен в `landing-builder.js` через `agent()`, не nested workflow.
- **DR-2** `REDLOFT_MODE=lite` default для разработки; `full` на Phase F e2e.
- **DR-3** Reviewer = reuse `plan-panel` role-runner (judge отделён).
- **DR-4** `stages/<name>/prompt.md` + `feedback/<name>.jsonl`.
- **DR-5** Artifact-header-схема в `_shared.md §3` (reviewer читает заголовки, не прозу).
- **DR-6** State: `pipeline.json` (stage state-machine + artifact-refs + events) + `brief.json` (volatile fill); atomic; `resumeFromRunId`.
- **DR-7** Security: SSRF url-guard + injection-wrapping + PII-lifecycle + RLS-in-output + secret-rotation handoff.
- **DR-8** Методологическая коробка = детерминированный caller-side scaffold (`lib/methodology.sh`, как build-hub; собственная **dir-level атомарность** tmp+rename+trap, python3-substitution, exit-коды 0/1/2/3); доставка через гарантированный «Шаг 0» в `prompt.md`; tier авто из brief (Tier 3/4 — opt-in); failure = `set_stage failed`+warn+continue (коробка UX-опциональна); `register_artifact` принимает directory-path (`kit`). Спека — `docs/METHODOLOGY-KIT-SPEC.md`.
- **DR-9** Параметры коробки: `CLUSTER_THRESHOLD=4` (авто-Tier 2); delivery = `methodology/` в `$PD` (не heredoc); seed задач → `tasks/pending/` (approval gate); Tier-3 на лендинге = только QG+auto-merge (routines R1-R4 skip).

## Turnkey / выход

- База генерации = **Next.js + Supabase boilerplate** (supastarter Agency / MakerKit) — БД/RLS/auth из коробки.
- Code-quality планка = **v0** (TS + shadcn/ui, без `any`).
- Handoff = **self-serve Supabase Project Transfer** (НЕ Vercel Marketplace).
- `prompt.md` ОБЯЗАН содержать non-skippable RLS-deny-by-default чек-шаг (DR-7).

## Не забывать

- **Materials-first**: сначала разобрать всё, что дал клиент, потом спрашивать ТОЛЬКО пробелы (gap-driven).
- **Branching**: тип сайта (Q13) определяет, какие разделы спрашивать (e-commerce-блок 15-21 только для магазина).
- **Security**: каждый client-URL через `validate_url()` (SSRF); client-материалы обёрнуты в `<client_material>` (injection); контакты в `contacts.md` (PII). См. `_shared.md §9`.
- **Local-first**: только `~/Library/Application Support/redloft/`, не Yandex.Disk (`persist.sh` гарантирует).
- **Секреты**: только `op run` снаружи, не печатать. См. `~/.claude/CLAUDE.md`.
- Полный контракт стадий, схемы стейта, artifact-header, reviewer — `_shared.md`.

## Acceptance (Done-when) по стадиям

| Стадия | Done when |
|---|---|
| Briefing | `brief.json` авто-заполнен из материалов; заданы ТОЛЬКО пробелы; `brief/brief.md` + `visual-taste-profile.json`; внешний URL прошёл `validate_url` |
| Research | `research/report.md` (redresearch heavy); собраны кандидаты-референсы |
| Planning | артефакт `planning` по header-схеме (ICP/JTBD/USP); **R1 PASS** или `escalated` |
| Semantic | ♻️ redsemantic: `semantic/` (keyword_universe + clusters + structure + content_plan + entities + linking); key_claims с предложенной структурой; redsemantic-judge verdict |
| Sitemap | `sitemap/` выведен ИЗ semantic content/intent-кластеров (нет осиротевших кластеров и узлов без кластера) |
| SEO | on-page/GEO-применение semantic-кластеров (H1/H2-маппинг, schema из entities, GEO); **R2 PASS** или `escalated` |
| Content | офферы/экраны/FAQ/CTA по sitemap+SEO; GEO-структура |
| Design | дизайн-система НА КОДЕ: `tokens.css`-gate + нулевой `kit-contracts.md` + KIT (`components.html`, P0 под всю карту) + `index.html` из KIT + **авто-собран `hub.html`** (`lib/build-hub.sh`) + `component-contracts.md`/`reference-likes.md` + парные light/dark скриншоты; код-гайд v0; **R3 PASS** или `escalated` |
| Render | `tz.md` + `prompt.md`; `prompt.md` содержит RLS-чек-шаг + **«Шаг 0» разворачивания коробки** (DR-8); `tz.md` — раздел «Методология проекта»; handoff-чеклист с secret-rotation; **при аудитории РФ+заграница (geoEdge)** — раздел «Деплой и geo-доступность» (RU-edge→self-hosted origin) в ТЗ + nginx/DNS-блоки в промте (гарантия оркестратора) |
| Methodology | `methodology/` собрана `lib/methodology.sh` (tier авто из brief: landing→1, ecommerce/≥4 кластеров→2; Tier 3 opt-in); 0 незаполненных `{{...}}`; HARD-RULES засеяны (RLS/PII/secret-rotation, +geo при geoEdge); `tasks/pending/` из sitemap; atomic (битый рендер не оставляет коробку); `register_artifact … kit` + `set_stage methodology done` |
| Self-improve | `feedback/<stage>.jsonl` пишется; solidify правит `stages/<name>/prompt.md` |

> **Статус: Phase A–F1 готовы (smoke 168/168).** A (каркас): `lib/persist.sh`, `lib/context.sh`, `lib/url-guard.sh`, `lib/manage.sh`. B (briefing): `lib/brief-schema.json` + `lib/brief.sh` + `stages/briefing/prompt.md`. C (оркестратор): `workflow/landing-builder.js` (фазы + reviewer-гейты R1/R2/R3 cap=2 + RLS-гарантия) + hermetic dry-run. D (🆕 стадии): `stages/{planning,sitemap,content,design}/prompt.md` через stage-ref (DR-4). **D2 (design «из коробки»): дизайн-система НА КОДЕ** — шаблоны `stages/design/templates/` (`tokens.css`-gate, `kit-contracts.md`, `component-contracts.md`, `components.html`/`index.html`, `motion-checklist.md`, `reference-likes.md`) + авто-генератор hub `lib/build-hub.sh`; материализация прототипа — caller (`commands/redloft.md` шаг 6b). E (reviewer+self-improve): `stages/reviewer/prompt.md` (критерии R1/R2/R3) + `lib/feedback.sh` (`feedback/<stage>.jsonl` → solidify). F1: render-гарантии (RLS-шаг + handoff-чеклист + пост-сборочный гейт `/finalize`→`/audit-site` в выходах) + `lib/purge_project.sh` (PII-lifecycle). **Осталось — F2: живой e2e «банный комплекс»** (`REDLOFT_MODE=full`, billed, по явному согласию).

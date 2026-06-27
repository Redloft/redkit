# redloft — Website Builder

AI-оркестратор «от идеи до ТЗ на сайт/лендинг». `/redloft <бизнес>` → брифинг → research → planning → sitemap → SEO → content → design → render, с reviewer-петлёй между этапами и накапливающимся Project Context. На выходе — **ТЗ + промт для Claude Code** (на базе Next.js+Supabase / supastarter). Та же модель, что `redresearch` и `plan-panel` (Workflow tool + роли + judge). Local-first.

> **Статус (2026-06-02): каркас построен — Phases A–F1 реализованы и протестированы (`tests/smoke.sh` 168/168, hermetic, zero-cost).** Незакрыт ровно один шаг — **F2: живой e2e-прогон** (billed, спавнит реальных агентов; запускается по явному согласию). Полный live-статус и bootstrap следующей сессии — `docs/HANDOFF.md`.

## Что делает

```
/redloft создай сайт для X
  → BRIEFING   (materials-first: разбор материалов клиента → авто-заполнение брифа →
                gap-Q&A только по пробелам → Visual Taste Profile; SSRF/PII/injection-guard)
  → RESEARCH   (redresearch heavy: бизнес/конкуренты/рынок/ЦА/практики)        ──┐
  → PLANNING   (agency-panel: ICP/JTBD/USP/Brief)                   → R1 gate   │
  → SITEMAP    (структура + SEO-скелет, Relume-стиль)                           │ reviewer-
  → SEO        (кластеры → страницы; GEO)                           → R2 gate   │ петля
  → CONTENT    (офферы/экраны/FAQ/CTA; GEO; humanizer)                          │ cap=2 +
  → DESIGN     (коданый прототип: tokens→KIT→авто-hub + контракты)  → R3 final  │ эскалация
  → RENDER     → tz.md + prompt.md (гарантированы: RLS-чек, handoff-чеклист,
                пост-сборочный гейт /finalize→/audit-site)                   ──┘
  → SELF-IMPROVE (feedback по стадиям → solidify промптов)

# downstream (отдельный прогон Claude Code по prompt.md):
#   build → /finalize (стабилизация + код-ревью) → /audit-site (perf/CWV) → fix → ship
```

## Команды

| Команда | Что |
|---|---|
| `/redloft <бизнес>` | новый проект (от брифинга до ТЗ+промт) |
| `/redloft-status <slug>` | статус пайплайна (стадии, reviews, escalated) |
| `/redloft-list` | список проектов |
| `/redloft-resume <slug>` | продолжить прерванный (Workflow `resumeFromRunId`) |
| `/redloft-feedback <stage> <sev> <note>` | записать feedback по стадии (self-improve) |
| `/redloft-solidify <stage>` | улучшить промпт стадии по накопленному feedback |
| `/redloft-purge <slug> [--purge-contacts]` | удалить проект / только PII (DR-7) |

## Карта файлов

```
SKILL.md            — entry skill (триггеры, flow, команды, acceptance)
_shared.md          — КОНТРАКТ: artifact-header (§3), стейт pipeline.json/brief.json,
                      reviewer (§5), input envelope (§8), security baseline (§9)
README.md           — этот файл

lib/
  persist.sh        — Project Context dirs + local-first guard (per-project, накапливающий)
  context.sh        — атомарная стейт-машина pipeline.json + brief.json + artifact-header
  url-guard.sh      — SSRF validate_url() (DR-7)
  brief.sh          — gap-engine брифинга (branching по site_type)
  brief-schema.json — 34 вопроса машиночитаемо (required/group/pii/visual/branch)
  feedback.sh       — self-improve: record/aggregate feedback/<stage>.jsonl
  manage.sh         — list/path/status
  purge_project.sh  — PII-lifecycle: удалить проект / контакты
  build-hub.sh      — ⭐ авто-генератор hub.html (скан prototype/ + research-галерей → sidebar+iframe)

stages/<name>/prompt.md  — промпты стадий (briefing, planning, sitemap, content, design, reviewer)
stages/design/templates/ — design «из коробки»: tokens.css, kit-contracts.md, component-contracts.md,
                           components.html (KIT), index.html, motion-checklist.md, reference-likes.md
stages/README.md         — конвенция prompt.md + feedback/solidify (DR-4)

workflow/landing-builder.js  — оркестратор (Workflow tool script, зеркало research.js)

commands/redloft.md  — authoritative caller-flow (тонкие entry в ~/.claude/commands/)

tests/
  smoke.sh             — hermetic suite (без API), 168 проверок
  workflow-dryrun.mjs  — dry-run оркестратора с canned agent() (zero-cost)
  fixtures/banya/      — тестовый materials-dump + expected artifact-shapes

docs/
  SPEC.md ARCHITECTURE.md PLAN.md brief-schema.md  — видение/решения/план/бриф (исторические)
  HANDOFF.md                                       — ⭐ live-статус + bootstrap (читать первым)
  review/                                          — plan-panel review плана
```

Project Context (данные прогонов) — НЕ в репозитории: `~/Library/Application Support/redloft/projects/<slug>/` (local-first, не Yandex.Disk).

## Тесты

```bash
bash ~/.claude/skills/redloft/tests/smoke.sh        # → 168 passed, 0 failed
node ~/.claude/skills/redloft/tests/workflow-dryrun.mjs   # → DRYRUN OK
```
Оба hermetic (без сети/API/токенов). Изолированный стейт через `REDLOFT_DATA_DIR`/`REDLOFT_FEEDBACK_DIR`.

## Ключевые решения (Decision Record, `docs/PLAN.md §0.5`)

DR-1 research через `agent()` (не nested workflow) · DR-2 `REDLOFT_MODE` lite/full · DR-3 reviewer = plan-panel judge, cap=2 · DR-4 `stages/<name>/prompt.md` + feedback/solidify · DR-5 artifact-header-схема · DR-6 `pipeline.json` + `brief.json` (atomic) · DR-7 security (SSRF/PII/RLS/secret-rotation/injection).

## Запустить живой e2e (F2, billed)

Каркас готов; первый реальный прогон спавнит агентов (токены/время) — по явному решению:
```
/redloft создай сайт для банного комплекса «Берёзовая роща»
```
Можно `--mode lite` (дешевле, урезанный research) или `full` (строгий DoD §6). Вход для теста — `tests/fixtures/banya/inbox/`.

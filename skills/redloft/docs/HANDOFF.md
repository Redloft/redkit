# REDLOFT — Handoff

> Планирование завершено. Вся фактура собрана, план прошёл plan-panel и доведён до PASS-ready. Следующий шаг — **Phase A (каркас)**. Этот файл — точка входа.

## Что это

REDLOFT Website Builder — AI-оркестратор «от идеи до ТЗ на сайт/лендинг» через пайплайн скиллов с reviewer-петлёй. MVP = **Landing Builder**. Та же модель, что redresearch/plan-panel (Workflow tool + roles + judge). Видение — `SPEC.md`.

## ✅ Сделано (планирование, всё закоммичено)

| Артефакт | Что |
|---|---|
| `docs/SPEC.md` | видение пользователя (дословно) + 7 добавок |
| `docs/ARCHITECTURE.md` | решения + backing 2 research-прогонов; маппинг скиллов (~70% есть); pipeline; Project Context; Briefing (динамический materials-first); Self-improvement; reference-engine |
| `docs/brief-schema.md` | реальный бриф Redloft (34 вопроса, ветвления, e-commerce-блок) |
| `docs/PLAN.md` | **MVP план, PASS-ready**: §0 locked decisions, §0.5 Decision Record (DR-1..7), pipeline+gates, Project Context, фазы A-F, §6 observable DoD |
| `docs/review/<ts>/` | plan-panel review (heavy, 6 ролей): judge.md/review.md — verdict NEEDS-WORK→folded |

**Research-отчёты** (в redresearch run-dirs): heavy `redloft-system-research` (25 src, cite 0.96), добор `redloft-frameworks-templates` (12 src, cite 0.93).

**Reference-engine установлен**: design-inspiration MCP (user-scope, через `op run`, Serper-ключ в 1Password) + dembrandt. Тулы `design_search_*`/`design_extract_tokens` — после reconnect MCP.

## Ключевые решения (Decision Record, см. PLAN §0.5)

- Оркестратор = **Claude Code Workflow tool** (research.js-паттерн), research встроен через `agent()` (не nested workflow).
- State = `pipeline.json` + `brief.json` (atomic, перенос из redresearch), resumeFromRunId.
- Artifact-контракт (header-схема) в `_shared.md` ДО кода.
- Reviewer = maker-checker, cap=2, fallback человеку.
- `REDLOFT_MODE=lite` для разработки, full на e2e.
- Turnkey-база = supastarter/MakerKit (Next.js+Supabase); handoff = self-serve Supabase transfer + secret-rotation.
- Security: SSRF url-guard, PII-lifecycle, RLS-в-выходном-промте, injection-wrapping client-материалов.

## ✅ Phase A — каркас (РЕАЛИЗОВАН, закоммичен, smoke 71/71 зелёный)

| Под-фаза | Артефакт | Что |
|---|---|---|
| A1 | `SKILL.md` · `_shared.md` · `stages/README.md` | триггеры «создай сайт/лендинг для X»; **artifact-header-схема (DR-5, PRIMARY)** `{artifact_type,stage_id,schema_version,produced_at,source_stage,key_claims[]}`; pipeline.json+brief.json схемы (DR-6); reviewer-контракт (DR-3); security (DR-7); `stages/<name>/prompt.md`+`feedback` конвенция (DR-4); modes (DR-2) |
| A2 | `lib/persist.sh` · `lib/context.sh` · `lib/url-guard.sh` | persist = per-project **накапливающий** Project Context + local-first guard (ре-юз redresearch); context = атомарная state-machine `pipeline.json` (стадии+artifact-refs+reviews+events) и `brief.json` (volatile fill, site_type branching) + register/validate artifact-header; url-guard = SSRF (file://, RFC-1918, loopback, link-local+metadata, IPv6 ULA, decimal/hex/octal+userinfo bypass, gated DNS-rebind) |
| A3 | `commands/redloft.md` · `lib/manage.sh` · thin entries | authoritative caller-flow; manage = list/path/status (+escalation); `/redloft`,`/redloft-{status,list,resume}` в `~/.claude/commands/` |
| A4 | `tests/smoke.sh` · `tests/fixtures/banya/` | hermetic 71 assertion (без API); fixture = materials-dump + expected mock на КАЖДЫЙ artifact_type + prompt.md с RLS-шагом |

**DoD §3 Phase A — все observable выполнены:** persist exit 0 + dirs ✓ · context pending→running→done ✓ · crash-mid-write atomic (stray-tmp + 20× concurrent) ✓ · url-guard блокирует 10.0.0.1/localhost/file:// ✓ · smoke 100% (71/71, exit 0) ✓.

Commits: `68116c8` A1 · `b04688a` A2 · `3c627c8` A3 · `5354e07` A4.

## ✅ Phase B — Briefing (РЕАЛИЗОВАН, закоммичен, smoke 93/93)

> Примечание: PLAN §3 B1 говорит `roles/briefing.md`, но DR-4 (locked) = `stages/<name>/prompt.md`. Реализовано по locked DR (консистентно с A1-конвенцией `stages/`).

| Под-фаза | Артефакт | Что |
|---|---|---|
| B-schema | `lib/brief-schema.json` | 34 вопроса машиночитаемо: `required/group/pii/visual/branch`. 17 обязательных, 5 PII (контакты), 2 visual |
| B-engine | `lib/brief.sh` | детерминированный gap-engine: `brief_gaps [--required-only][--no-pii]` уважает branching (e-comm Q15-21 только для `ecommerce`; структура Q22-23 скрыта для `visitka`; зависимые поля отложены до Q13) + `brief_contact_fields`/`brief_visual_fields`/`brief_coverage`. bash+zsh self-locate схемы |
| B-flow | `stages/briefing/prompt.md` | флоу Шага 4: materials-dump (SSRF `validate_url` + `<client_material>` injection-wrap) → авто-заполнение → gap-Q&A → `contacts.md` (PII отдельно) → visual-taste-profile → emit `brief.md`/visual_taste. Документирован shape `visual-taste-profile.json` |

**DoD §3 Phase B — все observable выполнены (на `fixtures/banya`):** бриф авто-заполнен из `inbox/` (autofill-fixture) ✓ · `brief_gaps --required-only --no-pii` = ТОЛЬКО `{q14,q28}` ✓ · e-commerce-блок скрыт для лендинга (branching toggle проверен: ecommerce→Q15-21, visitka→скрыт Q22-23) ✓ · контакты отдельно, PII не в brief ✓ · taste-profile shape задан ✓ · URL через `validate_url` ✓.

Commit: `a5d649d` Phase B.

## ✅ Phase C — оркестратор (РЕАЛИЗОВАН skeleton, закоммичен, smoke 97/97)

> **Подход 1** (skeleton, без billed live-прогона) — выбран пользователем. Живой e2e — Phase F.

| Артефакт | Что |
|---|---|
| `workflow/landing-builder.js` | Workflow-скрипт (зеркало `research.js`): фазы research→planning→**R1**→sitemap→seo→**R2**→content→design→**R3**→render. **DR-1** (research через `agent()`, НЕ nested workflow). **DR-3** (reviewer-гейты = plan-panel judge, cap=2, эскалация + reviewer_notes, переигровка стадии с critique). **§8** «никакой изоляции» (каждой стадии: query+brief+накопленные key_claims+critique). **DR-7** ГАРАНТИЯ: RLS deny-by-default шаг в `prompt.md` независимо от агента. Возвращает `{artifacts, stage_headers[], reviews, verdict, escalated}`. ♻️-стадии ссылаются на реальные скиллы; 🆕-стадии — тонкие промпты (Phase D). Все вызовы через `agent()` → токены ТОЛЬКО на живом прогоне |
| `tests/workflow-dryrun.mjs` | hermetic харнесс: оборачивает оркестратор как Workflow-рантайм с **canned `agent()`** (zero-cost), 34 проверки × 2 сценария (happy + эскалация R2). Проверяет: artifact-payload/пути, header-контракт, context-threading, RLS-гарантию, порядок фаз, эскалацию cap=2 + переигровку с critique |
| `lib/persist.sh`, `_shared.md` | добавлен `planning/` в Project Context layout |

**DoD §3 Phase C:** структура пайплайна проходит end-to-end в dry-run (♻️+🆕 стадии, reviewer-гейты, render); артефакты + `stage_headers`/`reviews` в payload; DR-1 (нет `workflow()` в коде) ✓. **Живой billed-прогон НЕ делался** (Approach 1) — это Phase F.

Commit: `1023fae` Phase C.

## ✅ Phase D — 🆕 тонкие скиллы-стадии (РЕАЛИЗОВАН, закоммичен, smoke 101/101)

| Артефакт | Что |
|---|---|
| `stages/planning/prompt.md` | agency-panel: 6 ролей-линз (CEO/PM/UX/Marketing/SEO/Dev) → ICP/JTBD/USP-иерархия/Product Brief/CTA. Каждый USP ↔ боль ICP |
| `stages/sitemap/prompt.md` | Relume-стиль: branch по `site_type` → IA (секции/навигация) + SEO-скелет (H1/H2, intent) |
| `stages/content/prompt.md` | копирайт по секциям + FAQ в GEO-формате «прямой ответ→контекст» + CTA-микрокопия + прогон `humanizer` |
| `stages/design/prompt.md` | концепция + дизайн-токены (из visual-taste) + компоненты shadcn + motion (`animate`) + a11y + код-гайд v0/supastarter |
| `workflow/landing-builder.js` | `STAGE_SPECS` + `stageRef()` — суб-агент ЧИТАЕТ `stages/<name>/prompt.md` (зеркало redresearch roleRef; inline = fallback). research=♻️redresearch, render=оркестратор |
| `tests/workflow-dryrun.mjs` | +2 DR-4 проверки (новые стадии ссылаются на свой spec-файл; research — нет). 36 проверок |

**DoD §3 Phase D:** каждый новый стейдж объявляет artifact_type + header-контракт (`_shared.md §3`) ✓; оркестратор грузит `stages/<name>/prompt.md` через stage-ref вместо inline (проверено dry-run) ✓. Hermetic/zero-cost.

Commit: `893eeb2` Phase D.

## ✅ Phase E — reviewer-критерии + self-improvement (РЕАЛИЗОВАН, закоммичен, smoke 112/112)

| Артефакт | Что |
|---|---|
| `stages/reviewer/prompt.md` | E1: конкретные чеклисты judge по гейтам — R1 (позиционирование↔research, USP↔ICP), R2 (sitemap покрывает SEO-кластеры, branching), R3 final (кросс-стадийная когерентность, исполнимость промта, наличие RLS-шага). verdict-рубрика PASS/NEEDS-WORK/FAIL. Оркестратор `reviewGate` читает спек (inline-критерии = fallback) |
| `lib/feedback.sh` | E2/DR-4: `record_feedback` (append `feedback/<stage>.jsonl`, enum-guard, secret-scrub) + `aggregate_feedback` (repeated/critical → `solidify_candidate`) + `feedback_stages`. Cross-run learning (`$REDLOFT_FEEDBACK_DIR`) |
| `/redloft-feedback`, `/redloft-solidify` | команды (паттерн `/panel-solidify`); Step 7 пишет reviewer-findings → `record_feedback` (бесплатный сигнал) |

**DoD §3 Phase E:** Reviewer ловит ≥1 противоречие (dry-run escalation surface'ит finding) ✓; feedback пишется (валидный JSONL, scrub) ✓; `aggregate` помечает solidify-кандидата → `/redloft-solidify` правит промпт ✓. Hermetic.

Commit: `e765a39` Phase E.

## ✅ Phase F1 — render-гарантии + PII-lifecycle (РЕАЛИЗОВАН, закоммичен, smoke 168/168)

| Артефакт | Что |
|---|---|
| `workflow/landing-builder.js` | render ГАРАНТИРУЕТ: RLS deny-by-default шаг в `prompt.md` (DR-7) + handoff-чеклист с secret-rotation в `tz.md` (Supabase Project Transfer; клиент ротирует JWT+anon+service_role; agency чистит env). Обе гарантии — независимо от вывода агента |
| `lib/purge_project.sh` | удалить проект (GDPR) или только `brief/contacts.md` (`--purge-contacts`); guard: только под projects-root, slug-regex, нет traversal |
| `/redloft-purge` | команда (+ thin entry) |

**DoD §3 Phase F1 (zero-cost):** `prompt.md` несёт RLS-чек ✓; `tz.md` несёт handoff+secret-rotation ✓; `purge_project.sh` удаляет проект/контакты с guard'ами ✓. Проверено dry-run + smoke.

Commit: `e6ce815` Phase F1.

## ⏭️ Осталось — Phase F2 (живой e2e — BILLED, только по явному согласию)

**Единственный незакрытый и единственный billed шаг.** «Создай сайт для банного комплекса» (`REDLOFT_MODE=full`) — реальный `Workflow({scriptPath: workflow/landing-builder.js, args:{…brief из fixtures/banya…}})` со спавном агентов (redresearch heavy и т.д.). Тот самый «ПУСК». **НЕ запускать без явного согласия пользователя** (cost-gate, PLAN §5).

Как запустить (когда согласятся): persist `banya-complex` → залить `fixtures/banya/inbox/*` → briefing (Phase B) → `Workflow` (commands/redloft.md Шаг 5) → записать artifacts/reviews (Шаг 6) → секрет-чек → показать `tz.md`+`prompt.md`.

**DoD §3 F2 / §6 success:** e2e даёт связный `tz.md`+`prompt.md`; RLS-чек в промте; R1/R2/R3 = PASS либо `escalated` с notes; артефакты по header-схеме; секрет-чек чист; `purge_project.sh` удаляет проект.

## Открытые (не блокеры) — PLAN §5
cost-gate · session-bound MCP vs unattended · concurrent multi-client · design-MCP reachability.

## Bootstrap новой сессии (Phase F2 — живой прогон)
```
cat ~/.claude/skills/redloft/commands/redloft.md           # caller-flow Шаги 1-7 (persist→brief→Workflow→artifacts)
cat ~/.claude/skills/redloft/workflow/landing-builder.js   # что запускается (фазы + reviewer + render-гарантии)
cat ~/.claude/skills/redloft/stages/briefing/prompt.md     # Phase B флоу (materials-dump из fixtures/banya/inbox)
ls ~/.claude/skills/redloft/tests/fixtures/banya/inbox     # вход для e2e
bash ~/.claude/skills/redloft/tests/smoke.sh               # A–F1 зелёные (168/168) — каркас рабочий
git -C ~/.claude/skills/redloft log --oneline              # история (планирование + A..F1)
```
F2 — **billed живой прогон**, только с явного согласия (cost-gate). Каркас A–F1 готов и протестирован hermetic — F2 это первый реальный «ПУСК», не стройка.

---
name: plan-panel
description: |
  Use when user wants a multi-role review of a proposed plan / RFC / implementation strategy.
  Spawns a "panel" of expert subagents (architect, qa, judge — always; security/frontend/backend/data/ops conditional based on detected scope), each with a strict checklist-driven protocol. Final judge synthesizes findings into priority-ranked action list with cross-examination of conflicts.

  TRIGGER on:
  • «проверь план», «верифицируй план», «собери панель», «посмотри план с разных сторон»
  • «что упустил в плане», «что важно учесть»
  • «прогони ревью», «нужна команда экспертов», «нужно мнение архитектора + qa + ...»
  • "review this plan", "verify this plan", "panel review", "expert review"
  • Explicit: «/plan-review», «/plan-panel», «/panel»
  • --from-task (Stage 1): «спланируй и проверь X», «сделай план под задачу X и прогони панель», "plan and verify X", "draft a plan for X and review it" — когда ПЛАНА ЕЩЁ НЕТ, есть только задача.

  Также активируется когда пользователь явно даёт большой план и просит «прежде чем начнём» / «прежде чем кодить» / «давай разберёмся» — это сигнал что нужна верификация.

  HEAVY MODE по умолчанию (5-8 ролей + Fable judge с cross-examination конфликтов между ролями). Lite — через флаг `--lite`. Cost ~$0.70-2.50 за full run.
allowed-tools:
  - Bash
  - Read
  - Write
  - Workflow
  - Agent
  - AskUserQuestion
---

# plan-panel — multi-role plan verification

## Flow (3 фазы)

```
User план → /plan-review
   ↓
Phase 1: SCOPE DETECTION (1 agent, Haiku)
   → читает план + project context (~/projects/<slug>.md если найден)
   → возвращает scope.json: { scope_tags, selected_roles, complexity, rationale }
   → пользователь видит выбранные роли, может override
   ↓
Phase 2: PARALLEL ROLE REVIEW (N agents, Sonnet)
   → выбранные роли работают параллельно с одинаковым input (план + scope.json)
   → каждая выдаёт structured JSON по схеме из _shared.md
   → агрегация в review.md (sole-author rule)
   ↓
Phase 3: JUDGE SYNTHESIS (1 agent, Fable, HEAVY mode)
   → читает все role outputs
   → ищет конфликты между ролями
   → если есть конфликт — ДЕЛАЕТ cross-examination round: задаёт уточняющий
     вопрос конкретной роли и переоценивает
   → выдаёт priority-ranked action list + ищет gaps (что НИ ОДНА роль не покрыла)
   → final verdict: PASS / FAIL / NEEDS-WORK
   ↓
Persistence:
   project/.plan-panel/<ts>-<slug>/  + копия в $CLAUDECORE_PATH/plan-panel/<project>/<ts>/
   plan.md, scope.json, review.md, judge.md, metadata.json
   ↓
Финал: показ judge.md пользователю + опциональный prompt на /panel-feedback
```

## Запуск

```bash
~/.claude/skills/plan-panel/workflow/panel.js
```

Это Workflow script. Вызывается через **Workflow tool** Claude Code когда срабатывает trigger. См. `workflow/panel.js` для детерминистской орк.

## Trigger phrases / activation

См. frontmatter `description`. Когда пользователь пишет «проверь план», «собери панель» и т.п. — этот skill активируется, дальше Claude должен:

1. Понять что план — это либо текущее сообщение пользователя, либо последний значимый план в session (если он сказал «проверь то что мы только что обсудили»)
2. Сохранить план в `<persistence_dir>/plan.md` (по схеме ниже)
3. Запустить `Workflow({scriptPath: "~/.claude/skills/plan-panel/workflow/panel.js", args: {plan_text, project_slug, mode}})`
   ⚠️ Workflow-песочница **без ФС-доступа** — передавай **содержимое плана инлайн** в `plan_text`, а не путь. Если план уже на диске (`plan.md`) — сначала `Read` его, затем подставь текст в `plan_text`. (panel.js читает `args.plan_text`, поля `plan_path` нет.)
4. После завершения — записать артефакты в `<project_dir>` (вкл. `learnings.entry.json`) и **авто-капчур в ledger** (push-петля самоулучшения):
   `[ -f <project_dir>/learnings.entry.json ] && bash lib/ledger.sh append ~/.claude/skills/plan-panel "$(cat <project_dir>/learnings.entry.json)" || true`
   — meta-критик уже отметил методологические пробелы ролей; ручной `/panel-feedback` больше НЕ обязателен (остаётся лишь для явных корректировок). Затем показать summary из judge.md.

## Запуск `--from-task` (Stage 1: задача без плана)

Когда пользователь даёт **задачу, а не план** (триггеры выше / явный `--from-task`):

1. Setup persistence с `run_type=from-task`:
   `bash lib/persist.sh "<cwd>" "<task-slug>" from-task` → `<project_dir>|<central_dir>|<ts>`
2. Запустить reviewer-loop workflow:
   `Workflow({scriptPath: "~/.claude/skills/plan-panel/workflow/reviewer-loop.js", args: {task_text, project_slug, cwd, project_dir, timestamp, mode, max_iters: 2}})`
   - Phase 0 Draft (Fable planner, читает код) → петля: panel.js (scope→roles→judge) → revise ×≤2.
   - scope-once: scoper считается на iter 1, переиспользуется (precomputed_scoper) далее.
3. После завершения — записать версии плана через `lib/persist-plan.sh <project_dir> <N>` (strip + canonical), плюс артефакты финальной панели (review.md/judge.md/learnings.entry.json) как в обычном flow, **и ledger-append**: `[ -f <project_dir>/learnings.entry.json ] && bash lib/ledger.sh append ~/.claude/skills/plan-panel "$(cat <project_dir>/learnings.entry.json)" || true`.
4. Показать пользователю: финальный verdict, сколько кругов, converged?/`ceiling`?, top-5 действий, путь к `plan.md`. Если `next_action:'finalize'` — закрыть петлю фразой «архитектура подтверждена, остаток — DoD кодинга → дальше `/finalize` по diff», без предложения ещё круга.

**Edge-cases** (обрабатывает reviewer-loop):
- задача расплывчата → `clarification:true` + `open_questions[]` → показать пользователю, НЕ гонять петлю;
- `code_was_read=false` → warning (план не заземлён на код);
- не сошлось за MAX_ITERS → `converged:false` + reason; oscillation (critical вырос) → ранний break;
- `ceiling:true` + `next_action:'finalize'` → confidence вышла на плато при NEEDS-WORK, остаток — implementation-DoD. **Не предлагать новый круг — направить на `/finalize`** (см. ниже). Срабатывает **только на NEEDS-WORK** (FAIL/UNCERTAIN петля доводит до MAX_ITERS как раньше) и требует **≥2 итераций** (на iter 1 `prevConfidence=null` → guard fail-open).

Флаги: `--lite`/`--ultra` управляют глубиной review-фаз (как обычно); cost-gate для `--from-task --ultra`.

## Persistence dirs (hybrid)

**Project-local**: `<cwd>/.plan-panel/<YYYY-MM-DD_HH-MM>-<plan-slug>/`
**Central mirror**: `$CLAUDECORE_PATH/plan-panel/<project-slug>/<YYYY-MM-DD_HH-MM>-<plan-slug>/`

`<project-slug>` определяется через `project-map` skill (`$CLAUDECORE_PATH/projects/<slug>.md` if cwd matches a known project) или fallback на basename cwd.

Создаются обе папки + symlink: central → project (чтобы редактирование одного отражалось в обоих).

## Modes

- **standard** (default heavy): scoper + architect + qa + judge + relevant conditional roles. Judge с cross-examination. Fable для judge, Sonnet для остальных. ~$0.70-2.50 *if API*, $0 *if Max*.
- **--lite**: scoper + architect + qa + judge. Без conditional ролей, без cross-exam. Sonnet роли, Fable judge. ~$0.20 *if API*, $0 *if Max*.
- **--ultra**: standard + Phase 4 «CrossModel». Финальный план + Claude judge.md прогоняется через **GPT-5 + Gemini 2.5 Pro параллельно** как outside opinion. Meta-judge синтезирует 3 точки зрения. Cross-model часть **всегда платная** (API через 1Password items `OpenAI` + `Gemini`): ~+$0.10-0.20 на real план. Для критических планов где важно «третье мнение».

## Output to user

После завершения workflow возвращает:
- Path к `judge.md`
- Summary action list (top-5 priority)
- Conflict count (если были)
- Gap count (что ни одна роль не покрыла)
- Кнопка: «дай feedback по ролям» → `/panel-feedback`

**Ceiling-handoff** (verdict=NEEDS-WORK): если `final_verdict_reasoning` судьи говорит, что остаток critical — implementation-уровня (архитектурных не осталось), это **потолок панели** (PASS запрещает любой critical, а детальный план всегда вскрывает implementation-critical из текста — см. `roles/judge.md` §Ceiling). Не предлагать ещё круг plan-review — сказать пользователю: «замысел подтверждён, priority_actions = DoD-чеклист для кодинга; верификация реализации → `/finalize` (code-review по diff)».

## Не забывать

- **Не запускать на тривиальных планах** (1-2 шага, без сложности). Scoper должен возвращать `complexity: 'low'` → можно skip с предложением "план тривиальный, нужен ли panel?".
- **Не двойной запуск**: если в этой же сессии уже был /plan-review на тот же план — спросить пользователя re-run или показать предыдущий результат. Если прошлый прогон вернул NEEDS-WORK с implementation-уровня остатком (ceiling) — **по умолчанию НЕ перезапускать**, а направить на `/finalize`: новый круг не сойдётся к PASS, только сожжёт токены (2-3 раунда достаточно — потолок ~0.85).
- **Версионирование plan.md**: если план эволюционировал — каждый run создаёт новую папку timestamp'a, старые не перезаписываются.

## Acceptance criteria (Done-when) для каждой фазы

| Фаза | Done when |
|---|---|
| **1. Persistence setup** (caller, до workflow) | `persist.sh` экзитит 0, возвращает 3-part pipe-delimited string `<project_dir>|<central_dir>|<ts>`. Оба dir'а существуют, project_dir записываемый. `plan.md` сохранён в project_dir. |
| **2. Scope (scoper agent)** | JSON по `SCOPE_SCHEMA`. `confidence >= 0.3`. `selected_roles.length >= 3`. Иначе — fail-fast (см. `_shared.md` §9), верни UNCERTAIN с user_action_required. |
| **3. Review (parallel roles)** | Каждая роль — JSON по `FINDINGS_SCHEMA`. Минимум 1 actionable suggestion per finding. `confidence >= 0.5` ИЛИ verdict=UNCERTAIN явно. Если timeout/null — judge видит это в execution_report. |
| **4. Synthesize (judge)** | JSON по `JUDGE_SCHEMA`. Если `skipped_not_implemented` непустой — gaps ДОЛЖЕН их упомянуть. `final_verdict_reasoning` объясняет verdict явно (не "see findings"). |
| **5. CrossModel** (только ultra) | `cross-model.sh` exit 0 ИЛИ partial result с явным `errors[]` array. GPT и Gemini оба JSON-parseable. Meta-judge синтезирует с `agreement_summary` (all_three / 2_of_3 / unique_to_*). |
| **6. Artifacts** (caller, после workflow) | Все 9 файлов в project_dir: `plan.md, scope.json, reviews.json, review.md, judge.json, judge.md, metadata.json` + (ultra) `meta-judge.json, meta-judge.md`. Central dir mirror через `cp` (best-effort — non-fatal если cloud-sync лажает). |
| **7. User summary** | В чате: verdict + confidence + top-5 priority actions + conflicts/gaps count + skipped_not_implemented mention + path к artifacts. Не вываливать весь review.md. |

## Edge cases

| Edge case | Handling |
|---|---|
| Scoper вернул `confidence < 0.3` | Fail-fast в orchestrator. Возврат `{ error: 'low-confidence-scope', user_action_required: '...' }`. НЕ запускать roles + judge. |
| Scoper вернул `selected_roles.length < 3` | То же — fail-fast |
| 2+ роли вернули null/timeout | Workflow продолжает с тем что есть. Judge видит `execution_report.failed_or_null_roles` и упоминает в summary "N ролей отвалилось". |
| Scoper выбрал роль не из Phase A (frontend/backend/data/ops) | Workflow её ПРОПУСКАЕТ + передаёт judge как `skipped_not_implemented`. Judge ОБЯЗАН отметить как gap. |
| Cross-model partial failure (GPT работает, Gemini падает) | `cross-model.sh` пишет error в `errors[]`, остальной JSON содержит то что есть. Meta-judge синтезирует из 2 источников вместо 3, отмечает degraded в summary. |
| Concurrent /plan-review | Каждый run создаёт unique `<ts>-<slug>` dir. Коллизия в 1 секунду крайне маловероятна. **Lock-файл для serialization** — Phase B (когда добавится /panel-feedback который правит artifacts). |
| Yandex.Disk symlink сломался | persist.sh пытается ln, но `\|\| true` — non-fatal. Local PROJECT_DIR остаётся canonical. Central mirror можно перегенерировать через `cp -r project_dir/* central_dir/`. |
| Plan слишком большой (>20k chars) | Token budget per role exceeded. Roles вернут UNCERTAIN. Judge поднимет gap. **Решение**: разбить план на несколько /plan-review запусков по logical sections. |

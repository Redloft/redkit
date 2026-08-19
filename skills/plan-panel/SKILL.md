---
name: plan-panel
description: |
  Use when user wants a multi-role review of a proposed plan / RFC / implementation strategy —
  OR of a non-code business artifact (КП/смета, презентация, концепция, аналитическая записка).
  Both go through this one skill; it auto-classifies the input (см. §0 ниже) and dispatches to
  the matching internal workflow — engineering roles (architect/qa/security/frontend/backend/
  data/ops/judge) for code plans, business roles (product-critic/client-advocate/business-analyst/
  unit-economics/budget-critic/legal-ru/ux-researcher/editor-ru/judge-artifact) for non-code
  artifacts. The user doesn't need to know which — say "прогони панель" either way.

  TRIGGER on:
  • «проверь план», «верифицируй план», «собери панель», «прогони панель», «посмотри план с разных сторон»
  • «что упустил в плане», «что важно учесть»
  • «прогони ревью», «нужна команда экспертов», «нужно мнение архитектора + qa + ...»
  • «проверь это КП/деку/концепцию/записку», «глазами заказчика посмотри», «сходится ли экономика»
  • "review this plan", "verify this plan", "panel review", "expert review"
  • Explicit: «/plan-review», «/plan-panel», «/panel», «/review-artifact»
  • --from-task (Stage 1): «спланируй и проверь X», «сделай план под задачу X и прогони панель», "plan and verify X", "draft a plan for X and review it" — когда ПЛАНА ЕЩЁ НЕТ, есть только задача.

  Также активируется когда пользователь явно даёт большой план и просит «прежде чем начнём» / «прежде чем кодить» / «давай разберёмся» — это сигнал что нужна верификация.

  HEAVY MODE по умолчанию (5-8 ролей + Opus 5 judge с cross-examination конфликтов между ролями; на --ultra судит Fable). Lite — через флаг `--lite`. Cost ~$0.70-2.50 за full run.
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
Phase 3: JUDGE SYNTHESIS (1 agent, Opus 5; на --ultra — Fable)
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

## Как добавить роль (Ф5)

Раньше требовалось шесть правок в разных местах, и роль без ключа в хардкод-словаре
**молча не запускалась**. Теперь:

1. Положить `roles/<name>.md` (структура — как у существующих: Checklist → Output → Anti-patterns → Self-check).
2. Добавить запись в `roles/registry.json`: `name`, `file`, `model`, `phase`, `focus`, `tags`.
3. Упомянуть роль в условиях активации `roles/scoper.md`, если она не `always: true`.

Всё. `ALLOWED`, промпт роли, модель и списки в `solidify.sh`/`feedback.sh` берутся из реестра.

**Проверка:** `node lib/registry-test.js` — файлы ролей на месте, `focus` в реестре совпадает
с хардкод-фолбэком, молчаливого скипа нет. Роль, выбранная scoper'ом и прошедшая `ALLOWED`,
но без промпта, **роняет прогон с явной ошибкой** — не выпадает тихо.

⚠️ `focus` в реестре и строка в хардкод-фолбэке `panel.js` должны совпадать, пока фолбэк жив:
иначе прогон через обновлённого caller'а и через необновлённого дадут разные промпты. Тест
паритета это ловит.

## Trigger phrases / activation

См. frontmatter `description`. Когда пользователь пишет «проверь план», «собери панель», «прогони панель» и т.п. — этот skill активируется, дальше Claude должен:

0. **Классифицировать вход, ДО выбора воркфлоу** (пользователь не обязан знать про два входа —
   это решает Claude по содержимому, не спрашивая, кроме явно неоднозначного случая):
   - **Код-план** (признаки: план работ по репозиторию/коду — файлы, функции, API, схема БД,
     деплой, тесты, фича/баг конкретного проекта-кода) → дальше по этому файлу,
     `workflow/panel.js` + `roles/registry.json` (шаг 1 и далее, без изменений).
   - **Не-код артефакт** (признаки: КП/смета, презентация/дека, концепция, аналитическая
     записка, документ для внешнего адресата — заказчика/инвестора/партнёра; про деньги,
     процесс, юнит-экономику, ценностное предложение — без изменений в коде) → это
     `/review-artifact`: следуй `commands/review-artifact.md` целиком (свой `artifact-panel.js`
     + `roles/registry-artifact.json` + свой словарь вердиктов READY/TIGHTEN/RETHINK/UNCERTAIN).
     **Не подмешивать** инженерные роли сюда и бизнес-роли в код-план — история с conf 0.80
     и 2 ролями из 8 (см. `roles/registry-artifact.json:6-10`) — результат именно смешения.
   - Неоднозначно (план одновременно и процесс, и код, либо непонятно что именно проверять) →
     один короткий уточняющий вопрос пользователю, не молчаливый guess: ошибка маршрута жжёт
     целый платный прогон ($0.70-2.50).

1. Понять что план — это либо текущее сообщение пользователя, либо последний значимый план в session (если он сказал «проверь то что мы только что обсудили»)
2. Сохранить план в `<persistence_dir>/plan.md` (по схеме ниже)
2b. **Архивариус (RedBrain-заземление, рекомендуется):** `bash ~/.claude/skills/redbrain/lib/archivist.sh <persistence_dir>/plan.md` → stdout захватить как `memory_brief`. Зовётся ЗДЕСЬ, оркестратором, ДО Workflow (recall.py нужен диск/SQLite, а песочница panel.js без ФС; subprocess, НЕ import — сохранить signal-инвариант). scope work fail-closed, fail-open (пусто → не передавать). Пропустить при `--no-memory`.
2c. **Fact-grounder (свежие веб-факты, рекомендуется, non-blocking):** `printf '%s' "<plan_text>" | python3 ~/.claude/skills/_shared/fact-grounder/ground.py` → stdout захватить как `research_brief` (пусто = ок, tier=none). Оркестратор зовёт ДО Workflow (движки — shell, песочница panel.js без FS). Дёшево (tier none→0 вызовов; light/critical→до 5 Tavily ~$0.04, scrub+бюджет-гард внутри адаптера). Стоимость мала → НЕ спрашивать пользователя (кроме явного critical+сомнение). Пропустить при `--no-research`. → роли+judge ловят freshness-conflict (устаревшая версия/EOL/CVE).
3. **Сгенерировать телеметрию (ОБЯЗАТЕЛЬНО, до Workflow)** — песочница Workflow запрещает
   `Date.now()`, поэтому `timestamp` физически не может родиться внутри `panel.js`; без этих
   двух args он садится на дефолты `'now'` / `'unknown-run-id'` (`panel.js:126,137`) и прогон
   выпадает из аналитики. До 2026-07-27 их не было в контракте — 45 из 70 записей ledger'а без
   даты, 48 без run_id.
   ```bash
   TS=$(date +%Y-%m-%d_%H-%M)
   RUN_ID=$(uuidgen | tr 'A-Z' 'a-z')   # uuid, НЕ "<ts>-<slug>": формат свободен, но короткие
                                        # осмысленные строки коллидируют в пределах минуты
   # Канон линз (Ф1): песочница Workflow без ФС — файл читает CALLER и передаёт инлайн.
   # Компактно (key/role/title), без aliases: критику нужен выбор, а не таблица синонимов.
   CANON=$(jq -c '[.lenses[] | {key, role, title}]' ~/.claude/skills/plan-panel/lenses/canon.json 2>/dev/null || echo '')
   # Реестр ролей (Ф5) — тоже читает caller, песочница без ФС. Пусто → panel.js работает
   # на прежнем хардкод-списке (fail-open, постадийная раскатка).
   REGISTRY=$(cat ~/.claude/skills/plan-panel/roles/registry.json 2>/dev/null || echo '')
   ```
   Запустить `Workflow({scriptPath: "~/.claude/skills/plan-panel/workflow/panel.js", args: {plan_text, project_slug, mode, timestamp: TS, run_id: RUN_ID, canon_lexicon: CANON, roles_registry: REGISTRY, memory_brief, research_brief}})`
   ⚠️ Без `canon_lexicon` критик выдаёт свободный `lens_key`, тот не резолвится в канон и
   находка уходит в карантин вместо горячей темы — то есть прогон выпадает из петли.
   Пусто (нет файла/битый) → fail-open, поведение как до Ф1.
   ⚠️ Workflow-песочница **без ФС-доступа** — передавай **содержимое плана инлайн** в `plan_text`, а не путь. Если план уже на диске (`plan.md`) — сначала `Read` его, затем подставь текст в `plan_text`. (panel.js читает `args.plan_text`, поля `plan_path` нет.) `memory_brief` из 2b — тоже инлайн-строкой (panel.js инъектит его в роли+judge; пусто → панель как раньше).
4. После завершения — записать артефакты в `<project_dir>` (вкл. `learnings.entry.json`) и **авто-капчур в ledger** (push-петля самоулучшения):
   `[ -f <project_dir>/learnings.entry.json ] && bash lib/ledger.sh append ~/.claude/skills/plan-panel "$(cat <project_dir>/learnings.entry.json)" --entry-point skill-freeform || true`
   — `entry_point` обязателен: `ledger.sh stat` даёт разбивку сломанной телеметрии по нему,
   иначе непонятно, какой из трёх входов (skill-freeform / slash-command / from-task) течёт.
   — meta-критик уже отметил методологические пробелы ролей; ручной `/panel-feedback` больше НЕ обязателен (остаётся лишь для явных корректировок).
5. **Внешние судьи (ВЫЗЫВАТЬ ВСЕГДА, кроме `--lite`; non-blocking)** — независимый голос вне Claude (OpenAI/GLM/Kimi) на том же плане.
   ⚠️ **Решают тумблеры, не ты.** `panel.sh` сам смотрит `ej_enabled_providers()` и при выключенных печатает одну строку «выключены» с exit 0 — то есть безусловный вызов ничего не стоит. Пока шаг числился «опциональным», он выпадал: тумблеры включены (`openai,glm,kimi`) с 2026-07-20, а последняя запись в `ledger.jsonl` внешних судей — 2026-07-22 при 85 прогонах панели после неё.
   `bash ~/.claude/skills/_shared/external-judge/panel.sh <project_dir>/plan.md "<VERDICT из judge.json: PASS→SHIP, NEEDS-WORK, FAIL→FIX-FIRST>" --out <project_dir>`
   — скраб/денилист/инфра-редакция внутри адаптера (fail-closed); сбой судьи НЕ ломает панель. Вывод (`cross-model.md`) вставить в summary. Расхождение с Claude-панелью = сигнал слепой зоны.
   Включение: `EJ_ENABLE="openai,glm"` в env или `_shared/external-judge/toggles.env`. Это отдельно от `--ultra` cross-model (GPT+Gemini): ultra = разовое «третье мнение» meta-judge, а тумблеры-судьи = систематический независимый вход на каждый heavy-прогон.
6. Показать summary из judge.md (+ блок внешних судей из шага 5, если был).
7. **Ф1-оценка redcost (опционально, если план для БИЛЛИНГ-задачи проекта):** когда план/спека
   относится к задаче Трекера с известным проектом/договором (действующий клиент или новый) —
   прогнать оценщик трудозатрат redcost:
   `estimate.context(summary, project|tag)` (резолв договора; `AmbiguousContract` → спросить тег) →
   оценить часы по ролям «как реальный спец» + обоснование (свериться с `context.similar` прецедентами)
   → `estimate.build_estimate(...)` → показать Игорю прогноз+обоснование → OK-гейт → записать
   `originalEstimation` (round-trip) + кандидат-прецедент. Детали — skill `redcost` §Ф1.
   Пропустить, если план не про оплачиваемую задачу проекта (внутренний скилл/инфра/ресёрч).

## Запуск `--from-task` (Stage 1: задача без плана)

Когда пользователь даёт **задачу, а не план** (триггеры выше / явный `--from-task`):

1. Setup persistence с `run_type=from-task`:
   `bash lib/persist.sh "<cwd>" "<task-slug>" from-task` → `<project_dir>|<central_dir>|<ts>`
2. Запустить reviewer-loop workflow:
   `Workflow({scriptPath: "~/.claude/skills/plan-panel/workflow/reviewer-loop.js", args: {task_text, project_slug, cwd, project_dir, timestamp, run_id, mode, max_iters: 2}})`
   ⚠️ `run_id` обязателен (`RUN_ID=$(uuidgen | tr 'A-Z' 'a-z')`). Без него `reviewer-loop.js:32`
   дефолтит и штампует вниз `unknown-run-id-i1`, `unknown-run-id-i2` — формально непустая строка,
   поэтому детектор по значению её пропустит, а прогон навсегда отчитается `telemetry_ok: true`.
   При ledger-append на шаге 3 добавить `entry_point: "from-task"`.
   - Phase 0 Draft (Fable planner, читает код) → петля: panel.js (scope→roles→judge) → revise ×≤2.
   - scope-once: scoper считается на iter 1, переиспользуется (precomputed_scoper) далее.
3. После завершения — записать версии плана через `lib/persist-plan.sh <project_dir> <N>` (strip + canonical), плюс артефакты финальной панели (review.md/judge.md/learnings.entry.json) как в обычном flow, **и ledger-append**: `[ -f <project_dir>/learnings.entry.json ] && bash lib/ledger.sh append ~/.claude/skills/plan-panel "$(cat <project_dir>/learnings.entry.json)" --entry-point from-task || true`.
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

- **standard** (default heavy): scoper + architect + qa + judge + relevant conditional roles. Judge с cross-examination. Opus 5 для judge, Sonnet для остальных. ~$0.70-2.50 *if API*, $0 *if Max*.
- **--lite**: scoper + architect + qa + judge. Без conditional ролей, без cross-exam. Sonnet роли, Opus 5 judge. ~$0.20 *if API*, $0 *if Max*.
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

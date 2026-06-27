# DESIGN — Stage 1 / Часть A: `--from-task` + reviewer-loop (Phase 0: Draft)

> Status: **SPEC, не реализовано.** Ревизия после panel-review (run `2026-06-02_00-54-06`, NEEDS-WORK).
> **Зависит от `DESIGN-foundation.md` (Stage 0)** — контракты `DRAFT_SCHEMA`/`REVISE`, checkpoint, scope-cache,
> reviewer-loop-модуль и validators берутся оттуда, здесь НЕ дублируются.
> Расширяет `SKILL.md`. Не меняет существующий путь «готовый план → review».

## Проблема

Вход скилла сейчас — готовый план. Частый кейс: есть только **задача** («сделай X»), плана нет.
Хочется отдать задачу одной строкой и получить на выходе **уже отстоявшийся** план, прошедший панель.

## Решение

Phase 0 — Draft перед pipeline + reviewer-loop вокруг Phase 1-3:
draft → review → (NEEDS-WORK? revise → re-review) ×≤2 → final.
**За флагом `--experimental`** до прохождения pilot-gate (action #10, см. ниже).

## Активация

```
/plan-review --from-task "<задача>" [--experimental]
```
- На время пилота `--from-task` требует `--experimental` (или сам спрашивает подтверждение). После pilot-gate — флаг убирается.
- Дал и задачу, и план → `--from-task` игнорируется (готовый план приоритетнее).
- `--from-task --ultra` → **pre-run cost/confirmation gate** (gap «cost-confirmation»): показать ожидаемую стоимость (Draft Fable + до 2×(scope+roles+judge) + CrossModel) и спросить подтверждение до запуска.

## Flow (loop живёт в `workflow/reviewer-loop.js`, не в panel.js — Stage 0 §3)

```
Задача (args.task_text)
   ↓
Phase 0: DRAFT (1 agent, Fable, roles/planner.md)
   вход: task_text + project context (project-map) + code context (codegraph/Read)
   выход: DRAFT_SCHEMA (Stage 0 §1.1) → plan.v1.md
   ↓ checkpoint{run_type:'from-task', phase:'draft'}
   reviewer-loop iter=1..MAX(2):
     Phase 1 SCOPE  — iter==1 считает scoper; iter>1 берёт scope_cache (Stage 0 §2.3)
     Phase 2 ROLES  — как сейчас
     Phase 3 JUDGE  — как сейчас → verdict
     PASS → выход (финал)
     NEEDS-WORK/FAIL → Phase 0b REVISE → plan.v(N+1).md → следующий iter
     iter==MAX и не PASS → выход, converged:false + причина (последний judge as-is)
   ↓
Persistence (plan.v1..vN + canonical plan.md) + user summary
```

### Phase 0 — DRAFT (`roles/planner.md`, Fable)
- **Обязан читать реальный код** (Read, codegraph_*, Bash ro, WebSearch); ставит `code_was_read=true`.
  `false` ⇒ warning в metadata (Stage 0 §4, executable AC).
- Выход — `DRAFT_SCHEMA`. `plan_markdown` — структура как у ручного плана (шаги что/зачем/риски), без кода.

### Phase 0b — REVISE (тот же `planner.md`, режим revise)
- Вход/выход — `REVISE` envelope из Stage 0 §1.2. Применяет actionable suggestions, не переписывая с нуля.
- Обязан вернуть `revise_notes` с записью на **каждый** critical/warning judge (applied/rejected+rationale).
  Покрытие проверяется runtime-валидатором (Stage 0 §4) — иначе revise считается невалидным.
- **Отказ ревайзера** (timeout/parse-fail/schema-violation) → `REVISE_ERROR_SCHEMA` (Stage 0 §1.2a): persist `plan.vN` со `status=revise_failed`, `converged:false`, следующая итерация НЕ стартует. Per-phase timeout, retry=0.

> **Secrets**: вывод планнера (`plan.vN`) проходит через глобальный strip (Stage 0 §7.1) **до** записи на диск и до попадания в judge-envelope — наравне с diff в Части B. plan «в вакууме»/секреты из прочитанного кода не утекают в артефакт.

## Где меняется код (Часть A, поверх Stage 0)

| Файл | Изменение |
|---|---|
| `workflow/reviewer-loop.js` | **Новый** модуль: Phase 0/0b + петля; вызывает фазы panel.js как функции. |
| `workflow/panel.js` | Вынести scope/roles/judge в экспортируемые функции (рефактор без смены happy-path). |
| `roles/planner.md` | **Новый** role-spec: draft + revise режимы, чек-лист, anti-patterns, обязательное чтение кода. |
| `SKILL.md` | Phase 0, флаг `--from-task --experimental`, триггеры, обновить Flow, cost-gate для --ultra. |
| `lib/persist.sh` | Версионирование `plan.v1.md … plan.vN.md`, canonical `plan.md` = последняя (checkpoint из Stage 0). |
| `(команда)` `/plan-draft` | алиас над `--from-task` (опц). |

## Pilot-gate (action #10) — до полной инвестиции

reviewer-loop выкатывается `--experimental`. Pilot: **10 реальных runs**, append-only лог `analytics.jsonl`
(verdict на iter=1, сошлось ли, кол-во кругов). Конкретный порог промоции: **≥6/10 runs, где revise поднял verdict iter1→iter2 (NEEDS-WORK→PASS)** → промотировать из experimental; иначе оставить draft без авто-revise. Решение по данным, не на глаз:
- если iter=1 PASS в большинстве → петля редко нужна, оставить draft без авто-revise;
- если revise реально вытягивает планы из NEEDS-WORK в PASS → промотировать.

## Acceptance criteria (executable, см. Stage 0 §4)

| Фаза | Done when |
|---|---|
| **0. Draft** | `DRAFT_SCHEMA`-валиден; `plan_markdown` ≥3 шага; `code_was_read=true` (иначе warning). |
| **0b. Revise** | `REVISE`-валиден; `revise_notes` покрывает все critical/warning judge (runtime-check); новый plan.md ≠ предыдущего. |
| **Loop** | MAX_ITERS=2; не сошлось → `converged:false` + причина; scope из cache на iter>1 (не пересчитан). |
| **Persist** | `plan.v1..vN` + canonical; `metadata.iterations[]` с verdict каждого круга; checkpoint status=complete. |
| **Cost-gate** | `--from-task --ultra` не стартует без подтверждения пользователя. |
| **User summary** | финальный verdict, кол-во кругов, converged?, top-5, путь. |

## Edge cases (+ из panel-review)

| Edge case | Handling |
|---|---|
| Задача расплывчата | планнер: `open_questions` непустой + `self_check_passed:false` → НЕ гонять петлю, вернуть clarification (аналог scoper fail-fast §9). |
| **Planner timeout / crash** (action #5) | расширить `_shared.md §9` fail-fast: planner null/timeout → abort с явным сообщением, без запуска roles. |
| Draft тривиален (1-2 шага) | guard «нужен ли panel?». |
| Петля осциллирует | MAX_ITERS=2; `regressed`-флаг если critical_count вырос (Stage 0 §4). |
| `--ultra` + `--from-task` | CrossModel только на **финальной** итерации + cost-gate. |
| Стоимость | Draft(Fable) + N×(scope+roles+judge); до ~2× обычного. execution_trace даёт фактическую цифру. |

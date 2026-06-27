# DESIGN — Stage 0: Foundation (общие контракты + checkpoint + persist)

> Status: **SPEC, не реализовано.** Создан по итогам panel-review (run `2026-06-02_00-54-06`, verdict NEEDS-WORK).
> Закрывает critical #1 (заморозить контракты) и critical #2 (единый checkpoint) — оба **общие** для
> `--from-task` (Часть A) и `/finalize` (Часть B). Реализуется **первым**, до обеих частей (action #6).

## Зачем отдельный stage

Панель показала: 4 critical от разных ролей (architect/backend/qa/ops) сходятся в **один** механизм —
per-iteration checkpoint. А контракты схем (DRAFT/REVISE/finalize-envelope/review_mode) если не заморозить
заранее — части A и B поедут на несовместимых форматах. Поэтому: один фундамент → потом две части,
каждая независимо shippable.

```
Stage 0 (этот doc): контракты + checkpoint + persist + AC-валидаторы   ← реализовать первым
   ↓
Stage 1: Часть A (--from-task + reviewer-loop)   — зависит от Stage 0
   ↓
Stage 2: Часть B (/finalize)                     — зависит от Stage 0
```
Каждый stage — отдельный DoD, отдельно мерджится. Stage 1 и 2 независимы между собой.

---

## 1. Замороженные контракты (правка `_shared.md`, atomic)

Всё ниже добавляется в `_shared.md` **одним коммитом** до написания любого orchestrator-кода.

### 1.1 `DRAFT_SCHEMA` (Часть A, Phase 0)
```json
{
  "type": "object",
  "required": ["plan_markdown", "assumptions", "open_questions", "self_check_passed", "code_was_read"],
  "properties": {
    "plan_markdown":     { "type": "string", "minLength": 50 },
    "assumptions":       { "type": "array",  "items": { "type": "string" } },
    "open_questions":    { "type": "array",  "items": { "type": "string" } },
    "self_check_passed": { "type": "boolean" },
    "code_was_read":     { "type": "boolean" }
  }
}
```
`code_was_read` — явный флаг: планнер сделал ≥1 codegraph/Read вызов. `false` ⇒ план «в вакууме» ⇒ warning в metadata (executable AC, см. §4).

### 1.2 `REVISE` — input envelope + `revise_notes` (Часть A, Phase 0b)
Вход планнеру в режиме revise:
```
{ prev_plan_markdown, judge_md, role_reviews[], iteration }
```
Выход — тот же `DRAFT_SCHEMA` + обязательное поле `revise_notes`:
```json
{
  "revise_notes": {
    "type": "array",
    "items": {
      "type": "object",
      "required": ["judge_action_rank", "disposition", "rationale"],
      "properties": {
        "judge_action_rank": { "type": "number" },
        "disposition":       { "enum": ["applied", "rejected", "deferred"] },
        "rationale":         { "type": "string" }
      }
    }
  }
}
```
**Правило**: каждый critical/warning из judge ОБЯЗАН иметь запись в `revise_notes` (applied или rejected+rationale). suggestion — опционально. Runtime-проверка покрытия — в §4.

### 1.2a `REVISE_ERROR_SCHEMA` (v2-critical#4) — отказ ревайзера
Reviser timeout / parse-fail / schema-violation НЕ роняет run молча:
```json
{
  "type": "object",
  "required": ["error", "phase", "iteration", "partial_plan_persisted"],
  "properties": {
    "error":  { "enum": ["timeout", "parse_fail", "schema_violation"] },
    "phase":  { "const": "revise" },
    "iteration": { "type": "number" },
    "partial_plan_persisted": { "type": "boolean" }
  }
}
```
Поведение: persist `plan.vN` с `checkpoint.status = revise_failed`, вернуть `converged:false` + reason, **не стартовать** следующую итерацию. Per-phase timeout, retry=0 (не повторяем дорогой Fable-вызов вслепую).

### 1.2b `DRAFT_ERROR_SCHEMA` (v3-warning) — симметрия с REVISE
Тот же контракт для отказа на Phase 0 draft (timeout/parse-fail/schema-violation) → abort без запуска roles (fail-fast §9). Семейство `*_ERROR_SCHEMA` унифицировано: `{error, phase, iteration?, partial_persisted}`.
**revise_notes coverage violation → abort, НЕ silent-pass**: если ревайзер не покрыл какой-то critical/warning judge — это `schema_violation` (REVISE_ERROR), а не молчаливый пропуск.

### 1.3 finalize envelope (Часть B)
Заменяет `plan_text` для review-ролей в режиме кода:
```json
{
  "type": "object",
  "required": ["diff_text", "changed_files", "review_mode"],
  "properties": {
    "diff_text":     { "type": "string" },
    "changed_files": { "type": "array", "items": { "type": "string" } },
    "full_files":    { "type": "object", "description": "path -> content, опционально, для файлов где нужен контекст вне diff" },
    "review_mode":   { "const": "code" }
  }
}
```

### 1.4 `review_mode=code` overlay — канонический блок для каждого `roles/*.md`
Добавляется **дословно** в конец каждого review-role файла (architect/qa/security/frontend/backend/data/ops).
НЕ дублируем роли — один блок-переключатель (решение по конфликту architect↔backend, action #1):
```markdown
## Если review_mode == "code"
Ты оцениваешь **реализованные изменения (git diff), а не план**.
- Источник истины — `diff_text` + (при нехватке контекста) `full_files` / Read / codegraph.
- Ищи: баги, регрессии, нарушенные инварианты, технический долг, незакрытые edge-cases В КОДЕ.
- Каждый finding.ref ОБЯЗАН указывать `путь:строка` из diff (не из плана).
- Severity rubric, FINDINGS_SCHEMA, sole-author rule — те же.
- Заполни `checked_files[]` (см. FINDINGS_SCHEMA) — какие файлы ты реально просмотрел.
```

### 1.5 `FINDINGS_SCHEMA` += `checked_files` (action #9)
В `FINDINGS_SCHEMA` (panel.js) добавить optional top-level:
```js
checked_files: { type: 'array', items: { type: 'string' } },  // какие файлы роль реально открыла (для review_mode=code)
```
Не required (чтобы не ломать существующий plan-review путь).

### 1.6 `_shared.md` §4 token budget += planner
| Роль | Input max | Output max | Model |
|---|---:|---:|---|
| planner (draft/revise) | 6k | 4k | Fable |
| fixer (finalize stabilize) | 8k | 3k | Sonnet |

---

## 2. Единый checkpoint-контракт (правка `lib/persist.sh` + новый `lib/checkpoint.sh`)

Закрывает critical #2 + конфликты architect↔backend (один state) и data↔ops (retention+crash).
**Один механизм**, переиспользуется обеими частями (`run_type` различает).

### 2.0 Единая state-machine (v3-critical#1) — checkpoint.json = single source of truth
**Lock — НЕ отдельные файлы** (`.lock`/`.redplan.lock`), а **производные поля внутри `checkpoint.json`**.
Один файл, одна атомарная запись, нет dual-source-of-truth / partial-lock-JSON / lock-schema-drift.
Это схлопывает 4 v2/v3-critical (dual-source, partial-JSON, mv-after-strip, lock-drift) в одно изменение.

`slug = sha1(normalize(task_text|diff))[:12]`, `normalize = trim + collapse-whitespace + lowercase`.
Self-test стабильности slug — фундамент concurrency-lock и resume-идемпотентности.

### 2.1 `checkpoint.json` (пишется в `<project_dir>/checkpoint.json`)
```json
{
  "schema_version": 1,
  "run_type": "plan-review | from-task | finalize",
  "status": "in-progress | complete | crashed | revise_failed",
  "phase": "draft|scope|review|judge|revise|stabilize|snapshot",
  "iteration": 1,
  "slug": "sha1[:12]",
  "lock_pid": 12345,
  "lock_at": "ISO8601",
  "lock_ttl_sec": 1800,
  "scope_cache": { "output": "scoper output (scope-once)", "files_hash": "...", "head_sha": "..." },
  "created_at": "ISO8601",
  "updated_at": "ISO8601",
  "expires_at": "ISO8601 (created_at + 90d)"
}
```

### 2.2 Атомарная запись + lock-acquire (v2-critical#3)
Любая запись checkpoint/artifact — через `tmp + rename` в пределах одной FS:
```
write → <file>.tmp → fsync → mv -f <file>.tmp <file>
```
На cloud-synced FS (Yandex.Disk) rename атомарен локально; sync — eventual, это ок (canonical = local, см. _shared.md §8).

**`checkpoint_acquire()`** — атомарный примитив через `mkdir <slug>.d` (директория-страж; mkdir атомарен на POSIX, без race чтения-проверки-записи). Успех mkdir ⇒ внутри пишем `checkpoint.json` с `lock_pid/lock_at/lock_ttl_sec` (lock-состояние живёт В checkpoint, §2.0). Закрывает concurrent-run race единым механизмом.

### 2.2b schema_version read-side policy (v2-critical#3, v3-critical#5)
При чтении checkpoint:
- `version > KNOWN_MAX` → **abort** (написан более новой версией скилла, не угадываем формат).
- `version < current` → **в Stage 0: всегда reject** + `backfill-scan` скрипт для существующих checkpoint (решение qa по conflict: миграционный фреймворк — overkill для v1; вводим, только когда появится v2 формата). Полноценный migration-contract (таблица `version→fn[]`, идемпотентность, backup-перед-migrate, restore-при-сбое) — отложен до первой реальной смены схемы.
- unknown поля при равной версии → **lenient** (игнор, forward-compat).

### 2.3 Resume-after-crash + freshness (v2-critical#3, warning #7)
- При старте run: `checkpoint.json.status == "in-progress"` для того же `run_type`+slug → предложить resume или fresh.
- `scope_cache` хранит `files_hash` + `git HEAD sha` на момент scoping. На iter>1/resume — пересчитать hash: совпал ⇒ reuse (scoper не считается, scope-once); **не совпал ⇒ warn + предложить пересчёт** (код уехал — старый scope невалиден). `scope_cache_hit:bool` → в `execution_trace`.
- Workflow завершился → `status: complete`.

### 2.5 Concurrency между run_type (v2-gap #1, v3-gap #3)
`from-task` и `/finalize` на одном slug — оба мутируют. **Решение**: project-level acquire через тот же mkdir-страж `<cwd>/.plan-panel/.run.d` (не отдельный lock-файл, §2.0), сериализует **мутирующие** run'ы. Read-only review не блокирует.
**v3-gap #3**: разные slug, но один код (concurrent `from-task` + `finalize` на разных задачах того же репо) — project-level страж их тоже сериализует (мутируют одно дерево). Тесты: (а) one slug from-task+finalize; (б) different-slug concurrent на одном репо.

### 2.4 Retention / GC (конфликт data↔ops)
- `expires_at = created_at + 90d`. Lazy GC: при каждом новом run чистить просроченные dirs в `.plan-panel/` и `.finalize/`.
- **Sync-exclude**: `/finalize` пишет в `.finalize/`, который содержит `diff.patch` (потенциально sensitive) → добавить `.finalize/` в Yandex.Disk ignore + НЕ делать central mirror для finalize по умолчанию (только metadata-only mirror). Часть B §secrets.

---

## 3. Размещение reviewer-loop + API-контракт (конфликт architect↔ops; v2-warning #6)

Loop НЕ встраивается в `panel.js` happy-path. Выносится в `workflow/reviewer-loop.js`,
который вызывает существующие фазы panel.js как функции. Облегчает rollback (ops) и unit-тесты (qa).

**Замороженный API (Stage 0, чтобы §6-фикстуры и rollback-scope были конкретны):**
- envelope передаётся через **runContext-параметр функции, НЕ через мутацию файла** (роль получает данные аргументом, не читает общий файл — тестируемо, без гонок).
- `panel.js` экспортирует чистые функции: `runScope(ctx)`, `runRoles(ctx)`, `runJudge(ctx)`.
- `reviewer-loop.js`: `reviewerLoop(ctx) -> {final_judge, iterations[], converged}`.
- `scope_cache` schema (с `files_hash`, `head_sha`) — заморожена здесь же.

---

## 4. Executable acceptance criteria (action #4)

AC не «структурные» (галочка глазами), а **исполняемые проверки** в orchestrator:
| Проверка | Как |
|---|---|
| DRAFT/REVISE/finalize-envelope валидны | JSON-schema validator на выходе агента (как уже делает StructuredOutput, но + кастомные инварианты ниже) |
| revise_notes покрывает все critical/warning judge | runtime: `judge.priority_actions.filter(critical|warning).every(a => revise_notes.some(n => n.judge_action_rank === a.rank))` иначе fail |
| fixer не глушил проверки | regex-guard по diff fixer'а: `/\b(skip|xit|xdescribe|eslint-disable|@ts-ignore|# type: ignore|pytest.mark.skip)\b/` → каждое попадание без обоснования в `fixer_warnings[]`. Фикстуры **и true-positive, и false-positive** (слово в комментарии/докстринге — не флагать). `fixer_warnings[]` уходит в finalize-envelope; judge **опускает verdict до NEEDS-WORK**, если warning касается файла из `changed_files`. |
| план «в вакууме» | `DRAFT_SCHEMA.code_was_read === false` → warning в metadata |

### 4.1 Oscillation control-flow (v2-critical#2) — flag должен ДЕЙСТВОВАТЬ, не только ставиться
```
iter == 1               → delta = undefined → regressed:false (нет предыдущего)
delta = crit(N) - crit(N-1)
delta > 0  → regressed:true → НЕМЕДЛЕННЫЙ break петли + checkpoint.status = crashed(oscillation)
```
Жёсткое правило: `regressed == true` И вырос **security-critical subset** (не любой critical) ⇒ **принудительный FIX-FIRST**, который НЕ может быть перекрыт `stable:true`. Два mock-теста обязательны (§6): (а) oscillation→FIX-FIRST; (б) iter=1 не ложно-regressed.

## 5. Observability (action #7)
`metadata.json.execution_trace[]`: на каждую фазу `{ phase, model, status, started_at(ISO-8601), ended_at, tokens_in, tokens_out, scope_cache_hit }`.
Без этого нет post-mortem и нет данных для обещанного cost-estimate. + `log()` на каждую фазу в stdout (Workflow narrator).
**Запрет payload в trace (v2-critical#1)**: trace хранит только метаданные (фаза/модель/токены/статус) — НИКОГДА не plan/diff/finding-тексты. Иначе secrets-strip обходится через trace.

## 7. Global guards (v2-gap #2)

### 7.1 Secrets-strip — глобальный, не только /finalize (v2-critical#1, v3-warning)
Strip применяется к **любому** контенту перед записью на диск и перед любым agent-envelope — включая **вывод планнера** (`plan.vN`) в Части A, не только diff в Части B. Порядок инвариантен: `source → strip → (только stripped) → checkpoint/envelope/plan.vN/trace`. Сырой контент НИКОГДА не достигает диска. Реализация — `lib/strip-secrets.sh` — **единственный entry point** (DoD-grep подтверждает single call-site), переиспользуется обеими частями.
- **`strip` exit ≠ 0 → abort, 0 байт на диск** (не пишем непроверенное). High-entropy порог — specify (напр. Shannon ≥ 4.0 на ≥20-символьной строке).

### 7.2 Hard cost-ceiling на ЛЮБОМ режиме (не только --ultra)
Конфигурируемый потолок (env/конфиг). На Phase 0 (draft/snapshot) — **dry-run estimate** ожидаемых вызовов (учесть `MAX_ROUNDS`/chunking/итерации). Если прогноз > ceiling → abort с prompt'ом подтверждения. Закрывает runaway: большой diff × MAX_ROUNDS=3 × chunking молча множит Sonnet-вызовы; `--ultra`-gate этого не ловит.

## 6. Test strategy (action #8)
- Mock-агент loop: фиксированные ответы scope/roles/judge → проверить переходы (NEEDS-WORK→revise→PASS, unconverged на MAX_ITERS).
- Schema fixtures: валидные/невалидные DRAFT/REVISE/finalize envelope.
- regex-guard fixtures для fixer.
- 1 реальный E2E на тривиальной задаче/diff перед merge каждого stage.

## DoD Stage 0 (machine-verifiable, v2-critical#5)
Каждый пункт — **исполняемый assert**, не «галочка глазами»:
- `_shared.md` содержит §1.1–1.6 + REVISE_ERROR_SCHEMA + budget. **Assert**: каждая JSON-schema проходит мета-валидатор (валидна сама по себе).
- `lib/checkpoint.sh` self-test exit 0, покрывает по отдельному assert: write, **crash-recovery** (kill в середине → resume даёт консистентный state), GC (просроченный dir удалён), resume-match (resumed state == pre-crash), `checkpoint_acquire` race (2 параллельных acquire → ровно один успех).
- **Crash-injection + canary тест (v2-critical#1, v3-critical#2)**: фикстура с canary-секретами (regex `sk-|ghp_|AIza|xoxb-|op://|-----BEGIN|Bearer [A-Za-z0-9]{20,}`), убить процесс в фазах draft/revise/snapshot/stabilize → `grep -q <regex>` над `checkpoint.json/plan.*.md/execution_trace/diff.patch` ДОЛЖЕН вернуть exit 1 (ни одного попадания). Crash-timing — через fault-inject флаг (детерминированно, не «повезёт поймать»). `execution_trace` доп. проверяется schema-validator'ом с **allowlist полей** (никаких лишних = никакого payload).
- `FINDINGS_SCHEMA` += `checked_files`; **assert** plan-review E2E на golden-фикстуре даёт прежний verdict (no regression).
- validators (§4) — переиспользуемые функции, покрыты unit-fixtures (§6), включая false-positive regex-guard.

## Overall DoD (через все 3 stage, v2-critical#5)
- Stage 0 self-tests зелёные → Stage 1 AC (loop: iter2 diff непустой, revise_notes покрывает каждый prior critical/warning, `converged:false` summary содержит причину) → Stage 2 AC (strip-pass 0 префиксов, fixer_warnings floors verdict, lock reclaim).
- 1 реальный E2E на каждый stage перед merge (§6).

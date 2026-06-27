# plan-panel — shared protocol

Этот файл — общий контракт для **всех** ролей. Любая роль обязана соблюдать схему output, severity rubric и sole-author rule. Без этого synthesis и self-improve не работают.

## 1. Output schema (СТРОГО JSON)

Каждая роль возвращает один JSON-объект:

```json
{
  "role": "architect|qa|security|frontend|backend|data|ops",
  "verdict": "PASS|FAIL|UNCERTAIN",
  "confidence": 0.85,
  "findings": [
    {
      "severity": "critical|warning|suggestion",
      "area": "короткая категория (например 'data-model', 'auth-flow', 'rollback', 'empirical-unknown')",
      "issue": "что именно не так / упущено / рискованно",
      "suggestion": "конкретное actionable исправление",
      "ref": "необязательно — ссылка на step плана / файл / строку"
    }
  ],
  "summary": "1-2 предложения общего вывода",
  "self_check_passed": true
}
```

**Правила**:
- `verdict=PASS` ⇔ нет critical findings и роль уверена в плане (`confidence ≥ 0.7`)
- `verdict=FAIL` ⇔ есть хотя бы один `critical` finding
- `verdict=UNCERTAIN` ⇔ конф нижe 0.7 ИЛИ план вне зоны экспертизы роли (роль должна явно сказать почему в `summary`)
- Минимум **1 actionable suggestion** в findings, иначе роль помечается `noise` в feedback log
- `self_check_passed=false` если роль не уверена что покрыла свой checklist целиком

## 2. Severity rubric (одинаковая для всех ролей)

| Уровень | Когда применять | Должно блокировать релиз? |
|---|---|---|
| **critical** | Уязвимость, потеря данных, нарушение договорённости с пользователем, blocker для следующего шага | Да |
| **warning** | Технический долг, недостающая обработка edge-cases, плохая практика, потенциальный риск | Не сразу, но фикс в той же итерации |
| **suggestion** | Improvement, оптимизация, лучший паттерн, polish | Опционально |

**Анти-паттерн**: помечать всё как critical. Если у тебя 5+ critical findings — пересмотри, возможно ты в режиме "всё плохо".

## 3. Sole-author rule

В artifact `review.md` каждая роль пишет **только в свою секцию** `## <Role>`. Никакая роль не правит чужие секции. Judge синтезирует, но не правит исходные секции — пишет в свой `## Judge`.

## 4. Token budget

| Роль | Input max | Output max | Model |
|---|---:|---:|---|
| scoper | 4k | 1k | Haiku |
| architect / qa / frontend / backend / data / ops / security | 4k | 2k | Sonnet |
| judge | 12k | 3k | Fable |
| planner (draft/revise) | 6k | 4k | Fable |
| fixer (finalize stabilize) | 8k | 3k | Sonnet |

Если роль явно вышла за бюджет — это сигнал что план слишком большой для одного review (нужно дробить на несколько /plan-review запусков).

## 5. Composability с другими skills

Роль может ССЫЛАТЬСЯ на другой skill для context, но **не вызывает** его (skills не композируются на ходу). Маркер: `→ см. ~/.claude/skills/<name>/SKILL.md`.

Конкретные привязки:
- `security` → `~/.claude/skills/secrets/SKILL.md` (1Password protocol, никогда .env)
- `frontend` → `~/.claude/skills/animate/SKILL.md` + `~/.claude/skills/emil-design-eng/SKILL.md`
- `data` → `supabase` skill (если scope включает supabase)
- `ops` → `$CLAUDECORE_PATH/servers/` (server inventory) + `$CLAUDECORE_PATH/projects/<slug>.md` (проект-контекст)
- Любая роль → `$CLAUDECORE_PATH/projects/<slug>.md` если найдено по имени проекта

## 6. Что роль НЕ делает

- ❌ Не пишет код в свой output (только findings + suggestions)
- ❌ Не вызывает других ролей
- ❌ Не редактирует план — только аннотирует
- ❌ Не говорит "плана нет, нужно больше деталей" — если плана недостаточно, говорит **что именно** недостаёт (это и есть finding с severity warning)

## 7. Input envelope (что роль получает от orchestrator)

```
review-роли (architect/qa/security/frontend/backend/data/ops):
  {
    plan_text: string,                  // оригинал плана пользователя
    scope: <scoper output JSON>,         // tags, complexity, rationale
    role_spec_file: string,              // путь к role .md (как self-reference)
  }

judge:
  {
    plan_text,
    scope,
    execution_report: {                  // ← добавлено после meta-self-review
      attempted_roles: [...],
      completed_roles: [...],
      failed_or_null_roles: [...],
      skipped_not_implemented: [...],
    },
    role_reviews: [...]                  // массив JSON от всех completed ролей
  }
```

Judge обязан в своём output отметить любые `skipped_not_implemented` роли как **gaps** (это области которые не были покрыты).

## 8. Persistence — canonical source of truth

Persistence dual, но **НЕ симметричный**:

| Location | Role | Что хранится |
|---|---|---|
| `<cwd>/.plan-panel/<ts>-<slug>/` | **canonical** — single source of truth | plan.md, scope.json, review.md, judge.md, metadata.json. `/panel-feedback` ПИШЕТ сюда. |
| `$CLAUDECORE_PATH/plan-panel/<project>/<ts>/` | **best-effort replica** (symlink или копия) | те же файлы, для cross-project аналитики и UI |
| `~/.claude/skills/plan-panel/roles/<role>.md` | **canonical** | role prompts, **никогда** не копируются в CloudCore — версионирование в `roles/<role>.history/` локально |
| `~/.claude/skills/plan-panel/feedback/<role>.jsonl` | **canonical** | feedback log, **никогда** не в CloudCore (может содержать sensitive plan-context) |

**Если symlink ломается** (Yandex.Disk sync issue) — local `.plan-panel/` остаётся source of truth, central — можно перегенерировать через rsync.

## 9. Fail-fast guard (orchestrator level)

Workflow обязан остановиться рано если:
- `scoper.confidence < 0.3` → план не distinguishable от не-плана, возвращаем clarification request пользователю **без Fable call**
- `selected_roles.length < 3` → недостаточно coverage для panel
- 2+ роли вернули `null` (timeout/crash) → degraded run, judge получает явный execution_report (см. §7)
- **planner draft/revise** вернул timeout/parse-fail/schema-violation → `*_ERROR_SCHEMA` (§10), abort без запуска roles (Stage 1)
- **fixer** crash/infra-error → stabilize останавливается, review идёт с `stable:false`/`unknown` (Stage 2)

## 10. Замороженные контракты Stage 0 (DESIGN-foundation §1)

> Реализация и self-test'ы: `lib/checkpoint.sh`, `lib/strip-secrets.sh`, `lib/validators.js`.
> Единый прогон: `bash lib/test-foundation.sh`. Эти контракты **заморожены** — Stage 1/2 строятся на них.

### 10.1 Schemas
- **DRAFT_SCHEMA** (planner draft): `{ plan_markdown(minLen50), assumptions[], open_questions[], self_check_passed:bool, code_was_read:bool }`. `code_was_read=false` ⇒ план «в вакууме» ⇒ warning в metadata.
- **REVISE** (planner revise): вход `{ prev_plan_markdown, judge_md, role_reviews[], iteration }`; выход = DRAFT_SCHEMA + `revise_notes[{ judge_action_rank, disposition:applied|rejected|deferred, rationale }]`. Каждый critical/warning judge ОБЯЗАН иметь запись (runtime-проверка `validators.reviseCoverage`).
- **\*_ERROR_SCHEMA** (DRAFT_ERROR / REVISE_ERROR): `{ error:timeout|parse_fail|schema_violation, phase, iteration?, partial_persisted }`. → persist `plan.vN` со `status=draft_failed|revise_failed`, `converged:false`, следующая итерация НЕ стартует, retry=0.
- **finalize-envelope** (review-роли в режиме кода): `{ diff_text, changed_files[], full_files?:map, review_mode:'code' }` — заменяет `plan_text`.
- **FINDINGS_SCHEMA** += `checked_files[]` (optional; какие файлы роль реально просмотрела в review_mode=code).

### 10.2 `review_mode=code` overlay (канонический блок — ОДИН источник)
Когда orchestrator передаёт роли `review_mode:"code"`, к её базовому промпту применяется этот блок (роли при wiring Stage 2 ссылаются сюда, НЕ копируют — против дрейфа):
```
Ты оцениваешь реализованные изменения (git diff), а не план.
- Источник истины — diff_text + (при нехватке) full_files / Read / codegraph.
- Ищи баги, регрессии, нарушенные инварианты, тех-долг, незакрытые edge-cases В КОДЕ.
- Каждый finding.ref ОБЯЗАН указывать путь:строку из diff (не из плана), без literal-значений секретов.
- Severity rubric (§2), FINDINGS_SCHEMA (§1), sole-author rule (§3) — те же.
- Заполни checked_files[] — какие файлы реально просмотрел.
```

### 10.3 checkpoint = single source of truth (DESIGN-foundation §2)
`checkpoint.json` хранит статус run'а И lock (`lock_pid/lock_at/lock_ttl_sec`) — отдельных .lock-файлов нет. `slug = sha1(normalize(text))[:12]`. Все мутации атомарны (`tmp→mv -f`). schema_version read-policy: `>KNOWN_MAX` abort, `<current` reject (Stage 0). project-lock — mkdir-страж + stale-reclaim. Retention `expires_at=+90d`, lazy GC. См. `lib/checkpoint.sh`.

### 10.5 META-CRITIC contract (петля самоулучшения)
В конце каждого workflow (panel.js/finalize.js + red* research/semantic/landing-builder) — meta-критик: классифицирует находки на «дефект этого плана/кода» vs «дыра в чек-листе/процессе» (→ `methodology_findings[{role, lens_key, severity, observation, proposed_checklist_delta}]`). `CRITIC_SCHEMA` **намеренно реплицирована inline в 5 workflow** — Workflow-sandbox без `import`/`require`/fs, единый модуль невозможен. **Менять схему синхронно во всех 5**; `lib/ledger.sh cluster` устойчив к отсутствующим полям (optional `//`), так что дрейф деградирует мягко, не падает. learnings_entry → ledger (`lib/ledger.sh append <skill_root>`) через caller (SKILL/command), т.к. workflow не пишет на диск. Кластеризация по `role||ascii_downcase(lens_key)`.

### 10.4 secrets-strip — глобальный, single entry point (DESIGN-foundation §7.1)
ЛЮБОЙ контент (plan.vN, diff, envelope, trace) проходит `lib/strip-secrets.sh` ПЕРЕД записью на диск/в envelope. `strip` exit≠0 ⇒ abort, 0 байт на диск. `execution_trace` — только метаданные, НИКОГДА payload. Инвариант проверяется `lib/crash-canary-test.sh`.

---
name: finalize
description: |
  Финал сессии: застабилизировать код (typecheck/lint/build/test + автофикс) и сделать многоролевое код-ревью по git diff одной командой.
  Сиблинг plan-panel, но вход — РЕАЛИЗОВАННЫЕ изменения (diff), а не план. Роли plan-panel в режиме review_mode=code; judge выдаёт SHIP / FIX-FIRST / NEEDS-WORK.

  TRIGGER on:
  • «застабилизируй и сделай ревью», «финал сессии», «приведи в порядок и проверь», «закругляемся, прогони финалку»
  • «сделай код-ревью изменений», «проверь что мы наделали», «перед коммитом проверь»
  • "stabilize and review", "finalize this", "wrap up the session", "final code review", "review my changes before commit"
  • Explicit: «/finalize»

  Флаги: --staged (только staged), --since <ref> (diff против ref), --review-only (пропустить стабилизацию), --lite/--ultra (глубина review).
allowed-tools:
  - Bash
  - Read
  - Edit
  - Write
  - Workflow
  - Agent
  - AskUserQuestion
---

# /finalize — stabilize + код-ревью по diff

Сиблинг `plan-panel`. Snapshot + stabilize делает **сессия детерминированно через Bash**
(надёжнее, чем агент на git), панель код-ревью (scope→roles→judge) — Workflow `finalize.js`.

Base dir: `~/.claude/skills/finalize`. Общие `strip-secrets.sh`/`checkpoint.sh` — symlink на `plan-panel/lib`.

## Процедура (что делает Claude при триггере)

### 0. Setup + Snapshot (Bash, детерминированно)
```bash
B=~/.claude/skills/finalize/lib
OUT=$(bash $B/persist.sh "<cwd>" "<session-slug>")          # → project_dir|central|ts ; пишет checkpoint(run_type=finalize)
PD=$(echo "$OUT" | cut -d'|' -f1)
GATES=$(bash $B/detect-gates.sh "<cwd>" "<project_slug>")    # JSON [{name,cmd}] или []
N=$(bash $B/snapshot.sh "<cwd>" "$PD" working)               # git diff → strip → diff.patch+changed_files ; mode: working|staged|since
```
- `mode` из флага: по умолчанию `working`; `--staged` → staged; `--since <ref>` → since.
- **N == 0** → стоп: «нечего финализировать (нет изменений)».
- `diff.patch` уже **secrets-stripped** (snapshot гонит через strip; сырое на диск не пишется).

### 1. Stabilize (Workflow `stabilize.js`, пропустить если `--review-only` или GATES==[])
Автоматизированный fixer-loop (≤3 раунда, regression-guard, deny-list, no-suppression — всё внутри):
```
Workflow({scriptPath: "~/.claude/skills/finalize/workflow/stabilize.js",
          args: {cwd, gates: GATES, max_rounds: 3}})
  → stabilize_report = {stable: true|false|"unknown", rounds, remaining_failures, fixer_warnings, history}
```
- `stable=true` — зелёное. `stable=false` — не сошлось за раунды (review всё равно идёт). `stable="unknown"` — гейтов нет ИЛИ infra-error (нет бинаря/network), fixer не запускался.
- Fixer чинит **причину, не глушит** тест/линтер; соблюдает deny-list (`.env*`/`*.pem`/`secrets/*`/…); regression-guard останавливает раунды если падений не убавилось.
- **После стабилизации ОБЯЗАТЕЛЬНО пересними diff** (fixer менял файлы): `bash $B/snapshot.sh "<cwd>" "$PD" <mode>` → актуальный `diff.patch` + `changed_files.txt`.
- `--review-only` или `GATES==[]` → пропустить, `stabilize_report = {stable:"unknown", rounds:0, remaining_failures:[], fixer_warnings:[]}`.

### 2. Панель код-ревью (Workflow)
```
Workflow({scriptPath: "~/.claude/skills/finalize/workflow/finalize.js", args: {
  diff_text: <содержимое PD/diff.patch>, changed_files: [...],
  stabilize_report, gates_found: GATES!=[], mode, project_slug, cwd, project_dir: PD, timestamp, run_id
}})
```
scope(по diff) → роли в `review_mode=code` (overlay `plan-panel/_shared.md §10.2`) → judge.
**Инвариант**: `stable ∈ {false, unknown}` ⇒ verdict ≠ SHIP (enforced и в judge-промпте, и в оркестраторе).

### 3. Артефакты + summary
- Записать `artifacts{}` из workflow в `$PD` (scope.json, reviews.json, review.md, judge.json, judge.md, stabilize.json, metadata.json, learnings.entry.json).
- **Авто-капчур в ledger (петля самоулучшения, push не pull):** `bash $B/ledger.sh append ~/.claude/skills/finalize "$(cat "$PD/learnings.entry.json")"` — копит methodology-находки meta-критика для scheduled-solidify. НЕ требует ручного `/panel-feedback`.
- `checkpoint.sh set "$PD" '.status="complete" | .phase="judge"'`.
- Central mirror — **только metadata** (diff/reviews с кодом НЕ копировать; persist.sh уже пометил это).
- Показать пользователю: **verdict** (SHIP/FIX-FIRST/NEEDS-WORK) + stable? + что чинил stabilize + top-5 actions + conflicts/gaps + путь к artifacts. Не вываливать diff.
- **Если `pending_live_verify=true`** (есть empirical-unknown) — verdict показать как **`SHIP — ⚠ pending live-verify`** и ОБЯЗАТЕЛЬНО вывести секцию `live_verify_dod[]`: это runtime-проверки, которые code-review структурно не закрывает (стык внешней системы × тип поля × поведение движка). Явно сказать пользователю: «мерджить можно, но НЕ считать готовым, пока не прогнан live-verify».

## Правила
- **НИКОГДА не коммитить/не пушить самому** — только чинить рабочее дерево и ревьюить. Коммит — решение пользователя.
- `.finalize/` — sync-excluded (persist.sh добавляет в .gitignore); содержит stripped, но всё равно не реплицируем код в central.
- Огромный diff (>200 файлов или >80k симв ≈20k токенов/роль) → finalize.js **автоматически** дробит по directory-prefix (≤100/группа), каждая роль проходит все группы, findings мёржатся (verdict=worst, checked_files объединяются), judge агрегирует. Дробление логируется (no silent cap). Scoper при дроблении получает список файлов + сэмпл.

## Self-test
`bash ~/.claude/skills/finalize/lib/test-finalize.sh` — detect-gates, snapshot, run-gates, strip, finalize.js + stabilize.js syntax, chunk logic, empirical logic.

## Verdict-словарь
- **SHIP** — можно мерджить (нет critical, стабильно).
- **SHIP — ⚠ pending live-verify** — код можно мерджить, но есть `empirical-unknown` finding: runtime-стык (внешняя система × тип поля × поведение движка/прокси-success), который code-review не закрывает. Прилагается `live_verify_dod[]` — обязательные проверки на реальном пути (write→read-back assert, граничная матрица, live-verify на проде) ПЕРЕД тем как считать готовым. Не «чистый» SHIP.
- **FIX-FIRST** — есть critical / нестабильно / remaining_failures → чинить до мерджа.
- **NEEDS-WORK** — существенные warning'и или подавление проверок.

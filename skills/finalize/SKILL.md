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
**Архивариус (RedBrain-заземление, рекомендуется):** `bash ~/.claude/skills/redbrain/lib/archivist.sh "$PD/diff.patch"` → stdout захватить как `memory_brief` (пусто = ок). Оркестратор зовёт ДО Workflow (recall.py нужен диск/SQLite; subprocess, НЕ import). scope work fail-closed, fail-open. Пропустить при `--no-memory`. → «известные грабли/решения по этому проекту» в роли+judge.

**Fact-grounder (ВЫЗЫВАТЬ ВСЕГДА, кроме `--no-research`/`--lite`; non-blocking):**
⚠️ Решает скрипт, а не ты: `tier=none` → ноль вызовов движков и пустой stdout, поэтому
безусловный вызов ничего не стоит. Пропуск шага стоит: план/дифф уходит к ролям без сверки
версий, EOL и CVE с вебом. Замер 2026-08-20 — за всю историю шаг отработал один раз.
Старая формулировка: `python3 ~/.claude/skills/_shared/fact-grounder/ground.py < "$PD/diff.patch"` → stdout захватить как `research_brief` (пусто = tier none, ок). Тоже ДО Workflow (движки — shell). Дёшево (none→0 вызовов; иначе до 5 Tavily ~$0.04, scrub+бюджет-гард внутри). НЕ спрашивать (стоимость мала). Пропустить при `--no-research`/`--lite`. → роли+judge ловят freshness-conflict (EOL-версия/депрекейт-API/CVE в diff'е). Передать в Workflow args как `research_brief`.
```
Workflow({scriptPath: "~/.claude/skills/finalize/workflow/finalize.js", args: {
  diff_text: <содержимое PD/diff.patch>, changed_files: [...], memory_brief, research_brief,
  canon_lexicon: <`jq -c '[.lenses[]|{key,role,title}]' ~/.claude/skills/finalize/lenses/canon.json`>,
  stabilize_report, gates_found: GATES!=[], mode, project_slug, cwd, project_dir: PD, timestamp, run_id
}})
```
scope(по diff) → роли в `review_mode=code` (overlay `plan-panel/_shared.md §10.2`) → judge.
**Инвариант**: `stable ∈ {false, unknown}` ⇒ verdict ≠ SHIP (enforced и в judge-промпте, и в оркестраторе).

### 2.5 Внешние судьи (ВЫЗЫВАТЬ ВСЕГДА, кроме `--lite`; non-blocking)
Независимый второй голос вне Claude-семейства (OpenAI/GLM/Kimi) на том же diff.
Caller-level (op run + curl вне Workflow-песочницы), НЕ SPOF — сбой любого судьи не ломает finalize.

⚠️ **Шаг не опциональный — решают тумблеры, не ты.** `panel.sh` сам проверяет
`ej_enabled_providers()` и при выключенных тумблерах печатает одну строку «выключены» с exit 0.
Пока формулировка была «опционально», шаг просто выпадал: тумблеры стоят
`openai,glm,kimi` с 2026-07-20, а последняя запись в `ledger.jsonl` — 2026-07-22 при
десятках прогонов после. Дешёвая безусловная команда надёжнее уговоров.
```bash
E=~/.claude/skills/_shared/external-judge
# $CV = verdict Claude-панели из judge.json (SHIP/FIX-FIRST/NEEDS-WORK)
bash "$E/panel.sh" "$PD/diff.patch" "$CV" --out "$PD"   # → cross-model.md + cross-model.json в $PD
```
- Скраб (fail-closed) и денилист (ИНН/реквизиты/sensitive-проекты) + инфра-редакция — **внутри** адаптера, до отправки.
- Вывод `panel.sh` (markdown-блок «Внешние судьи» + подсветка расхождений с Claude) вставить в summary шага 3.
- Включение: `EJ_ENABLE="openai,glm"` в env ИЛИ `_shared/external-judge/toggles.env`. Kill: `EJ_KILL=1` / файл `KILL`. Budget-cap: `EJ_BUDGET_USD_DAY`.
- Если в diff есть чувствительное (финансы/PII проекта) — судья сам заблокируется (denylist-block в блоке).

### 3. Артефакты + summary
- Записать `artifacts{}` из workflow в `$PD` (scope.json, reviews.json, review.md, judge.json, judge.md, stabilize.json, metadata.json, learnings.entry.json).
- **Авто-капчур в ledger (петля самоулучшения, push не pull):** `bash $B/ledger.sh append ~/.claude/skills/finalize "$(cat "$PD/learnings.entry.json")" --entry-point finalize` — копит methodology-находки meta-критика для scheduled-solidify. НЕ требует ручного `/panel-feedback`.
- `checkpoint.sh set "$PD" '.status="complete" | .phase="judge"'`.
- Central mirror — **только metadata** (diff/reviews с кодом НЕ копировать; persist.sh уже пометил это).
- Показать пользователю: **verdict** (SHIP/FIX-FIRST/NEEDS-WORK) + stable? + что чинил stabilize + top-5 actions + conflicts/gaps + путь к artifacts. Не вываливать diff.
- **Если запускались внешние судьи (2.5)** — под verdict'ом вставить содержимое `$PD/cross-model.md` (блок «Внешние судьи» + подсветка расхождений). Расхождение внешнего судьи с Claude-панелью = сигнал слепой зоны, не игнорировать.
- **Если `pending_live_verify=true`** (есть empirical-unknown) — verdict показать как **`SHIP — ⚠ pending live-verify`** и ОБЯЗАТЕЛЬНО вывести секцию `live_verify_dod[]`: это runtime-проверки, которые code-review структурно не закрывает (стык внешней системы × тип поля × поведение движка). Явно сказать пользователю: «мерджить можно, но НЕ считать готовым, пока не прогнан live-verify».

### 4. Ф3-confirm redcost (опционально, если finalize закрывает БИЛЛИНГ-задачу проекта)
Когда финалим работу, привязанную к задаче Трекера биллинг-проекта (любой проект с договором) и
задача реально закрывается — прогнать финальный расчёт redcost (skill `redcost` §Ф3):
1. Резолв договора; собрать факт-часы по ролям «как реальный спец» (авто-черновик, Игорь правит).
2. `final.prepare(issue, summary, contract, approved_roles, date, estimate_hours, delta_reason)` →
   клиентский комментарий (цензор) + writer_task.
3. Показать Игорю ИТОГ (роли-часы, дельта к прогнозу Ф1, остаток лимита) → **OK-гейт**.
4. `writer.write_task_result` / `tracker_adapter` → worklog (`start`!) + комментарий (guard старой схемы,
   идемпотентность, half-success). Round-trip GET+assert.
5. **ТОЛЬКО при `overall='written'`** → `final.confirm_after_write(issue, approved_roles, date)` →
   `predicted→approved` + дельта → сохранить `data/precedents.json`. База учится (Ф1 будущих задач точнее).
Пропустить, если finalize не про оплачиваемую задачу (внутренний скилл/инфра — как этот redcost-финал).

### 5. Guides-freshness check (если работа затрагивает сайт проекта с Гайдом)
Если финализируемая работа — по САЙТУ проекта, у которого есть Гайд (База знаний в bridge
mini-app — у части клиентских проектов он есть), прогнать чек **«изменил сайт → нужна ли правка гайда?»**:
появился ли новый функционал/блок, изменился флоу, новое место в админке, новый тип инцидента,
новая интеграция. Если реально нужен **новый раздел/статья** (или правка существующей) —
**проактивно предложить Игорю** конкретно (какой раздел/статью + тезисы); контент сам не пишу,
предлагаю, решение за Игорём. Пропустить на инфра/тулинге (как сама сборка движка гайдов) и если
для пользователя гайда ничего не изменилось (не спамить). См. память `guides-freshness-check`.

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

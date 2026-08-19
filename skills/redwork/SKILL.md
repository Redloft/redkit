---
name: redwork
description: |
  Составной оркестратор полного цикла задачи: implement→test-gate→finalize→deploy→post-verify.
  Доводит понятную задачу до прода с минимальным участием человека. Тонкая стейт-машина поверх
  существующих команд (plan-panel/finalize/audit-site/run/verify/tracker), драйв /loop, резюм из state.json.
  Рабочий (обкатан на реальных прогонах до прода). Phase 2–6 (план — вход). 3 режима (default 2).
  Полная спека — DESIGN-mvp.md.

  TRIGGER on:
  • «сделай задачу X redwork», «прогони X через redwork», «доведи X до прода сам»
  • «redwork режим 1|2|3 …», "redwork mode 3 …"
  • Explicit: «/redwork», «/redwork-resume», «/redwork-init» (онбординг проекта)
allowed-tools: [Bash, Read, Edit, Write, Workflow, Agent, AskUserQuestion]
---

# /redwork — оркестратор полного цикла (implement→…→prod)

Сессия — оркестратор: deterministic-механика через Bash-либы (`lib/*.sh`), агентные/панельные части
(реализация кода, `/finalize`, `plan-panel`) — через Workflow/Agent. `/loop` держит процесс живым;
state.json — single source of truth, резюм после краша/паузы. **Спека-контракт — `DESIGN-mvp.md` (v3).**

Base: `~/.claude/skills/redwork`. Шаренные `strip-secrets.sh`/`ledger.sh` — symlink на plan-panel/lib.

## Режимы (default 2; парсится из NL «redwork режим N»)
- **1 аккуратный**: ✋-подтверждение на каждой границе (план/dev/прод).
- **2 мягкий (default)**: авто до dev → ✋ глазки на dev → авто до прод → ✋ апрув прода.
- **3 автопилот**: всё сам; человек только эскалация-по-сомнению + high-risk деплой.
- **Эскалация-по-сомнению — всегда** (safety floor): автофикс не сошёлся / неоднозначность / high-risk / не-SHIP.

## Онбординг проекта — ЖЁСТКИЙ ГЕЙТ (ПЕРВЫЙ запуск на проекте — `/redwork-init`)
redwork адаптируется под каждый проект (dev/prod/ветки/git/деплой/откат). Первый запуск → онбординг (`ONBOARDING.md`):
DETECT стек+git → INTERVIEW невыводимое (доктрина деплоя) → GENERATE `## redwork`-секцию в **CLAUDE.md проекта** (source of
truth) + `.redwork.json` + опц. `.redwork-autonomy.json` → VERIFY (lint+resolve **ЗЕЛЁНЫЙ**+rollback+shadow-gate) → `config.sh
mark-onboarded` (проставляет `onboarding_status.complete` с `content_sha` атомарно) → человек/init COMMIT'ит (autonomy —
подписанным коммитом, A0′). Дальше прогоны читают артефакты, без повторного опроса.

⛔ **Онбординг — ГЕЙТ, не «предложить» (инцидент на двух клиентских проектах 2026-07-29 — `HARDEN-onboarding-gate.md`).** Ровно потому,
что раньше было «предложить», оператор проехал на дефолтах и вскрывал deploy/dev/миграции вживую у прод-границы. Теперь на старте
`/redwork` **машинный `config.sh gate` fail-closed решает**, работать или нет — НЕ сессия «по ощущению». Нет завершённого
онбординга → redwork **НЕ стартует**, гонит `/redwork-init` до зелёного. Гейт ре-валидирует живые инварианты КАЖДЫЙ вызов
(`complete:true` форджируем — одного его мало). Exit-таксономия и обход — см. `lib/config.sh §ONBOARDING HARD-GATE`.

**Blast-radius / аварийный обход:** гейт — ПЕРВОЕ, во что упирается каждый вызов redwork. Если он ложно блокирует (баг на
валидном, но необычном конфиге) — `REDWORK_GATE_DISABLE=1` (аварийный обход, ГРОМКО логируется в `feedback/gate-events.log`),
либо `git revert` одного `lib/config.sh` (гейт НЕ требует правок `.redwork.json` в проектах для отката). Единственный штатный
обход для тривиального проекта — человек руками пишет `_meta.onboarding_status.trivial={value:true,by,at,why}` (аудируется).

## Старт (`/redwork <задача|CPMO-id|@plan.md> [--repo PATH] [режим N] [--auto-deploy]`)
```bash
L=~/.claude/skills/redwork/lib
REPO="<--repo или cwd>"; MODE="<N|2>"
# ⛔ ОНБОРДИНГ-ГЕЙТ (fail-closed) — ДО всего. exit≠0: 10 REQUIRED→/redwork-init · 11 INCOMPLETE→до-онбордить
#    (STOP печатает точную remediation) · 12/13/20/21 битый/ref/usage/tooling.
# ⚠ РЕЖИМ РАСКАТКИ (Слой 5.1): пока флот НЕ смигрирован (ВСЕ проекты предшествуют onboarding_status →
#    все дают 11), гейт РАБОТАЕТ В ADVISORY (печатает+логирует, но НЕ блокирует), чтобы не заблокировать
#    рабочие проекты «в лоб». Enforce (настоящий hard-stop) включается флагом REDWORK_GATE_ENFORCE=1
#    ТОЛЬКО когда весь флот проектов зелёный (`config.sh --status-all`). Тогда 11 → exit 1.
bash $L/config.sh gate "$REPO"; GC=$?
if [ "$GC" -ne 0 ]; then
  if [ "${REDWORK_GATE_ENFORCE:-0}" = 1 ]; then echo "⛔ онбординг-гейт: redwork остановлен (GATE_RESULT выше)"; exit 1
  else echo "⚠ ГЕЙТ advisory (до миграции флота): онбординг неполон — смигрируй /redwork-init. Продолжаю."; fi
fi
# (под Ф2-автопилотом/gate2 при ENFORCE: exit 10/11 → структурированное STOP-событие в эскалацию, БЕЗ ретрая онбординга в loop)
bash $L/config.sh lint "$REPO" || { echo "конфиг невалиден → стоп"; exit 1; }  # security-гейт (argv/cred/integrity)
bash $L/step.sh sweep                                                      # честная картина: пометить брошенные
SLUG=$(bash $L/state.sh slug "<task+repo>")
RD=$(bash $L/state.sh init "$SLUG" "<task БЕЗ секретов>" "$REPO" "$MODE" "redwork/$SLUG")
# lock берёт step.sh begin на первом тике — вручную не лочить
# план — вход: записать в $RD/plan.md (из @plan.md / прошлого plan-panel / задачи+плана)
git -C "$REPO" switch -c "redwork/$SLUG" 2>/dev/null || git -C "$REPO" switch "redwork/$SLUG"
```
Затем запустить драйвер: `/loop` (self-paced) с промтом «выполни redwork-step для $RD» — он крутит шаги ниже, пока не DONE или blocked.

## redwork-step (один тик /loop) — механика в `step.sh`, НЕ в этом тексте
Эмпирика 8 прогонов: то, что записано здесь текстом, сессия под нагрузкой пропускает (5 прогонов брошены
в `P2_implement/pending` при сделанной работе, `budget.llm_calls=0` везде, ledger не писался ни разу).
Поэтому переход фазы возможен **только** через `step.sh` — он одной операцией пишет phase+phase_status+event+heartbeat.

```bash
bash $L/step.sh begin "$RD"        # ← тик НЕ начинается иначе. Печатает PHASE/MODE/BUDGET + контракт.
                                   #   Сам берёт lock, инкрементит iterations, пишет step_version.
<хендлер фазы>                     # перед КАЖДЫМ Agent/Workflow: bash $L/step.sh llm "$RD"  (exit 2 → СТОП)
bash $L/step.sh end "$RD" --next <PHASE>                       # успех → следующая фаза, loop продолжает
bash $L/step.sh end "$RD" --done --note "<итог>"               # финал: ledger+gc+unlock, СТОП loop
bash $L/step.sh end "$RD" --escalate <REASON> <needs_csv> [d]  # нужен человек: blocked_on+TG+unlock, СТОП loop
```
`end` без одного из трёх флагов → exit 1: **тик нельзя завершить «никак»** — это и есть дефект, который лечим.
Exit-коды: `0` ok · `1` контракт · `2` BUDGET_EXCEEDED · `3` state/схема · `4` lock занят · `5` крах step.sh.
После `--escalate` СЕССИЯ дофаеривает push (PushNotification) + (если CPMO-id) `tracker` коммент.
Значимые действия внутри хендлера по-прежнему → `events.sh append` (типизированно, без raw stdout).

## Хендлеры фаз (что делает сессия)
- **P2_implement** (авто, ПО ШАГАМ плана): baseline `typecheck+lint` ДО правок (сломано → escalate `BASELINE_LINT_BROKEN`). Для каждого шага плана: правки → локальный `typecheck+lint exit 0` → `events gate_result`. Неоднозначность/нужно продуктовое решение → escalate `IMPL_AMBIGUOUS`. Done when: все шаги, typecheck+lint 0 → phase=P3.
- **P3_testgate**: `CFG=$(config.sh read $REPO)`. Прогнать gates (CFG.gates|detect-gates) + e2e + smoke(staging если `CFG.staging.url`!=null, иначе skip+warning) + `audit-site`(если фронт). Красное → Workflow `finalize/workflow/stabilize.js` (fixer-loop). regression-guard: рост skipped = регрессия. Не сошлось → escalate `TEST_FIXER_FAILED`. Done → phase=P4.
- **P4_finalize_pre**: Workflow `finalize/workflow/finalize.js` (см. /finalize SKILL — snapshot+stabilize+панель). SHIP → `state set_json .verdicts.finalize_pre = {verdict,build_sha:$(git rev-parse HEAD)}`; `pending_live_verify` → `live_verify_dod[]` в state. FIX-FIRST → автофикс ≤N → re-finalize. Не SHIP после N → escalate `FINALIZE_NOT_SHIP`. **Режим-гейт dev:** режим 1|2 → escalate-как-чекпоинт `WAIT_HUMAN(needs:review_dev)` (это «✋ глазки на dev»); режим 3 → дальше. Done → phase=P5.
- **P5_deploy** (стоячий гейт, two-phase commit):
  1. `RISK=$(risk-classify.sh <changed_files> --tags <scope> --max-auto N --add-glob …)`.
  2. Гейт: low + (`--auto-deploy`|режим3) → авто; medium/high → escalate `DEPLOY_HIGH_RISK`(needs:approve_deploy). режим3+high → нужен ACK (нет → HOLD). `migrations+нет rollback+risk≥medium` → блок.
  3. Пред-условия: `CFG.deploy.rollback` — одно из: **(a)** валидный argv → авто-rollback при smoke-fail; **(b)** `null` = ЯВНАЯ manual-rollback политика (нет безопасного one-shot отката, напр. бэкенд git-revert+ff-redeploy на платёжном проде) → авто-rollback ЗАПРЕЩЁН, smoke-fail эскалируется человеку; **(c)** поле отсутствует → escalate `DEPLOY_NO_ROLLBACK` (откат не определён вовсе). smoke-spec полна.
  4. **two-phase:** `state set_json .deploy_intent={id:<uuid>,status:"pending"}` + `events deploy{intent_id,exit_code:-1}` ДО вызова. **Re-read HEAD, assert ==finalize_pre.build_sha** (TOCTOU; ветка изолирована). Вызов argv через op: `op run --env-file=<(...CFG.deploy.env op://...) -- <CFG.deploy.cmd argv>` (НЕ eval/sh -c). Success → `.deploy_intent.status=deployed` + `events deploy{intent_id,exit_code}`.
  5. smoke `{cmd,expected_status_code,expected_response_contains}` (наблюдаемый результат, `-v` запрещён) → `events smoke_result{observed_status_code,match,expected_status_code}`. Зелёное → phase=P6. Красное: если `rollback` argv → **auto-rollback** (op-run CFG.deploy.rollback + `events rollback`) → escalate `SMOKE_FAILED`, провал rollback → escalate `ROLLBACK_FAILED`(needs:manual_rollback); если `rollback==null` (manual-policy) → **НИКАКОЙ авто-записи на прод** → сразу escalate `SMOKE_FAILED`(needs:manual_rollback) с инструкцией ручного отката из `_meta.rollback`/`## redwork`.
  - **Resume idempotency:** если на старте P5 `deploy_intent.status==pending` (краш между intent и success) → escalate (не авто-редеплой).
- **P6_postverify**: прод-smoke + прогнать каждый `live_verify_dod[]` (отметить `passed`) + Workflow `/finalize` на проде (`finalize_post`). **Автофикс на проде ЗАПРЕЩЁН** — любая проблема → escalate `POSTVERIFY_ISSUE` (+ опц. rollback по политике). `live_verify_dod[]` пуст → прод-smoke единственный обязательный + ACK. monitoring: ждать `post_deploy_watch_minutes`, нарушение порога → escalate. Всё passed + smoke pass → phase=P6.5.
- **P6.5_devsync** (ФИНАЛ большой работы; выполняется, если `CFG.dev_sync` задан — у проекта есть dev-зеркало): после зелёного прода **синхронизировать dev по прод-ветке** — zero-drift-инвариант `dev HEAD == origin/<прод-ветка>` + только dev-only слой (тест-моки/фейк-интеграции) поверх. Иначе dev — недостоверный стенд для следующей задачи. Канон-процедура и грабли (`core.filemode false`; skip-worktree блокирует checkout; НЕ `git … | tail` при set -e; reverse mock-патча не годится при ручных правках → forward-reapply канона) — **ClaudeCore `docs/prod-dev-drift-discipline.md`** + project-runbook. Не гейт прода (dev ≠ прод), но часть DoD: сбой → escalate `DEVSYNC_ISSUE`; успех → `state set_json .dev_synced=true`. Нет `CFG.dev_sync` → skip. → phase=DONE.

## `/redwork-resume <slug>` (после ответа человека)
`commands/redwork-resume.md`: re-lock, прочитать `blocked_on`, применить `{human_decision:approve|reject|answer, answer?}`, очистить `blocked_on`, продолжить `/loop`. approve на P5 → деплой; reject → откат фазы/стоп; answer → передать в зависшую фазу.

## Инварианты (НЕ нарушать)
Деплой только `verdict=SHIP` И `HEAD==build_sha` И зелёный наблюдаемый smoke. medium/high никогда не авто (floor-globs неотключаемы). rollback валиден ДО деплоя. P5/P6 идемпотентны (deploy_intent). P6-автофикс запрещён. Все записи → `validate_no_secrets`/keyword-guard; raw stdout/stderr НЕ в events; креды только `op://`+`$ENV`; команды argv, не eval. Работа на ветке `redwork/<slug>`.

⚠ **«Один run на repo» СЕЙЧАС НЕ ОБЕСПЕЧЕН** (вскрыто security-ревью 2026-07-27, дефект давний):
`slug = sha1(текст задачи + repo)`, а лок лежит внутри `run_dir` → две РАЗНЫЕ задачи на одном репозитории
дают два независимых лока, оба доходят до P5 и могут катить на прод параллельно (`HEAD==build_sha`
не спасает — у каждого свой build_sha на своей ветке). Фактическая гарантия — «один run на задачу».
До починки (нужен лок, ключованный по `repo`, а не по run_dir): **не запускать два redwork на одном
репозитории одновременно** — руками.

**State-гигиена — механизирована в `step.sh` (не полагаться на текст).** Фазу нельзя продвинуть, не записав
одновременно phase+phase_status+event+heartbeat; бюджет инкрементит `step.sh llm`; ledger пишет `end --done`;
брошенные ловит `step.sh sweep` + Stop-хук `~/.claude/hooks/redwork-sweep.sh`. Детали — шапка `lib/step.sh`.

**Каналы эскалации step.sh/sweep: ТОЛЬКО TG + durable `escalations.log`.** В Я.Трекер они не пишут — там
fail-closed money-guard, а detail/note машинные (риск и молчаливой резки хуком, и утечки суммы). Коммент
в Трекер оставляет СЕССИЯ после `--escalate`, по своим правилам.

**Ledger: `feedback/runs.jsonl` (исходы прогонов, `kind:"run_outcome"`), НЕ `learnings.jsonl`** — там
методологические находки петли самоулучшения, её формат ждёт solidify; смешение испортит обе выборки.

## Self-test
`bash ~/.claude/skills/redwork/lib/test-redwork.sh` — state/events/risk-classify/escalate/config/**step/migrate**.

## Статус
**РАБОЧИЙ (Phase 2–6, режимы 1–2; режим 3 — только на низкорисковых прогонах).** Обкатан: 8 прогонов,
2 доведены до прода со сквозным smoke (shakedown-режим 3 `f192756eab4a` 2026-06-28; RedTask M2–M5
`720bb6635d8e` 2026-07-23, деплой 067–069 + зелёный smoke, finalize 2 раунда FIX-FIRST→fixed).
Empirical-остаток MVP закрыт живьём: smoke-гейт, build_sha-gating, op-run-инъекция, two-phase deploy,
эскалация `DEPLOY_NO_ROLLBACK` при manual-rollback-доктрине — все сработали как заложено.
Онбординг (`/redwork-init`) обкатан на многослойном клиентском проекте → 4 critical влиты в ONBOARDING/config.sh.
**Онбординг-гейт (2026-07-29, `HARDEN-onboarding-gate.md`, 2 круга plan-panel):** `config.sh gate` fail-closed
+ `mark-onboarded` (атом-запись) + `--status-all` + observability. Self-test +13 gate-кейсов зелёный. ⚠ гейт
ЕЩЁ НЕ флипнут в обязательный старт — сначала живая миграция флагманских проектов через `/redwork-init` до exit 0
(иначе заблокирует флагманы посреди работы). См. §Онбординг + [[redwork-onboarding-hard-gate]].

**Не обкатано (осторожно):** режим 3 с автодеплоем на high-risk (DESIGN-autonomy Phase B/C не реализованы —
деплой всё ещё human), P6.5 devsync, авто-rollback по argv (реальный ff+opcache — только на staging).

---
name: redwork
description: |
  Составной оркестратор полного цикла задачи: implement→test-gate→finalize→deploy→post-verify.
  Доводит понятную задачу до прода с минимальным участием человека. Тонкая стейт-машина поверх
  существующих команд (plan-panel/finalize/audit-site/run/verify/tracker), драйв /loop, резюм из state.json.
  MVP = Phase 2–6 (план — вход). 3 режима (default 2). Полная спека — DESIGN-mvp.md.

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

## Онбординг проекта (ПЕРВЫЙ запуск на проекте — `/redwork-init`)
redwork адаптируется под каждый проект (dev/prod/ветки/git/деплой/откат). Первый запуск → онбординг (`ONBOARDING.md`):
DETECT стек+git → INTERVIEW невыводимое (доктрина деплоя) → GENERATE `## redwork`-секцию в **CLAUDE.md проекта** (source of
truth) + `.redwork.json` + опц. `.redwork-autonomy.json` → VERIFY (lint+rollback+shadow-gate) → человек COMMIT'ит (autonomy —
подписанным коммитом, A0′). Дальше прогоны читают артефакты, без повторного опроса. На старте обычного `/redwork`: если конфига
нет → предложить `/redwork-init`; если есть → работать по нему (проверив консистентность `## redwork` ↔ JSON).

## Старт (`/redwork <задача|CPMO-id|@plan.md> [--repo PATH] [режим N] [--auto-deploy]`)
```bash
L=~/.claude/skills/redwork/lib
REPO="<--repo или cwd>"; MODE="<N|2>"
bash $L/config.sh lint "$REPO" || { echo "конфиг невалиден → стоп"; }      # security-гейт ДО всего
SLUG=$(bash $L/state.sh slug "<task+repo>")
RD=$(bash $L/state.sh init "$SLUG" "<task БЕЗ секретов>" "$REPO" "$MODE" "redwork/$SLUG")
bash $L/state.sh lock "$RD" || { echo "уже активен run на repo → стоп"; }  # один run/repo
# план — вход: записать в $RD/plan.md (из @plan.md / прошлого plan-panel / задачи+плана)
git -C "$REPO" switch -c "redwork/$SLUG" 2>/dev/null || git -C "$REPO" switch "redwork/$SLUG"
```
Затем запустить драйвер: `/loop` (self-paced) с промтом «выполни redwork-step для $RD» — он крутит шаги ниже, пока не DONE или blocked.

## redwork-step (один тик /loop)
1. `PHASE=$(bash $L/state.sh get "$RD" .phase)`; `MODE=$(… .mode)`.
2. Выполнить хендлер фазы (ниже). Каждое значимое действие → `events.sh append` (типизированно, без raw stdout).
3. Успех фазы → `state.sh set_str "$RD" '.phase=$val' <next>`; `.phase_status=done`; **loop продолжает**.
4. **Нужен человек** → `bash $L/escalate.sh "$RD" <REASON_CODE> "<needs_csv>" [detail]` → затем СЕССИЯ дофаерит push (PushNotification) + (если CPMO-id) `tracker` коммент; `state.sh unlock "$RD"`; **СТОП loop** (ждём `/redwork-resume`).
5. `DONE` → `events gc`, `ledger.sh append`, отчёт, `tracker-done` (если CPMO), `state.sh unlock`; **СТОП loop**.
6. Бюджет: инкремент `.budget.llm_calls`; > `[IMPL-DEFAULT 20]` → escalate `BUDGET_EXCEEDED`.

## Хендлеры фаз (что делает сессия)
- **P2_implement** (авто, ПО ШАГАМ плана): baseline `typecheck+lint` ДО правок (сломано → escalate `BASELINE_LINT_BROKEN`). Для каждого шага плана: правки → локальный `typecheck+lint exit 0` → `events gate_result`. Неоднозначность/нужно продуктовое решение → escalate `IMPL_AMBIGUOUS`. Done when: все шаги, typecheck+lint 0 → phase=P3.
- **P3_testgate**: `CFG=$(config.sh read $REPO)`. Прогнать gates (CFG.gates|detect-gates) + e2e + smoke(staging если `CFG.staging.url`!=null, иначе skip+warning) + `audit-site`(если фронт). Красное → Workflow `finalize/workflow/stabilize.js` (fixer-loop). regression-guard: рост skipped = регрессия. Не сошлось → escalate `TEST_FIXER_FAILED`. Done → phase=P4.
- **P4_finalize_pre**: Workflow `finalize/workflow/finalize.js` (см. /finalize SKILL — snapshot+stabilize+панель). SHIP → `state set_json .verdicts.finalize_pre = {verdict,build_sha:$(git rev-parse HEAD)}`; `pending_live_verify` → `live_verify_dod[]` в state. FIX-FIRST → автофикс ≤N → re-finalize. Не SHIP после N → escalate `FINALIZE_NOT_SHIP`. **Режим-гейт dev:** режим 1|2 → escalate-как-чекпоинт `WAIT_HUMAN(needs:review_dev)` (это «✋ глазки на dev»); режим 3 → дальше. Done → phase=P5.
- **P5_deploy** (стоячий гейт, two-phase commit):
  1. `RISK=$(risk-classify.sh <changed_files> --tags <scope> --max-auto N --add-glob …)`.
  2. Гейт: low + (`--auto-deploy`|режим3) → авто; medium/high → escalate `DEPLOY_HIGH_RISK`(needs:approve_deploy). режим3+high → нужен ACK (нет → HOLD). `migrations+нет rollback+risk≥medium` → блок.
  3. Пред-условия: `CFG.deploy.rollback` валиден (нет → escalate `DEPLOY_NO_ROLLBACK`); smoke-spec полна.
  4. **two-phase:** `state set_json .deploy_intent={id:<uuid>,status:"pending"}` + `events deploy{intent_id,exit_code:-1}` ДО вызова. **Re-read HEAD, assert ==finalize_pre.build_sha** (TOCTOU; ветка изолирована). Вызов argv через op: `op run --env-file=<(...CFG.deploy.env op://...) -- <CFG.deploy.cmd argv>` (НЕ eval/sh -c). Success → `.deploy_intent.status=deployed` + `events deploy{intent_id,exit_code}`.
  5. smoke `{cmd,expected_status_code,expected_response_contains}` (наблюдаемый результат, `-v` запрещён) → `events smoke_result{observed_status_code,match,expected_status_code}`. Зелёное → phase=P6. Красное → **auto-rollback** (op-run CFG.deploy.rollback + `events rollback`) → escalate `SMOKE_FAILED`; провал rollback → escalate `ROLLBACK_FAILED`(needs:manual_rollback).
  - **Resume idempotency:** если на старте P5 `deploy_intent.status==pending` (краш между intent и success) → escalate (не авто-редеплой).
- **P6_postverify**: прод-smoke + прогнать каждый `live_verify_dod[]` (отметить `passed`) + Workflow `/finalize` на проде (`finalize_post`). **Автофикс на проде ЗАПРЕЩЁН** — любая проблема → escalate `POSTVERIFY_ISSUE` (+ опц. rollback по политике). `live_verify_dod[]` пуст → прод-smoke единственный обязательный + ACK. monitoring: ждать `post_deploy_watch_minutes`, нарушение порога → escalate. Всё passed + smoke pass → phase=DONE.

## `/redwork-resume <slug>` (после ответа человека)
`commands/redwork-resume.md`: re-lock, прочитать `blocked_on`, применить `{human_decision:approve|reject|answer, answer?}`, очистить `blocked_on`, продолжить `/loop`. approve на P5 → деплой; reject → откат фазы/стоп; answer → передать в зависшую фазу.

## Инварианты (НЕ нарушать)
Деплой только `verdict=SHIP` И `HEAD==build_sha` И зелёный наблюдаемый smoke. medium/high никогда не авто (floor-globs неотключаемы). rollback валиден ДО деплоя. P5/P6 идемпотентны (deploy_intent). P6-автофикс запрещён. Все записи → `validate_no_secrets`/keyword-guard; raw stdout/stderr НЕ в events; креды только `op://`+`$ENV`; команды argv, не eval. Работа на ветке `redwork/<slug>`; один run/repo (lock).

## Self-test
`bash ~/.claude/skills/redwork/lib/test-redwork.sh` — state/events/risk-classify/escalate/config.

## Статус
**MVP-скелет: либы готовы и протестированы; оркестрация (этот SKILL) + commands — каркас.** НЕ обкатан на реальном прогоне. Перед доверием проду — первый прогон на безопасном репо (закрыть empirical-остаток из DESIGN-mvp.md: корректность smoke-гейта, build_sha-gating, op-run-инъекция).

# redwork — MVP spec v3 (после plan-review #1+#2; архитектурные critical закрыты, готов к сборке)

Оркестратор полного цикла задачи: implement→test-gate→finalize→deploy→post-verify. Тонкая стейт-машина
(как redloft гоняет стадии), **переиспользует** существующие команды (`plan-panel`/`/finalize`/`audit-site`/
`run`/`verify`/`tracker`). Драйв `/loop` self-paced, резюм из state.json. MVP = Phase 2–6 (план — вход).

Статус замысла: 2 раунда plan-review. Раунд 1 → закрыты state-versioning, concurrency, secrets-в-state,
идемпотентность, SHIP↔артефакт. Раунд 2 → закрыты command-surface, two-phase-deploy/TOCTOU, machine-contracts,
output-capture-secrets, retention-инвариант, reason_code-enum. Остаток = implementation-DoD (→/finalize при
сборке) + empirical-unknown (→первый реальный прогон на стенде). Маркер `[IMPL-DEFAULT]` = числовой дефолт, тюнится в коде.

## Цель
Убрать ручное «держание» конвейера. Человек — только на реальных развилках. Понятные задачи идут до прода сами.

## Инвокация
`/redwork <задача | CPMO-id | @plan.md> [--repo <path>] [режим 1|2|3] [--auto-deploy]`. Режим из NL, default 2.

## Режимы (default 2)
1 «аккуратный» (✋ на каждой границе); 2 «мягкий» (авто→✋dev→авто→✋прод); 3 «автопилот» (всё сам, человек только эскалация-по-сомнению + high-risk деплой). **Эскалация-по-сомнению — safety floor во всех режимах.**

## State.json (single source of truth)
`schema_version:1`; read-policy `>KNOWN_MAX→abort`, `<current→migrate|reject`; **миграции**: `lib/migrations/state-v{N}-to-v{N+1}.sh`, вызывает orchestrator при старте/resume, бэкап перед migrate, `<N-2→reject`. ВСЕ записи только `jq --arg/--argjson` (task с кавычками/newlines; iterations строго int). Поля: schema_version, slug, task, repo, mode, branch, phase, phase_status, risk_class, lock{pid,at,ttl_sec}, verdicts{plan, finalize_pre{verdict,build_sha}, finalize_post{verdict,build_sha}}, deploy_intent{id,status:pending|deployed|rolled_back}, live_verify_dod[{check,type,passed}], blocked_on null|{reason_code,needs}, iterations, budget{llm_calls}.
- **Concurrency:** project-lock «один run/repo» (mkdir-страж + lock{pid,at,ttl_sec} + stale-reclaim, checkpoint.sh §10.3); 2-й → exit с сообщением. Уникальная ветка `redwork/<slug>` — **HEAD ветки меняет только redwork** (база закрытия TOCTOU).

## events.jsonl — observability-хребет (machine-contract)
Рядом со state, **append-only, strip-гейт + validate_no_secrets на КАЖДЫЙ append**. **НЕ писать raw stdout/stderr** команд — только `{exit_code, summary}` где summary = strip(первые N байт), strip = keyword-regex + энтропийный детектор. `payload_summary` — **типизированный union per event_type**:
- `phase_start|phase_done`: {phase, verdict?}
- `gate_result`: {gate, exit_code}
- `smoke_result`: {observed_status_code, match:bool, expected_status_code}  ← обязательные поля
- `deploy|rollback`: {intent_id, exit_code}
- `escalation`: {reason_code}
**Retention-ИНВАРИАНТ** (не параметр): events.jsonl не pruned пока `phase!=DONE` или `blocked_on!=null`; lazy GC `lib/gc.sh` при старте run; числовой TTL/max_entries = `[IMPL-DEFAULT]`.

## Драйвер
`/loop` self-paced: тик `redwork-step` → state → фаза → state → `blocked_on`→эскалация+стоп; иначе дальше. Таймауты `[IMPL-DEFAULT] max_phase_minutes`, `wait_for_human_timeout_hours`; budget `[IMPL-DEFAULT] max_llm_calls=20` → `BUDGET_EXCEEDED`-эскалация.

## Фазы (Done when)
- **P2 Implement** (авто, по шагам плана): шаг→правки→локальный гейт `typecheck+lint exit 0`→следующий. **Baseline:** typecheck+lint снимаются ДО P2 (`BASELINE_LINT_BROKEN`→эскалация, чтобы не приписать чужие ошибки). **Done when:** все шаги реализованы, typecheck 0, lint 0. Эскалация: неоднозначность/продуктовое.
- **P3 Test-gate**: gates(config|detect-gates)+e2e+smoke(staging)+audit-site(фронт). Красное→`finalize.stabilize`(≤3,regression-guard,no-suppression). **regression-guard:** diff passed/failed/**skipped** vs baseline — рост skipped = suppression = регрессия. **Done when:** gates exit 0 + e2e pass-rate ≥ `[IMPL-DEFAULT 0.8]` (или из конфига). Эскалация: fixer не сошёлся/регрессия/заглушка.
- **P4 Finalize-pre**: `/finalize`→SHIP? FIX-FIRST→автофикс≤N→re-finalize. Пишет `finalize_pre={verdict,build_sha=HEAD}`. pending_live_verify→live_verify_dod[] в P6. **Done when:** verdict=SHIP. Эскалация: не SHIP после N (`sha_mismatch` loop-guard N=2).
- **P5 Deploy** (стоячий гейт, **two-phase commit**): risk-классификатор. Пред-условия: rollback валиден; smoke-spec полна. **Шаги:** (1) `deploy_intent{id,status:pending}` → events (tmp→mv) ДО вызова; (2) **re-read HEAD, assert ==build_sha** (TOCTOU-минимизация; ветка изолирована); (3) вызов через **argv, не shell-строку**: `op run --env-file=<(...op://...) -- <deploy.argv>` (нет eval/`sh -c "$var"` → нет инъекции); (4) success→`status:deployed`; (5) smoke `{cmd,expected_status_code,expected_response_contains}` (все обязательны; наблюдаемый результат, не голый exit 0; `-v` запрещён). Зелёное→proceed; красное→auto-rollback(+events)+эскалация. **Resume при pending-без-success → эскалация (не авто-редеплой).** low+(--auto-deploy|режим3)→авто; medium/high→человек. **Done when:** status=deployed И smoke pass. Таймауты на deploy/smoke/rollback.
- **P6 Post-verify**: прод-smoke + прогон live_verify_dod[] + `/finalize` на проде (finalize_post). **Автофикс на проде ЗАПРЕЩЁН (escalate_always).** Инвариант: `live_verify_dod[]` непуст (пусто→прод-smoke единственный обязательный + ACK). **Done when:** все live_verify_dod[] passed=true + прод-smoke pass. Чисто→DONE (tracker-done+ledger+отчёт). Мониторинг: `monitoring.signals` (обяз. `error_rate_5xx`, `p95_latency` + пороги); P6 ждёт `post_deploy_watch_minutes`, нарушение порога→эскалация.

## Risk-классификатор + safety-floors
Консервативно unknown=high. **NON-OVERRIDABLE floor-globs** (юзер только усиливает через `add_human_globs`): `**/migrations/**`, `**/auth/**`, `**/*payment*`, `**/*.pem`, `**/*.key`, `.env*`. high: floor-globs/scope-теги. дифф>`[IMPL-DEFAULT] max_auto_files=20`→≥medium. иначе low. low→авто-деплой; medium/high→человек (режим3 high пингует). migrations+нет rollback+risk≥medium→блок. режим3+high→деплой только после ACK (нет→HOLD).

## Command-surface security (.redwork.json)
- `deploy/rollback/smoke.cmd` — **argv-массив** (`["bash","deploy.sh","apply","master"]`), НЕ shell-строка → нет инъекции. Если строка — lint reject метасимволов `; | && $( \` > <` в той же фазе, что и cred-lint.
- **Cred-lint:** литералы `token=/password=/secret=` → отказ. Креды только `$ENV`+`env:["DEPLOY_TOKEN=op://AI-Tokens/.../credential"]`, инъекция `op run` снаружи в P5.
- **Config-integrity:** `.redwork.json` должен быть git-tracked и не-modified на момент run (иначе эскалация) — защита от подмены команд в рантайме.

## .redwork.json (форма)
gates(auto|list), e2e{cmd,pass_threshold}, staging{url:null}, deploy{argv,env[op://],smoke{cmd,expected_status_code,expected_response_contains},rollback{argv,timeout_sec,on_failure_action,max_manual_rollback_wait_minutes},timeout_sec}, risk{add_human_globs,max_auto_files}, monitoring{alert_channels,signals,post_deploy_watch_minutes}. Без файла→detect-gates+спросить deploy один раз. **staging.url=null→** smoke=skipped(+warning), деплой-инвариант на local/docker-smoke при low, **режим3→2 для P5**.

## Эскалация (3 канала, строгая схема, без секретов)
`lib/escalate.sh` принимает ТОЛЬКО `{slug,phase,reason_code(enum),needs:[{need_type,detail_code}],run_path,ts}` — без command-output/PII/task-текста. `need_type` детерминирован из `reason_code`. **Per-channel strip перед каждым каналом.** push+TG `@rltimebot`+Трекер(если CPMO-id). per-channel timeout, «доставлено ≥1»=успех иначе локальный лог+retry. `/redwork-resume {slug,human_decision:approve|reject|answer,answer?}`.

## Machine contracts (границы компонентов)
Adapter-обёртки (`lib/adapters/<skill>.sh`) для finalize/audit-site/tracker/plan-panel возвращают `{exit_class: ok|infra_error|verdict_fail, verdict?, artifacts_path, machine_summary}` — **infra-error отличается от verdict-fail** (infra→retry/escalate, не «провал ревью»). `live_verify_dod:[{check,type,passed}]` — общий формат P4→P6.

## Инварианты безопасности
Деплой только SHIP И `HEAD==build_sha` И зелёный smoke(наблюдаемый). medium/high никогда не авто; floor-globs неотключаемы. rollback валиден до деплоя; провал rollback→circuit-breaker (`on_failure_action`, `max_manual_rollback_wait`)→`needs[manual_rollback]`+эскалация. P5/P6 идемпотентны (two-phase + intent); P6-автофикс запрещён. Все записи→validate_no_secrets+strip; только op://-ссылки/env-имена; raw stdout/stderr НЕ в events. Команды — argv, не eval. Работа на ветке; необратимое→events.

## Остаток — классификация судьи
- **implementation-DoD (→/finalize при сборке):** числовые `[IMPL-DEFAULT]` (таймауты, e2e-порог, max_auto_files, max_llm_calls, TTL), точная операционализация regression-guard, формат отчёта DONE, lifecycle веток.
- **empirical-unknown (→первый реальный прогон на стенде, НЕ панель/finalize):** корректность smoke-гейта (краснеет ли на реально сломанном проде), build_sha-gating под git-дрейфом, поведение `op run`-инъекции на проде.
- **future (next iteration):** Phase 1 интейк/ресерч, post-deploy watch-фаза P7, расширенные deploy-адаптеры, DR-backup.

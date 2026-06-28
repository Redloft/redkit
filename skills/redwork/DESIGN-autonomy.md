# redwork — PROD-AUTONOMY CONTRACT (расширение P5, spec v2 — после plan-panel #1)

Расширяет `DESIGN-mvp.md` (v3) §P5_deploy. Даёт redwork режиму 3 право катить на прод **без ручного «да»** —
но только за машинно-проверяемым контрактом, который СИЛЬНЕЕ ручного решения. Любой непройденный критерий →
откат к человеку (эскалация). Строгий супермножество безопасности, не ослабление.

**Статус:** plan-panel раунд 1 (6 ролей, NEEDS-WORK@0.86, единогласно, конфликтов по существу нет). v2 закрывает
4 архитектурных critical-кластера (watcher-супервизор, rate-limit integrity, межфазовое TOCTOU, watch-state SoT) +
gap «integrity≠authorization» + фазирование/exit-контракт/SSRF. Эмпирику (C1 SSH+opcache, D2 signals на bare-metal)
спека ЯВНО выносит на staged live-verify — не закроет ни панель, ни /finalize.
**Phase A РЕАЛИЗОВАН (2026-06-28):** `lib/defaults.sh` + `lib/autonomy-gate.sh` (детерминированный гейт A∧B∧¬E, fail-closed,
трёхзначный exit 0/1/2). Хермётичный gate-шейкдаун 21/21: all-pass→auto ТОЛЬКО при полном валидном контракте (с реальным
SSH-подписанным коммитом owner'а), блокировка на каждом из 15 критериев по отдельности, инвариант fail-closed держит.
Деплой в Phase A всё ещё human (shadow-mode). Phase B/C (autodeploy + watch+супервизор) — не реализованы.

## Контекст и решения owner'а (вшиты)
- **PROD-SAFETY-закон амендится**: прод-запись = явное «да, катим»+diff ИЛИ удовлетворённый autonomy-контракт в owner-scope. Коммит контракта owner'ом = pre-approval. Закон расширен, не отменён.
- **Старт-scope: любой low-risk diff** внутри scope-globs (код включительно, КРОМЕ floor-globs).
- Базис: redwork v3 (two-phase commit, TOCTOU build_sha, argv-exec, command-surface security, machine-contracts, floor-globs, эскалация без PII, events.jsonl типизированный).

## Принцип
`auto = A(авторизация) ∧ B(готовность) ∧ C(обратимость) ∧ D(верификация) ∧ ¬E(floor)`. ВСЕ зелёные → автодеплой.
Хоть один промах/неизвестность → `DEPLOY_NEEDS_HUMAN{failed[]}` с точными критериями. **Fail-closed везде.**
Гейт — детерминированная чистая функция (`lib/autonomy-gate.sh`), без LLM, хермётично тестируема.

## Threat model (11 векторов)
1. Подмена авторизации → integrity (A0) + МЕТА-правило A4 (VOID если diff трогает autonomy/`.redwork.json`/floor).
2. **TOCTOU контракта (gate↔invoke)** → §TOCTOU: re-check `autonomy_sha` + `build_sha` непосредственно перед invoke.
3. Scope-creep → ВСЕ changed-files ∈ scope (all, не any).
4. Мёртвый rollback → C1 валидация ДО деплоя.
5. Деплой на сломанный прод → C3 health GREEN ДО.
6. **Watcher умер** → §Watcher-супервизор: durable вне-сессионный супервизор + heartbeat + fail-safe rollback.
7. **Runaway-петля / rate-limit fail-open** → §Rate-limit integrity: flock + счёт по deployed-событиям + fail-closed + runtime kill-switch.
8. Утечка секрета → §Cred-lint: argv-скан + events field-whitelist + op:// pre-check.
9. Тихий автокат мимо owner → E3 постфактум-нотификация (durable пол).
10. Гетероскоуп risk → два независимых сигнала (B1+B2).
11. **Integrity≠authorization** (gap#2) → §Authorization-root: подписанный коммит / owner-allowlist, иначе fail-closed.

---

## A. Авторизация — `.redwork-autonomy.json`
- **A0 (integrity):** git-tracked И не-modified/не-staged (`git diff HEAD --quiet`). НЕ-git репо → autonomy запрещена.
- **A0′ (authorization-root, gap#2):** integrity доказывает «не подменён в рантайме», НЕ «owner это написал». MVP-корень доверия: **последний коммит, тронувший autonomy-файл, ОБЯЗАН быть verified-signed** (`git verify-commit HEAD-for-path` зелёный) И автор ∈ pinned `owners[]` (в самом файле, но валидируется против подписи, не против себя). Подпись недоступна на хосте → autonomy disabled (fail-closed), не «доверяем git-tracked». GPG/SSH-signing — обязателен для MVP, не future.
- **A1 (enabled):** `{ autonomy:"enabled", owners:["<id>"], approved_at, version:1 }`. Отсутствие/`disabled` → human.
- **A2 (scope):** `scope:{ globs[], max_files:N>0, branches[], windows[{tz,days,from,to}], max_deploys_per_window:M>0 }`. Пустой glob/≤0 число → human.
- **A3 (in-scope):** все changed-files ⊆ globs; count ≤ max_files; ветка ∈ branches; время ∈ window; deploy_count_window < M (см. §Rate-limit); kill_switch off (оба: git-флаг И runtime-файл).
- **A4 (МЕТА-правило):** diff ∩ {autonomy-файл, `.redwork.json`, floor-globs} ≠ ∅ → autonomy VOID → human (нельзя автокатить изменение собственной авторизации/конфига).
- **A5 (require-блок):** `require:{ rollback_validated:true, prebackup:true|"n/a", prod_health_green:true, watch_minutes:N≥5, signals[], target, supervisor:"systemd"|"launchd"|"cron" }`. Любое false/missing обязательное → human.

## B. Готовность (два независимых сигнала)
- **B1:** `finalize_pre.verdict==SHIP` И `HEAD==finalize_pre.build_sha` И finalize_pre без high-severity findings.
- **B2:** `risk-classify`=low (floor hard-block независимо от контракта — E1).
- **B3:** P3 полностью зелёный: gates exit 0, e2e ≥ порога, regression-guard (skipped не вырос = no suppression).

## C. Обратимость (доказать ПЕРЕД риском)
- **C1 (rollback validated):** rollback argv настроен И провалидирован до деплоя. ⚠️ **EMPIRICAL для SSH+opcache** (см. §Эмпирика): MVP-валидация = доказанное наличие prev-good-SHA (`git rev-parse <prev>` существует И был ранее deployed по events) + dry-run если идемпотентна; корректность реального ff+opcache-reset — на staging. `rollback_validated_at` ts пишется в state как precondition.
- **C2 (restore point):** `prebackup:true` → снять restore-point ДО деплоя, id в state; `"n/a"` ТОЛЬКО для declared-stateless. Провал снятия → human.
- **C3 (prod health green ДО):** health-URL зелёный baseline ПЕРЕД деплоем. Красный → `PROD_UNHEALTHY_PREDEPLOY` human.

## D. Верификация
- **D1 (smoke полный, hardened):** наблюдаемый статус И тело против РЕАЛЬНОГО прод-URL. **curl-allowlist-шаблон**: только `--max-time`, `-fsS`, `--data-urlencode`, cache-busting header; **запрет** `-v/-i/--trace/-o`. `expected_status_code` + `expected_response_contains` (AND-список строк) оба обязательны. **SSRF-allowlist на target**: запрет `127./10./169.254./localhost/*.metadata` (защита от внутреннего pivot).
- **D2 (post-deploy watch + супервизор):** см. §Watcher-супервизор. После зелёного smoke — watch на `watch_minutes`, poll `signals`. Нарушение порога ИЛИ stale heartbeat → auto-rollback + эскалация.
- **D3:** только после чистого watch → DONE.

## E. Floor — неотключаемо, НАД контрактом
- **E1:** floor-globs (`migrations/auth/payment/.pem/.key/.env`) → всегда человек. Floor-классификатор НЕЗАВИСИМ от контракта (две проверки, обе обязаны пропустить).
- **E2 (эскалация-по-сомнению):** infra-error адаптера, missing обязательное поле, любая неоднозначность → human. Fail-closed.
- **E3 (audit + постфактум):** каждый автодеплой → типизированный event-trail + **обязательный** push/TG owner'у постфактум (durable-лог = пол; провал нотификации логируется, но деплой уже в events).

---

## §Watcher-супервизор (critical #1) — durable вне-сессионный
Проблема: в session/loop-модели если сессия умирает (SSH-disconnect, краш) во время watch — никто не ловит регрессию, прод остаётся deployed-но-неверифицированным.
- **Компонент `lib/watch-supervisor.sh`** — идемпотентный, читает run-state, проверяет: (1) `now > watch_until`? → finalize watch (чисто → DONE); (2) signals breached? → auto-rollback + escalate; (3) heartbeat не stale? Запускается **вне сессии**: `systemd-transient`/`launchd`/`cron` (поле A5 `supervisor`), переживает смерть /loop.
- **Heartbeat-контракт:** watch-петля (в сессии ИЛИ в супервизоре) пишет `autonomy.watch.heartbeat_at` каждые ≤`[IMPL-DEFAULT 30s]`. Супервизор: `now − heartbeat_at > [IMPL-DEFAULT 90s]` → watcher мёртв → **fail-safe auto-rollback + escalate** (НЕ молчаливый проход).
- **Host:** супервизор на orchestrator-хосте (где крутится redwork), poll прод-signals удалённо.
- **Degraded-mode (fail-closed):** на хосте нет ни одного из {systemd,launchd,cron} → autonomy НЕ разрешена (gate→human). Супервизор — hard precondition, не опционален.
- **Каскад (gap#3):** rollback тоже упал → терминальное состояние `PROD_UNRECOVERABLE` + `needs:[manual_rollback]` + circuit-breaker (v3 `on_failure_action`, `max_manual_rollback_wait`); супервизор больше НЕ ретраит, держит эскалацию.

## §Rate-limit integrity (critical #2) — fail-closed
- **deploy_count_window** считается ТОЛЬКО по `deploy`-событиям с `exit_code==0` (фактически deployed), не по intent-pending.
- Чтение events.jsonl под **flock + project-lock** (как append в v3); денормализованный счётчик в `state.json` (atomic tmp→mv) для O(1).
- **Fail-closed:** truncation/read-error/parse-fail → счётчик трактуется как `=M` (лимит исчерпан) → human. Никогда не fail-open.
- **Runtime kill-switch:** не-git файл `.redwork-killswitch` (gitignored), проверяется в watch-петле И перед КАЖДЫМ деплоем; `touch` = немедленный auto-rollback/HOLD. (git-флаг `kill_switch` — медленный декларативный; runtime-файл — быстрый.)

## §Межфазовое TOCTOU (critical #3)
Зазор: gate прочитал autonomy-файл на решении, но он мог измениться к моменту two-phase invoke.
- **Re-check ПЕРЕД invoke** (симметрично v3 `HEAD==build_sha`): `autonomy_sha = git rev-parse HEAD:.redwork-autonomy.json` зафиксирован на gate-решении; перед invoke re-read → mismatch → `TOCTOU_BREACH` → human (откат P5, не деплой).
- Тот же re-check для `.redwork.json` (deploy-механика).

## §Watch-state — единый источник правды (critical #4, конфликт arch↔backend↔data)
- **Сэмплы** (durable, audit) → `events.jsonl` append-only (integrity, защита от grow-only corruption через retention v3).
- **Агрегат** (real-time решения гейта) → `state.json`: `autonomy.watch.{last_sample, count, max, approx_p95, breached}`, atomic tmp→mv, O(1).
- Зафиксировано в Инвариантах. Гейт/супервизор читают агрегат; пост-мортем — из events.

## §Constants / defaults (warning, блокирует hermetic-тест)
- Все числовые дефолты — в `lib/defaults.sh` (единая секция): `watch_minutes`, `max_deploys_per_window`, `heartbeat_interval=30s`, `heartbeat_stale=90s`, `health_poll`, `signal_poll`, `restore_point_id_format`.
- **AC:** `autonomy-gate.sh` ОТВЕРГАЕТ контракт при missing/≤0 числовом обязательном поле (fail-closed). Это делает гейт хермётично-тестируемым.

## §Гейт — `lib/autonomy-gate.sh` (трёхзначный exit-контракт)
```
autonomy-gate.sh decide <run_dir> <repo> <changed_files_file>
  → JSON { decision:"auto"|"human", failed:[{criterion,detail}], passed:[] }
  exit 0  = решение принято (читай .decision)
  exit 1  = infra_error (→ human, fail-closed)
  exit 2  = floor-нарушение (→ human, отдельный машинный класс для P5)
```
Чистая функция: читает state.json, autonomy-файл, `.redwork.json`, changed-files, events.jsonl. НЕ сеть/деплой. Перечисляет ВСЕ провалы (не short-circuit). `decision:auto` ⟺ failed пуст И exit 0.

## §Интеграция в P5 + фазирование (warning #9)
**Фазы реализации (≥3 shippable, degraded-default fail-closed — нет фазы → автодеплой невозможен):**
- **Phase A (gate-only):** `autonomy-gate.sh` + constants + A/B/E-критерии. Деплой всё ещё human, но решение гейта логируется (shadow-mode — собираем, сравниваем с ручным «да»).
- **Phase B (+autodeploy в scope):** gate=auto → two-phase (v3) → hardened smoke → DONE без watch. Только для declared-stateless/мгновенно-обратимых.
- **Phase C (+watch+супервизор):** D2 watch + watcher-супервизор + runtime kill-switch. Полная автономия.
- Migration-contract: state.json `schema_version` bump → `lib/migrations/`; autonomy `version>1` → human (новая версия контракта требует ре-апрува).

P5-поток: `risk=low? ├ режим1|2 → human ├ режим3 → gate decide → auto→[two-phase→smoke→(Phase C: watch)→DONE] / human→escalate DEPLOY_NEEDS_HUMAN{failed[]}; medium|high → human всегда`. Gate ПЕРЕД two-phase как доп. предусловие.

## §Cred-lint enforcement (warning #8)
argv deploy/rollback regex-скан на литералы `token=/password=/secret=`; events.jsonl **field-whitelist** (forbidden `stdout/stderr/output/raw`); TG-сообщение только из whitelisted метаданных; op:// secret pre-check как blocker до деплоя.

## §LLM-budget в autonomy-loop (gap#3)
Watch-петля — **детерминированная** (poll signals, без LLM) → cost≈0. Любой LLM-вызов в autonomy-пути инкрементит v3 `budget.llm_calls`; `> [IMPL-DEFAULT]` → `BUDGET_EXCEEDED` escalate. Watch не должен звать LLM вообще (инвариант).

## state.json — добавки
`autonomy:{ decision, target, passed[], deploy_count_window, rollback_validated_at, restore_point_id?, autonomy_sha, watch:{started_at, watch_until, heartbeat_at, last_sample, count, max, approx_p95, breached} }`. jq-safe writes. schema_version bump → migration.

## Инварианты (НЕ нарушать)
- Автодеплой ⟺ ВСЕ A∧B∧C∧D зелёные И ¬E. Любой промах/неизвестность → human (fail-closed).
- Авторизация = подписанный коммит owner'а (A0′), не просто git-tracked. Нельзя автокатить изменение autonomy/`.redwork.json`/floor (A4).
- Floor независим от контракта (E1). Rollback доказан ДО (C1). Прод здоров ДО (C3).
- Re-check autonomy_sha+build_sha перед invoke (§TOCTOU). Rate-limit fail-closed (§Rate-limit). Kill-switch: git+runtime.
- Watcher-супервизор durable вне сессии; смерть watcher → auto-rollback (heartbeat fail-safe). Нет супервизора → нет автономии.
- Watch-сэмплы→events, агрегат→state (SoT). Watch без LLM. Каждый автодеплой виден owner'у постфактум (E3).
- Секреты только op://+$ENV argv; raw НЕ в events.

## Остаток — классификация судьи
- **implementation-DoD (→/finalize при сборке):** числовые дефолты в `lib/defaults.sh`, exit-коды, cred-lint regex, restore-point id format, точный migration-скрипт.
- **empirical-unknown (→ staged live-verify на staging, precondition `rollback_validated_at`; НЕ панель/finalize):** C1 SSH+opcache rollback (opcache-кэш × прокси-success smoke × нагрузка); D2 signals на bare-metal nginx TOM1 — **p95 убран из MVP** (требует external APM), минимальный viable signal = tail `nginx access.log` → 5xx-rate; реально ли auto-rollback успевает при breach.
- **repo-specific (config-time):** deploy/rollback/health доктрины сайта (`ai/<slug>-prod` ff-only по SSH + opcache) — в `.redwork.json`/контракте при подключении репо.
- **future:** ML-слой риск-оценки поверх детерминированного; canary/percentage-rollout; внешний APM для p95.

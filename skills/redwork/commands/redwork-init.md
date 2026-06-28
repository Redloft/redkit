---
description: Онбординг проекта под redwork — детект стека + опрос доктрины деплоя → генерация проектного конфига (CLAUDE.md §redwork + .redwork.json + опц. autonomy)
---

# /redwork-init [--repo PATH] [--autonomy]

Первый запуск redwork на проекте: адаптировать оркестратор под ЭТОТ проект (dev/prod/ветки/git/деплой/откат).
Полный протокол — `~/.claude/skills/redwork/ONBOARDING.md`. Идемпотентен: артефакты есть и согласованы → summary, no-op.

## Что делает (5 шагов ONBOARDING.md)
1. **DETECT** — стек/гейты (package.json/composer/pyproject/Makefile), git (remote, ветки, подписи), прод-следы (CI, Dockerfile, nginx, deploy-скрипты) → черновик. **🔑 repo-layout:** классифицировать git-слои (code vs config/governance vs deploy-target) + **web-served-root** проба (`curl https://<prod>/.gitignore`→200?). Публичный корень / отдельный config-слой → **out-of-tree** (НЕ класть `.redwork.json` в code-repo, иначе утечёт). См. ONBOARDING.md §Out-of-tree + §DETECT.
2. **INTERVIEW** — спросить ОДИН раз только невыводимое: прод host/path/деплой-ритуал/opcache/URL/smoke-маркер; откат; ветки dev/prod-конвенция; режим по умолчанию; нужен ли автодеплой (+scope/floor/окна/supervisor); op://-секреты деплоя.
3. **GENERATE (авто)** — config-слой по DETECT-локации: in-tree → `<code-repo>/.redwork.json`; **out-of-tree/web-served → АВТО governance-репо `${REDWORK_OPS_DIR:-~/ops}/<project>/`** (git init + `.redwork.json`+`.redwork-autonomy.json`+`REDWORK.md`). `owners` авто из `git config user.email` (+сверка с allowed_signers). CLAUDE.md: in-tree → полная секция; web-served → минимальный непубличный указатель. `.gitignore += .redwork-killswitch`.
4. **VERIFY** — `config.sh lint` + `resolve` (из ожидаемого слоя); не-утечка (web-served: curl dotfile→не-200); реально-трекается (check-ignore); rollback-валидация; `autonomy-gate.sh decide` в shadow; консистентность §redwork ↔ JSON.
5. **COMMIT (авто)** — redwork-init делает **подписанный** коммит сам (`git commit -S` в cfg_top); запуск init'а owner'ом с его ключом = pre-approval (A0′ = «контракт подписан ключом owner'а»). **Verify-гейт:** `verify-commit HEAD` обязан пройти, иначе autonomy НЕ включается (откат на `disabled` + как настроить signing). Без настроенной подписи — `.redwork-autonomy.json` не создаётся.

## Самообучение
Init **самообучается**: на DETECT зовёт `onboarding-kb.sh suggest "<стек>"` → пред-заполняет опрос дефолтами от похожих ранее онбордённых проектов (меньше вопросов со временем); после успешного COMMIT — `onboarding-kb.sh record` с САНИТИЗИРОВАННЫМ архетипом (только shape: стек+классы механизмов, без host/path/url/имён). База локальна (`knowledge/archetypes.jsonl`), в публичный redkit не синкается. Детали — `ONBOARDING.md` §Самообучение.

## Правила
- Секреты — только `op://`+`$ENV`, никаких литералов (cred-lint reject).
- deploy/rollback.cmd — **argv-массив** (ssh+remote-string безопасен: метасимволы внутри элемента, не парсятся локально).
- `--autonomy` форсит генерацию autonomy-контракта; без флага — спросить «нужен ли автодеплой».
- floor (migrations/auth/payment/.pem/.key/.env) — неотключаем, в шаблон не выносится.
- Без `--repo` — текущий cwd (должен быть git-репо; не-git → autonomy запрещена, обычный режим можно).

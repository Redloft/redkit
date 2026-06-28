---
description: Онбординг проекта под redwork — детект стека + опрос доктрины деплоя → генерация проектного конфига (CLAUDE.md §redwork + .redwork.json + опц. autonomy)
---

# /redwork-init [--repo PATH] [--autonomy]

Первый запуск redwork на проекте: адаптировать оркестратор под ЭТОТ проект (dev/prod/ветки/git/деплой/откат).
Полный протокол — `~/.claude/skills/redwork/ONBOARDING.md`. Идемпотентен: артефакты есть и согласованы → summary, no-op.

## Что делает (5 шагов ONBOARDING.md)
1. **DETECT** — стек/гейты (package.json/composer/pyproject/Makefile), git (remote, ветки, подписи), прод-следы (CI, Dockerfile, nginx, deploy-скрипты) → черновик.
2. **INTERVIEW** — спросить ОДИН раз только невыводимое: прод host/path/деплой-ритуал/opcache/URL/smoke-маркер; откат; ветки dev/prod-конвенция; режим по умолчанию; нужен ли автодеплой (+scope/floor/окна/supervisor); op://-секреты деплоя.
3. **GENERATE** — секция `## redwork` в `CLAUDE.md` проекта (source of truth, нарратив) + `.redwork.json` (машинный: deploy.cmd argv, smoke полный, rollback) + опц. `.redwork-autonomy.json` (контракт v2) + `.gitignore += .redwork-killswitch`.
4. **VERIFY** — `config.sh lint`; rollback-валидация; `autonomy-gate.sh decide` в shadow на пробном диффе (показать решение, человек НЕ катит); консистентность §redwork ↔ JSON.
5. **COMMIT** — человек ревьюит и коммитит САМ; `.redwork-autonomy.json` — **подписанным** коммитом (pre-approval, A0′). redwork конфиг автономии автономно не коммитит.

## Правила
- Секреты — только `op://`+`$ENV`, никаких литералов (cred-lint reject).
- deploy/rollback.cmd — **argv-массив** (ssh+remote-string безопасен: метасимволы внутри элемента, не парсятся локально).
- `--autonomy` форсит генерацию autonomy-контракта; без флага — спросить «нужен ли автодеплой».
- floor (migrations/auth/payment/.pem/.key/.env) — неотключаем, в шаблон не выносится.
- Без `--repo` — текущий cwd (должен быть git-репо; не-git → autonomy запрещена, обычный режим можно).

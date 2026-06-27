# START HERE — как работать над {{PROJECT_TITLE}}
<!-- EN: How to work on this project. Read this first (1 minute). -->

> Проект ведётся по простой методологии. Прочитай за минуту — и работай по циклу ниже.
> _This project follows a lightweight methodology. Read once, then follow the loop._

## 0. Один раз при старте · One-time setup
1. Прочитай `CLAUDE.md` (что за проект, стек {{STACK}}) и `docs/HARD-RULES.md` (правила — их нельзя нарушать).
2. Применил `supabase/rls-bootstrap.sql`? Без него БД открыта. Сделай **до первого деплоя**.
3. Глянь `docs/tasks/pending/` — там уже лежат задачи по разделам сайта.

## 1. Рабочий цикл — повторяй для каждой задачи · The loop
```
 ┌─ Берёшь задачу из docs/tasks/ready/         (пусто? → §2)
 │     ↓
 │  Создаёшь ветку (НЕ работаешь в main/dev) → задачу в in_progress/
 │     ↓
 │  Делаешь по описанию задачи
 │     ↓
 │  Прогон /finalize (typecheck + lint + build + ревью). Красное — чинишь, НЕ коммитишь.
 │     ↓
 │  Коммит только нужных файлов: git add <конкретные пути>  (не git add .)
 │     ↓
 └─ Задачу в done/. Берёшь следующую.
```

## 2. Новая задача / идея · New task
1. Создай файл в `docs/tasks/pending/` по `docs/tasks/TASK-TEMPLATE.md`.
2. Готова к работе? Перенеси в `ready/` — это и есть «одобрено» (approval gate).
   Пока в `pending/` — в работу не берём.

## 3. Чего нельзя · Never (полное — в docs/HARD-RULES.md)
- ❌ пушить прямо в `main`/`dev`  ·  ❌ `git add .` вслепую  ·  ❌ ослаблять typecheck/lint/build
- ❌ секреты в код/`.env` — только 1Password  ·  ❌ деплой без RLS deny-by-default

## 4. Улучшил сам процесс? · Improved the process?
<!-- BEGIN TIER-2 -->
Запиши короткую заметку в `docs/methodology-proposals/` — методология растёт вместе с проектом.
<!-- END TIER-2 -->
<!-- BEGIN TIER-1-ONLY -->
Заметь это в коммит-месседже или в `README.md` — на Tier 1 отдельного журнала ещё нет.
<!-- END TIER-1-ONLY -->

<!-- BEGIN TIER-2 -->
## 5. Несколько направлений сразу · Multiple workstreams
Каждое направление/сущность ведёшь отдельным planning-чатом — реестр в `docs/chats/REGISTRY.md`,
передача между чатами через `docs/chats/handoff-queue.md`.
<!-- END TIER-2 -->

<!-- BEGIN TIER-3 -->
## 6. Прод и поддержка · Production & maintenance
Quality Gates — `docs/security-quality-gate.md` / `docs/performance-quality-gate.md`.
Авто-мерж зелёных веток — `.github/workflows/auto-merge.yml`.
<!-- END TIER-3 -->

<!-- BEGIN TIER-4 -->
## 7. Длинные цели и большой код · Long goals & large codebase
Многосессионная цель → `docs/goal-pursuit.md` (цель = проверяемое условие, `.goal/`).
База разрослась → `docs/codegraph-setup.md` (структурные запросы вместо grep).
<!-- END TIER-4 -->

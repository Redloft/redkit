# Hard Rules — {{PROJECT_NAME}}
<!-- EN: Non-negotiable rules, grouped into 6 clusters (MP-028). Text is the contract, grouping is for scanning. -->

> Правила, которые **нельзя нарушать**. Сгруппированы в 6 кластеров для быстрого чтения.
> _Non-negotiable. If a change breaks a rule — stop and reconsider, don't work around it._

## A. Branch & Commit safety · Ветки и коммиты
- **A1** Никогда не коммить/пушить напрямую в `main` или `dev`. Только через рабочую ветку + PR.
  _Never commit/push directly to `main`/`dev`. Work on a branch._
- **A2** Коммить **конкретные пути** (`git add path/to/file`), не `git add .` / `git add -A`.
  Это исключает попадание мусора и секретов в коммит. _(pathspec commits)_
- **A3** Перед коммитом проверь, что ты на правильной ветке (`git branch --show-current`). _(branch verify)_

## B. Approval & Workflow · Одобрение и поток
- **B1** Задача идёт в работу только из `docs/tasks/ready/`. `pending/` = ещё не одобрено.
- **B2** Каждая нетривиальная задача описана по `docs/tasks/TASK-TEMPLATE.md` до старта.

## C. Quality Gates · Качество
- **C1** Не ослаблять `typecheck` / `lint` / `build` ради «чтобы прошло». Чинить причину.
- **C2** Перед коммитом — зелёный `/finalize` (typecheck + lint + build + ревью diff).
- **C3** Без `any` в TypeScript; правки UI — responsive (mobile + desktop).

## D. Code & Design Conventions · Код и дизайн
- **D1** Новый/изменённый UI-компонент — по существующей дизайн-системе (токены, не хардкод).
- **D2** Соблюдай конвенции окружающего кода (нейминг, структура, плотность комментариев).

## E. Build/Automation Boundaries · Границы автоматики
- **E1** Автоматические правки (если есть) ограничены trivial-фиксами; не трогают бизнес-логику без задачи.

## F. Security · Безопасность (project-seeded)
{{SECURITY_RULES}}

<!-- redloft: F-кластер засеян из security-findings проекта (DR-7). -->

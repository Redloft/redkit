# R2 — Scenario Runner (routine) · {{PROJECT_NAME}}
<!-- EN: Run key user scenarios (e2e/smoke) and report regressions. (MP-011/015) -->

> Прогон ключевых пользовательских сценариев (e2e/smoke) → отчёт о регрессиях.
> _Run key e2e/smoke scenarios; report regressions._

## Что делает · Steps
1. Прогнать набор сценариев (критичные пути: главная → ключевое действие → конверсия).
2. Падение → запись в `docs/feedback-journal.md` + задача в `pending/` с шагами воспроизведения.
3. Отчёт: пройдено/упало, ссылки на артефакты (скрины/логи).

## Границы
- Только чтение/прогон; не правит код. Фиксы — отдельными задачами по `PROTOCOL.md`.

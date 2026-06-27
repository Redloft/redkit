# R1 — Night Stabilization (routine) · {{PROJECT_NAME}}
<!-- EN: Nightly: keep the main branch green. Auto-fix only trivial; never touch business logic. (MP-011/017/041) -->

> Ночная рутина: держать основную ветку зелёной. Авто-чинит ТОЛЬКО тривиальное.
> _Nightly: keep main green; auto-fix trivial only._

## Что делает · Steps
1. Прогнать `typecheck` + `lint` + `build` + тесты на основной ветке.
2. Красное и причина **тривиальна** (импорт, форматирование, типобуквоедство) → авто-фикс в отдельной ветке + PR с меткой `auto-merge`.
3. Красное и причина **нетривиальна** → НЕ чинить; завести задачу в `docs/tasks/pending/` + запись в `docs/feedback-journal.md`.
4. Отчёт: что было красным, что починено, что эскалировано.

## Границы · Boundaries (Hard Rule)
- НЕ трогать бизнес-логику `src/` вне whitelist тривиальных правок.
- Любой авто-фикс проходит тот же gate (build+tsc), что и человек.

# CodeGraph Setup — {{PROJECT_NAME}}
<!-- EN: For codebases large enough that structural queries beat grep. Index symbols/edges; query before editing. (MP-055/056) -->

> Когда кодовая база выросла настолько, что структурные вопросы («кто это вызывает», «что сломается»)
> дешевле задать индексу, чем грепать. CodeGraph = AST-граф символов и связей.
> _When the codebase is big enough that structural queries beat grep._

## Когда включать · When
- Десятки+ модулей, частые рефакторы, «что сломается, если поменяю X».
- Маленький проект (лендинг) — НЕ нужен, grep/чтение достаточно.

## Установка · Setup
1. Инициализировать индекс: `codegraph init -i` (в корне репо).
2. Проверить здоровье: `codegraph status`.
3. Индекс отстаёт от записей ~1s (file-watcher) — не запрашивай сразу после правки.

## Когда использовать · Use for structural questions
- «Где определён X?» → search · «Кто вызывает Y?» → callers · «Что сломается?» → impact
- «Как X доходит до Y?» → trace · «Контекст для задачи» → context
Литеральный текст (строки, комментарии) — обычный grep. Доверяй результатам графа, не перепроверяй грепом.

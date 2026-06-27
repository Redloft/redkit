# Tasks Protocol — {{PROJECT_NAME}}
<!-- EN: Task lifecycle. Folders ARE the state machine. (MP-001 / MP-005) -->

> Папки = состояние задачи. Задача перемещается между папками по мере работы.
> _Folders are the state. A task moves between folders as it progresses._

## Жизненный цикл · Lifecycle
```
pending/  →  ready/  →  in_progress/  →  done/
(черновик)   (одобрено)  (в работе)      (готово)
```

| Папка | Значение | Кто переносит дальше |
|---|---|---|
| `pending/` | идея/черновик, ещё не одобрено | автор задачи (после описания → `ready/`) |
| `ready/` | одобрено, можно брать в работу | исполнитель (берёт → `in_progress/`) |
| `in_progress/` | прямо сейчас делается | исполнитель (после `/finalize` + коммит → `done/`) |
| `done/` | завершено и закоммичено | — |

## Правила · Rules
1. **Approval gate:** в работу берём только из `ready/`. `pending/` — не трогаем (MP-005).
2. Одна задача = один файл по `TASK-TEMPLATE.md`. Имя: `NN-короткое-описание.md`.
3. Перенос между папками — обычный `git mv`, отдельным понятным коммитом.
4. Не держи >1-2 задач в `in_progress/` одновременно (WIP-лимит).
5. Завершение задачи = зелёный `/finalize` + коммит нужных файлов + перенос в `done/`.

## Сложность · Complexity (MP-008)
В frontmatter задачи укажи `complexity: low|medium|high`. High/затрагивает auth/схему БД/архитектуру →
поставь `opus_review: true` (нужен глубокий ревью перед мержем).

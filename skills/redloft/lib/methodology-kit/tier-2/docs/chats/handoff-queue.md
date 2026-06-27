# Handoff Queue — {{PROJECT_NAME}}
<!-- EN: Cross-workstream handoffs go through this queue, not direct pings. (MP-034) -->

> Когда одно направление зависит от другого — кладёт запись СЮДА, а не пингует напрямую.
> Принимающее направление разбирает очередь в начале своей сессии.
> _Cross-chat dependencies queue here; the receiver drains it at session start._

## Открытые передачи · Open handoffs
| Дата | От (направление) | Кому | Что нужно / Ask | Статус |
|---|---|---|---|---|
| | | | | open · in-progress · done |

<!-- RU: пример строки —
| 2026-06-08 | Checkout | Catalog | Нужен API `GET /products/:id` с полем `stock` | open |
-->

## Правила · Rules
1. Запись = конкретный ask + кто ждёт + дата. Без «вообще надо бы».
2. Принимающий: разбери `open` в начале сессии → переведи в `in-progress`/`done`.
3. Закрытые (`done`) переноси вниз/архивируй раз в неделю, чтобы очередь была короткой.
4. Блокирующая передача висит >2 сессий → подними в соответствующих planning-чатах (`REGISTRY.md`).

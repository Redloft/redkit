# /redanalyst-ecom — выручка / продажи

Вес: **phased** (write, самый чувствительный). Два пути: (A) ecommerce-события на сайте (оплата в
браузере) ИЛИ (B) серверные офлайн-конверсии (оплата известна только на бэке/в CRM/1С/у эквайера).
Выбор пути определяет аудит (`source_of_truth`).

## Путь A — ecommerce на сайте
- dataLayer `purchase` + `items[]` (см. `references/ga4-gtm.md` для структуры, применимо и к Метрике).
- Инструкция/сниппет человеку; проверить, что событие с суммой ловится в отчёте.

## Путь B — офлайн-конверсии (главный, из кейса-эталона)
Прежде всего — **найти источник истины об оплате** (аудит: `source_of_truth`), НЕ доверять статусу
заказа на сайте (может врать). Затем матчинг по рецепту `references/offline-matching-recipe.md`.

Порядок (каждый — checkpoint, идемпотентность через `lib/ledger.py`):
1. **152-ФЗ hard-gate**: согласие на передачу ClientID+сумм подтверждено? Нет → стоп, к
   `references/privacy-152fz.md` / `/redloft-consent`. Боевую загрузку с суммами без согласия НЕ включать.
2. **21-day gate**: `GET .../visit_join_threshold` → окно. Не эмить строки старше.
3. **Собрать дельту** из источника истины: только заказы **с ClientID**, в окне, новее прошлого
   `batch_id` (ledger). Нормализовать суммы (comma-decimal → float), учесть возвраты/частичные.
4. **dry-run**: собрать CSV (UTF-8: `Target,ClientId,DateTime(unix,past),Price,Currency`), показать
   пользователю, НЕ слать.
5. **canary**: 1–2 строки → `POST upload` → `ledger` reserve/mark → poll `GET uploading/{id}` до
   `processed` → дождаться строки в отчёте (лаг ~2ч). Только потом — полный объём.
6. **live** полный объём (по write-safety contract, kill-switch активен) → read-back: число
   `processed` == число отправленного по ledger.

## Захват ClientID
Если офлайн, но ClientID не захватывается — сначала это (`references/clientid-capture.md`): сниппет
`getClientID` + проброс front→back до записи заказа + web-only gate (проговорить, что телефон/оффлайн
в сквозную не попадут). Backfill истории без ClientID **невозможен** — не обещать.

## Done-when
`last_batch.status=processed` в state + строки видны в отчёте по цели; ledger не содержит дублей;
суммы совпали с источником истины (сверка). `verify-report`-совместимый вывод.

## Handoff
Блок для `/rc-sync --infra` (`_shared.md §8`). Предложить непрерывный self-check (redjob): сверка
числа загрузок с объёмом заказов 1С/CRM + TG-алерт — предохранитель от «молча перестало течь».

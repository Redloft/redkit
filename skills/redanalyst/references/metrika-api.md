# Яндекс.Метрика API — карта для автоматизации

База: `https://api-metrika.yandex.net` (зеркало `.yandex.ru`). Авторизация — OAuth-токен в заголовке
`Authorization: OAuth <token>`. Токен только через `op run` (см. SKILL.md §Токены).

## Семейства API

| API | Для чего | Ключевое |
|---|---|---|
| **Management** | счётчики, цели, гранты, загрузка офлайн-данных | write-операции скилла |
| **Reporting** | агрегированная статистика (dimensions/metrics/segments) | аудит: срабатывают ли цели, расход Директа |
| **Logs** | сырые не-агрегированные хиты/визиты | глубокая диагностика (когда отчёт «сглаживает») |
| **Measurement Protocol** | серверная инъекция хитов | параллель GA4 MP (см. ga4-gtm.md) |

## Цели (goals)

- Список: `GET /management/v1/counter/{id}/goals`
- Создать: `POST /management/v1/counter/{id}/goals`, тело `{ "goal": {"name","type","conditions":[...]} }`
- `type` ∈ `url` | `action` (reachGoal/JS-событие) | `number` | `step` (составная воронка) | `ecommerce`
- Для офлайн-привязки заводится **action-цель**, её id идёт как `Target` в CSV загрузки.
- **Read-back после создания** (Done-when): перечитать `GET goals`, убедиться, что цель есть; для
  action-цели — проверить реальное срабатывание в отчёте (не просто «создана»).

## Офлайн-конверсии (главный источник тихих сбоев)

1. **Сначала окно:** `GET /management/v1/counter/{id}/offline_conversions/visit_join_threshold`
   → сколько дней назад можно грузить. **НЕ эмить строки старше порога** (21 день макс; окно
   открывается постепенно после включения опции).
2. **Загрузка:** `POST /management/v1/counter/{id}/offline_conversions/upload?client_id_type=CLIENT_ID`
   (или `USER_ID`/`YCLID`/`PURCHASE_ID`). Тело — CSV, **UTF-8**:
   - обязательные колонки: `Target` (id цели), идентификатор (`ClientId`/`UserId`/`Yclid`/`PurchaseId`),
     `DateTime` (unix, **в прошлом**);
   - опциональные: `Price`, `Currency` (ISO 4217).
3. **Проверка загрузки:** `GET /management/v1/counter/{id}/offline_conversions/uploadings` (список) и
   `GET .../offline_conversions/uploading/{uploadingId}` (одна) → статус. Данные в отчётах ~2 часа
   (иногда 24–48ч). **Успех = `processed`, а НЕ HTTP 200 на upload.**
4. **Диагностика LINKAGE_FAILURE:** Метрика отдаёт **построчный отчёт офлайн-конверсий** — какой
   идентификатор использован, статус привязки, причина непривязки. Скилл читает его, чтобы
   само-диагностировать сбой, а не гадать. Типовые причины: нет/неверный идентификатор; `DateTime` в
   будущем или кривой; визит старше 21 дня; JS-цель не настроена; дубли; не-UTF-8 файл.

## OAuth scopes (запрашивать узко)

- `metrika:read` — отчёты, конфиг счётчика, статусы загрузок → **достаточно для read-only аудита**.
- `metrika:write` — создавать счётчики/цели.
- **офлайн-грант** «Загрузка офлайн данных» — отдельная галка в OAuth-приложении, НЕ входит в write.
- Плюс на самом счётчике должна быть включена «Загрузка данных» (Настройка → Загрузка данных) — ручной
  шаг человека.

## Reporting API (для аудита и crosschannel)

- `GET /stat/v1/data?ids={counter}&metrics=...&dimensions=...&filters=...`
- Проверить срабатывание цели: метрика `ym:s:goal<goalId>reaches` за период.
- Расход Директа: параметр `direct_client_logins` + соответствующие dimensions/metrics.

## Ошибки/лимиты (решение panel #7)

- Ретраить `429`/`5xx` с backoff; `4xx` (кроме 429) — не ретраить, это твоя ошибка в payload.
- Зависший `uploading` (не `processed` за SLA) → dead-letter + алерт, не молчать.
- Все ответы могут уходить в `run.log` — **скрабить**: `grep -iE 'OAuth|op://' run.log` = 0 hits.

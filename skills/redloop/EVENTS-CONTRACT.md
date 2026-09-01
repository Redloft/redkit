# redloop — EVENTS-CONTRACT v2

Единственный интерфейс между тремя раннерами (redwork / `/loop` / Workflow / одиночная сессия)
и детекторами. Детекторы НЕ читают транскрипт, НЕ парсят вывод модели — только этот журнал.
Действие рождает событие: **panel-critical #1**.

## Файл и права
- Путь: `runs/<run_id>/events.jsonl`, append-only, одна JSON-строка на событие.
- **Единственный писатель — сессия прогона** (через `lib/events.sh append`, `O_APPEND` + lock).
  Внешний сторож (`redjob`) **только читает** journal + mtime и пишет свои алерты в
  СВОЙ файл (`runs/<run_id>/alerts.jsonl`). Асимметрия прав снимает конфликт ops↔backend.
- Ротация запрещена, пока `phase != DONE`.

## Схема (обязательные поля каждого события)
```
{ schema_version: 1, ts: "<ISO8601 UTC>", run_id, seq: <int, монотонный>,
  event_type: <enum>, kind: "progress"|"infra_failure"|"negative_verdict"|"blocked",
  severity: "info"|"warn"|"critical",
  denominator: { iter: <int>, of: <int|null> },     # ⚠ знаменатель ОБЯЗАТЕЛЕН
  payload: { ... }                                   # типизирован per event_type
}
```
`kind` — тот самый нерасщеплённый шов: **«раннер упал» ≠ «раннер честно вернул отрицательный
вердикт»**. `infra_failure` (таймаут, OOM, обрыв, exit≠0 самого раннера) → ретрай уместен.
`negative_verdict` (тест красный, judge=FIX-FIRST, DoD не сошёлся) → ретрай БЕСПОЛЕЗЕН без
изменения подхода: считается в LOOP-детекторе, а не в infra-ретраях.
`blocked` (v2) — третье состояние, найденное на живых прогонах: проверка упёрлась во ВНЕШНЕЕ
(нет токена, доступ снят, чужой сервер отдаёт статику мимо нашего конфига). Не красная и не
упавшая: действие за владельцем. Не зелёная тоже — DoD не закрыт.

⚠ **kind выводится ТОЛЬКО в `events.sh`, ровно в одном месте.** Порядок: сначала `result`
(закрытый enum `blocked_by_env` | `blocked_owner_action`) → `blocked`; иначе `exit_code==0`
→ `progress`; иначе `negative_verdict`. Детекторы читают `kind` и НЕ парсят префиксы payload:
правило, живущее в двух местах, разъезжается — это уже стоило скиллу трёх немых детекторов.

## event_type + обязательные поля payload
| event_type | payload (обязательное) | kind по умолчанию |
|---|---|---|
| `run_start` | `runner`, `contract_sha` (+ автоснапшот `budget` и `strict_journal`) | progress |
| `iter_start` | `task_id` | progress |
| `iter_done` | `task_id`, `files_changed:int`, `checkboxes_done:int` | progress |
| `check_result` | `check_id`, `cmd_hash`, `exit_code`, опц. `result` | см. правило kind выше |
| `runner_error` | `exit_code`, `error_class` | infra_failure |
| `assumption` | `assumption_id`, `text_hash` | progress |
| `question` | `reason_code`, `allowed:bool` | progress \| negative_verdict |
| `detector_fire` | `detector`, `shadow:bool`, `evidence` | warn/critical |
| `escalation` | `reason_code`, `needs[]` | critical |
| `run_done` | `verdict`, `iters`, `interventions`, `cost_usd?` | progress |
| `heartbeat` | `alive_at` | progress |

## Запрещено в журнале (наследуется от redwork)
Нет `stdout`/`stderr`/`raw`/`output`, нет текста задачи, нет PII, нет значений секретов.
Только структурный summary и хеши. Каждый append проходит `secret-guard`.

## Потребители (у каждого сигнала есть адресат — иначе сигнала нет)
| Сигнал | Потребитель |
|---|---|
| `detector_fire` (shadow=false) | `lib/escalate.sh` → TG @Attunedbot Игорю |
| `detector_fire` (shadow=true) | только `runs.jsonl` + отчёт калибровки, НЕ будит человека |
| `run_done` | TG-карточка итога + `postmortem.sh` → ledger |
| `heartbeat` stale | внешний сторож redjob → TG (детектор тишины сам обязан быть не-тихим) |

## Политика записи (v2) — то, чего не даёт просьба в промпте

Два живых прогона дали 5 и 3 события на 22 и 19 итераций: пять детекторов из шести читают
`iter_done`/`check_result`, им было нечего читать. Просьба в промпте это не лечит, поэтому:

- **`run_done` без единого `iter_done` отвергается** (`exit 4`, `reason=no_iterations_logged`).
  Финал без итераций означает, что сторож был слеп весь прогон.
- **Финал объявляется один раз.** Повтор с ТЕМ ЖЕ payload — no-op с предупреждением (ретрай
  раннера безопасен). Повтор с ДРУГИМ payload → `exit 4`, `reason=run_done_already_recorded`:
  продолжение работы после финала — это новый `run_id`.
- **Строгость фиксируется в `run_start`** (`strict_journal`) и дальше читается ИЗ ЖУРНАЛА.
  Журнал есть, а поля нет → прогон стартовал до выката v3 и доживает по старым правилам
  (`strict=0`); иначе обещание «идущий прогон не потеряет финал» было бы ложным.
  Журнала нет вовсе и приходит `run_done` → это ноль итераций, самый слепой случай:
  политика применяется, отказ `no_iterations_logged`.
  Рубильник: `REDLOOP_STRICT_JOURNAL=0` на старте прогона.
- **`_policy_check` читает журнал ДО взятия лока.** Это осознанно и безопасно ровно потому,
  что писатель по контракту один (сессия прогона); при двух писателях здесь был бы TOCTOU.
  Инвариант single-writer — предусловие политики, а не деталь реализации.
- **Бюджет снимается снапшотом в `run_start`** из `contract.json`. Детектор бюджета остаётся
  чистой функцией от журнала и не лезет во второй файл.

### Коды возврата `events.sh append`
| код | значение |
|---|---|
| 0 | записано (или идемпотентный no-op) |
| 1 | невалидный вход: enum, обязательное поле, секрет, запрещённое поле |
| 4 | **отказ по политике журнала** — причина машинная, в stderr `reason=<код>` |

## Доставка финала
`run_done` может сам звать `escalate.sh RUN_DONE` (`REDLOOP_AUTO_FINAL_NOTIFY=1`).
Вызов идёт **после снятия лока и вне `append()`**: `escalate.sh` пишет своё событие через этот
же `events.sh`, и вызов из-под лока молча провалился бы на каждом прогоне.
В сообщение уходят только машинные поля (вердикт, DoD, итерации) — свободный текст агента во
внешний канал не отправляется. По умолчанию выключено, пока путь не подтверждён живым прогоном.

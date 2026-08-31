# redloop — EVENTS-CONTRACT v1

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
  event_type: <enum>, kind: "progress"|"infra_failure"|"negative_verdict",
  severity: "info"|"warn"|"critical",
  denominator: { iter: <int>, of: <int|null> },     # ⚠ знаменатель ОБЯЗАТЕЛЕН
  payload: { ... }                                   # типизирован per event_type
}
```
`kind` — тот самый нерасщеплённый шов: **«раннер упал» ≠ «раннер честно вернул отрицательный
вердикт»**. `infra_failure` (таймаут, OOM, обрыв, exit≠0 самого раннера) → ретрай уместен.
`negative_verdict` (тест красный, judge=FIX-FIRST, DoD не сошёлся) → ретрай БЕСПОЛЕЗЕН без
изменения подхода: считается в LOOP-детекторе, а не в infra-ретраях.

## event_type + обязательные поля payload
| event_type | payload (обязательное) | kind по умолчанию |
|---|---|---|
| `run_start` | `runner`, `contract_sha`, `patterns_sha`, `budget` | progress |
| `iter_start` | `task_id` | progress |
| `iter_done` | `task_id`, `files_changed:int`, `checkboxes_done:int` | progress |
| `check_result` | `check_id`, `cmd_hash`, `exit_code` | negative_verdict при exit≠0 |
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

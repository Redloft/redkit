# redreference — RUNBOOK (operational recovery)

Сценарии сбоев интерактивной петли и восстановления. Дополняет автоматические
защиты (WAL recovery, flock, scrub). Все пути — `~/Library/Application Support/redreference/runs/<TS>-<slug>/`.

---

## 1. Порт feedback-server занят
**Симптом:** `feedback-server: EADDRINUSE` / сервер не стартует.
**Причина:** редкая коллизия в диапазоне 49152–65535.
**Действие:** caller просто перезапускает `feedback-server.js` — он берёт новый `listen(0)` (free ephemeral port). Если повторяется — проверь, не висит ли старый сервер: `manage.sh status <slug>` покажет `feedback-server pid … ALIVE` → `manage.sh kill <slug>`.

## 2. Браузер не открылся
**Симптом:** `open page/index.html` ничего не показал (удалённая сессия / нет GUI).
**Действие:** caller печатает прямой путь/URL: `file://<run_dir>/page/round-<N>.html`. Если пользователь удалён — подними локальный http-сервер на этой странице и дай `http://127.0.0.1:<port>` (file:// не работает с телефона). Транспорт ответов всё равно работает через **«📋 скопировать JSON»** → вставка в чат.

## 3. Сервер завис / лик процесса
**Симптом:** `feedback_server.pid` жив дольше раунда; пользователь ушёл.
**Защита:** idle-timeout 15 мин (сбрасывается keepalive `/ping`) + hard-cap 30 мин → сервер сам гаснет.
**Действие вручную:** `manage.sh kill <slug>` (kill по PID из status.json + `clear_feedback_server`). При старте нового раунда `reference.js`/caller убивает живой `feedback_server.pid` из прошлого run (stale-cleanup, не ждёт 30 мин).

## 4. Download/copy-fallback: ответы не дошли через сервер
**Симптом:** сервер недоступен (file://, нет сети к localhost).
**Действие:** на финальном экране — **«📋 скопировать JSON»** (clipboard; если буфер запрещён — появляется выделяемая textarea, Cmd+C). Пользователь вставляет JSON в чат → caller валидирует (`validate-card.js --feedback`) и `round.sh ingest <run_dir> <N> <answers.json>`.

## 5. Адаптер вернул 0 карточек
**Симптом:** `round.sh next … COUNT=0` («no fresh cards»).
**Причины/действия:**
- Длинный запрос → Are.na 0 каналов: `arena.sh` сам укорачивает запрос (drop trailing word). Если всё равно 0 — **расширь бриф** (более общий стиль) или смени источник.
- Всё уже показано (дедуп съел всё): увеличь `page` (`round.sh next <run> <N> <page+1>`) — пагинация вглубь; или смени нишу.
- Сетевой флейк / rate-limit Are.na: повтори через 1–2с (фетчи обёрнуты `retry.sh` с backoff). Прокси для IP-блоков: `redproxy` (только Land-book/Behance).

## 6. Индекс/деривативы повреждены
**Симптом:** `captures.jsonl` рассинхронен с `captures-index.json` / status; дубликаты или пропуски.
**Защита:** `wal_recover` на старте авто-ребилдит из `phases/round-*.committed.jsonl` при `committed>anchor` или несовпадении счётчиков (`INDEX_REBUILT`).
**Действие вручную:** `manage.sh rebuild-index <slug>` — пересобирает `captures.jsonl`/`feedback.jsonl`/`captures-index.json` из committed-раундов (single source of truth = `status.last_committed_round`).

## 7. Stage E: битый payload при мёрже в redloft
**Симптом:** `export-redloft.sh` → `TASTE_MERGE_FAILED`.
**Защита:** merged JSON валидируется (`jq -e`) ДО записи; `visual-taste-profile.json` не трогается при ошибке; перед записью делается `.bak`.
**Действие:** target цел (Design идёт на брифинг-профиле). Если `.bak` остался от прошлой удачной записи и текущий target подозрителен — `cp visual-taste-profile.json.bak visual-taste-profile.json`. 0 лайков → `TASTE_EMPTY` (норма, не ошибка — мёрж пропущен намеренно).

---

## Retention / хранилище
`manage.sh cleanup [--older-than 30d] [--prune-screenshots] [--dry-run]` — хранит последние run'ы, не трогает `running`. Предупреждает при суммарном размере >1GB. `--prune-screenshots` чистит только тяжёлые `screenshots/` старых run'ов.

## Тесты
- **Hermetic gate (MVP):** `bash tests/smoke.sh` — 0 сети, детерминирован, обязан быть зелёным.
- **Canary (не гейт):** `bash tests/canary.sh` — live-probe адаптеров + `verify-fixtures.sh` (FIXTURE_SCHEMA_DRIFT). Может падать при сетевых проблемах / смене API; запускать по расписанию, НЕ блокирует MVP.

## Секреты
`run.log` скрабится на записи (`sanitize.sh scrub_secrets`). Перед шерингом: `bash lib/sanitize.sh scrub < run.log | diff - run.log` — расхождений быть не должно. Креды (Thum.io/Microlink/Evomi/Eagle) — только `op run`, никогда в чат/файл.

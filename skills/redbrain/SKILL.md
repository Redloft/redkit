---
name: redbrain
description: |
  Граф-память ClaudeCore («супер-память» агентства): граф сущностей и связей поверх
  memory/*.md (Phase 1), с дешёвым SQLite-retrieval и Haiku-экстракцией на ingest.
  Дополняет файловый memory-слой (MEMORY.md остаётся истиной), НЕ заменяет его.

  TRIGGER on:
  • «что связано с X», «где у меня всплывало X», «покажи связи X», «найди по графу X»
  • «обнови граф-память», «переиндексируй память», «bootstrap redbrain»
  • «граф памяти», «супер-память», «redbrain статус/health»
  • "what's connected to X in my memory", "rebuild the memory graph", "redbrain status"
  • Explicit: «/redbrain», «/redbrain-bootstrap», «/redbrain-query», «/redbrain-status», «/redbrain-golden»

  НЕ для: кода («что вызывает функцию» → codegraph_*), поиска в вебе (→ WebSearch/redresearch),
  чтения одного конкретного memory-файла (→ Read напрямую).
allowed-tools:
  - Bash
  - Read
  - Write
  - Agent
---

# redbrain — граф-память ClaudeCore (Phase 1 MVP)

Дизайн-контракт: `$CLAUDECORE_PATH/roadmap/graph-memory-DESIGN.md` (research + plan-panel
2026-07-03, все architectural-фиксы панели внесены). Phase 1 = только bootstrap
`memory/*.md`; auto-ingest встреч/Трекера — Phase 2 (design-only, гейт на
cross-project data scope — НЕ реализовывать без отдельного дизайна).

## Идея в одну строку

`memory/*.md` — листочки-истина. redbrain — быстрый указатель поверх них:
SQLite-граф «кто с чем связан», обход бесплатный, платный только ingest (Haiku).

## Storage: два мозга

`~/Library/Application Support/graph-memory/` — WAL-mode, НЕ на Yandex.Disk
(правило C1: облачный sync × инкрементальная запись = конфликтные копии).
Потеря базы некритична: ре-bootstrap из источников восстанавливает всё.

Два физических файла, общий движок; scope через env `REDBRAIN_SCOPE`:
- **`work.db`** (default) — рабочий мозг: memory/*.md, projects/, apis/,
  ROADMAP/BACKLOG/INVENTORY, judge/research-сводки. Его видит любой рабочий
  контур (и будущая LLM-«сотрудник»).
- **`private.db`** (`REDBRAIN_SCOPE=private`) — приватный контур: servers/
  (IP/SSH), клиентские карточки RedControl (суммы, ФИО, контакты), личное.
  Граница на уровне файловой системы, fail-closed: рабочему контуру путь
  не выдаётся; личный ассистент опрашивает оба (два вызова с разным scope).
- При сомнении «куда писать» — в private (fail-closed), спросить Игоря.
- **Запись требует ЯВНОГО scope**: `insert/mark-source/revert/alias/rekey`
  отказывают, если `REDBRAIN_SCOPE` не задан (никакого молчаливого default
  work при записи — забытый env не утечёт приватом в общий мозг). Чтение
  (status/check/export, все query) — default work, без трения.
- **--prefix на уже проиндексированной директории**: сначала миграция
  `graphdb.py rekey <старый_sid> <новый_sid>` для существующих строк (rename,
  без повторной платной экстракции), только потом сканы с --prefix. Смешивать
  prefixed/unprefixed сканы одной директории нельзя — вечные дубли.

## Политика записи (бриф Игоря 2026-07-03 — ЗАКОН для любого ingest)

**В work.db пишем ТОЛЬКО устойчивые факты** — то, что живёт месяцами:
проект↔сервер↔домен↔стек↔инструмент↔скилл, принятые решения, грабли/паттерны.
**НЕ пишем**: статусы задач, ежедневные события, черновики, «сегодня сделали X»
— устаревает за неделю и превращает граф в свалку.

**В private.db** (`REDBRAIN_SCOPE=private`): servers (IP/SSH), клиентские
карточки (ФИО/контакты), ВСЕ деньги (суммы, ставки, условия сделок — даже без
ФИО), содержание переговоров, личное (семья/здоровье/планы/недвижимость).
Правило: work знает ЧТО делаем, private — ЗА СКОЛЬКО, С КЕМ и что по жизни.

**События с датами** (встречи, дайджесты): в граф идёт только выжимка
устойчивых фактов («клиент Y хочет фичу Z», «договорились о стеке»);
хронология «когда» остаётся в исходном файле саммари — граф помнит «что
связано», а не «что когда было». Узлы вида meeting-2026-07-03 НЕ создавать.

**Контроль качества**: ingest полностью авто (без превью), но раз в месяц —
janitor-прогон: узлы без связей, дубли-опечатки, устаревшие concept-узлы →
ревью-список Игорю на подтверждение удаления. Никогда не удалять молча.

## Flow: bootstrap / re-ingest (`/redbrain-bootstrap`)

```
0. SCOPE (обязательно): export REDBRAIN_SCOPE=work|private — сверить с
   намерением ДО начала (scan печатает активный scope в JSON; insert без
   явного env откажет).

1. SCAN (детерминированно, бесплатно)
   python3 lib/scan.py <dir> [--prefix "<ns>/"]
   → hash-check против sources (не менялся → skip; это и есть идемпотентность:
     Haiku НЕ вызывается повторно на неизменённом файле — недетерминизм LLM
     не может «переписать» граф);
   → secret-scrub ДО LLM (sk-/ghp_/AIza/op:///Bearer/eyJ → [REDACTED-SECRET]);
   → frontmatter + wikilinks → det_triples в pending-payload (НЕ в базу —
     см. шаг 3, tombstone-семантика требует один insert на документ);
   → pending-документы выгружены в scrubbed-файлы (пути в stdout JSON).

2. EXTRACT (Haiku, единственная платная часть)
   Для pending-документов — Agent-батчи (model: haiku), по 5-8 доков на агента.
   Промпт агенту — см. «Extraction prompt» ниже. Агент возвращает JSON-массив
   [{source_id, content_hash, triples:[...]}].

3. INSERT (детерминированно)
   Для каждого документа СЛИТЬ det_triples (из scan) + triples (из Haiku)
   в ОДИН payload и вставить одним вызовом:
   echo '<json det+llm triples>' | python3 lib/graphdb.py insert
   ⚠️ insert делает tombstone ВСЕХ старых рёбер этого source_id перед append —
   две отдельные вставки для одного документа затрут друг друга. Один документ
   = ровно один insert.

4. ALIASES (после первого bootstrap или при добавлении новых)
   Haiku канонизирует имена в латиницу («диадок»→diadok) — кириллический
   запрос без алиаса не найдёт узел. Сид-список golden/aliases.txt:
   grep -v '^#' golden/aliases.txt | while IFS='|' read a c; do
     python3 lib/graphdb.py alias "$a" "$c"; done
   Новая частая сущность с ru-написанием → дописать строку в aliases.txt.

5. VERIFY
   python3 lib/graphdb.py status            — counts
   bash lib/golden.sh                       — golden query-set, DoD = ≥12/15 pass
```

Batch-ingest крупного объёма? Сначала snapshot: `cp graph.db graph.db.bak-<ts>`.
Прогон дал мусор? `python3 lib/graphdb.py revert <run_id>` — откат одним запросом.

## Extraction prompt (для Haiku-агента)

```
Ты — entity/relation extractor. Прочитай файлы: <список scrubbed-путей>.
Для КАЖДОГО файла извлеки 5-15 триплетов (subject, relation, object) о
сущностях: проекты, инструменты/сервисы, люди, серверы, домены, skills,
концепции. Правила:
- имена сущностей — короткие канонические (напр. "redkit", "1password",
  "yandex tracker"), БЕЗ склонений, на языке оригинала;
- relation — короткий глагол/предикат en: uses, part_of, deployed_on,
  integrates_with, stores_in, depends_on, replaces, configured_via, related_to;
- НЕ извлекай строки похожие на секреты/токены ([REDACTED-SECRET] пропускай);
- КАЧЕСТВО > количество: только связи, реально помогающие ответить
  «что связано с X» (число сущностей не коррелирует с качеством recall —
  проверено research'ем).
Верни СТРОГО JSON-массив:
[{"source_id":"<имя файла>","content_hash":"<из задания>",
  "triples":[{"src":"...","src_type":"project|tool|person|server|skill|concept",
              "relation":"...","dst":"...","dst_type":"..."}]}]
```

Числа: ~35 memory-файлов ≈ 4-6 Haiku-агентов ≈ копейки; повторный прогон
неизменённого корпуса = 0 вызовов (всё skip по hash).

## Flow: запросы (`/redbrain-query`, бесплатно, без LLM)

| Вопрос | Команда |
|---|---|
| «найди сущность по имени» | `python3 lib/query.py search <substr>` |
| «что связано с X» (прямые связи) | `python3 lib/query.py entity <name>` |
| «окрестность X» (2 hop, recursive CTE) | `python3 lib/query.py context <name> [--depth 2]` |
| «в каких доках всплывало X» | `python3 lib/query.py docs <name>` |
| «что было истинно на дату D» | `python3 lib/query.py asof <ISO> [name]` (см. «Слой 3») |
| статус базы | `python3 lib/graphdb.py status` |
| экспорт (reversibility) | `python3 lib/graphdb.py export > graph.jsonl` |

Ответ пользователю: не сырой JSON, а короткая сводка «X связан с A (uses),
B (part_of) — упоминается в доках D1, D2» + предложение открыть конкретный
memory-файл (граф — указатель; полный контекст — в самом файле).

## Ranking: почему БЕЗ PageRank

Phase 1 = плоский lookup + CTE-окрестность. PPR — только если golden-набор
покажет недостаточный recall И замер latency наивной реализации ок
(двойной критерий — решение plan-panel: premature abstraction).

## Правила

- Граф — производный индекс. НИКОГДА не «исправлять» память правкой графа:
  правится memory/*.md → ре-scan подхватит.
- Не выводить в чат содержимое [REDACTED-SECRET]-спанов и не ослаблять scrub.
- `--force` (полный ре-ingest) — только по явной просьбе: платно и бессмысленно
  на неизменённых файлах.
- Phase 2 (встречи/Трекер, PPR, embedding entity-resolution) — не начинать
  без отдельного дизайна: cross-project data bleed = hard blocker.


## Слой 2: оперативная память + Мия + календарь (Phase 2.5, live 2026-07-04)

Поверх графа — backlog (`lib/backlog.py`, таблица в тех же work/private.db):
задачи/идеи/дневник/календарь-кандидаты из разговоров. Статусы CAS-переходами
(one-shot гарантирован). Классификатор inbox (`ingest-note.py`) роутит:
graph|backlog|calendar|diary|none одним Haiku-вызовом; проект — только из
белого списка projects/*.md; diary → всегда private.

**Мия** (= @Attunedbot, модуль `redcontrol/autopilot/mia.py`, callback-префикс
`mia:` в approve_listener — у бота ОДИН getUpdates-консьюмер, вторых поллеров
не заводить!): превью задач с ✅/❌ (`mia-dispatch.sh`, launchd com.redbrain.mia
5 мин + хвост pull-inbox), по ✅ создаёт задачу в Трекере через
tracker_rest.create_issue С READ-BACK → backlog routed.

**Мия-перемычка** (`~/.claude/hooks/mia-tracker-gate.sh`, PreToolUse на
issue_create): Claude-сессии создают задачи ТОЛЬКО по подписанной квитанции
(HMAC, ключ в Keychain mia-receipt-key, one-shot, TTL 30 мин). Нет квитанции →
deny + gate-request → Мия пришлёт кнопки. Toggle: файл mia/MIA_GATE со словом
off. money-guard независим, проходят оба.

**Календарь** (`bridge/mac/calendar-add.py`, gsuite-OAuth, scope выдан):
автосоздание в личном GCal без подтверждения ТОЛЬКО при детерминированных
guard'ах — дата дословно в тексте (G1), будущее ≤18 мес (G2), ≤3/прогон (G3),
идемпотентность по тегу mia-auto:backlog_id (G4), тег+цитата в событии (G5).
Провал guard'а → clarify → Мия спросит. НИКОГДА не ослаблять guard'ы промтом.

## Слой 3: темпоральные слои (schema v3, live 2026-07-07)

Дизайн-контракт: `roadmap/DESIGN-temporal-layers-v2.md` (после plan-panel
NEEDS-WORK@0.86 + внешние судьи; верификация этапов — /finalize по диффу, не
новый круг панели). Три части: би-темпоральные факты · конвейер
candidate→confirmed · present-context в recall.

**Схема v3** (миграция S0, обе базы): `edges` + `valid_at/invalid_at/expired_at`
(closed-open интервал `valid_at ≤ t < invalid_at`, NULL = истинен сейчас),
`status ∈ candidate|confirmed|expired|invalidated`,
`attribution ∈ doc|user_statement|model_inference`; таблицы `episodes`
(id=hash(channel|ts|content) ДО скраба; content ПОСЛЕ pii-скраба) и
`edge_episodes` (lineage ребро↔эпизод). Backfill: старые рёбра =
`confirmed/doc/valid_at=created_at`.

**Контракт tombstone ↔ invalidation (НЕ ломать):**
- `attribution='doc'` (Phase-1 scan) — живёт по document-tombstone: DELETE
  рёбер source_doc + повторный insert, «один док = один insert» как раньше.
  Tombstone фильтрует `WHERE source_doc=? AND attribution='doc'` — episode-рёбра
  не трогает. `revert <run_id>` — тоже только doc-слой.
- Episode-рёбра (`user_statement`/`model_inference`, source_doc=`episode:<id>`) —
  НИКОГДА не DELETE: только `invalidate` (закрытие valid-окна) или TTL→expired.

**Команды graphdb.py (новые):**
```
echo '<payload>' | graphdb.py insert-episode
  # payload: {"episode":{"ts":ISO,"channel":"plaud|chat|telegram|calendar|doc",
  #           "content":"..."}, "run_id":"...", "triples":[{src,relation,dst,
  #           attribution, valid_at?, invalid_at?, ...}]}
  # одна транзакция: PII-скраб (lib/pii.py) → episodes + candidate-рёбра + lineage.
  # Идемпотентно: детерминированные id → повтор = нулевой дифф; та же тройка из
  # ДРУГОГО эпизода = +1 lineage-строка (корроборация), не дубль.
  # Gate экстракции: relation только из словаря (существующие в графе +
  # golden/relations-allow.txt); мусорная valid_at → fallback на ts эпизода;
  # отклонённое возвращается в rejected[], не пишется молча.
graphdb.py invalidate <edge_id> <ISO-дата>
  # закрыть valid-окно (status='invalidated'); doc-рёбра — refuse.
graphdb.py status   # теперь + episodes/candidates counters
```
Запись (insert-episode/invalidate) требует явного `REDBRAIN_SCOPE` — как весь write.

**Конвейер candidate→confirmed (`lib/promote.py`):**
```
promote.py scan [--ttl-days 30] [--min-episodes 2] [--notify]
  # TTL-проход (candidate старше TTL без корроборации → expired) + proposal-пачка:
  # ≥2 независимых эпизодов (разные дни ИЛИ каналы) → на confirmed;
  # user_statement → с 1 эпизода; model_inference с 1 — остаётся candidate.
  # Противоречие с активным confirmed → conflicts (ручной разбор, не авто).
  # --notify → TG-карточка Игорю (@Attunedbot sender, op_env.sh-паттерн).
promote.py apply <proposal-id|path>   # перевести пачку ПОСЛЕ ✅ Игоря
promote.py status                     # счётчики конвейера
```
Идемпотентно (тот же набор → тот же proposal-id байт-в-байт), под общим
writer-lock'ом `redbrain` (lib/lock.py — busy → skip, не сериализуемся силой).
События: append-only `~/.cache/redbrain/promote/events.log`. Кандидаты НЕ видны
recall'у и query по умолчанию.

**Темпоральное чтение (query.py):**
- Дефолт БЕЗ флагов = байт-в-байт как до v3 (только confirmed; golden 15/15 —
  прямой тест контракта).
- `--include-candidates` и `--asof <ISO>` — на `entity|context|docs`.
- `query.py asof <ISO-дата> [entity] [--limit 50]` — срез «что было истинно
  на дату»; без entity — только «презентные» relation из
  `golden/relations-allow.txt` (иначе backfill зальёт выдачу всем графом).
- На до-v3 базе фильтры fail-open (нет колонки status → поведение как раньше).

**Present-context (recall.py):** `present_context()` — эфемерный блок «сейчас»,
собирается на лету (≤10мс): (1) confirmed-факты AS OF now по презентным relation
и субъектам `REDBRAIN_PRESENT_SUBJECTS` (default игорь/igor); (2) календарь
сегодня/завтра из кэша `~/.cache/redbrain/calendar.json` (TTL 2ч по mtime,
stale → блок молча пропущен); (3) хвост эпизодов за 24ч. Debug: `recall.py
--present`. Кэш пишет `bridge/mac/calendar-poll.py` (gsuite-OAuth, только под
`op run` через обёртку `run-calendar-poll.sh` — op_env.sh против ночных
TCC-окон; atomic tmp+rename, сбой сети оставляет старый кэш) под launchd
`com.redbrain.calendar-poll`.

**Тесты:** `tests/test_temporal.sh` (20: транзакции, no-overlap, tombstone
не трогает episode-рёбра, идемпотентность, scope-guard) и
`tests/test_promote.sh` (16: двойной прогон = идентичные карточки, TTL,
apply, events.log, busy-lock). Изолированные БД (`REDBRAIN_DB_DIR`=tmp) —
живые базы не трогаются. Гонять после любой правки graphdb/promote.

## OPS-runbook: 4 точки отказа (v2 §rollback)

1. **Миграция v3** — перед любой миграцией/batch: `sqlite3 <db> "PRAGMA
   wal_checkpoint(TRUNCATE)"` + `cp -a` ОБЕИХ баз (без checkpoint'а wal/shm
   теряются). Симптом порчи: golden < 15/15 или `COUNT(*) edges` уплыл →
   откат = вернуть snapshot, повторить миграцию. Ре-bootstrap из источников —
   последний резерв (платный Haiku).
2. **Промоушен** — promote.py идемпотентен: подозрение на кривой прогон →
   `promote.py status` + хвост `~/.cache/redbrain/promote/events.log`
   (переходы `old→new reason episode_count`). Ложный confirmed →
   `graphdb.py invalidate <edge_id> <now>` (никогда не DELETE). Lock завис →
   `lock.py` покажет владельца; мёртвый PID снимается им же.
3. **Calendar-poller** — сбой fetch НЕ портит кэш (atomic write only-on-success);
   recall сам скипает stale-кэш по TTL 2ч — деградация тихая и безопасная.
   Диагностика: `~/.cache/redbrain/com.redbrain.calendar-poll.{out,err}.log`;
   ночные op-окна → проверить source op_env.sh в run-calendar-poll.sh.
   ⚠️ known-issue 2026-07-07: в plist'е НЕТ StartInterval/StartCalendarInterval
   (redjob-генерация) — джоб не срабатывает сам, нужен ре-генер с расписанием
   (дизайн: раз в 30 мин, :00/:30).
4. **Recall-hook** — fail-open по построению: порча/отсутствие базы, миграция
   на полпути, битый кэш → блок молча пропущен, промт не блокируется.
   tier-1 rollback = `REDBRAIN_RECALL_DISABLE=1`; здоровье —
   `recall.py --report` (error/timeout ≠ miss); p95 под promote-батчем —
   контракт S4.

## Files

```
lib/graphdb.py   — schema v3/insert/insert-episode/invalidate/tombstone/revert/status/export
lib/scan.py      — hash-check + scrub + frontmatter/wikilinks + pending
lib/query.py     — search/entity/context/docs/asof (+--include-candidates/--asof)
lib/promote.py   — конвейер candidate→confirmed: scan/apply/status (S2a)
lib/pii.py       — единый PII/money-скраб (episodes hot path + dream REM)
lib/recall.py    — авто-recall + present_context() (ядро UserPromptSubmit-хука)
lib/lock.py      — writer-lock 'redbrain' (promote/poller/ingest)
lib/golden.sh    — прогон golden-набора (DoD)
golden/queries.json        — 15 эталонных запросов, порог 12/15
golden/relations-allow.txt — allowlist «презентных» relation (gate + asof; DRAFT до S3-калибровки)
golden/aliases.txt         — ru↔en алиасы
bridge/mac/calendar-poll.py — кэш календаря для present-context (launchd, 30 мин)
tests/test_temporal.sh      — 20 unit-тестов протокола записи v3
tests/test_promote.sh       — 16 тестов конвейера промоушена
```

## Recall-хук (авто-проверка графа на КАЖДУЮ задачу)

Push-протокол recall'а: `UserPromptSubmit`-хук на каждый промт (SQLite, без LLM)
матчит сущности задачи в графе и, если сильный матч, инъектит
компактный блок «по задаче уже есть факты в памяти». Закрывает дыру pull-модели
(факт есть, но не поднялся, если Claude не догадался запросить). Дизайн-ревью:
plan-panel ultra 2026-07-06 → NEEDS-WORK@0.88 (потолок), фиксы внесены.

- **`lib/recall.py`** — ядро. Modes: `--hook` (stdin hook-JSON → hookSpecificOutput),
  `--text` (debug), `--report` (агрегат events.log), `--self-test` (21 проверка).
  Group-by-name (nodes.name НЕ уникально), type-aware порог (concept-single-word
  строже — 38% узлов concept = шум), deny-лист, dedupe per session, session-cap,
  signal-watchdog 150мс, sqlite mode=ro+timeout. **work-scope ЖЁСТКО зашит**
  (REDBRAIN_SCOPE НЕ читается — private не всплывёт в work-промт).
- **`~/.claude/hooks/redbrain-recall.sh`** — тонкая обёртка: kill-switch,
  stdin→recall.py, macOS-safe timeout, FAIL-OPEN (любая ошибка → exit 0, промт
  никогда не блокируется/не задерживается).
- **Врезка** — `~/.claude/settings.json` → `UserPromptSubmit`, `timeout:5`.

**Observability** (`~/.cache/redbrain/recall/events.log`, ротация 512КБ, chmod 700):
на КАЖДЫЙ проход `{ts,sid,plen,matched,facts,ms,outcome}` — БЕЗ текста промта/
фактов. `outcome ∈ hit|shadow|miss|skip|dedup|throttled|timeout|error|disabled`.
`recall.py --report` → hit-rate, latency p50/p95, error+timeout health, топ-сущности.
Разделяет `miss` (штатно) от `error`/`timeout` (поломка) — fail-open не тихая смерть.

**Env-тумблеры:** `REDBRAIN_RECALL_DISABLE=1` (kill), `_SHADOW=1` (считать+логировать,
НЕ инъектить), `_LOG=0`, `_SCORE_FLOOR`/`_CONCEPT_FLOOR`/`_MAX_ENTITIES`/`_MAX_FACTS`/
`_SESSION_CAP`/`_MIN_PROMPT`/`_DEADLINE_MS`/`_STOP`.

**Rollout / rollback:**
- Shadow-фаза (по умолчанию при врезке): `REDBRAIN_RECALL_SHADOW=1` префиксом в
  command. Собрать `--report` на реальных промтах → флип вживую = убрать префикс.
- Backup перед правкой settings.json: `settings.json.bak-pre-recall` (глобальный
  файл без git — blast radius = все проекты). Правка — atomic + reparse-валидация.
- **tier-1 rollback** = `REDBRAIN_RECALL_DISABLE=1` (env, settings.json не трогать).
  **tier-2** = удалить блок `UserPromptSubmit` из settings.json.
- **Backup/recovery графа:** порча/отсутствие work.db → recall молчит (fail-open,
  UX не критичен). Ре-bootstrap: `scan.py + graphdb.py` (платный Haiku-ingest).
- **Латентность (finalize-замер 2026-07-06, полный hook-путь):** p50 ~100мс /
  p95 ~210мс. Доминирует **cold-start питона (~97мс, инхерентно)**; сам матчинг
  (load_index+match) лишь +12мс, sweep амортизирован до раза/час. В SHADOW —
  терпимо. **Для LIVE-флипа уже за порогом** (p95≫60мс): резидентный unix-socket
  демон срежет cold-start до <10мс. Демон = prerequisite live-инъекции, НЕ shadow.
  Мониторить `recall.py --report`.

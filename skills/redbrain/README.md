# redbrain

**Граф-память для Claude Code** — SQLite-граф сущностей и связей поверх файлового
memory-слоя (`memory/*.md` остаётся истиной, граф — быстрый указатель поверх).
Запросы бесплатны и мгновенны (без LLM); платный только ingest новых документов
(Haiku-экстракция триплетов). С v3 — темпоральные слои: би-темпоральные факты,
конвейер candidate→confirmed и present-context «что сейчас».

Часть [redkit](https://github.com/Redloft/redkit) — семьи red*-скиллов для Claude Code.

## Идея

- **Два физических мозга** (`work.db` / `private.db`, env `REDBRAIN_SCOPE`) —
  граница приватного на уровне файловой системы, fail-closed: запись требует
  явного scope, забытый env не утечёт приватом в общий граф.
- **Ingest идемпотентен**: hash-skip неизменённых файлов (LLM не вызывается
  повторно), secret-scrub до LLM, tombstone-семантика «один документ = один insert».
- **Retrieval без LLM**: `search / entity / context (recursive CTE) / docs / asof`.
- **Recall-хук**: UserPromptSubmit-хук матчит сущности промта в графе и
  инъектит факты push'ем (fail-open, observability в events.log).

## Темпоральные слои (schema v3)

- **Би-темпоральные факты**: `edges` + `valid_at/invalid_at/expired_at/status/attribution`;
  closed-open интервалы; инвалидация вместо удаления (`graphdb.py invalidate`).
- **Эпизоды**: `graphdb.py insert-episode` — эпизод (plaud/chat/telegram/calendar/doc)
  + candidate-рёбра + lineage в одной транзакции; PII/money-скраб на входе
  (`lib/pii.py`); gate экстракции — relation только из словаря графа +
  `golden/relations-allow.txt`.
- **Конвейер candidate→confirmed** (`lib/promote.py scan/apply/status`):
  корроборация ≥2 независимых эпизодов, TTL кандидатов, идемпотентные
  proposal-пачки под writer-lock'ом, апрув пачки одним ✅.
- **Present-context**: эфемерный блок «что сейчас» в recall-хуке (AS OF now +
  кэш календаря + последние эпизоды), ≤10мс, fail-open.
- Дефолтное чтение БЕЗ флагов — байт-в-байт как до v3 (только confirmed);
  темпоральный срез — `query.py asof <ISO> [entity]`, флаги
  `--include-candidates` / `--asof`.

## Тесты

```bash
bash tests/test_temporal.sh   # 20 — протокол записи v3 (изолированная tmp-БД)
bash tests/test_promote.sh    # 16 — конвейер промоушена
bash lib/golden.sh            # golden query-set по живому графу (DoD ≥12/15)
```

## Snapshot-политика

Публичная копия = движок (`lib/`, `tests/`, `golden/`, `SKILL.md`).
Персональная обвязка (mac-bridge: инжест голосовых заметок, TG-диспетчер,
календарь-поллер, launchd-джобы) и дизайн-доки живут в приватном каноне
`~/.claude/skills/redbrain/` и в snapshot не публикуются.

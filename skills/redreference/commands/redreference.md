# /redreference — caller flow (authoritative)

Полный orchestration-контракт. Источник истины (версионируется со skill). Workflow-песочница без FS → **caller** (Claude) делает persist, держит status.json, поднимает feedback-server, коммитит раунды через WAL, пишет artifacts.

---

## `/redreference <бриф>` — основной flow (через `lib/round.sh`-оркестратор)

`lib/round.sh` инкапсулирует persist+WAL+dedup+cap+page+taste. Caller (Claude)
держит интерактив: открывает страницу / принимает вставленный JSON.

### Шаг 1 — Старт + дистилляция брифа (P1)
`$ARGUMENTS` = ниша/бриф/пожелания (пусто → последний значимый запрос сессии).
```bash
RUN_DIR=$(bash ~/.claude/skills/redreference/lib/round.sh start "$BRIEF" | sed -n 's/^RUN_DIR=//p')
```
Создаёт run (local-first, C1-guard), сохраняет сырой бриф в `brief.txt`, `wal_recover`.

**Дистилляция (caller-side, ОБЯЗАТЕЛЬНО перед раундом 1):** длинный/русский бриф нельзя слать в галереи сырым (Are.na/Awwwards/Behance матчат короткие EN-запросы; сырой абзац → мусор). Ты (оркестрирующий Claude) выжимаешь бриф в **2-4 коротких английских ключа** + **интент**, и кладёшь `$RUN_DIR/brief-keys.json` (схема = BRIEF_SCHEMA в `workflow/reference.js`):
```json
{ "query_tags": ["spa wellness", "sauna landing", "warm minimal"],
  "intent": "site",   // site = коммерч. сайты/лендинги/приложения → Awwwards/Behance ведут;
                      // mood = мудборд/фактуры/бренд-эстетика → Are.na ведёт
  "sources": ["awwwards","behance"] }
```
`round.sh` читает этот файл (`resolve_query()` / `_read_intent()`): query_tags → запрос раунда 1 и якорь экспансии; intent → состав пула адаптеров. Нет файла/невалиден → fallback на сырой `brief.txt` + intent=site (обратная совместимость). Файл переживает resume (caller-side, не WAL).
Опц. перед первым scraper-источником: `check-vendor-drift.sh`=0 (D4 gate).

### Шаг 2 — Петля раундов (N=1,2,…)
Для каждого раунда:
```bash
OUT=$(bash ~/.claude/skills/redreference/lib/round.sh next "$RUN_DIR" "$N")
# → QUERY= / NONCE= / COUNT= / PAGE=    (фетч адаптеров → dedup vs index → cap 12 → WAL pending → страница)
```
- **Источники:** `round.sh` дёргает Are.na (`arena.sh`). Для design-inspiration MCP: caller сам вызывает `mcp__design-inspiration__design_search_images` → `design-inspiration.sh parse` и подкладывает в фетч (или `REDREFERENCE_MOCK_RAW`). 0 карточек → расширь бриф / `page+1` (RUNBOOK#5).
- **Открой страницу:** `open "$PAGE"` (или дай `file://$PAGE` / подними http для удалённого — RUNBOOK#2). Можно поднять feedback-server (§0) для прямого POST; **дефолт интерактива с Claude — «📋 скопировать JSON» → вставка в чат**.
- **Прими голос:** пользователь вставляет JSON → сохрани в файл → 
  ```bash
  bash ~/.claude/skills/redreference/lib/round.sh ingest "$RUN_DIR" "$N" answers.json
  # → INGESTED= / LIKES= / PRIORITY= / ANTI= / UX_PREF= / UI_PREF= / NEXT_QUERY= / STOP=
  ```
  (validate → WAL commit → пересчёт вкуса). `STOP=continue` → следующий раунд; иначе стоп.

### Шаг 3 — Render + (опц.) redloft-встройка
- Покажи: курированный набор (top liked + UX/UI), сошёлся ли вкус (rounds/confidence), путь. `write_status done completed 0`. Источники с атрибуцией; link-only (Pinterest/Dribbble/Savee) — отдельным списком ссылок.
- **Секрет-чек:** `bash lib/sanitize.sh scrub < "$RUN_DIR/run.log" | diff - "$RUN_DIR/run.log"` — без расхождений (scrub на записи).
- **redloft-встройка (Stage E):** когда redreference внутри redloft-пайплайна (или по запросу):
  ```bash
  bash ~/.claude/skills/redreference/lib/export-redloft.sh "$RUN_DIR" \
    "<project>/brief/visual-taste-profile.json" "<project>/design/reference-likes.md"
  ```
  merge (не затирает брифинг) + backup + flock + atomic; 0 лайков → `TASTE_EMPTY` (не трогает).

---

## Управляющие команды (`lib/manage.sh`, без агентов)

| Команда | Реализация |
|---|---|
| `/redreference-list` | `manage.sh list` |
| `/redreference-status <slug>` | `manage.sh status <slug>` (status.json + liveness worker/feedback-server) |
| `/redreference-resume <slug>` | `detect_stale` → `wal_recover` → re-invoke Workflow с `resumeFromRunId` |
| `/redreference-share <slug>` | `manage.sh path <slug>` → отдать curated captures + taste-profile (scrub-checked) |
| (ops) | `manage.sh rebuild-index <slug>` (RUNBOOK#6), `manage.sh kill <slug>`, `manage.sh cleanup [--older-than 30d] [--prune-screenshots]` |

---

## Anti-patterns
- ❌ Не писать run-каталог в Yandex.Disk (C1) — только `~/Library/Application Support/redreference/` (persist.sh гарантирует).
- ❌ Не коммитить раунд двумя независимыми append'ами — только `wal_commit` (атомарность).
- ❌ Не скрейпить Pinterest/Dribbble/Mobbin/Refero/Savee — link-only (ToS).
- ❌ Не печатать секреты; Thum.io/Microlink/Evomi/Eagle — только `op run`. run.log через `scrub_secrets`.
- ❌ Не передавать scraped-текст в промпт роли без `sanitize.sh strip_instructions()` (F6).
- ❌ Не перезаписывать `visual-taste-profile.json` пустым — `taste_profile:null` → не трогать (backup-before-write).

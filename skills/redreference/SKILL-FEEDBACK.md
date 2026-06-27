# redreference — копилка улучшений (feedback log)

Живой фидбек по реальным прогонам. Источник правды для доработки. Приоритет = ожидаемый прирост качества подбора.

> **✅ P1–P8 РЕАЛИЗОВАНЫ (2026-06-11, smoke 63→77/77).** План прошёл redplan (`.plan-panel/2026-06-11_12-15-39-redreference-improvements/`, NEEDS-WORK@0.86 = потолок, фиксы вплетены). Что сделано:
> - **P1** дистилляция: caller пишет `$RUN_DIR/brief-keys.json` (query_tags 2-4 EN + intent); `round.sh resolve_query()` = `steer.txt > brief-keys > brief.txt`.
> - **P2** intent-routing: `_fetch_round` пул по интенту (site→Awwwards/Behance 8/8 + Are.na 2; mood→Are.na 3ch + 4/4); `INTENT=` в выводе.
> - **P3** title в ingest: `VOTED: #id [verdict] title — url`.
> - **P4** чистые анти: `anti_references` = ТОЛЬКО явный 👎 dismatch ref_url (vocab убран из экспорта); комменты → `preferences[]` (motion/scroll/scale/density/color/type × prefer/avoid), schema_version 1→2.
> - **P5** mid-loop steer: `round.sh next ... --steer "<dir>"` → `steer.txt` (сброс = удалить файл).
> - **P6** добор: COUNT<6 → накопить RAW (page+1/+2) → один dedup; `COUNT_BELOW_MIN=` warning; MOCK выключает.
> - **P7** stop-fix: streak по фактическим `phases/round-*.committed.jsonl` (`taste.js stop --committed-rounds`), не арифметика; раунд с лайком рвёт streak.
> - **P8** log: `log_event` тихий no-op при не-attached (был stdout-мусор); `log_attach` в next/ingest (append-only).
>
> **RUNBOOK-дельты:** `brief-keys.json`/`steer.txt` — caller-side не-WAL артефакты, переживают resume; сброс steer = `rm steer.txt`. Нет brief-keys → fallback на сырой `brief.txt` + intent=site.

---

## Прогон 2026-06-11 (спа/сауна-бриф → потом разворот в «агентства»)

### ✅ Что зашло (НЕ ломать)
- **Раздельные ⭐UX / ⭐UI + 💬 комментарий — киллер-фича.** Главный инсайт прогона («мы агентство, а не спа-бизнес»; «крупность элементов — хочу так же») пришёл из **свободного комментария**, не из цифр. Без него петля не поняла бы поворот. `liked_comments` → дизайн-стадия = самое ценное.
- Сходимость быстрая (2 раунда, чёткий сигнал).
- «📋 Копировать JSON → вставить в чат» без feedback-сервера — ноль трения.
- Адаптеры Awwwards/Behance — точно в нишу, со скриншотами (Leil Saunas, Gusta, noteworthy, A Quiet Thermal Spa).
- WAL / persist / local-first + экспорт в `visual-taste-profile` + `reference-likes` — штатно.

### ⚠️ Что мешало → 🎯 Backlog (по приоритету)

**P1. Query-дистилляция перед адаптерами.** *(самый большой прирост)*
Длинный русский абзац-бриф уходил в адаптеры сырым → Are.na выдал застройщиков ЖК, галереи матчили плохо. `arena.sh` сейчас лишь **отбрасывает слова с конца** (грубо), не дистиллирует по смыслу.
- *Фикс:* шаг brief→keys ДО фетча: извлечь 2–4 коротких англо-ключа (ниша/стиль/интент) из брифа (+ из лайкнутых тегов на раунд>1). Роль `brief-interpreter` (есть в reference.js BRIEF_SCHEMA, но round.sh её не зовёт) → `query_tags`. round.sh `next` использует их вместо сырого брифа.
- *Где:* `lib/round.sh` (QUERY=), `workflow/reference.js` (brief-interpreter), `lib/taste.js query` (уже даёт common keywords — переиспользовать).

**P2. Source-routing по интенту.**
Are.na как единственный live-источник раунда 1 — мимо на «spa/sauna/wellness» (у него ~0; он для мудбордов/фактур, не коммерческих лендингов).
- *Фикс:* для website/landing-интента вести **Awwwards/Behance**, Are.na — вторым/для текстур. Детект интента из брифа (landing|website|app → site-галереи; mood|texture|brand → Are.na). round-robin (уже есть в dedup-cards.py) сохранить, но **порядок/состав пула** по интенту.
- *Где:* `lib/round.sh` `_fetch_round` (сейчас зовёт только arena.sh — подключить awwwards.sh/behance.sh + интент-роутинг).

**P3. Title в answers/ingest.**
Чтобы узнать «card 14 = RELOAD», пришлось копать `round-2.*.jsonl` (дедуп/cap переставили id). В answers/ingest нет title — только `card_id`.
- *Фикс:* при ingest резолвить `card_id → title/ref_url` из round-cards и логировать/показывать; опц. класть title в feedback.jsonl (для аудита и для liked_comments-маппинга). build-page может класть title в payload (необязательно — caller резолвит из round-cards по card_id).
- *Где:* `lib/round.sh ingest` (резолв + вывод), опц. `lib/build-page.js` payload.

**P4. Чистые анти-референсы.**
В `anti_references` попали нормальные студии, просто не выбранные в раунд (Copula, REF Digital, NVRMND), и **обрывки комментов как теги** (`animation`, `scrolling`, `luxury`). «не нравится анимация при скролле» — ценный **motion-сигнал**, а записан как анти-реф → будущий дизайн может «избегать» хороших рефов.
- *Фикс:* (a) anti_references ТОЛЬКО на явный 👎 dismatch (уже так в taste.js — проверить, что skip/не-выбор НЕ попадает); (b) комментарии НЕ парсить в disliked_tags — выделить **structural preferences** (motion/scroll/density/scale) отдельным полем `preferences[]` из комментов (а не в анти). «не нравится X при скролле» → `{motion:"avoid scroll-jacking"}`, не anti.
- *Где:* `lib/taste.js` (anti gating + новый разбор комментов в preferences вместо disliked).

**P5. Mid-loop steer.**
Авто-`NEXT_QUERY` не ловит смену категории: после спа-лайков расширялся в «leil saunas interaction», хотя сказано «нужны агентства». Пришлось руками подменять пул через `MOCK_RAW`.
- *Фикс:* штатный `steer:`-ввод — одна строка, перебивающая query-экспансию на следующий раунд (`round.sh next <run> <N> --steer "agency portfolio"`). Surface как опцию между раундами.
- *Где:* `lib/round.sh next` (флаг `--steer` → QUERY override).

**P6. Добор при тонком раунде.**
Раунд 1 показал 5 карточек. Если источник вернул <6 — авто-подтянуть следующий адаптер/страницу ДО показа.
- *Фикс:* в `round.sh next` после dedup/cap: если COUNT < MIN(6) → fetch следующего адаптера / page+1, пока не наберём MIN или источники не кончатся.
- *Где:* `lib/round.sh next` (loop добора).

**P7. STOP=zero_like_streak ложно сработал** при 5 лайках в раунде 2 — логика стопа спорная.
- *Фикс:* пересмотреть `taste.js stop` — streak считать по раундам БЕЗ единого лайка; 5 лайков в раунде ≠ zero-like. Проверить, что round-номер в feedback совпадает с тем, по которому считается streak (возможно off-by-one из-за глобальных id / разнесённых run'ов).
- *Где:* `lib/taste.js` (cmd `stop`, ZERO_LIKE_STREAK логика).

**P8. (мелочь) `log_event: log_init not called`** лезет в stderr на старте.
- *Фикс:* `round.sh next`/`ingest` идут отдельными процессами → log_init не вызван. Либо вызвать `log_init` в начале каждой подкоманды, либо сделать log_event тихим при не-инициализированном логе (return 0 без echo).
- *Где:* `lib/log.sh` (тихий no-op) или `lib/round.sh` (log_init per subcommand).

---

### Сводная приоритизация
1. **P1 query-дистилляция** + **P2 source-routing по интенту** — вместе дают главный скачок релевантности (раунд 1 будет в нишу).
2. **P4 чистые анти-рефы** + **P7 stop-логика** — корректность сигнала (не «избегать» хорошего, не стопать рано).
3. **P3 title в ingest** + **P5 mid-loop steer** + **P6 добор** — UX петли.
4. **P8 log warning** — гигиена.

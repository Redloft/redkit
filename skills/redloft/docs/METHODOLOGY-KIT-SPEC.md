# redloft × Methodology Kit — Integration Spec (v2)

> Status: **Tier 0–4 РЕАЛИЗОВАНЫ; Phase 6 self-test пройден; врезка вычищена** (panel-verified spec). Источник истины для методологической «коробки» в redloft.
> Реализовано (2026-06-08): `lib/methodology.sh` + `lib/methodology-kit/{tier-0..4}` + `core-MPs/README` (provenance) + wire-in (landing-builder/commands/_shared/context/manage). `/redloft-status` показывает коробку (.methodology-version). **`/finalize` пройден (NEEDS-WORK@0.82 → фиксы применены):** safe-swap (.bak) вместо rmtree, убран мёртвый `--force-reseed`, anchor-regex DR-8-гарантии, guard незакрытого TIER-блока, depth-limit+лог в sitemap-walk, path-traversal guard, generated_at, YAML-escape title, `--skip-methodology`→`set_stage skipped` инвариант, reproducible-gate `tests/run-all.sh`. Тесты: run-all ALL GREEN — full smoke 168/168, methodology.smoke 58/58, **selftest (Phase 6) 19/19**, e2e 11/11, dryrun OK. Осталось ТОЛЬКО: живой billed e2e через Workflow (нужен реальный бизнес + согласие на cost).
> Язык артефактов коробки: **bilingual** (EN skeleton + RU inline-комментарии).
> Сиблинг-доки: `SKILL.md` (flow), `_shared.md` (контракты стадий/стейта), `commands/redloft.md` (caller-контракт).
>
> **v2 changelog** — свёрнут review `/plan-panel` (NEEDS-WORK@0.86, 6 ролей, конвергентно; артефакты в `.plan-panel/2026-06-08_01-41-49-redloft-methodology-kit/`):
> dir-level atomic write (C1), pipeline.json integration (C2), исполняемый RLS-template (C3),
> python3-substitution + exit-коды, идемпотентность, graceful degradation, DR-8/DR-9, Phase 1a/1b,
> и **новый §11 — онбординг «как работать по методологии» (START-HERE.md)**.

---

## 0. Что строим (one line)

redloft уже выдаёт `tz.md` + `prompt.md` для Claude Code на Next.js+Supabase базе.
Эта спека добавляет **третий гарантированный выход — методологическую коробку** (`methodology/`):
детерминированный scaffold рабочей методологии (CLAUDE.md hub-router, Hard Rules, tasks-lifecycle,
**START-HERE онбординг**, опц. routines), **пред-заполненный под конкретный проект** из накопленного
Project Context, который Claude Code разворачивает в корень нового репо первым шагом и **по которому
дальше ведёт всю работу над проектом**.

### Goals
- Каждый redloft-проект стартует с готовой методологией **и понятной инструкцией как по ней работать**.
- Коробка **знает про проект**: стек, ICP/USP, security-правила (RLS/PII/secret-rotation), geo-edge.
- Tier выбирается **автоматически** из сигналов redloft (без нового опроса, кроме апселла Tier 3/4).
- Generalized core — Wellbookin-isms вычищены; коробка переиспользуема и потенциально open-source.

### Non-goals
- НЕ строим отдельный репозиторий `claude-code-methodology-kit`. Коробка живёт в redloft.
- НЕ генерируем код методологии через LLM-агента — это **детерминированный shell-scaffold**.
- НЕ тащим в landing Tier 3/4 по умолчанию (cron routines, auto-merge) — opt-in.

---

## 1. Архитектурное решение: коробка = гарантированный детерминированный выход

redloft уже имеет паттерн **«гарантированных оркестратором блоков»** (`HANDOFF_CHECKLIST`,
`GEO_EDGE_TZ/PROMPT`, RLS-post-build-gate) — дописываются в выходы **независимо от LLM-агента**.
Коробка реализуется тем же приёмом, но на **caller-side** (как `build-hub.sh`), т.к. Workflow-скрипт
без FS-доступа, а коробка — файлы на диске.

> **⚠️ Уточнение после review (C1):** `build-hub.sh` пишет **один** файл атомарно (tmp + `os.replace`).
> `methodology.sh` пишет **дерево из 20–40 файлов** → нужна **собственная dir-level атомарность**
> (см. §5.1), а не «такая же, как build-hub». Формулировка «близнец build-hub» — про *паттерн*
> (детерминированный caller-side scaffold), НЕ про механизм записи.

**Правило:** ничего в коробке не зависит от «настроения» модели. Контент = статические шаблоны +
подстановка переменных из Project Context. Воспроизводимо, тестируемо hermetic dry-run'ом.

---

## 2. Tier-модель и авто-выбор

| Tier | Название | Включается | Сигнал-источник |
|---|---|---|---|
| **0** | Foundation | ВСЕГДА | — |
| **1** | Solo | дефолт любого сайта | — |
| **2** | Multi-aspect | авто | `site_type ∈ {ecommerce, multi-page, catalog, multi-entity}` (Q13) **OR** `semantic.content_clusters ≥ CLUSTER_THRESHOLD` (=4, DR-9) |
| **3** | Production | opt-in (спросить) | production-сигнал в брифе ИЛИ `geoEdge` активен |
| **4** | Advanced | opt-in (редко) | только по явному запросу (goal-pursuit, codegraph) |

Логика (caller, Шаг 6): `tier=1; if site_type∈MULTI → 2; elif clusters≥4 → 2; offer_tier3 = production|geoEdge → AskUserQuestion`.
Тиры **накопительны**: Tier 2 = files(0)+files(1)+files(2).

---

## 3. Содержимое коробки по тиру (manifest + источник MP)

Все файлы bilingual. `{{...}}` — плейсхолдеры (§4). Источник = generalized из 60 Wellbookin MP.

### Tier 0 — Foundation (всегда)
| Файл | Содержание | Из |
|---|---|---|
| `START-HERE.md` | **онбординг «как работать по методологии»** (§11) — читается первым | new (см. §11) |
| `CLAUDE.md` | hub-router skeleton: проект, стек, ссылки на `START-HERE`, `tz.md`, Hard Rules, tasks/ | MP-031/033 |
| `docs/HARD-RULES.md` | 6 тематических кластеров (presentation), только **core** | MP-028 + MP-009/013 |
| `docs/tz.md` | копия redloft `tz.md` (источник правды по продукту) | redloft-native |
| `supabase/rls-bootstrap.sql` | **исполняемый** RLS deny-by-default + per-table policy (C3) | DR-7 |
| `.gitignore`, `README.md` | базовые | — |

Core Hard Rules (Tier 0): **A. Branch&Commit** (не пушить в `main`/`dev`; pathspec-commit MP-009; branch-verify MP-013) · **C. Quality Gate** (не ослаблять typecheck/lint/build; перед коммитом зелёный `/finalize`) · **F. Security** (RLS deny-by-default → `rls-bootstrap.sql`; секреты только op/1Password; PII-lifecycle).

### Tier 1 — Solo (дефолт)
`docs/tasks/PROTOCOL.md` (lifecycle + approval gate, MP-001/005) · `docs/tasks/TASK-TEMPLATE.md` (YAML frontmatter, MP-008/043) · `docs/tasks/{pending,ready,in_progress,done}/.gitkeep` · `docs/prompts/iteration.md` (closing-flow, MP-014/025) · `docs/working-protocol.md` (Mode A/B lightweight).

### Tier 2 — Multi-aspect (e-comm/multi-page)
`docs/chats/REGISTRY.md` (planning-чаты на сущность + dispatcher, MP-004/010) · `docs/chats/handoff-queue.md` (MP-034) · `docs/methodology-proposals/{README,INDEX,MP-TEMPLATE}.md` (MP-029) · `docs/product-principles.md` (seed из planning).

### Tier 3 — Production (opt-in)
`routines/R1..R4` (MP-011/012/015/017/041) · `.github/workflows/auto-merge.yml` (MP-018/044) · `docs/security-quality-gate.md` + `docs/performance-quality-gate.md` · `docs/feedback-journal.md` (MP-020/025/049).
> Для **лендинга** cron-routines R1-R4 избыточны → при opt-in по умолчанию ставим только QG + auto-merge (DR-9).

### Tier 4 — Advanced (opt-in, редко)
goal-pursuit MP-050/052/055/057 + codegraph-setup. **Вне scope первой реализации.**

---

## 4. Плейсхолдеры и сидинг из Project Context

| Плейсхолдер | Источник |
|---|---|
| `{{PROJECT_NAME}}` | slug / brief |
| `{{PROJECT_TITLE}}` | brief.summary |
| `{{STACK}}` | константа `Next.js + Supabase (supastarter)` |
| `{{ICP}}` `{{JTBD}}` `{{USP}}` | `planning/planning.md` key_claims |
| `{{SITE_SECTIONS}}` | `sitemap/` → seed задач в `tasks/pending/` |
| `{{GEO_EDGE_RULE}}` | `geoEdge` флаг |
| `{{SECURITY_RULES}}` | DR-7 findings (whitelisted поля, §5.4) |
| `{{TIER}}` | выбранный tier |

> **Подстановка — только `python3`, НЕ `sed` (C4/§5.4).** Снимает разом: shell-injection через
> LLM-seed, транзитивный prompt-injection, и **корректную UTF-8/кириллицу** (sed на кириллице ломается).

### Killer-фича: project-specific слой засевается, не пишется руками
- `HARD-RULES.md` ← seed из DR-7 (RLS deny-by-default — `rls-bootstrap.sql`; secret-rotation; PII) + geo-edge rule если `geoEdge`.
- `tasks/pending/` ← seed по разделам sitemap (по одной задаче на ключевой экран).
- `product-principles.md` ← seed ICP/JTBD/USP из planning.

Итог: коробка приезжает **знающей про проект**, не generic-болванка.

---

## 5. Раскладка в скилле + контракт `methodology.sh`

```
~/.claude/skills/redloft/
├── lib/
│   ├── methodology.sh            # 🆕 ассемблер (контракт §5.1-5.4)
│   └── methodology-kit/          # 🆕 bilingual шаблоны
│       ├── tier-0/ tier-1/ tier-2/ tier-3/ tier-4/
│       ├── core-MPs/             #     provenance-карта tier→MP (maintainer-only, §7)
│       └── MANIFEST.json         #     tier → список файлов + manifest_version
├── workflow/landing-builder.js   # ✏️ + METHODOLOGY_PROMPT_STEP (гарант. блок)
├── commands/redloft.md           # ✏️ Шаг 6 (§6.2)
├── _shared.md                    # ✏️ §X methodology-артефакт + directory register_artifact (§6.3)
├── docs/METHODOLOGY-KIT-SPEC.md  # 📄 этот файл
└── tests/                        # ✏️ smoke (§8)
```

### 5.1 Dir-level atomic write (C1) + safe-swap (finalize-finding)
```
1. render → $PD/methodology.tmp.<pid>/         (НЕ сразу в финал)
2. validate: ни одного незаполненного {{...}}; все файлы MANIFEST на месте; нет незакрытых TIER-блоков
3. safe-swap (НЕ rmtree+rename — оставлял окно «нет ни старой, ни новой»):
   if DEST exists: rename DEST → DEST.bak-<pid>
   rename tmp → DEST          (atomic на одной ФС)
   на сбое второго rename: restore DEST.bak → DEST
   на успехе: rm -rf DEST.bak  (правки разработчика переживают сбой)
4. finally: rm -rf tmp  (на любом ненулевом exit)
   guards: src внутри KIT, dst внутри tmp (path-traversal defence-in-depth)
```
Гонка concurrent-runs на финальном `mv` (gap) → tmp-имя с `$$` (pid) уникально; `mv -T` overwrite атомарен.
Smoke: kill-9 в середине рендера → финальной `methodology/` нет, tmp убран.

### 5.2 Exit-коды (контракт для caller)
| code | значение | реакция caller |
|---|---|---|
| 0 | коробка собрана | register_artifact, продолжить |
| 1 | фатал (нет MANIFEST/шаблонов/невалидный tier) | abort стадии methodology + warn |
| 2 | незаполненные плейсхолдеры после рендера | abort + warn (баг шаблона/сидинга) |
| 3 | soft: собрано, но upstream-стадии не было (degraded, см. 5.3) | продолжить + warn |

### 5.3 Graceful degradation (отсутствие upstream-артефактов)
- нет `semantic/` → `clusters=0` → Tier 1 (warn).
- нет `sitemap/` → один `tasks/pending/00-SETUP.md` плейсхолдер вместо seed по разделам.
- нет `planning/` → `product-principles`/ICP-плейсхолдеры с inline-TODO.
Фикстуры: `no-semantic`, `no-sitemap`.

### 5.4 Безопасность подстановки (C4 + secret-check)
- `python3`-substitution + sanitize/length-cap seed-значений; whitelist полей для `{{SECURITY_RULES}}`.
- PII grep-guard на seed-значениях (не пускать телефон/email в HARD-RULES).
- Существующий секрет-чек в `redloft.md` сузить: реальные token-shapes, **drop `op://`** (легитимны), `--exclude-dir=methodology`; + pre-copy token-grep в Шаге 0 prompt.md.

### 5.5 Идемпотентность (re-run / `--force`)
- **Коробка собирается целиком** (atomic), поэтому идемпотентность — на уровне всей `methodology/`:
  есть и не `--force` → **skip** (не перетираем правки); `--force` → полная безопасная пересборка (safe-swap §5.1).
- ~~`--force-reseed`~~ — **убран** (finalize-finding): был мёртвым флагом (гранулярного reseed нет, т.к. дерево
  пересобирается целиком). Обновление seed = `--force`.
- `.methodology-version` несёт `manifest_version` + `tier` + `generated_at`.

---

## 6. Точки врезки (минимальный diff)

### 6.1 `landing-builder.js` — гарантированный шаг в prompt.md (как GEO_EDGE_PROMPT)
```js
const METHODOLOGY_PROMPT_STEP = [
  '## Шаг 0 (обязательный, не пропускать) — Развернуть методологическую коробку',
  'В корне репо лежит папка `methodology/` (приехала с этим ТЗ, tier {{TIER}}).',
  '1. ПЕРЕД копированием: `grep -rIn` коробки на реальные токены — если нашёл, СТОП.',
  '2. Скопируй содержимое `methodology/` в корень репо.',
  '3. **Прочитай `START-HERE.md` — это инструкция как работать над проектом.** Затем `CLAUDE.md` и `docs/HARD-RULES.md`.',
  '4. Применить `supabase/rls-bootstrap.sql` (deny-by-default) ДО первого деплоя.',
  '5. Первый коммит: "chore: methodology kit (tier {{TIER}})" в рабочую ветку (НЕ main).',
  '6. Дальше веди работу по `START-HERE.md` / `docs/tasks/PROTOCOL.md`.',
].join('\n')   // дописывается в prompt_md ВСЕГДА
```
`tz.md` → раздел «Методология проекта» (в `HANDOFF_CHECKLIST`-стиле): что в коробке, какой tier, ссылка на START-HERE.

### 6.2 `commands/redloft.md` — Шаг 6 (caller, после write artifacts)
```
6.x  Tier-выбор по §2 (brief.site_type + semantic clusters).
6.y  offer_tier3 → AskUserQuestion (добавить Tier 3: QG + auto-merge?).
6.z  bash lib/methodology.sh "$PD" --tier <N> [--tier3] [--force]
      exit 0|3 → продолжить; 1|2 → warn (методология soft-fail, не рушит выдачу).
6.w  на exit 0/3: register_artifact "$PD" methodology kit "methodology/" render '["tier <N>","seeded: rls,pii,geo"]'
      set_stage "$PD" methodology done|skipped|failed
```

### 6.3 `_shared.md` — §X Methodology artifact + directory register_artifact (C2)
- `methodology/` — render-стадийный артефакт; детерминированный; **не идёт через reviewer** (нет key_claims-прозы), проверяется hermetic-тестом на полноту плейсхолдеров.
- **Формально расширить `register_artifact`**: разрешить `path` = директорию (сейчас только файл — недокументированное расширение). Описать в `_shared.md` контракт directory-артефакта.
- `pipeline.json`: `stage_id=methodology`, статус `done|skipped|failed`, на сбое `set_stage failed`+warn (НЕ abort — коробка UX-опциональна). Персист `chosen_tier`/`kit_version`/seed-event.

### 6.4 Decision Records
- **DR-8** Методкоробка = детерминированный caller-side scaffold; **собственная dir-level атомарность** (tmp+mv+trap, §5.1); failure-policy = `set_stage failed`+warn+continue (+`--skip-methodology`); doставка через гарантированный Шаг 0 в prompt.md; tier авто из brief, Tier 3/4 — opt-in; register_artifact принимает directory.
- **DR-9** Зафиксированы §10-решения: delivery = `methodology/` в `$PD` (не heredoc); `CLUSTER_THRESHOLD=4` (именованная константа); seed задач → `tasks/pending/` (уважая approval gate MP-005); Tier-3 на лендинге → только QG+auto-merge, routines R1-R4 skip.

---

## 7. Generalization: что вычистить из Wellbookin MP

Убрать: доменные сущности (EAM, bookingService, specialists, addons) → `{{ENTITY}}`-примеры · пути Hetzner/Mac/IP → плейсхолдеры · Russian-only → bilingual · Wellbookin-specific Hard Rules (`AuthContext.tsx` и т.п.) → generic · ссылки на конкретные docs → относительные.
Маппинг tier→MP: Tier1 MP-001/005 · Tier2 MP-004/005/029/034 · Tier3 MP-011/018/020 · Tier4 MP-050/052/057 · Cross MP-009/013/028.

---

## 8. Acceptance (Done-when)

| # | Критерий |
|---|---|
| A1 | `methodology.sh "$PD" --tier 1` → `$PD/methodology/` с START-HERE+CLAUDE+HARD-RULES+tasks/, **0 незаполненных `{{...}}`** |
| A2 | Tier авто: landing→1, ecommerce→2 (hermetic-фикстуры brief.json) |
| A3 | `prompt.md` ВСЕГДА содержит «Шаг 0» со ссылкой на START-HERE (гарантия) |
| A4 | project-specific seed: RLS (`rls-bootstrap.sql`)/PII/secret-rotation в HARD-RULES; geo-edge rule при geoEdge |
| A5 | `tasks/pending/` засеян по разделам sitemap; при no-sitemap → `00-SETUP.md` |
| A6 | **Atomicity**: kill-9 в середине рендера → нет финальной `methodology/`, tmp убран |
| A7 | **Exit-коды** 0/1/2/3 по §5.2; caller трактует 3 как soft-warn |
| A8 | **Injection-фикстура** (апострофы, backticks, `$`, кириллица, YAML-injectible) проходит через python3-substitution без поломки/инъекции |
| A9 | **Idempotency**: повторный запуск без `--force` не перетирает; `tasks/pending/` skip-if-nonempty |
| A10 | smoke для tier 0–2; Tier 3 при `--tier3`; grep-gate Phase 1 (0 Wellbookin/AuthContext/Hetzner хитов); MANIFEST-vs-filesystem полнота |
| A11 | Шаблоны bilingual (EN + RU comment) |

---

## 9. Фазы реализации

- **Phase 1a — Audit**: протегировать 60 MP, выписать все Wellbookin-строки, отобрать ~20 MP для Tier 0–2. Grep-gate-список. (≈1 ч)
- **Phase 1b — Generalize**: вычистка §7 → `core-MPs/`; grep-gate проходит (0 хитов). (≈10 ч)
- **Phase 2 — Templates**: `methodology-kit/tier-0..2/` bilingual + `START-HERE.md` + `rls-bootstrap.sql` + `MANIFEST.json`. **Гейт: DR-8/DR-9 задокументированы ДО написания шаблонов.**
- **Phase 3 — Assembler**: `lib/methodology.sh` (atomic §5.1 + exit-коды §5.2 + degradation §5.3 + python3-subst §5.4 + idempotency §5.5) + hermetic smoke (A1/A6/A7/A8/A9).
- **Phase 4 — Wire-in**: `landing-builder.js` (METHODOLOGY_PROMPT_STEP) + `commands/redloft.md` Шаг 6 + `_shared.md` §X + DR-8/DR-9.
- **Phase 5 — Tier 3** (opt-in: QG + auto-merge; routines skip для лендингов) — отдельно.
- **Phase 6 — Self-test**: прогон на фикстуре «банный комплекс», проверить коробку + START-HERE в выходе.

---

## 10. Открытые решения — ЗАКРЫТЫ (DR-9)

1. ~~CLUSTER_THRESHOLD~~ → **4** (именованная константа).
2. ~~Доставка файлов~~ → **`methodology/` в `$PD`** (Claude Code копирует по Шагу 0), не heredoc.
3. ~~tasks/ seed~~ → **`pending/`** (уважает approval gate MP-005).
4. ~~Tier 3 routines на лендинге~~ → **skip** даже при opt-in; оставить QG + auto-merge.

---

## 11. 🆕 Онбординг: «как работать по методологии» (START-HERE.md)

> Требование заказчика: **просто и понятно**. Когда redloft развернул проект, разработчик/Claude Code
> должен за 1 минуту понять рабочий цикл. Поэтому — отдельный одностраничник `START-HERE.md`,
> читается ПЕРВЫМ (на него ссылается prompt.md Шаг 0 и CLAUDE.md).
> Tier-aware: на Tier 1 — только цикл задач; Tier 2 добавляет блок «несколько направлений»;
> Tier 3 — блок «рутины». Лишних тиров в файле нет (methodology.sh собирает по tier).

### Контракт START-HERE.md (что в нём, bilingual)

```markdown
# START HERE — как работать над {{PROJECT_TITLE}}
> Этот проект ведётся по простой методологии. Прочитай за 1 минуту — и работай по циклу ниже.

## 0. Один раз при старте
1. Прочитай `CLAUDE.md` (что за проект, стек {{STACK}}) и `docs/HARD-RULES.md` (правила — их нельзя нарушать).
2. Применил `supabase/rls-bootstrap.sql`? Без этого БД открыта. Сделай до первого деплоя.
3. Глянь `docs/tasks/pending/` — там уже лежат задачи по разделам сайта.

## 1. Рабочий цикл — повторяй для каждой задачи
   ┌─ Берёшь задачу из `docs/tasks/ready/`  (пусто? см. §2)
   │   ↓
   │  Создаёшь ветку (НЕ работаешь в main/dev) → перенёс задачу в `in_progress/`
   │   ↓
   │  Делаешь по описанию задачи
   │   ↓
   │  Прогон `/finalize` (typecheck + lint + build + ревью). Красное — чинишь, не коммитишь.
   │   ↓
   │  Коммит только нужных файлов (`git add <конкретные пути>`, не `git add .`)
   │   ↓
   └─ Перенёс задачу в `done/`. Берёшь следующую.

## 2. Новая задача / идея
1. Создай файл в `docs/tasks/pending/` по `docs/tasks/TASK-TEMPLATE.md`.
2. Готова к работе? Перенеси в `ready/` (это и есть «одобрено», approval gate).
   Пока в `pending/` — не берём в работу.

## 3. Чего нельзя (Hard Rules — кратко, полное в docs/HARD-RULES.md)
- ❌ пушить прямо в `main`/`dev`  ·  ❌ `git add .` вслепую  ·  ❌ ослаблять typecheck/lint/build
- ❌ секреты в код/.env — только 1Password  ·  ❌ деплой без RLS deny-by-default

## 4. Когда что-то улучшил в самом процессе
Запиши короткую заметку в `docs/methodology-proposals/` (если есть, Tier 2+) — методология растёт с проектом.

<!-- TIER-2 BLOCK (если несколько направлений) -->
## 5. Несколько направлений сразу
Каждое направление/сущность ведёшь отдельным planning-чатом — реестр в `docs/chats/REGISTRY.md`,
передача между чатами через `docs/chats/handoff-queue.md`.

<!-- TIER-3 BLOCK (production) -->
## 6. Прод и поддержка
Quality Gates — `docs/security-quality-gate.md` / `docs/performance-quality-gate.md`.
Авто-мерж зелёных веток — `.github/workflows/auto-merge.yml`.
```

### Принципы онбординга
- **Один цикл, не дерево протоколов.** Подробности — в `docs/`, но START-HERE даёт рабочий минимум.
- **Конкретные команды/папки**, не абстракции («перенеси в `ready/`», а не «пройди approval gate»).
- **Tier-aware сборка**: блоки §5/§6 вставляются `methodology.sh` только если tier ≥ 2/3.
- **Project-filled**: `{{PROJECT_TITLE}}`/`{{STACK}}` подставлены — выглядит как написанный под проект.

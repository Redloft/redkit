# REDLOFT — архитектурный разбор

> **Статус (2026-06-02): research завершён, Phases A–F1 реализованы** (live-статус — `HANDOFF.md`). Этот файл — архитектурные решения + backing research (исторический контекст); 🔬-пункты закрыты разделом «Research findings» ниже.

## Ключевой инсайт

REDLOFT — это **та же модель, что `redresearch` и `plan-panel`**: оркестратор, который не работает сам, а гоняет skills по детерминированному пайплайну (Workflow-скрипт), с **Reviewer-петлёй** и **общим контекстом** между этапами. → У нас уже есть рабочий шаблон оркестратора (`research.js`) и шаблон панели ролей с judge/cross-examination (`plan-panel`). Это **сборка**, не «с нуля».

Оценка: ~70% уровня-1 скиллов закрывается существующими; новое — оркестраторы, Sitemap/Content/Design-спеки, Reviewer-петля как переиспользуемый слой, Project Memory, client handoff, doc-site.

## Маппинг: REDLOFT skill → что уже есть

| REDLOFT (уровень 1) | Существующее | Дописать |
|---|---|---|
| **Research** | `redresearch` (heavy/ultra, cited) + `domain-check` (нейминг/домен) + `project-map` | бизнес/конкурент-обёртка, профиль ЦА |
| **Planning** (агентство) | паттерн `plan-panel` (панель ролей + judge) | роли: CEO/PM/UX/Marketing/SEO/Dev → ICP/JTBD/USP/Brief |
| **Sitemap** | — | новый (вход: Planning+SEO) |
| **SEO** | `audit-site` (SEO-блок), `anthropic-skills:seo` | кластеризация запросов → SEO-страницы |
| **Content** | `content-gen` (визуал/стоки), `humanizer` (анти-AI текст) | копирайт: офферы/экраны/FAQ/CTA/статьи |
| **Design** | `page-design-pipeline`, `emil-design-eng`, `animate`, `design-motion-principles`, Figma-skills | design-spec + промты для Claude Code |
| **Performance → Perf/SEO/GEO** | **`audit-site` уже делит ровно на CWV+SEO+GEO** | оформить как 3 отдельных скилла (как ты просил) |
| **Reviewer** ⭐ | `plan-panel` judge + cross-examination | переиспользуемая критик-петля между этапами |
| **Memory** (future) | частично `project-map` | persistent **Project Context** слой |
| (реализация/аудит кода) | `codegraph` MCP | — |
| **Client handoff** | — 🔬 | Supabase + перенос хостинга/БД, передача ownership |
| **Docs** (dev.max.ru/help-стиль) | — 🔬 | doc-site генератор под 3 аудитории |
| **🆕 Briefing** (pre+post) | мультимодал: Read (картинки/скрины), WebFetch+screenshot (сайты), `domain-check` | taste-probing flow + Visual Taste Profile + reference survey |
| **🆕 Self-improve** | паттерн `plan-panel`: `feedback/*.jsonl` + `solidify.sh` + `share-prompt.sh` | feedback-петля на все скиллы REDLOFT + брифинг |

## Оркестратор Landing Builder (MVP) — как Workflow-скрипт

Зеркалит `research.js`: `phase()` на каждый этап, `agent()`/под-`workflow()` на skills, артефакты в Project Context, Reviewer между этапами.

```
вход: {бизнес-описание, URL?, материалы клиента?}
  → 🆕 PRE-BRIEFING  (materials-first: клиент вываливает ВСЁ [тексты/транскрипт звонка/
                      скрины/ссылки] → авто-заполняю схему brief-schema.md → спрашиваю
                      ТОЛЬКО пробелы (gap-driven) + visual taste-probing → живой Brief)
  → Research      (redresearch heavy → Research Report; собирает КАНДИДАТЫ-референсы)
  → 🆕 POST-BRIEFING (показать найденные сайты/изображения → survey «что ближе»
                      → уточнить Visual Taste Profile перед дизайном)
  → Planning      (agency-panel → Brief/ICP/JTBD/USP)
  → Reviewer #1   (полнота позиционирования? противоречия research↔brief?)
  → Sitemap       (структура из brief+research)
  → SEO           (кластеры → SEO-структура страниц)
  → Reviewer #2   (sitemap покрывает SEO-кластеры? логика переходов?)
  → Content       (тексты экранов/офферы/FAQ/CTA по sitemap+SEO)
  → Design        (концепция+UI+промты; ОПИРАЕТСЯ на Visual Taste Profile)
  → Reviewer #3 (final) (всё согласовано? ТЗ полное? промт исполним?)
выход: ТЗ + sitemap + content pack + design spec + промт для Claude Code
  → 🆕 SELF-IMPROVE  (feedback по всему циклу → solidify промтов ВСЕХ скиллов + брифинга)
```

**Reviewer-петля (из plan-panel):** после ключевых этапов judge ищет противоречия/пробелы; при FAIL/NEEDS-WORK — этап переигрывается с замечаниями (как cross-examination, но между этапами). Бюджет: макс 1-2 ре-ран на этап (иначе зацикливание).

## Project Context (общий стейт + зародыш Memory)

Как redresearch run-dir, но **per-project и накапливающий**:
```
~/Library/Application Support/redloft/projects/<project-slug>/
  context.json        ← live стейт пайплайна (этапы, статусы, ссылки на артефакты)
  research/           ← Research Report + sources/claims (из redresearch)
  brief/ sitemap/ seo/ content/ design/   ← артефакты этапов
  reviews/            ← Review Reports
  memory/             ← бренд-гайд, tone of voice, design-system, SEO-кластеры (Memory Skill)
  tz.md  prompt.md    ← финальные выходы
```
Memory Skill (фаза 2): при повторном запуске по тому же `<project-slug>` — этапы читают `memory/` и **развивают**, а не начинают с нуля. Это и есть слой «система vs набор агентов».

Data residency: как redresearch — локально (`~/Library/Application Support/redloft/`), НЕ Яндекс.Диск.

## 🆕 Briefing — Phase 0.5 (pre) + post-research checkpoint

Парадная дверь системы. Цель — **попасть в визуальные + позиционные ожидания ДО** дорогих downstream-этапов (это прямо поднимает качество всего цикла).

**Pre-briefing = ДИНАМИЧЕСКИЙ, materials-first (ключевой принцип пользователя).** Бриф — не статичная форма, а ЖИВАЯ схема (must-know = `docs/brief-schema.md`, 34 вопроса Redloft), наполняется из 3 источников и финализируется по итогам ВСЕХ работ (как часть ТЗ):
1. **Materials dump (СНАЧАЛА!)** — клиент вываливает всё что есть: тексты, черновики ТЗ, **запись/транскрипт звонка**, скриншоты, ссылки, артефакты первичного касания. Я разбираю (`Read` для файлов/PDF/изображений, транскрипт аудио, `WebFetch`/firecrawl для ссылок) и **авто-заполняю** вопросы схемы, на которые ответы уже есть в материалах.
2. **Gap-driven Q&A** — спрашиваю пользователя ТОЛЬКО непокрытую дельту схемы, уважая **branching** (Q13 тип сайта → какие разделы вообще нужны; e-commerce-блок Q15-21 только для магазина). Не спрашиваю то, что уже извлёк.
3. **Visual reference intake (Q11/Q12)** — мультимодально, по одному референсу: картинка/скрин (`Read`) или URL (`design_extract_tokens`/screenshot) + «нравится» → наводящие (палитра/композиция/типографика/кнопки/mood) → **Visual Taste Profile**. «Нужна рекомендация» (Q17-20) → REDLOFT сам предлагает стек из research.

→ Бриф НЕ финальный на входе: обогащается research'ем (ЦА/конкуренты/SEO) и фиксируется в конце. Это и есть «динамический бриф».

**Post-research briefing:**
- Research собирает **кандидаты-референсы** (сайты ниши/конкурентов + визуальные образцы).
- Показываю подборку → survey «что ближе / что отторгает» → уточняю Taste Profile перед Design.
- Закрывает разрыв «я думал, вы хотели X».

Артефакты: `brief/brief.md` + `brief/visual-taste-profile.json` в Project Context → кормят Design, Content и всю систему. Инструменты уже есть: `Read` (изображения), `WebFetch`+chrome/playwright (скрин сайтов), `content-gen` (генерация образцов-вариантов на выбор), `domain-check`.

### Reference engine (поиск визуальных референсов) — статус API 2026

Платформенные API почти все закрылись для поиска инспирейшна:
- **Pinterest API v5** — есть `/search/pins`, НО gated: Trial = sandbox (пины скрыты), нужен Standard access (видео-демо + ручное ревью), поиск ориентирован на свои/partner-пины. Онбординг > польза для MVP → **skip**.
- **Dribbble API v2** — стал publish-only (v1 retired), просмотра/поиска shots больше НЕТ → **тупик для референсов**.
- **Behance** — публичного API нет (Adobe выпилил).

**Рабочий паттерн 2026 = search-with-`site:`-filters + token-extraction**, не платформенные API:
- **У нас уже есть `firecrawl`** → тот же site:-scoped поиск по галереям (dribbble/behance/mobbin/awwwards/land-book) + скрейп — без новых ключей. **Primary, бесплатно.**
- **✅ УСТАНОВЛЕНО (2026-06-01, вариант B):** `design-inspiration-mcp-server` (YonasValentin) — MCP user-scope, ищет Dribbble/Behance/Awwwards/Mobbin/Pinterest через **Serper** + `design_extract_tokens` (палитра/типографика/spacing/radii/shadows с живого сайта через `dembrandt`). Запускается через `op run --env-file ~/.claude/mcp/serper.op.env` (ключ из 1Password, в конфиге только `op://`-ссылка). 4 тула: `design_search_images`, `design_search_references`, `design_search_styles`, `design_extract_tokens`. Код: `~/.claude/mcp/design-inspiration-mcp-server` (audited: только Serper + dembrandt, без exfil). Доступен после reconnect MCP.
- **Киллер-фича для «нравится ЭТОТ сайт»:** extract design tokens с живого URL → реальная палитра/шрифты/отступы → прямо в Visual Taste Profile + Design skill. Делается `design_extract_tokens` ИЛИ нашими chrome-devtools/playwright + firecrawl.
- Стоковое фото — Unsplash/Pexels/Pixabay (уже в `content-gen`); генерация moodboard-вариантов — `content-gen`.

Вывод: за Pinterest/Dribbble API гоняться не нужно — firecrawl + (опц.) design-inspiration MCP + token-extraction закрывают reference-движок брифинга.

## 🆕 Self-improvement loop (работа над ошибками — встроена)

После полного цикла — **обязательный** feedback + solidify. Паттерн `plan-panel` переиспользуется 1:1:
- `feedback/<skill>.jsonl` — накопление замечаний (что сработало/нет на прогоне) по каждому скиллу **и брифингу**.
- `solidify` — на основе накопленного feedback правит промпт конкретного скилла (как `/panel-solidify`).
- `share-prompt` — PR-ready bundle, если улучшение в upstream.
- Триггер: после финального Reviewer — «дать feedback по этапам?» → собрать → предложить solidify слабых мест. Повторяющиеся Reviewer-замечания на этап = автоматический кандидат на solidify.

Цель: каждый прогон делает систему **и брифинг** лучше — это и есть «система самоулучшения процесса», а не набор статичных агентов.

## MVP scope (что строим первым)

1. Оркестратор `landing-builder` (Workflow-скрипт) — каркас пайплайна + Project Context + Reviewer-петля.
2. Этапы через **существующие** skills где можно (Research=redresearch, Reviewer=plan-panel-judge, Perf/SEO/GEO=audit-site, Design=page-design-pipeline, Content визуал=content-gen).
3. Новые тонкие скиллы: agency-panel (Planning), Sitemap, Content-copy, Design-spec.
4. Выход: ТЗ + промт для Claude Code.

Отложено в фазу 2: Website Improver, Product Builder, полноценный Memory Skill, doc-site генератор, turnkey client handoff.

## ✅ Research findings (heavy-research: 25 источников, 179 claims, cite-coverage 0.96)

Полный отчёт: `~/Library/Application Support/redresearch/runs/2026-06-01_20-35-13-redloft-system-research/report.md`. Ключевые решения (закрывают бывшие 🔬):

1. **Оркестрация = control plane** [arXiv 2601.13671; MS Learn]. Оркестратор обеспечивает когерентность, НЕ просто маршрутизирует. Разделять **planning** (декомпозиция «идея→этапы ТЗ») и **policy** (governance). Состояние двухслойное: **operational** (чекпоинты/прогресс) + **knowledge** (контекст) = наш Project Context. 3-tier агенты (worker/service/support). Внешние инструменты — через MCP с проверкой схем. Перед мульти-агентом оценивать по лестнице: direct call → single agent+tools → multi-agent (overhead оправдан только при реальной сложности).
2. **Reviewer-петля = maker-checker** [Reflexion NeurIPS'23: 91% vs 80% pass@1; critique-routing +15.8 п.п.]. Передавай агенту **запрос + предыдущий черновик + critique**; буфер рефлексий короткий (1-3). **ОБЯЗАТЕЛЬНО iteration cap + fallback на человека**; оптимум — **2 хода**, дальше насыщение. → мой план «макс 1-2 ре-рана на этап» подтверждён эмпирикой.
3. **🔴 Turnkey Supabase — развилка моделей** [Supabase Docs]. Строить на **self-serve Project Transfer** (модель A): переход ownership к клиенту возможен, НО — один регион, предварительно отключить GitHub-интеграцию/log drains/project-scoped роли, downtime 1-2 мин при downgrade на Free. **НЕ строить на Vercel Marketplace** (модель B): проект нельзя перенести между Supabase-org стандартно, ownership только через Vercel Team roles. Это влияет на архитектуру поставки с самого начала.
4. **Turnkey-сборка обязана включать БД + security из коробки** [уроки Lovable/Bolt]. Авто-генерировать и **валидировать RLS** в оркестраторе (клиенты Lovable застревают на RLS днями); интегрированная БД из коробки (Bolt без неё непригоден для нетехнических). → это работа оркестратора, не клиента.
5. **Doc-site = гибрид под 3 аудитории** [сравнения 2026]. Dev → **Mintlify** (MCP + API playground + авто llms.txt/llms-full.txt) или **Docusaurus** (бесплатно, LCP 0.9s, контроль). Клиент/контент-менеджер → **GitBook** (WYSIWYG, real-time, без Git). Формат dev.max.ru/help ≈ Mintlify/Docusaurus-стиль.
6. **GEO > keyword clustering** [GEO-bench peer-reviewed + гиды 2026]. Зашить в Content/SEO-скиллы: статистика + цитаты + авторитетные источники (+30-40% видимости); структура «прямой ответ → контекст → FAQ»; **llms-full.txt** (абсолютные URL + описания); robots.txt открыт для GPTBot/ClaudeBot/PerplexityBot; schema (Article/FAQ/HowTo). **Keyword stuffing вредит** в генеративных движках. GEO особенно усиливает новые лендинги без домен-авторитета.

### ✅ Добор-research (фреймворки/builders/boilerplates — gap закрыт, 12 источников, cite 0.93)

7. **Оркестратор REDLOFT = Claude Code Workflow tool** (наш research.js-паттерн). Добор: Claude Agent SDK — #2 production-рейтинга, Anthropic-native (hooks/MCP/skills/subagents) — а Workflow tool это и есть его рантайм, мы уже на нём. LangGraph — #1 для **standalone Python** (stateful, checkpointing, HITL; Klarna/Uber/LinkedIn), берём ТОЛЬКО если понадобится сервис вне Claude Code. CrewAI — быстрый прототип. AutoGen — дорогой ($0.45/задача). → **не тащим внешний фреймворк в v1.**
8. **Builders как референс/выход**: **v0** (Vercel) — эталон качества кода (production TS + shadcn/ui, без `any`) → планка для нашего code-output + handoff на Next.js/Vercel. **Relume** — AI-sitemap→wireframe→стайлгайд (НЕ production-код) → паттерн для нашего **Sitemap-скилла**. **Framer** — маркетинг-лендинги (low-maintenance). **Lovable** — rapid MVP+Supabase (но loose typing, рефакторинг). REDLOFT сам генерит на Claude Code → целимся в v0-уровень кода.
9. **Turnkey-база = Next.js + Supabase boilerplate**: **supastarter Agency (€1499, unlimited client projects, white-label)** — идеально под agency-модель REDLOFT (multi-tenancy/billing/admin/auth из коробки → закрывает «БД+RLS+security из коробки» из п.4 + white-label handoff). Альтернатива: **MakerKit** ($299-599 lifetime, Next.js16+React19+Supabase+shadcn). Это и есть «готовая сборка на гите», о которой ты спрашивал.

## Следующие шаги

1. ✅ heavy-research → фактура сведена.
2. ✅ добор-research (фреймворки/builders/boilerplates) → gap закрыт, tech-stack выбран.
3. ✅ Бриф разобран → `brief-schema.md` + динамический materials-first флоу.
4. ✅ Reference-движок брифинга подключён (design-inspiration MCP + Serper).
5. ⏳ Написать `PLAN.md` (MVP Landing Builder, пошагово) — ВСЯ фактура собрана.
6. Прогнать `PLAN.md` через `plan-panel` (наш reviewer на наш план — мета-догфуд).
7. Реализовать каркас оркестратора.

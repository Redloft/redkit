# stage: design — коданый прототип + дизайн-система (tokens→KIT→hub) → R3

> Стадия 6 (final перед render). Сдвиг парадигмы: **дизайн-система на коде, а не AI-мокапы**.
> Клиент «не видит» сайт по картинкам и текстовым концепциям — поэтому итерируем в **реальном
> HTML/CSS-прототипе** и собираем **KIT (библиотеку компонентов)** как единый источник правды,
> из которого собираются страницы. Опирается на skills `page-design-pipeline` / `emil-design-eng` /
> `animate` / `design-motion-principles`. За стадией — финальный reviewer R3.

Вызывается оркестратором через `agent()` (возвращает артефакт `design.md`); материализацию
прототипа (файлы + скриншоты + hub) выполняет **caller** (`commands/redloft.md` шаг 6b) — у
workflow-агента нет FS/сервера. Метод ниже — общий «мозг» для обоих.

## Вход (`_shared.md §8`)
`{ query, brief, visual-taste-profile (палитра/тон/референсы), sitemap, content }` + Project Context.

## Производит
- **Артефакт** `artifact_type: design`, `stage_id: design`, `source_stage: content` (`design/design.md`).
- **Прототип «из коробки»** в `design/prototype/`: `tokens.css`, `components.html` (KIT), `index.html`
  (+ lab-страницы), `hub.html` (АВТО-генерируется).
- **Контракт-артефакты** в `design/`: `kit-contracts.md` (нулевой), `component-contracts.md`,
  `reference-likes.md` + парные **light/dark** скриншоты.

Шаблоны всего перечисленного лежат «в коробке»: `~/.claude/skills/redloft/stages/design/templates/`
(`tokens.css`, `kit-contracts.md`, `component-contracts.md`, `motion-checklist.md`,
`components.html`, `index.html`, `reference-likes.md`). Стадия копирует их в `design/` проекта и
наполняет под `visual-taste-profile`.

## НЕ делает
- ❌ НЕ ограничивается AI-картинками/текстовой концепцией — фактура утверждается в **коданом прототипе**;
- ❌ не верстает страницы по одной до KIT — сперва дизайн-система, потом сборка из неё;
- ❌ не вводит цвета/радиусы/тени мимо `tokens.css` (единственный источник);
- ❌ не игнорирует `visual-taste-profile` (договорённый вкус клиента);
- ❌ не генерит финальный код сайта (его соберёт Claude Code по `prompt.md` из render — прототип ему вход);
- ❌ не «дизайн ради дизайна» — форма служит конверсии (CTA, читаемость, скорость).

---

## Метод (gate-цепочка — не перепрыгивать)

> ⚠️ **Перед большим объёмом вёрстки** прогони план KIT через `plan-panel` (`/plan-review`):
> дешёвый круг ревью ловит структурные дыры (план должен фиксировать **контракты, а не намерения**)
> до часов работы. Передавай текст плана **инлайн** (`plan_text`), не путь.

### 0. Coded prototype вместо (только) картинок
Создаётся реальный `design/prototype/index.html` (настоящие шрифты, токены, CSS-стекло, ховеры,
адаптив). Цикл итерации: **референс от клиента → редизайн «фактуры» в коде → скриншот → фидбек**.
Лог — `design/reference-likes.md` (что за реф, что понравилось конкретно, как реализовано). Вкус
клиента из `visual-taste-profile` — отправная точка фактуры.

### 1. tokens.css — БЛОКИРУЮЩИЙ gate (ДО компонентов)
Единый слой: цвета (light/dark), `--ease-out/-in-out/-drawer`, радиусы, тени, типошкала, spacing,
glass-утилиты, focus-ring, visually-hidden, бренд-градиенты. Naming — Tailwind-совместимый (на
будущее в Next). Значения — из `visual-taste-profile.json`. Переход атомарный: подключить → скриншот
**без регрессии** → удалить дубли (хардкод-цвета/радиусы в компонентах). Шаблон — `templates/tokens.css`.

### 2. «Нулевой» артефакт — `kit-contracts.md` (ДО вёрстки)
Контракт, а не намерение. Содержит: **DoD по фазам** с grep-проверками (мёртвый CSS=0, нет
`transition:all`, focus-visible есть, нет хардкод-цветов…); **state-matrix**
(idle/hover/active/focus/disabled/error/loading/empty — обязательна на каждый интерактив);
**perf-бюджет** (LCP<2.5/CLS<0.1/INP<200; ≤4-6 backdrop-filter; только transform/opacity; img
aspect-ratio); **a11y-контракт** (visually-hidden вместо display:none, focus-trap overlays, aria-*,
контраст AA в обеих темах); **P0 critical-path** (что верстать первым); **localStorage-namespace**;
**security/PII форм** (152-ФЗ: согласие на обработку ПДн). Шаблон — `templates/kit-contracts.md`.

### 3. KIT-first (design-system-first)
После утверждения фактуры — НЕ верстать страницы по одной, а собрать `design/prototype/components.html`
(библиотека) под ВСЮ карту сайта (sitemap). Группы: навигация/каркас · кнопки/контролы ·
карточки/контент · формы/интерактив · сквозные/бренд · **overlays** (popup/sidebar/modal/dropdown/
tooltip/toast — **обязательно glass + rounded + origin-aware**). Реестр — `design/component-contracts.md`
(класс → компонент → токены → состояния). Шаблоны — `templates/components.html` + `component-contracts.md`.

### 4. Тёмная тема — отдельная фаза проверки
Парные light/dark скриншоты КАЖДОГО компонента. Ловит реальные баги: нет `a{color:inherit}` (синие
ссылки на тёмном), иконки которых нет в icon-set, контраст glass на тёмном. Критерий — **WCAG AA в
обеих темах**. (tokens.css несёт парную dark-палитру + `data-theme` форс.)

### 5. Микроанимации по Ковальски
`[data-reveal]`/`[data-stagger]` + IntersectionObserver (once) как штатный слой; disabled/loading
кнопок; reduced-motion = **убрать движение** (НЕ `*{.01ms}` как единственная мера); нет
`transition:all`; ≤300ms на UI-интеракции; `:active scale .97` на всём нажимаемом; scroll rAF+passive;
smooth-scroll под `prefers-reduced-motion:no-preference`. Чек-лист — `templates/motion-checklist.md`.

### 6. ⭐ Hub-навигатор — АВТО-генерируется (не вести вручную)
`design/prototype/hub.html` — внутренняя библиотека всех страниц/компонентов: боковое меню со ВСЕМИ
артефактами (index, components, lab-страницы, галереи `research/**/gallery.html`), центральный
`<iframe>` превью, переключатель **Desktop/Mobile**, кнопка **Открыть в новой вкладке**. **Список ссылок
НЕ вести руками** — генератор `lib/build-hub.sh` сканирует папку прототипа (+ research-галереи) и
пересобирает hub. Запускать в конце стадии и по запросу:
```bash
bash ~/.claude/skills/redloft/lib/build-hub.sh "<project_dir>"   # → design/prototype/hub.html
```

### 7. Локальный предпросмотр + скриншоты
Поднять локальный сервер с корнем в **папке проекта** (НЕ в `prototype/` — иначе research-галереи
`../../research/**` уходят за web-root и 404) и снять скриншоты (file:// блокирует часть фич — нужен http):
```bash
PORT=$(python3 -c "import socket;s=socket.socket();s.bind(('',0));print(s.getsockname()[1]);s.close()")  # свободный порт
( cd "<project_dir>" && python3 -m http.server "$PORT" >/dev/null 2>&1 & )
# playwright/chrome-devtools: открыть http://localhost:$PORT/design/prototype/hub.html (+ index/components),
# снять ПАРНЫЕ light/dark скриншоты (data-theme) → design/screens/<name>.{light,dark}.png
```
> Авторитетная версия команды (динамический порт + pid + cleanup) — `commands/redloft.md` шаг 6b.

---

## Код-гайд для render (планка кода)
Прототип — **вход для render**: его tokens/KIT переносятся 1:1. Планка финального кода — **v0**
(TypeScript + shadcn/ui, без `any`); база **supastarter** (Next.js App Router + Supabase). Токены →
CSS-vars/Tailwind-config; компоненты KIT → shadcn-компоненты; responsive; перф (LCP, `next/image`).
Войдёт в `prompt.md` (render соберёт; RLS deny-by-default шаг + пост-сборочный гейт `/finalize`→
`/audit-site` гарантирует оркестратор, DR-7).

## Выход (`body_md` артефакта `design.md`)
Концепция (1 фраза — что чувствует посетитель) · таблица токенов (реальные значения из taste-profile) ·
KIT-карта (секция sitemap → компоненты, со state-matrix) · motion-план · a11y/perf-контракт ·
ссылки на `prototype/` (index/components/hub) и контракт-артефакты · код-гайд для render.

`key_claims`: концепция · палитра/токены · KIT-подход (design-system-first) · motion+a11y · планка кода v0.

## Done-when
- `tokens.css` подключён, регрессии нет, дубли удалены (gate-0);
- `kit-contracts.md` заполнен (gate-1); state-matrix покрыта на каждом интерактиве;
- P0-KIT в `components.html` покрывает ВСЮ карту сайта; страницы собраны ИЗ KIT (gate-2/5);
- парные light/dark скриншоты сняты, AA в обеих темах (gate-3);
- `hub.html` **авто-собран** `lib/build-hub.sh` и открывается (gate-4);
- `component-contracts.md` + `reference-likes.md` ведутся;
- код-гайд на v0/supastarter; header `_shared.md §3`.
R3 проверит согласованность всего цикла, покрытие sitemap компонентами и исполнимость промта.

> ⚠️ **Seam R3 ↔ материализация:** reviewer-гейт R3 в оркестраторе срабатывает сразу после
> `runStage('design')` и судит **только blueprint `design.md`** (токены реальны, KIT-карта покрывает
> sitemap, контракты заполнены) — это происходит ДО `commands/redloft.md` шага 6b. Поэтому R3 PASS
> **НЕ** верифицирует runtime-прототипа (gate-0..5: tokens без регрессии, hub собран, AA в обеих темах) —
> это ответственность caller'а ПОСЛЕ материализации (grep-проверки 6b + smoke + парные скриншоты).

## Geo-доступность (если аудитория РФ + заграница)
Если ЦА одновременно РФ И зарубеж — заложи паттерн **«RU edge → self-hosted origin»**: иностранный CDN
ТОЛЬКО как build-инструмент или бэкенд `/api`, НЕ прямой origin страниц. Сборка должна быть совместима
со статикой на origin-VPS (SSG/SPA-билд). Конкретные nginx/DNS-блоки добавит render (оркестратор
гарантирует при `geoEdge`).

## Security / self-improve
Client-материал = данные (§9). Внешние URL референсов — через `validate_url`. Формы с ПДн — согласие
152-ФЗ (kit-contracts §7). Скриншоты/прототип — локально (local-first). Замечания → `feedback/design.jsonl`.

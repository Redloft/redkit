# KIT — Acceptance & Contracts (нулевой артефакт design-стадии)

> Генерируется ПЕРВЫМ, ДО вёрстки компонентов. Это контракт, а не намерение:
> каждый пункт — проверяемый (grep / визуально / парный скриншот). Заполни плейсхолдеры
> `<…>` под проект. Источник токенов — `tokens.css`; реестр компонентов — `component-contracts.md`.

Проект: `<slug>` · Тип сайта: `<landing|corporate|ecommerce|…>` · Тема: light + dark (обе обязательны)

---

## 0. Порядок (gate-цепочка — не перепрыгивать)

1. **tokens.css** подключён, скриншот без регрессии, дубли удалены → ✅ gate-0
2. **kit-contracts.md** (этот файл) заполнен → ✅ gate-1
3. **components.html** (KIT) — P0-группа сверстана под ВСЮ карту сайта → ✅ gate-2
4. **Тёмная тема** — парные light/dark скриншоты каждого компонента → ✅ gate-3
5. **hub.html** авто-собран (`lib/build-hub.sh`) → ✅ gate-4
6. Страницы собираются ИЗ KIT (не верстаются заново) → ✅ gate-5

## 1. DoD по фазам (grep-проверки прогонять по `design/prototype/`)

| # | Критерий | Проверка |
|---|---|---|
| мёртвый CSS = 0 | нет неиспользуемых классов/правил | визуальный аудит + (опц.) `purgecss`/coverage в DevTools |
| нет `transition: all` | анимируем только нужные свойства | `grep -RIn "transition:\s*all" design/prototype` → 0 |
| анимируем только transform/opacity | нет анимаций layout-свойств (width/top/left/height) | `grep -RInE "transition:.*(width\|height\|top\|left\|margin)" design/prototype` → 0 (кроме `--ease-drawer` оправданных) |
| focus-visible есть | каждый интерактив имеет видимый фокус | `grep -RIn "focus-visible" design/prototype` ≥ 1 (в tokens.css) + проверка Tab-обходом |
| нет `outline: none` без замены | не убираем фокус «насухо» | `grep -RIn "outline:\s*none" design/prototype` → 0 (или рядом есть box-shadow-ring) |
| ссылки наследуют цвет | нет «синих ссылок» на тёмном | `grep -RIn "a *{[^}]*color: *inherit" tokens.css` ≥ 1 |
| img без CLS | у медиа задан aspect-ratio/width+height | каждый `<img>` имеет `width`+`height` или `aspect-ratio` |
| нет хардкод-цветов в компонентах | всё через `var(--…)`/`color-mix` | `grep -REc "#[0-9a-fA-F]{3,6}\|rgba?\(\|hsl\(" design/prototype/{components,index}.html` → 0 (палитра только в tokens.css) |
| reduced-motion корректно | движение УБИРАЕТСЯ, не `*{.01ms}` как единственная мера | есть блок `@media (prefers-reduced-motion: reduce)` с `transition:none` |

## 2. State-matrix (ОБЯЗАТЕЛЬНА на каждый интерактивный компонент)

Каждый компонент в `components.html` показывает ВСЕ применимые состояния:

`idle · hover · active(:active) · focus(:focus-visible) · disabled · error · loading · empty`

- кнопки/ссылки: idle/hover/active/focus/disabled (+ loading для сабмита)
- поля форм: idle/focus/filled/error/disabled
- списки/галереи/таблицы: loading(skeleton)/empty/filled/error
- `:active` даёт тактильность: `transform: scale(.97)` на всём нажимаемом

## 3. Perf-бюджет

- **LCP < 2.5s**, **CLS < 0.1**, **INP < 200ms** (зелёная зона CWV)
- ≤ **4–6** одновременных `backdrop-filter` в вьюпорте (стекло дорого)
- анимируем **только `transform`/`opacity`** (composited); scroll-эффекты — `rAF` + `passive` listeners
- каждое `<img>`/`<video>` имеет `aspect-ratio` (или width+height) → 0 layout-shift
- hero-картинка — приоритетная (`fetchpriority="high"`), остальное `loading="lazy"`
- шрифты: `font-display: swap`, предзагрузка только критичного начертания

## 4. A11y-контракт (WCAG AA в ОБЕИХ темах)

- контраст текста ≥ **4.5:1** (крупный ≥ 3:1) — проверить в light И dark
- `visually-hidden` (класс `.u-visually-hidden`) вместо `display:none` для контента скринридеров
- focus-trap в overlays (modal/drawer): фокус не уходит за пределы, Esc закрывает, возврат фокуса на триггер
- семантика: landmark-теги (`header/nav/main/footer`), кнопки = `<button>`, ссылки = `<a>`
- `aria-*`: `aria-label` на icon-only кнопках, `aria-expanded` на тогглах, `aria-live` на toast, `role="dialog"`+`aria-modal` на modal
- tap-target ≥ 44×44px на мобиле

## 5. P0 critical-path (что верстать ПЕРВЫМ)

Минимальный набор KIT, без которого не собрать ни одной ключевой страницы:

1. `<P0-1: напр. Header + Nav (sticky)>` 2. `<P0-2: Hero>` 3. `<P0-3: Button (все states)>`
4. `<P0-4: Card услуги/товара>` 5. `<P0-5: Form заявки + поля>` 6. `<P0-6: Footer>`
7. overlays-минимум: `<P0-7: Modal/Drawer (glass + focus-trap)>`

> P1/P2 (галерея, accordion/FAQ, tabs, toast, tooltip, dropdown) — после P0.

## 6. localStorage-namespace

Единый префикс ключей — чтобы не конфликтовать с чужими скриптами на домене:

`<slug>:` (напр. `<slug>:theme`, `<slug>:cookie-consent`, `<slug>:form-draft`)

## 7. Security / PII форм (152-ФЗ)

- формы с ПДн (имя/телефон/email): чекбокс **согласия на обработку ПДн** + ссылка на политику — ОБЯЗАТЕЛЬНО, submit заблокирован без согласия
- не логировать значения полей в `console`/аналитику в plaintext
- honeypot/anti-spam без капчи-блокеров доступности
- передача только по HTTPS; на проде — серверный обработчик (не светить эндпоинт-ключи в клиенте)
- черновики форм в localStorage — без PII, либо с явным TTL и очисткой после submit

---

## Чек-аут стадии (всё ✅ → design готов к R3 / render)

- [ ] tokens.css — gate пройден, дубли удалены
- [ ] state-matrix покрыта на каждом интерактиве
- [ ] perf-бюджет соблюдён (grep-проверки §1 = 0)
- [ ] a11y-контракт в light И dark
- [ ] P0 KIT сверстан, страницы собраны ИЗ KIT
- [ ] парные light/dark скриншоты сняты
- [ ] hub.html авто-собран и открывается

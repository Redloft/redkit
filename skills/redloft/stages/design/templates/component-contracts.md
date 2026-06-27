# Component Contracts — реестр KIT (класс → компонент → токены → состояния)

> Единый источник правды по библиотеке. Каждая строка = один компонент из `components.html`.
> Заполняется по мере вёрстки KIT. Страницы прототипа собираются ИЗ этих компонентов (не верстаются заново).
> Группы покрывают ВСЮ карту сайта (sitemap). Overlays — ОБЯЗАТЕЛЬНО glass + rounded + origin-aware.

Легенда состояний: `i`=idle `h`=hover `a`=active `f`=focus `d`=disabled `e`=error `l`=loading `∅`=empty

## Навигация / каркас
| Класс | Компонент | Токены | Состояния |
|---|---|---|---|
| `.c-header` | Header (sticky, shrink-on-scroll) | `--color-surface`, `--shadow-sm`, `--ease-out` | i, scrolled |
| `.c-nav` | Nav + mobile burger | `--color-text`, `--space-*` | i, h, f, open |
| `.c-footer` | Footer | `--color-surface-2`, `--text-sm` | i |
| `.c-container` | Контейнер ширины | `--container`, `--space-*` | — |

## Кнопки / контролы
| Класс | Компонент | Токены | Состояния |
|---|---|---|---|
| `.c-btn` `.c-btn--primary` | Кнопка (CTA) | `--color-accent`, `--color-accent-fg`, `--radius-md`, `--dur-fast` | i, h, a(`scale .97`), f, d, l |
| `.c-btn--ghost` | Вторичная кнопка | `--color-border`, `--color-text` | i, h, a, f, d |
| `.c-input` | Поле ввода | `--color-border`, `--color-focus-ring`, `--radius-md` | i, f, filled, e, d |
| `.c-select` `.c-checkbox` | Селект / чекбокс | `--color-accent`, `--color-border` | i, f, checked, d |

## Карточки / контент
| Класс | Компонент | Токены | Состояния |
|---|---|---|---|
| `.c-card` | Карточка (услуга/товар) | `--color-surface`, `--shadow-md`, `--radius-lg`, hover-lift | i, h, f |
| `.c-hero` | Hero-секция | `--grad-brand`, `--text-4xl`, `--space-12` | i |
| `.c-gallery` | Галерея/masonry | `aspect-ratio`, `--radius-md` | ∅, l, filled |
| `.c-accordion` | Accordion / FAQ | `--ease-out`, `--color-border` | collapsed, expanded, f |
| `.c-tabs` | Tabs | `--color-accent`, `--ease-out` | i, active, f |

## Формы / интерактив
| Класс | Компонент | Токены | Состояния |
|---|---|---|---|
| `.c-form` | Форма заявки (+ согласие 152-ФЗ) | `--color-surface`, `--space-*` | i, validating, e, success |
| `.c-field` | Поле + label + error-text | `--color-danger`, `--text-sm` | i, f, e, d |

## Сквозные / бренд
| Класс | Компонент | Токены | Состояния |
|---|---|---|---|
| `.c-badge` | Бейдж/метка | `--color-accent`, `--radius-full` | i |
| `.c-divider` | Разделитель | `--color-border` | — |
| `.c-theme-toggle` | Переключатель темы (localStorage `<slug>:theme`) | `--ease-out` | light, dark, f |

## Overlays (⚠️ ОБЯЗАТЕЛЬНО: glass + rounded + origin-aware)
| Класс | Компонент | Токены | Состояния |
|---|---|---|---|
| `.c-modal` | Modal (focus-trap, Esc, `role=dialog`) | `.u-glass`, `--radius-lg`, `--ease-out` | closed, open, f-trap |
| `.c-drawer` | Sidebar/Drawer (origin-aware: слайд от края) | `.u-glass`, `--ease-drawer` | closed, open |
| `.c-dropdown` | Dropdown (origin = триггер) | `.u-glass`, `--radius-md` | closed, open, f |
| `.c-tooltip` | Tooltip (origin-aware) | `.u-glass`, `--text-xs` | hidden, shown |
| `.c-toast` | Toast (`aria-live`) | `.u-glass`, `--ease-out` | enter, shown, exit |
| `.c-popup` | Popup/Popover | `.u-glass`, `--shadow-lg` | closed, open |

> **origin-aware** = анимация раскрытия идёт из точки-источника (триггера/края), а не из центра экрана:
> `transform-origin` совпадает с триггером; drawer слайдит от своего края (`--ease-drawer`).

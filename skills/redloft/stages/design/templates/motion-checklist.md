# Микроанимации — чек-лист (по Эмилю Ковальски)

> Штатный motion-слой прототипа. Сдержанность > эффектность: анимация служит понятности,
> а не украшению. Завязано на токены `--ease-*` / `--dur-*` из `tokens.css`.
> См. также skill `animate` и `design-motion-principles`.

## Reveal-on-scroll (штатный слой)
- `[data-reveal]` — элемент появляется при входе во вьюпорт; `[data-stagger]` — каскад детей
- через **IntersectionObserver, `once: true`** (отписка после первого показа — не дёргать повторно)
- начальное состояние: `opacity:0; transform: translateY(8–16px)`; конечное — `opacity:1; translateY(0)`
- только `transform`/`opacity` (composited), длительность ≤ `--dur-slow`

```js
const io = new IntersectionObserver((es) => {
  es.forEach(e => { if (e.isIntersecting) { e.target.dataset.shown = '1'; io.unobserve(e.target); } });
}, { rootMargin: '0px 0px -10% 0px' });
document.querySelectorAll('[data-reveal]').forEach(el => io.observe(el));
```

## Интеракции (UI)
- ≤ **300ms** на любую UI-интеракцию (открытие/ховер/переход состояния); микро — `--dur-fast`
- **нет `transition: all`** — перечисляй свойства явно
- `:active { transform: scale(.97) }` на ВСЁМ нажимаемом (тактильность)
- hover-lift карточек: `transform: translateY(-2px)` + усиление тени, `--ease-out`
- кнопки: `disabled` гасит интерактив; `loading` — спиннер/скелет, блок повторного сабмита

## Overlays
- раскрытие **origin-aware**: `transform-origin` = точка-источник (триггер/край), не центр
- drawer/sidebar — слайд от своего края через `--ease-drawer`
- modal — fade + лёгкий scale из `.98`; backdrop fade; focus-trap

## Скролл / плавность
- scroll-эффекты — `requestAnimationFrame` + listeners с `{ passive: true }`
- smooth-scroll только под `@media (prefers-reduced-motion: no-preference)`

## Reduced-motion (доступность)
- `@media (prefers-reduced-motion: reduce)` → **УБРАТЬ движение** (`transition:none`, без transl/scale)
- ❌ НЕ сводить к `*{ animation-duration: .01ms }` как к единственной мере — это не «без движения», это «очень быстрое движение»
- reveal-элементы при reduced-motion сразу в конечном состоянии (видимы, без анимации входа)

## Анти-паттерны
- ❌ бесконечные авто-анимации в зоне внимания (отвлекают, жрут CPU/батарею)
- ❌ анимация layout-свойств (width/height/top/left) — дёргает рефлоу, ломает perf-бюджет
- ❌ параллакс/тяжёлый motion без `will-change`-дисциплины и без reduced-motion fallback

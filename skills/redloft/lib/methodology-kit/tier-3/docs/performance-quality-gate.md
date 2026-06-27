# Performance Quality Gate — {{PROJECT_NAME}}
<!-- EN: Performance bar before production. Use /audit-site (Lighthouse) to verify. -->

> Планка производительности перед продом. Проверка — `/audit-site` (Lighthouse / Core Web Vitals).
> _Performance bar; verify with /audit-site._

## Core Web Vitals (mobile, реальная сеть)
- [ ] **LCP** < 2.5s
- [ ] **CLS** < 0.1
- [ ] **INP** < 200ms

## Изображения · Images
- [ ] Современные форматы (WebP/AVIF), отдаются по размеру (`next/image` или аналог).
- [ ] Hero-изображение с `priority`/preload; остальные — lazy.
- [ ] Нет картинок-«тяжеловесов» > ~200KB без причины.

## Бандл и загрузка · Bundle & loading
- [ ] Нет крупных неиспользуемых зависимостей; тяжёлое — динамический импорт.
- [ ] Шрифты — `font-display: swap`, сабсеты под нужные языки.
- [ ] Кэш-заголовки на статику корректны.

> Расширяй под проект через MP (`docs/methodology-proposals/`).

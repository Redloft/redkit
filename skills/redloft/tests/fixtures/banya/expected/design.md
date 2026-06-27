---
artifact_type: design
stage_id: design
schema_version: 1
produced_at: 2026-06-02T11:10:00Z
source_stage: content
key_claims:
  - "Дизайн-концепция: тёмная природная палитра + дерево + латунный акцент (из Taste Profile)"
  - "Токены: фон #1A1715, акцент #C9A36A, текст #E8DFD2; serif заголовки, гротеск тело"
  - "Компоненты на shadcn/ui; крупные фото-секции, мягкие тени, спокойные motion-переходы"
  - "Целевая планка кода = v0 (TS + shadcn, без any) на supastarter/Next.js+Supabase базе"
---
# Design spec: Берёзовая роща

> Mock. Опирается на `visual-taste-profile.json`. R3 (final) после этого этапа.

## Концепция
Тёмный «вечер в лесу»: крупные фото парных и чана, тёплый латунный акцент, много воздуха.

## Токены (design-system seed)
- color.bg `#1A1715`, color.surface `#221E1A`, color.accent `#C9A36A`, color.text `#E8DFD2`
- type.heading: humanist serif; type.body: grotesque; scale 1.25
- radius: 12px; shadow: мягкая, низкий контраст; motion: 200-300ms ease-out, без резких

## Компоненты (shadcn/ui)
Hero, Card (услуга), Gallery (masonry), Accordion (FAQ), Form (заявка), Sticky CTA.

## Motion
Лёгкий parallax на hero-фото; reveal-on-scroll секций; hover lift на карточках (см. `animate`).

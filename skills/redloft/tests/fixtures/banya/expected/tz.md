---
artifact_type: tz
stage_id: render
schema_version: 1
produced_at: 2026-06-02T11:30:00Z
source_stage: design
key_claims:
  - "Лендинг + страница сертификатов на Next.js+Supabase (supastarter/MakerKit база)"
  - "Главная цель: форма заявки на аренду → запись в БД + уведомление + анти-спам"
  - "Контент/SEO/дизайн-токены зафиксированы из артефактов стадий"
  - "Handoff: self-serve Supabase Project Transfer + обязательная ротация секретов"
---
# ТЗ: лендинг «Берёзовая роща»

> Mock финального ТЗ (Phase F собирает из всех артефактов).

## Цель и метрики
Заявки на аренду (primary), сертификаты (secondary). KPI: конверсия hero→заявка.

## Стек
Next.js (App Router) + Supabase (Postgres/Auth/Storage) на supastarter-базе; TS + shadcn/ui (планка v0).

## Структура
Лендинг (10 секций, см. sitemap) + `/sertifikaty`. Контент — из content.md. Токены — из design.md.

## Функционал
- Форма заявки: дата/время/парная/имя/телефон → таблица `bookings` + уведомление (email/Telegram).
- Форма сертификата → таблица `cert_requests`.
- Анти-спам (rate-limit/капча), валидация телефона.
- Галерея из Supabase Storage; llms-full.txt + schema (FAQ/Article).

## Данные (Supabase)
Таблицы `bookings`, `cert_requests`, `gallery_assets`. **RLS обязателен** (см. prompt.md, шаг безопасности).

## Handoff
Self-serve Supabase Project Transfer (один регион; отключить GitHub-интеграцию/log-drains/project-scoped роли). После переноса — клиент ротирует JWT secret + anon/service_role; agency удаляет env-ссылки.

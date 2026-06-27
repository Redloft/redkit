---
artifact_type: prompt
stage_id: render
schema_version: 1
produced_at: 2026-06-02T11:35:00Z
source_stage: design
key_claims:
  - "Промт для Claude Code: сгенерировать лендинг на supastarter (Next.js+Supabase)"
  - "Содержит non-skippable RLS deny-by-default чек-шаг после генерации схемы (DR-7)"
  - "Передаёт токены/контент/структуру из артефактов как вход"
  - "Code-quality планка v0: TS + shadcn/ui, без any"
---
# Промт для Claude Code: лендинг «Берёзовая роща»

> Mock. Это вход для отдельного запуска Claude Code (redloft код не пишет).

## Задача
Сгенерируй production-лендинг на базе supastarter (Next.js App Router + Supabase, TS + shadcn/ui, без `any`). Структура — из ТЗ; тексты — из content pack; токены/дизайн — из design spec.

## Шаги
1. Инициализируй проект на supastarter-базе; настрой дизайн-токены (color/type/radius из design.md).
2. Собери секции лендинга (Hero…FAQ…Форма) на компонентах shadcn/ui.
3. Схема Supabase: таблицы `bookings`, `cert_requests`, `gallery_assets`.
4. **🔒 ОБЯЗАТЕЛЬНЫЙ ШАГ БЕЗОПАСНОСТИ (НЕ ПРОПУСКАТЬ).** После генерации схемы:
   - включить **RLS на ВСЕХ таблицах** (`alter table … enable row level security`);
   - политика **deny-by-default**: без явной allow-политики доступа нет;
   - формы пишут через серверный route с service_role (ключ только на сервере), клиент — anon без прямого доступа на запись;
   - прогнать проверку: ни одна таблица не доступна анонимно на чтение/запись сверх задуманного.
   Это прямой урок Lovable: незакрытый RLS = утечка данных. Без этого шага задача НЕ считается выполненной.
5. SEO/GEO: метатеги, FAQ/Article schema, `llms-full.txt`, robots для ИИ-ботов.
6. Форма заявки → запись в БД + уведомление; анти-спам.

## ✅ Пост-сборка — обязательный гейт перед публикацией (НЕ ПРОПУСКАТЬ)
После генерации кода, ДО деплоя, прогнать в порядке:
1. **`/finalize`** — стабилизация (typecheck/lint/build/test + автофикс) + многоролевое код-ревью git diff. Вердикт SHIP / FIX-FIRST / NEEDS-WORK; при FIX-FIRST исправить и повторить.
2. **`/audit-site`** (performance) — Lighthouse Core Web Vitals (LCP/CLS/INP), image delivery, SEO, GEO, cache. Исправить регрессии.
3. Публиковать только при `/finalize` = SHIP И зелёном perf-аудите.

## Definition of done
Сборка без ошибок TS; RLS включён и deny-by-default подтверждён; `/finalize` = SHIP; `/audit-site` зелёный (CWV); формы пишут в БД.

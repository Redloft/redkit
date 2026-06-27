# Security Quality Gate — {{PROJECT_NAME}}
<!-- EN: Run this checklist before every production deploy. Any ❌ blocks the deploy. -->

> Чек-лист перед КАЖДЫМ продакшен-деплоем. Любой ❌ блокирует деплой.
> _Pre-deploy security gate. Any ❌ = no deploy._

## База данных · Database
- [ ] RLS включён на **всех** таблицах (`supabase/rls-bootstrap.sql` применён, deny-by-default).
- [ ] Самопроверка «таблицы без RLS» пуста (запрос в `rls-bootstrap.sql §4`).
- [ ] `service_role`-ключ НЕ используется на клиенте — только на сервере/edge-функциях.

## Секреты · Secrets
- [ ] Ни одного секрета в коде/`.env`/git (grep на `sk-`/`ghp_`/`AIza`/`eyJ` — 0 hits).
- [ ] Все ключи — в 1Password / переменных окружения хостинга.
- [ ] При смене владельца проекта — ротация всех ключей (handoff-чеклист в `docs/tz.md`).

## Вход и доступ · Input & access
- [ ] Серверная валидация всех пользовательских входов (не только клиентская).
- [ ] Auth-проверки на каждом защищённом маршруте/действии.
- [ ] Нет SSRF/open-redirect в обработке внешних URL.

## Зависимости · Dependencies
- [ ] `npm audit` без high/critical (или зафиксирован осознанный риск).

> Расширяй под проект через MP (`docs/methodology-proposals/`).

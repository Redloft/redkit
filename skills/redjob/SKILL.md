---
name: redjob
description: |
  Дежурный оператор парка launchd/cron джоб (метафора авиадиспетчера): единый
  реестр, карта парка, read-only doctor-аудит класса тихих поломок (PATH-127,
  op/keychain-TCC, missing bins, коллизии расписаний, дрифт реестр↔диск) + советник
  размещения новой джобы с генерацией plist из канон-шаблона. Ops-слой над launchd.

  TRIGGER on:
  • «что у меня бегает», «карта джоб», «список джоб», «что по ночам крутится»
  • «аудит джоб», «проверь джобы», «что не так с джобами», «почему джоба падает»
  • «сколько launchd-агентов», «коллизии джоб», «куда посадить джобу»
  • "what jobs run on my mac", "audit my launchd jobs", "job map", "where to schedule a job"
  • Explicit: «/redjob», «/redjob-list», «/redjob-doctor», «/redjob-add»
allowed-tools: [Bash, Read]
---

# redjob — дежурный оператор launchd/cron

Парк launchd-агентов на маке растёт стихийно, и «что когда бегает» приходится
реконструировать grep'ом по plist и логам. Класс тихих поломок — plist без PATH к
homebrew (скрипт падает 127), `op` без service-account токена (ночное окно доступа
к Keychain), отсутствующий бинарь, коллизии расписаний — живёт месяцами, потому что
никто не смотрит. redjob = единый реестр + доктор, который ловит именно этот класс,
проверяя **исход**, а не паттерн (PATH — реальным резолвом бинарей в окружении джобы).

## Команды

```bash
# Фаза 1 — read-only
bin/redjob list [--md]      # карта: timeline / interval / persistent / по проектам
bin/redjob doctor [--quiet] # аудит; exit≠0 при CRITICAL; --quiet прячет INFO
bin/redjob validate         # jobs.yaml по схеме
bin/redjob seed [--write]   # собрать реестр из живых plist (dry-run без --write)
# Фаза 2 — советник (НЕ устанавливает, сажает человек)
bin/redjob add <spec.json>              # совет: слоты по клиренсу / коалесинг / dependency
bin/redjob add <spec.json> --generate   # + сгенерить plist, self-doctor, печать install/rollback
```

## Что ловит doctor

| Правило | Severity | Ловит |
|---|---|---|
| `no-trigger` | CRITICAL | plist без единого триггера (StartCalendarInterval/StartInterval/KeepAlive) и RunAtLoad=false — джоба никогда не запустится. С RunAtLoad=true → WARNING. Смотрит в plist, не в реестр (seed отмывает kind=unknown→keepalive) |
| `path-resolve` | CRITICAL | бинарь не резолвится в РЕАЛЬНОМ PATH джобы. Через login-shell (zsh -lc) → INFO |
| `op-safety` | CRITICAL | `op` без op_env.sh/SA-токена → риск окна Keychain-доступа. depth=1 эвристика |
| `exit-code` | CRITICAL/WARNING | 126/127 (не найден) → CRITICAL; прочий ненулевой → WARNING |
| `drift` / `drift-code` | WARNING | plist на диске нет в реестре (и наоборот); скрипт зовёт `op`, а реестр `auth: none` |
| `collision-heavy` | WARNING | два тяжёлых (headless-агент) в ±30мин — не сажай в одно окно |
| `collision-lock` / `lock-group` | WARNING/INFO | джобы делят lock — секвенируй |
| `plist-xml` | WARNING | plist не строгий XML (сырой control-байт; plutil терпит, expat нет) |
| `secrets` | CRITICAL | секрет-значение в jobs.yaml (реестр хранит только ИМЕНА env) |

## Инварианты

- **doctor — строго read-only.** Никаких `launchctl load/unload`, никаких правок plist.
- **`add` (Фаза 2) — только под явный апрув человека.** Диспетчер разрешает посадку,
  сажает человек: печатает install/rollback командами, НЕ выполняет. Сгенерированный
  plist сам проходит полный doctor ДО показа install (CRITICAL → install не печатается).
- **Секреты/значения не печатать.** Всё, что рендерится наружу, проходит `scrub_text`.
  Реестр хранит только имена env-переменных; значение секрета в любом поле = блок записи.
- **Реестр — источник правды, но код важнее.** deps_bins/auth сверяются с реальным
  скриптом; расхождение = WARNING «реестр отстал от кода».

## Настройка под себя

- `jobs.yaml` генерится `redjob seed --write` (не коммить — карта личного парка).
- `lib/seed.py` → `ANNOTATIONS` — overlay для того, что скан entrypoint не выводит
  (локи через depth>1, weight в под-скрипте, notes). Заполни своими джобами.
- env `REDJOB_MASK_MODULE=/path/mod.py` — свой маскировщик (иначе встроенный fallback).
- env `REDJOB_EXTERNAL_PREFIXES=a.,b.` — доп. вендорские префиксы (кроме apple/google/homebrew).

## Тесты

`tests/run.sh` — assert-таблица «фикстура → правило → severity» + golden-снэпшот живого
парка. Дату передавать `TODAY=YYYY-MM-DD` (в песочнице `date` бывает недоступен).

## Требования

macOS (launchctl/plutil/pmset), Python 3 + PyYAML. Только чтение системного состояния.

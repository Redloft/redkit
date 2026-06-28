# redwork — протокол онбординга проекта (project intake)

redwork запускается на РАЗНЫХ проектах (разные стек, git-флоу, ветки dev/prod, ритуал деплоя, откат, opcache…).
Чтобы адаптироваться, redwork при ПЕРВОМ запуске на проекте проводит **онбординг** — структурированную одноразовую
настройку — и фиксирует её В САМОМ ПРОЕКТЕ. Дальше каждый прогон просто читает зафиксированное и работает по нему.
Это бывшая «Phase 1 intake» из DESIGN-mvp (была future) — теперь определена.

## Принцип: один источник правды + его машинная проекция
- **Источник правды (человек):** раздел `## redwork` в **`CLAUDE.md` проекта** — нарратив процедуры: dev→prod, ветки,
  git-флоу, ритуал деплоя/отката, opcache/cache-bust, прод-URL, кто апрувит, грабли. Claude читает CLAUDE.md каждую
  сессию → оркестратор всегда видит процедуру; рядом с уже живущей там PROD-SAFETY-политикой.
- **Машинная проекция (детерминированный код):** `.redwork.json` (gates/deploy/smoke/rollback) + опц. `.redwork-autonomy.json`
  (autonomy-контракт, owner-signed). Bash-гейт/P5 парсят ИХ, не прозу.
- Init держит оба согласованными. Расхождение `## redwork` ↔ JSON на запуске → эскалация (config drift).

## Артефакты, создаваемые в проекте (git-tracked)
```
<repo>/CLAUDE.md            → секция «## redwork» (человеко-читаемая процедура; source of truth)
<repo>/.redwork.json        → машинный конфиг (gates, deploy argv, smoke, rollback)
<repo>/.redwork-autonomy.json → опц. autonomy-контракт (только если нужен автодеплой; owner ПОДПИСЫВАЕТ коммит, A0′)
<repo>/.gitignore           → += .redwork-killswitch (runtime-флаг, НЕ коммитится)
```

## Протокол `/redwork-init` (первый запуск на проекте)
Идемпотентен: если артефакты есть и согласованы — no-op (печатает summary). Иначе 5 шагов.

### 1. DETECT (авто, без вопросов)
Скилл сам определяет что может:
- **Стек/гейты:** `package.json`(scripts: lint/test/build; biome/eslint/vite/tsc) · `composer.json`(php) · `requirements.txt`/`pyproject`(pytest) · `Makefile` · `*.csproj` → черновик `gates`.
- **Git:** remote, default-branch, существующие ветки/конвенции, есть ли подписанные коммиты (для A0′).
- **Прод-следы:** CI-конфиги (`.github/workflows`, codemagic), `Dockerfile`, `nginx`-конфиги, deploy-скрипты в репо.
Результат — **черновик** конфига с заполненным тем, что выводимо.

### 2. INTERVIEW (спросить человека ОДИН раз — только невыводимое)
Структурированный опрос, ответы → в проект НАВСЕГДА (не переспрашиваем):
- **Прод-таргет(ы):** host (SSH-alias), path, ритуал деплоя (напр. `git fetch && merge --ff-only` или rsync/CI-trigger), cache-bust/opcache-reset (как именно), прод-URL, smoke-маркер (статус + строка в теле), health-URL.
- **Откат:** механизм (ff-to-prev-SHA / `git reset --hard` / CI-rollback), как валидируется ДО деплоя.
- **Ветки:** dev-ветка, прод-ветка/конвенция (напр. `ai/<slug>-prod`), ff-only? кто мержит.
- **Политика апрува:** дефолтный режим (1/2/3); нужен ли автодеплой; если да — scope globs (что можно автокатить), доп. floor-globs, deploy-окна, rate-limit, supervisor.
- **Секреты:** какие `op://`-ссылки нужны деплою (никогда литералы — см. cred-lint).

Опрос — минимальный: каждый пункт с DETECT-дефолтом подтверждается одним «ок/правь», невыводимое запрашивается явно.

### 3. GENERATE (записать оба представления согласованно)
- Секция `## redwork` в `CLAUDE.md` (по шаблону ниже) — нарратив из ответов.
- `.redwork.json` — машинный (deploy.cmd как **argv-массив**; секреты только `op://`+`$ENV`; smoke полный).
- `.redwork-autonomy.json` (если автодеплой) — по контракту v2 (DESIGN-autonomy); **owner подписывает коммит**.
- `.gitignore += .redwork-killswitch`.

### 4. VERIFY (до коммита)
- `config.sh lint <repo>` — argv/cred-lint/git-integrity.
- rollback-валидация (dry-run / наличие prev-good-SHA).
- `autonomy-gate.sh decide` в **shadow** на пробном диффе → показать решение + объяснение (что человек НЕ катит).
- консистентность `## redwork` ↔ JSON.

### 5. COMMIT (действие человека)
Человек ревьюит сгенерированное и **коммитит сам**; `.redwork-autonomy.json` — **подписанным** коммитом (это его pre-approval, authorization-root A0′). redwork НЕ коммитит автономно конфиг автономии.

## Шаблон секции `## redwork` для CLAUDE.md проекта
```markdown
## redwork (оркестратор полного цикла)

**Стек/гейты:** <напр. biome lint + tsc typecheck + vite build>.
**Ветки:** dev=`<...>`; прод-конвенция=`<ai/<slug>-prod>`; мерж в прод: <ff-only по SSH>; кто апрувит: <...>.
**Деплой (ритуал):** <человеческое описание: куда, чем, как cache-bust/opcache>.
  Машинно: `.redwork.json` → deploy.cmd (argv), env (op://), smoke, rollback.
**Прод:** URL `<...>`; health `<...>`; smoke-маркер `<статус + строка>`.
**Откат:** <механизм + как валидируется ДО деплоя>.
**Режим по умолчанию:** <1|2|3>. **Автодеплой:** <нет | да — см. `.redwork-autonomy.json`, scope=<...>>.
**PROD-SAFETY:** прод-запись = явное «да, катим»+diff ИЛИ удовлетворённый autonomy-контракт (если включён). Floor (migrations/auth/payment/secrets) — всегда человек.
**Грабли проекта:** <...>.
```

## Самообучение: база архетипов проектов (`lib/onboarding-kb.sh`)
Онбординг — **самообучающийся** (push-петля, как plan-panel/ledger). Каждый успешный init дописывает в локальную базу
**САНИТИЗИРОВАННЫЙ архетип** проекта; новые онбординги читают её и предлагают дефолты от ПОХОЖИХ → меньше вопросов со временем.
- **Что хранится:** ТОЛЬКО абстрактный shape — `{stack[](теги), git_flow, deploy_class, cachebust_class, rollback_class, branch_convention(паттерн), mode_default, autonomy}`. Классы — enum (`deploy_class`: ssh-git-ff-only|ssh-rsync|ci-trigger|vercel|…; `cachebust_class`: php-opcache|cdn-purge|asset-hash|…; `rollback_class`: git-reset-prev-sha|ci-rollback|…).
- 🔒 **Анти-утечка (fail-closed):** `record` ОТВЕРГАЕТ запись, если значение похоже на host/url/ip/path (`://`,`@`,IP,`/path`), есть лишний ключ (где могла бы осесть PII) или класс вне enum. + strip-secrets defense. НИКАКИХ host/path/url/имён/секретов.
- **Локальность:** база `~/.claude/skills/redwork/knowledge/archetypes.jsonl` — ЛОКАЛЬНА, **НЕ синкается в публичный redkit** (синкается только КОД `onboarding-kb.sh`).
- **Где в протоколе:**
  - **Шаг 1 DETECT** дополняется: `onboarding-kb.sh suggest "<stack-теги>"` → modal-дефолты от пересекающихся архетипов («проекты этого типа обычно: deploy=ssh-git-ff-only, rollback=prev-sha, cache=php-opcache, ветки ai/<slug>-prod»).
  - **Шаг 2 INTERVIEW** пред-заполняется этими дефолтами → человек подтверждает/правит, а не отвечает с нуля. Чем больше проектов онбордено — тем меньше вопросов.
  - **Шаг 5 (после успешного COMMIT)** → `onboarding-kb.sh record '<sanitized-archetype>'` (push, не pull).

## Последующие запуски
redwork на старте: `config.sh lint` + проверка наличия секции `## redwork` + консистентности. Всё есть и согласовано →
работает по конфигу, БЕЗ повторного опроса. Конфиг отсутствует/рассогласован/`version` autonomy вырос → re-onboard (шаг 2 точечно)
или эскалация. Подмена `.redwork.json`/autonomy в рантайме ловится git-integrity (A0) + мета-правилом (A4).

## Связь с фазами
Онбординг = «Phase 1» (intake), выполняется ДО P2. P2–P6 (DESIGN-mvp v3) и autonomy-gate (DESIGN-autonomy v2) читают
произведённые артефакты. Один онбординг на проект; повторно — только при изменении доктрины.

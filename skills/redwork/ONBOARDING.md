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

### ⚠️ Out-of-tree config (web-served / многослойные git-проекты)
Если **корень code-repo раздаётся публично** (web-root отдаёт dotfiles: `GET https://site/.redwork.json`→200) или
конфиг/деплой-механика живут в ОТДЕЛЬНОМ git-слое (governance-репо, НЕ деплоится) — `.redwork.json` в code-repo
**раскрыл бы деплой-механику наружу** (argv, `op://`-имена, SSH-хост). Тогда конфиг кладётся **вне code-repo**, в его
собственный git-tracked слой, а redwork получает путь через:
- **env `REDWORK_CONFIG_FILE=<abs>`** (предпочтительно для web-served: НИЧЕГО не оседает в деплой-дереве), или
- **`<repo>/.redwork-config-ref`** (1 строка = путь; tracked+unmodified в code-repo) — для проектов, где корень НЕ
  публичен. ⚠️ для web-served репо ref НЕЛЬЗЯ (сам ref уедет в public_html).
Integrity (tracked+unmodified) применяется к РЕЗОЛВНУТОМУ файлу в ЕГО git; single-read из committed-blob; symlink/
traversal зарезаны (`config.sh` §OUT-OF-TREE). **НИКОГДА** не коммить `.redwork.json`/`.redwork-config-ref` в
web-served code-repo. Boundary: out-of-tree + autonomy пока не поддержаны (autonomy-gate A4 fail-closed → human).

## Протокол `/redwork-init` (первый запуск на проекте)
Идемпотентен: если артефакты есть и согласованы — no-op (печатает summary). Иначе 5 шагов.

### 1. DETECT (авто, без вопросов)
Скилл сам определяет что может:
- **Стек/гейты:** `package.json`(scripts: lint/test/build; biome/eslint/vite/tsc) · `composer.json`(php) · `requirements.txt`/`pyproject`(pytest) · `Makefile` · `*.csproj` → черновик `gates`.
- **Git:** remote, default-branch, существующие ветки/конвенции, есть ли подписанные коммиты (для A0′).
- **Прод-следы:** CI-конфиги (`.github/workflows`, codemagic), `Dockerfile`, `nginx`-конфиги, deploy-скрипты в репо.
- **🔑 Repo-layout (КРИТИЧНО — иначе «5-минутный config-write» уезжает в duty-сессию; ledger 2026-06-28):** НЕ считать репо единым местом. Классифицировать git-слои: **code-repo** (деплоится) vs **config/governance** (деплой-механика, НЕ деплоится) vs **deploy-target** (прод-хост). Если конфиг/деплой-механика логически НЕ принадлежат code-repo → ветка **out-of-tree** (§Out-of-tree), НЕ класть `.redwork.json` в code-repo. Сигналы слоя: отдельный governance-репо рядом, separate-git-dir, монорепо-слои.
- **🔑 Web-served-root (КРИТИЧНО):** если есть прод-URL И корень code-repo похож на web-root (`index.php`/`.htaccess`/urlrewrite/`public_html`-чекаут) → проба `curl -s -o /dev/null -w '%{http_code}' https://<prod>/.gitignore`. **200 → корень публичен → out-of-tree ОБЯЗАТЕЛЕН**, ref-файл в code-repo ЗАПРЕЩЁН (только `REDWORK_CONFIG_FILE` env; иначе сам `.redwork.json`/`.redwork-config-ref` утечёт: `GET https://site/.redwork.json` отдаст argv деплоя + `op://`-имена + SSH-хост).
Результат — **черновик** конфига + **config-локация** (in-tree | out-of-tree env | out-of-tree ref) с заполненным тем, что выводимо.

### 2. INTERVIEW (спросить человека ОДИН раз — только невыводимое)
Структурированный опрос, ответы → в проект НАВСЕГДА (не переспрашиваем):
- **Прод-таргет(ы):** host (SSH-alias), path, ритуал деплоя (напр. `git fetch && merge --ff-only` или rsync/CI-trigger), cache-bust/opcache-reset (как именно), прод-URL, smoke-маркер (статус + строка в теле), health-URL.
- **Откат:** механизм (ff-to-prev-SHA / `git reset --hard` / CI-rollback), как валидируется ДО деплоя.
- **Ветки:** dev-ветка, прод-ветка/конвенция (напр. `ai/<slug>-prod`), ff-only? кто мержит.
- **Политика апрува:** дефолтный режим (1/2/3); нужен ли автодеплой; если да — scope globs (что можно автокатить), доп. floor-globs, deploy-окна, rate-limit, supervisor.
- **Секреты:** какие `op://`-ссылки нужны деплою (никогда литералы — см. cred-lint).

Опрос — минимальный: каждый пункт с DETECT-дефолтом подтверждается одним «ок/правь», невыводимое запрашивается явно.

### 3. GENERATE (записать оба представления согласованно — АВТО)
redwork-init создаёт всё сам (не диктует человеку шаги):
- **Config-слой по DETECT-локации:**
  - **in-tree** (не web-served, конфиг принадлежит code-repo) → `<code-repo>/.redwork.json` (+ опц. `.redwork-autonomy.json`).
  - **out-of-tree** (web-served корень ИЛИ отдельный governance-слой) → АВТО-создать governance-репо `${REDWORK_OPS_DIR:-~/ops}/<project>/` (`git init` если нет), туда `.redwork.json` + `.redwork-autonomy.json` + `REDWORK.md` (полный нарратив — вне web-root). redwork получает путь через `REDWORK_CONFIG_FILE`. **НИКОГДА** не класть конфиг/ref в web-served code-repo (ни `.redwork.json`, ни `.redwork-config-ref`).
- `.redwork.json` — машинный (deploy.cmd **argv-массив**; секреты только `op://`+`$ENV`; smoke полный).
- `.redwork-autonomy.json` (если автодеплой) — контракт v2; **`owners` авто-берётся из `git config user.email`** (НЕ угадывать — иначе A0′ author∉owners; урок termoport: git-email ≠ личный gmail) И сверяется с `allowed_signers` (иначе verify-commit не пройдёт → предупредить).
- **CLAUDE.md код-репо:** in-tree → полная `## redwork`-секция; **web-served → только МИНИМАЛЬНЫЙ непубличный указатель** (config-локация + команда запуска, БЕЗ деталей деплоя/хоста — корень публичен), полный нарратив в governance `REDWORK.md`.
- `.gitignore += .redwork-killswitch` (в том слое, где живёт конфиг).
- **🔑 whitelist-gitignore-trap (ledger 2026-06-28):** после записи конфига в его git-слой прогнать `git -C <cfg_top> check-ignore <relpath>` И `git -C <cfg_top> status --short`. Если файл **ignored** (governance-слой часто whitelist-`.gitignore`: `/*`+`/.*` игнорят всё, только `!`-исключения трекаются) → конфиг молча не трекается → integrity упадёт «untracked». Лечение: добавить `!`-исключение в `.gitignore` слоя + предупредить человека (это правка governance-политики, его решение).

### 4. VERIFY (до коммита)
- `config.sh lint <repo>` — argv/cred-lint/git-integrity.
- `config.sh resolve <repo>` — для out-of-tree: подтвердить, что конфиг резолвится из ОЖИДАЕМОГО слоя (resolved_from/path/cfg_top), а не случайно из code-repo. Drift-check: при последующих запусках это же проверяется на старте.
- **🔑 не-утечка (web-served):** если DETECT отметил web-served-root → `curl -s -o /dev/null -w '%{http_code}' https://<prod>/.redwork.json` И `/.redwork-config-ref` → ОБА не-200 (404/403). 200 → конфиг наружу, СТОП (вернуть в out-of-tree).
- **🔑 реально трекается:** `git -C <cfg_top> check-ignore <relpath>` пусто (не ignored) И `ls-files` находит файл (закрывает whitelist-gitignore-trap до коммита).
- rollback-валидация (dry-run / наличие prev-good-SHA).
- `autonomy-gate.sh decide` в **shadow** на пробном диффе → показать решение + объяснение (что человек НЕ катит).
- консистентность `## redwork` ↔ JSON.

### 5. COMMIT (АВТО — подписанный коммит делает redwork-init)
redwork-init сам делает **подписанный** коммит конфиг-слоя: `git -C <cfg_top> add -A && git commit -S -m "redwork onboarding: ..."`.
- **Безопасность сохранена:** валидный signed-commit требует ключа owner'а (op-ssh-sign/1Password) → автокоммит ВО ВРЕМЯ init'а, запущенного owner'ом с его ключом, = его pre-approval (A0′ требует именно «контракт подписан ключом owner'а», не «человек вручную набрал git commit»). Запуск `/redwork-init` человеком = авторизация.
- **Verify-гейт:** после коммита `git -C <cfg_top> verify-commit HEAD` ОБЯЗАН пройти (author∈owners, подпись валидна). Не прошёл (подпись не настроена / email ∉ allowed_signers) → **НЕ включать autonomy** (контракт неверифицируем → гейт всё равно даст human): откатить `autonomy:"disabled"` + сообщить человеку как настроить signing/allowed_signers.
- Если signing вообще не настроен (нет gpg.format/signingkey) → автокоммит обычный (для `.redwork.json`), но `.redwork-autonomy.json` НЕ создавать (autonomy без подписи бессмысленна) — предложить настроить подпись.
- Человек по-прежнему может ревьюить артефакты до запуска (init печатает их) и отказаться.

## Шаблон секции `## redwork` для CLAUDE.md проекта
```markdown
## redwork (оркестратор полного цикла)

**Стек/гейты:** <напр. biome lint + tsc typecheck + vite build>.
**Ветки:** dev=`<...>`; прод-конвенция=`<ai/<slug>-prod>`; мерж в прод: <ff-only по SSH>; кто апрувит: <...>.
**Деплой (ритуал):** <человеческое описание: куда, чем, как cache-bust/opcache>.
  Машинно: `.redwork.json` → deploy.cmd (argv), env (op://), smoke, rollback.
**Конфиг-локация:** `<in-tree .redwork.json | out-of-tree: REDWORK_CONFIG_FILE=<abs> | .redwork-config-ref>` (см. §Out-of-tree).
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

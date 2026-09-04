# redkit

Монорепо red*-скиллов для Claude Code: общий **kernel** (`core/`) + **skills/** поверх него.
Один источник правды для ядра, симлинки резолвятся, один `install.sh`.

## Структура
```
redkit/
  core/                 # общий kernel (code-dep у всех скиллов)
    strip-secrets.sh    # secrets-redaction (entropy + keyword), single entry point
    checkpoint.sh       # state-machine + lock + atomic write
    ledger.sh           # append-only learnings ledger (петля самоулучшения)
    secret-guard.sh     # keyword-детектор секретов для структурных payload
    validators.js       # DRAFT/revise/oscillation валидаторы
    test-core.sh
  skills/
    plan-panel/         # multi-role верификация плана (redplan)
    finalize/           # stabilize + код-ревью по diff
    redwork/            # ВЕРШИНА: оркестратор полного цикла implement→…→prod
    redresearch/        # multi-source fact-checked research (+ tiered self-host фетчер)
    redsemantic/        # SEO-ядро: keyword universe → кластеры → структура
    redreference/       # подбор дизайн-референсов с петлёй вкуса
    redjob/             # дежурный оператор launchd/cron джоб (standalone, без core-dep)
    redbrain/           # граф-память: SQLite-граф + темпоральные слои (standalone, без core-dep)
    redanalyst/         # настройка/аудит веб- и сквозной аналитики Метрика+Директ (standalone, без core-dep)
  install.sh
  core/publish-gate.sh  # проверка публичной поверхности перед публикацией
```

## Публикация: обязательный гейт

redkit публичный, но собирается из `~/.claude/skills`, где живут реальные данные
оператора (IP, имена клиентов, почта, домашние пути). Перед любым пушем:

```bash
bash core/publish-gate.sh           # tracked + untracked (всё, что не в .gitignore)
bash core/publish-gate.sh --staged  # только staged
bash core/publish-gate.sh --self-test  # контроль самого гейта
```

Область проверки — **tracked и untracked-но-не-ignored** файлы: новый файл, ещё не
попавший в коммит, — такая же публичная поверхность (один `git add .`). Итоговая
строка печатает знаменатель по обеим категориям (`чисто (tracked 347, untracked 20)`),
чтобы «чисто» говорило, что именно проверено.

`--self-test` подкладывает утечку в untracked-файл (в том числе с не-ASCII именем)
и проверяет, что гейт КРАСНЕЕТ; он же входит в `bash core/test-core.sh`.

Повесить на pre-commit, чтобы не забывать:

```bash
printf '#!/bin/sh\nexec bash core/publish-gate.sh --staged\n' > .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
```

Первый запуск в свежем клоне предупредит, что список приватных имён не задан:

```bash
cp core/publish-gate.names.example core/publish-gate.names   # и заполнить своим
```

`publish-gate.names` в `.gitignore` — перечень имён клиентов сам по себе
коммерческая тайна, в публичном скрипте его быть не может. Без файла проверка
имён не молчит, а громко сообщает, что пропущена.

Ложное срабатывание на заведомом плейсхолдере → добавить ERE в
`core/publish-gate.allow`. Реальное значение туда **не добавляют** — его обобщают.

⚠️ Если приватное уже улетело в историю, `git push --force` НЕ спасает: GitHub
держит объекты достижимыми через `refs/pull/*`. Помогает только пересоздание
репозитория.
Каждый скилл: `lib/<kernel>.sh` — симлинк на `../../../core/<file>` (резолвится и в репо, и после install в `~/.claude/core`). `deps.txt` — runtime-скиллы, которые он вызывает.

## Граф зависимостей
```
core  ◀── code-dep ── plan-panel, finalize, redwork (и все будущие red*)
redwork ── runtime-invoke ──▶ plan-panel · finalize · audit-site · tracker · (run/verify встроенные)
finalize ── runtime ──▶ plan-panel (роли в review_mode=code)
```
redwork имеет code-dep только на `core` (как finalize) → живёт рядом с core в одном репо; остальное — runtime-invoke (объявлено в `deps.txt`, ставится отдельно).

## Установка
```bash
git clone https://github.com/Redloft/redkit && cd redkit && bash install.sh
# core → ~/.claude/core ; skills → ~/.claude/skills/* ; проверка runtime-deps
bash ~/.claude/core/test-core.sh
bash ~/.claude/skills/redwork/lib/test-redwork.sh
```
`CLAUDE_DIR=/path` — кастомный install-таргет (для песочницы/CI).

## Петля самоулучшения
Каждый прогон skill-ов пишет методологические находки в `<skill>/feedback/learnings.jsonl` через `core/ledger.sh` (meta-критик). Stop-hook нудит на `solidify` при накоплении. `feedback/` и run-артефакты (`.plan-panel/`, `.finalize/`) — gitignored, не публикуются.

## Статус
Вся red*-семья: `plan-panel`, `finalize`, `redwork`, `redresearch`, `redsemantic`, `redreference`, `redjob`, `redbrain`, `redanalyst` + общий `core`. Сюда консолидированы ранее отдельные `Redloft/redplan` (= plan-panel+finalize) и `Redloft/redfetch` (= tiered-фетчер, живёт в `skills/redresearch/lib/fetch_tiered.py`) — те репы archived в пользу redkit.

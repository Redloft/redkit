# redjob

**Дежурный оператор парка launchd/cron джоб на macOS** — метафора авиадиспетчера:
единый реестр того, что бегает, read-only doctor-аудит тихих поломок, и советник
размещения новой джобы с генерацией plist из канон-шаблона.

Часть [redkit](https://github.com/Redloft/redkit) — семьи red*-скиллов для Claude Code.

## Зачем

launchd-агенты растут стихийно; «что когда бегает» реконструируется grep'ом по plist.
Класс тихих поломок никто не ловит:

- plist без PATH к homebrew → скрипт падает `127` (бинарь не найден);
- `op` без service-account токена → окно доступа к Keychain ночью;
- отсутствующий бинарь, коллизии расписаний, дрифт реестр↔диск.

redjob проверяет **исход, а не паттерн**: PATH — реальным резолвом бинарей в
эффективном окружении джобы (с учётом того, что скрипт сам чинит PATH / делегирует
в login-shell); op-safety — честной эвристикой глубины source depth=1.

## Установка

```bash
# как часть redkit
git clone https://github.com/Redloft/redkit && cd redkit
pip3 install pyyaml
ln -s "$PWD/skills/redjob/bin/redjob" ~/.local/bin/redjob   # или добавь в PATH
```

## Быстрый старт

```bash
redjob seed --write     # собрать реестр из ~/Library/LaunchAgents
redjob list             # карта парка: timeline / persistent / по проектам
redjob doctor           # аудит (exit≠0 при CRITICAL)
```

Советник новой джобы:

```bash
cat > job.json <<'EOF'
{"label":"com.me.backup","project":"me","kind":"calendar",
 "script":"/Users/me/bin/backup.sh","weight":"light","auth":"none",
 "deps_bins":["sqlite3"],"calendar":{"Hour":3,"Minute":30}}
EOF
redjob add job.json              # предложит свободные слоты + коалесинг
redjob add job.json --generate   # + сгенерит plist, self-doctor, напечатает install/rollback
```

`add` **не устанавливает** — печатает команды, сажаешь ты (self-doctor гейт валидирует
plist до показа install; невалидный label / секрет в spec / коллизия — блокируются).

## Дизайн

- **Реестр** `jobs.yaml` — единый источник правды (schema_version, atomic-write под flock
  + re-parse-валидация). Генерится `seed` на каждой машине, в git не коммитится.
- **doctor** — 9 правил read-only, проверяют исход. Честны по глубине эвристики
  (login-shell → INFO не CRITICAL; op по абсолютному пути ловится; гвард в комментарии ≠ safe).
- **advisor** — свободные слоты ранжированы по клиренсу от контеншена; кандидаты на коалесинг.
- **plistgen** — plist из канон-шаблона (PATH с homebrew+~/.local/bin, логи, шапка
  install/uninstall) + self-doctor гейт (полный ruleset на сгенерированном) до показа install.
- **scrub** — единая точка scrub-on-render; secrets-lint реестра.

Ловит security-класс в самом себе: label валидируется как reverse-DNS (path-traversal +
shell-инъекция в печатаемых install-командах), значения секретов в spec блокируются.

## Требования

macOS, Python 3 + PyYAML. Только чтение системного состояния (launchctl/plutil/pmset);
никаких load/unload/правок plist — установку выполняет человек по напечатанным командам.

## Лицензия

MIT — см. [LICENSE](../../LICENSE).

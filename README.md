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
  install.sh
```
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
v1: `core` + `plan-panel` + `finalize` + `redwork` (orchestration tier). Далее (v2): `redresearch`, `redsemantic`, `redloft`, `redreference`.

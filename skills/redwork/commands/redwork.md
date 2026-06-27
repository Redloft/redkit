# /redwork — caller flow

Полная процедура и инварианты — `~/.claude/skills/redwork/SKILL.md` (+ `DESIGN-mvp.md` v3). Здесь — порядок запуска.

> Workflow-скрипты не имеют fs/git → **оркестрирует СЕССИЯ** (Bash-либы + Workflow для finalize/plan-panel + Agent для реализации). `/loop` держит процесс. Один run/repo (lock). Только op:// для кредов, strip везде.

## Шаги
1. **Парс инвокации:** задача (текст | CPMO-id → подтянуть из `tracker` | `@plan.md`), `режим N` из NL (default 2), `--repo` (default cwd), `--auto-deploy`.
2. **Security-гейт ДО всего:** `bash $L/config.sh lint "$REPO"` — невалидный конфиг/инъекция/литеральные креды → стоп с сообщением (`CONFIG_INVALID`).
3. **Init + lock:** `SLUG=$(state.sh slug "<task|repo>")`; `RD=$(state.sh init "$SLUG" "<task без секретов>" "$REPO" "$MODE" "redwork/$SLUG")`; `state.sh lock "$RD"` (занят → стоп: один redwork на repo).
4. **План — вход:** записать `$RD/plan.md` (из `@plan.md` / последнего `plan-panel` / задача+набросок). Нет плана → сперва прогнать `/plan-review --from-task` (Phase 1 — пока ручной вход в MVP).
5. **Ветка:** `git -C "$REPO" switch -c "redwork/$SLUG" 2>/dev/null || git -C "$REPO" switch "redwork/$SLUG"` (fallback на resume, ветка уже есть).
6. **Драйвер:** запустить `/loop` (self-paced) с задачей «выполни redwork-step для `$RD` по SKILL.md, пока не DONE/blocked». Каждый тик — фаза P2→P6 (см. SKILL §Хендлеры).
7. **Эскалация:** при `blocked_on` — `escalate.sh` уже записал; СЕССИЯ дофаерит `PushNotification` + (CPMO) `tracker` коммент (только reason_code/needs/run_path, без command-output). `unlock`, стоп loop.
8. **DONE:** `events gc` + `ledger.sh append ~/.claude/skills/redwork "$(cat $RD/learnings.entry.json)"` (если есть) + отчёт + `tracker-done` (CPMO) + `unlock`.

**Секрет-чек перед показом:** `grep -RInE 'sk-|AIza|ghp_|eyJ[A-Za-z0-9]' "$RD"` (events/state) → 0 hits. (op:// НЕ ищем — это безопасная ссылка, см. secret-guard.sh.)

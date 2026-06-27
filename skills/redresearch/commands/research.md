# /research — caller flow (authoritative)

Полный orchestration-контракт для slash-команд redresearch. Тонкие entry-файлы в `~/.claude/commands/research*.md` делегируют сюда. Источник истины — этот файл (версионируется со skill).

> Workflow scripts не имеют FS-доступа → **caller** (Claude, выполняющий команду) делает persist, пишет run-spec, запускает Workflow, и пишет artifacts из payload на диск.

---

## `/research <topic>` — основной flow

### Шаг 1 — Тема + флаги

`$ARGUMENTS` = тема. Парсинг флагов:
- `--lite` / `--standard` / `--heavy` / `--ultra` → явный mode (skip Шаг 3 auto-scope)
- `--fresh` → игнорировать 7-дневный кэш источников
- иначе → `mode=auto` (scoper решит)

Тема может быть пустой → используй последний значимый research-вопрос из сессии.

### Шаг 2 — Slug + run dir

```bash
SLUG=$(printf '%s' "$TOPIC" | head -c 200 | python3 -c "
import sys, re
T={'а':'a','б':'b','в':'v','г':'g','д':'d','е':'e','ё':'yo','ж':'zh','з':'z','и':'i','й':'y','к':'k','л':'l','м':'m','н':'n','о':'o','п':'p','р':'r','с':'s','т':'t','у':'u','ф':'f','х':'kh','ц':'ts','ч':'ch','ш':'sh','щ':'sch','ъ':'','ы':'y','ь':'','э':'e','ю':'yu','я':'ya'}
s=sys.stdin.read().lower().strip(); s=''.join(T.get(c,c) for c in s)
s=re.sub(r'[^a-z0-9]+','-',s).strip('-')[:40]; print(s or 'research')")
OUT=$(bash ~/.claude/skills/redresearch/lib/persist.sh "$SLUG")
RUN_DIR="${OUT%|*}"; TS="${OUT#*|}"
RUN_ID=$(uuidgen | tr 'A-Z' 'a-z')
```

### Шаг 3 — (только mode=auto) Auto-scope

Запусти Workflow scope-only, чтобы получить рекомендацию дёшево:
```
Workflow({ scriptPath: "~/.claude/skills/redresearch/workflow/research.js",
  args: { topic: TOPIC, mode: "auto-scope-only", run_id: RUN_ID, timestamp: TS, slug: SLUG }})
```
→ `{ scope_only:true, scoper, mode, needs_user_confirmation, estimated_seconds, recommended_subtopics }`.

### Шаг 4 — (если needs_user_confirmation) подтверждение

`needs_user_confirmation === false` (lite/standard) → **молча продолжаем**, никакого вопроса.

`=== true` (heavy/ultra) → `AskUserQuestion`:
```
"Тема «<topic>». Scoper рекомендует: <mode> — <mode_reasoning>.
~<estimated_seconds/60> мин, <cost из таблицы SKILL.md>. Запускаем?"
Options: <recommended mode (рекомендуется)> · более лёгкий (standard) · ultra (если рекомендован heavy) 
```
Cost: lite $0/~2мин · standard $0/~5мин · heavy $0 (Gemini Pro дёшево)/~15мин · ultra **+$0.10-0.20 API** (GPT-5)/~30мин. На Max Claude-часть = $0.

### Шаг 5 — run-spec.json + initial status

```bash
GIT_REV=$(git -C ~/.claude/skills/redresearch rev-parse --short HEAD 2>/dev/null || echo unknown)  # F14
jq -nc --arg id "$RUN_ID" --arg slug "$SLUG" --arg mode "$MODE" --arg topic "$TOPIC" \
  --argjson eta "${ETA:-300}" --argjson ru "$RU_LANG" --arg git "$GIT_REV" \
  '{run_id:$id, slug:$slug, mode:$mode, topic:$topic, ru_lang:$ru, git_rev:$git,
    scoper:{estimated_seconds:$eta}, created_at:(now|todateiso8601)}' > "$RUN_DIR/run-spec.json"
# initial status так, чтобы /research-status работал сразу
source ~/.claude/skills/redresearch/lib/heartbeat.sh
init_status "$RUN_DIR" "$SLUG" "$MODE" "$RUN_ID"
```

### Шаг 6 — Запуск

**lite / standard — FOREGROUND** (это рабочий Phase A путь):
```
Workflow({ scriptPath: "~/.claude/skills/redresearch/workflow/research.js",
  args: { topic: TOPIC, mode: MODE, run_id: RUN_ID, timestamp: TS, slug: SLUG,
          fresh: FRESH, git_rev: GIT_REV, precomputed_scoper: SCOPER /* из Шага 3 если был */ }})
```
Workflow async-возвращает payload + `runId` (`wf_...`). **Сразу после launch сохрани runId для F7 resume:**
```bash
source ~/.claude/skills/redresearch/lib/heartbeat.sh
set_workflow_id "$RUN_DIR" "<wf_runId из ответа Workflow>"
```
По завершении → Шаг 7.

**heavy / ultra — BACKGROUND**: тот же Workflow (он сам async — tool возвращает task id, Claude уведомят по готовности). Пока идёт — пользователь свободен. Caffeinate против сна: для длинных run'ов оберни launch в `lib/run-with-caffeinate.sh` (Phase B fully-detached путь через `workflow/worker.sh` + `research-runner.py` — для session-independent запусков; в Phase A heavy/ultra идут через async Workflow в живой сессии).

### Шаг 7 — Запиши artifacts + статус

`result.artifacts` = `{filename: content}`. Для каждого → **Write tool** в `$RUN_DIR/<filename>` (report.md, sources.jsonl, claims.jsonl, conflicts.jsonl, meta.json, scope.json, learnings.entry.json).
```bash
source ~/.claude/skills/redresearch/lib/heartbeat.sh
write_status "$RUN_DIR" done completed 0
# Петля самоулучшения (push): meta-критик уже отметил системные пробелы процесса → в ledger
[ -f "$RUN_DIR/learnings.entry.json" ] && bash ~/.claude/skills/plan-panel/lib/ledger.sh append ~/.claude/skills/redresearch "$(cat "$RUN_DIR/learnings.entry.json")" || true
```
**Секрет-чек перед показом** (если есть run.log от background): `grep -iE 'sk-|AIza|ghp_|op://|eyJ' "$RUN_DIR/run.log" && echo "🚨 SECRET LEAK"` — должно быть 0 hits.

### Шаг 8 — Покажи пользователю

- **lite / standard**: рендер `report_md` прямо в чат + строка `Verdict: <verdict> · confidence <c> · cite-coverage <cc> · <N> источников`. Путь к run_dir. Если `degraded` — упомяни.
- **heavy / ultra**: TG ping (бот `TG redresearch` или reuse) «Research готов: <topic> → <run_dir>/report.md». В чат — краткий summary + путь (файл уже на маке, transfer не нужен).
- Gaps (judge) — если есть, перечисли. Предложи `/research-share <slug>`.

---

## Управляющие команды (через `lib/manage.sh`, без агентов)

| Команда | Реализация |
|---|---|
| `/research-list` | `bash ~/.claude/skills/redresearch/lib/manage.sh list` |
| `/research-status <slug>` | `manage.sh status <slug>` (показывает status.json + liveness pid) |
| `/research-cleanup [--older-than 30d] [--dry-run]` | `manage.sh cleanup …` (C5; не трогает running) |
| `/research-resume <slug>` | `detect_stale` (heartbeat.sh) → если `stale`/`failed` → перезапусти Workflow с тем же run-spec; если `running`+live → покажи статус; если `completed` → покажи report |
| `/research-share <slug>` | прочитай `$(manage.sh path <slug>)/report.md`, отдай пользователю (копия/рендер) |
| `/research-replay <slug>` | F14: re-render отчёта из cached sources/claims БЕЗ re-fetch (для итерации synth/judge промптов) |

`/research-replay` логика:
```bash
DIR=$(bash ~/.claude/skills/redresearch/lib/manage.sh path "$SLUG")
CACHED_SOURCES=$(jq -sc . "$DIR/sources.jsonl")   # array
CACHED_CLAIMS=$(jq -sc . "$DIR/claims.jsonl")     # array
GIT_REV=$(git -C ~/.claude/skills/redresearch rev-parse --short HEAD 2>/dev/null || echo unknown)
# Workflow({ scriptPath: ".../workflow/research.js", args: {
#   topic, mode, run_id: <new>, timestamp, slug, git_rev: GIT_REV,
#   replay: true, cached_sources: <CACHED_SOURCES>, cached_claims: <CACHED_CLAIMS> }})
# → пропускает hunt+read, гонит только synth→judge на тех же источниках. Запиши новый report.md.
```

`/research-resume` логика:
```bash
source ~/.claude/skills/redresearch/lib/heartbeat.sh
DIR=$(bash ~/.claude/skills/redresearch/lib/manage.sh path "$SLUG")
WF=$(read_status "$DIR" workflow_run_id)   # F7: persisted на launch
case "$(detect_stale "$DIR")" in
  stale|failed|interrupted)
    # F7 resume: re-invoke Workflow с resumeFromRunId=$WF — Workflow tool вернёт
    # cached результаты для завершённых agent() и re-run только прерванные/оставшиеся.
    # Если $WF пуст (старый run) — fresh Workflow по $DIR/run-spec.json.
    echo "resume via Workflow({scriptPath, resumeFromRunId:'$WF'})";;
  running) echo "still running — показать /research-status, не дублировать";;
  completed) echo "done — показать $DIR/report.md";;
esac
```

---

## Anti-patterns

- ❌ Не спрашивай про mode если `needs_user_confirmation=false` — это friction.
- ❌ Не запускай heavy/ultra без подтверждения (время/деньги).
- ❌ Не пиши run-каталог в Yandex.Disk (C1) — только `~/Library/Application Support/redresearch/` (persist.sh это гарантирует).
- ❌ Не выводи весь sources.jsonl/claims.jsonl в чат — только report.md + summary.
- ❌ Не печатай значения секретов; cross-model только через `op run` снаружи.
- ❌ Не дублируй run если в этой сессии уже шёл `/research` на ту же тему — спроси re-run или покажи прошлый.

## Phase A status

Реализовано и протестировано: scoper, source-hunter, deep-reader, synth-claude (inline), judge (inline), lite/standard foreground flow, worker.sh (C2/W1), manage.sh (C5). Phase B: synth-gpt5/synth-gemini как роли-файлы, fact-checker роль-файл, `research-runner.py` (fully-detached background), research-специфичный cross-model.sh, F7 idempotency, F14 reproducibility/`--replay`.

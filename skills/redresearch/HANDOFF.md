# redresearch — Handoff for next session

> Контекст исчерпан в предыдущей сессии. Foundations Phase A написаны и протестированы. Следующая сессия продолжает с worker + orchestrator + SKILL.md + scoper. Этот документ — всё что нужно знать.

## Что это за skill

`redresearch` — multi-agent research для Claude Code. По модели redplan: scoper решает дёшево, фан-аут ролей по mode, judge синтезирует. **Local-first** (на маке, не TOM1 — capacity и co-tenancy риски), 4 mode: lite/standard/heavy/ultra. Триггеры: «исследуй X», `/research <topic>`.

## Архитектура (финальная после 3 итераций plan-panel)

- **Path**: `~/Library/Application Support/redresearch/runs/<TS>-<slug>/` (НЕ Yandex.Disk — C1 data residency)
- **NotebookLM выпилен** (A0.5 ToS audit: FORBIDDEN, см. `lib/NOTEBOOKLM-TOS-VERDICT.md`). Heavy/ultra работают на Claude+GPT-5+Gemini direct API через `cross-model.sh`. Gemini 2.5 Pro замещает grounded Q&A (2M context)
- **State**: `status.json` single source of truth. Lock содержит только pid. `worker_pid` в status.json + `kill -0` — primary stale detector
- **Output**: report.md + sources.jsonl + claims.jsonl + run.log (JSONL) + meta.json
- **TG notify** только при heavy/ultra ready (без file transfer — файл уже на маке)

## Какие фазы пройдены plan-panel

| Iteration | Mode | Verdict | Critical | Outcome |
|---|---|---|---|---|
| v1 | ultra | NEEDS-WORK | 9 | F1-F9 baseline (command injection, secrets, locks, OOM, disk) |
| v2 (Phase A) | heavy | NEEDS-WORK | 11 | TOM1 capacity disaster discovered |
| v3 (local-first pivot) | standard→heavy | NEEDS-WORK | 11→2/role | Convergent — accepted as checklist |

Все артефакты сохранены в `$CLAUDECORE_PATH/.plan-panel/redresearch-v1/`.

**Решение**: переписывать v4 не имеет смысла. 5 critical + 5 warning из v3 — **CHECKLIST.md** в этой папке. Закрываем при имплементации.

## ✅ PHASE A COMPLETE (2026-06-01)

End-to-end `/research "What is RDAP"` (lite) проходит за **174.8s (<3 мин target)**,
verdict PASS, confidence 0.92, cite_coverage 0.88, 5 источников (4 primary), 38/38
claims с cite_ids, secrets-grep = 0. Все 33 smoke-проверки зелёные.

```
~/.claude/skills/redresearch/
├── SKILL.md                        ✅ entry, triggers, 6-phase flow, 4-mode table
├── _shared.md                      ✅ JSONL schemas, confidence rubric, cite [N], templates
├── CHECKLIST.md                    ✅ C1/C2/C3/C5/W1/W2/W5 closed; C4/W4 partial (Phase B)
├── HANDOFF.md                      ← этот файл
├── commands/research.md            ✅ authoritative caller flow
├── lib/
│   ├── NOTEBOOKLM-TOS-VERDICT.md   ✅ FORBIDDEN
│   ├── cross-model.sh              ✅ (plan-panel; research-adapter = Phase B)
│   ├── persist.sh                  ✅ paths + C1 Yandex.Disk guard
│   ├── heartbeat.sh                ✅ init/write/read/detect_stale; zsh+bash safe; set -e safe
│   ├── log.sh                      ✅ JSONL + allowlist + secrets scrub
│   ├── manage.sh                   ✅ list/status/path/cleanup (C5)
│   └── run-with-caffeinate.sh      ✅ W4 wrapper (wired for heavy/ultra)
├── roles/
│   ├── scoper.md                   ✅ Haiku routing
│   ├── source-hunter.md            ✅ WebSearch-primary, firecrawl-escalation
│   └── deep-reader.md              ✅ WebFetch + F6 injection guard + URL deny-list
├── tests/smoke.sh                  ✅ 33 hermetic checks (no live API)
└── workflow/
    ├── research.js                 ✅ orchestrator (lite/standard wired; heavy/ultra scaffold)
    └── worker.sh                   ✅ C2 parent wrapper + W1 exit codes
```

Live `~/.claude/commands/research*.md` (6 slash entries) установлены.

Note: lite-run сжёг ~1M subagent tokens (haiku readers тянут полные большие
страницы) — **Phase B: cap fetched content в deep-reader** чтобы снизить cost.
synth-claude больше НЕ переэмитит claims (это была #1 latency-причина, 200s→~50s).

## 📜 Phase A — implementation order (HISTORICAL — всё сделано, см. git log)

> Этот раздел — исходный план Phase A. Всё реализовано и закоммичено. Оставлен как reference. Актуальный статус Phase A/B — секции «✅ PHASE A COMPLETE» выше и «Task ID» ниже.

Порядок имплементации (с CHECKLIST.md links):

### 1. `workflow/worker.sh` (closes C2 SIGKILL parent, W1 exit codes)

Парсит `--run-dir`, валидирует `run-spec.json` (C2 + A2.1), читает spec via jq, init_status, потом:
```bash
python3 ./lib/research-runner.py --run-dir "$RUN_DIR" &
CHILD_PID=$!
trap 'write_status "$RUN_DIR" "" failed' EXIT INT TERM
wait $CHILD_PID
rc=$?
trap - EXIT INT TERM
if [ $rc -eq 0 ]; then write_status "$RUN_DIR" done completed
else write_status "$RUN_DIR" "" failed "$rc"; fi
```

Exit codes table (W1): 0=ok, 1=generic, 2=BUSY (lock held), 3=schema invalid, 4=missing run-spec, 137=SIGKILL.

### 2. `workflow/research.js` (Workflow tool orchestrator)

Mirror `~/.claude/skills/plan-panel/workflow/panel.js` структуру. Phases по mode:
- `lite`: scope → hunt → read → synth-claude → judge → render (всё inline, Claude only)
- `standard`: + Gemini Flash synth → judge
- `heavy`: 15-25 sources + Gemini Pro + fact-checker
- `ultra`: + GPT-5 synth (cross-model.sh) + meta-judge

Pipeline pattern (не barrier) где можно: deep-reader items стартуют как только source-hunter их выдаёт.

### 3. `SKILL.md`

Триггеры: «исследуй», «глубокий ресерч», `/research`. Flow: scoper → confirm mode → Workflow → render. Modes table (4 mode × cost/time/sources/models). NotebookLM **не упоминать** — выпилен.

### 4. `_shared.md`

JSONL schemas (sources, claims, conflicts), confidence rubric (high/medium/low), cite format `[N]`, sole-author rule, output templates (brief/standard/deep).

### 5. `roles/scoper.md`

Haiku prompt. Input: topic. Output JSON:
```json
{
  "mode": "lite|standard|heavy|ultra",
  "output_template": "brief|standard|deep",
  "ru_lang": false,
  "primary_sources_needed": false,
  "estimated_subtopics": 3,
  "estimated_seconds": 600,
  "confidence": 0.85,
  "recommended_subtopics": []
}
```
Mode rules:
- 1-2 sentences factoid → lite
- Overview + 3-5 angles → standard
- Academic/legal/regulatory + citations → heavy
- User said «глубокий»/«ультра», topic critical → ultra
- RU detection: ≥30% кириллицы → `ru_lang: true`

### 6. `roles/source-hunter.md`

Tools: `firecrawl_search`, `firecrawl_map`. RU sources если `ru_lang`. Output ranked top-N URL list. Dedup по url + content_hash. Cache 7d unless `--fresh`.

### 7-10. Остальные роли

deep-reader, synth-claude, synth-gpt5, synth-gemini, fact-checker, judge.

### 11. Commands (`commands/research.md` и т.д.)

`/research <topic>`, `/research-resume <slug>`, `/research-list`, `/research-status <slug>`, `/research-cleanup [--older-than 30d]` (C5), `/research-share <slug>`.

### 12. Smoke tests (W5) в `tests/smoke.sh`

Stub без живых API: concurrent-lock=BUSY, kill-9=failed, init→completed lite flow.

## 🟥 CHECKLIST — ещё открытые critical/warning

См. `CHECKLIST.md`. Закрыто: C1, C3, W3 (NotebookLM N/A). Открыто:
- C2 worker_pid SIGKILL recovery — heartbeat готов, нужен parent wrapper в worker.sh
- C4 secrets hygiene — N/A для NotebookLM, но в `cross-model.sh` calls тоже надо проверить grep-check в run.log
- C5 retention/cleanup — нужен `/research-cleanup`
- W1 exit codes table — в worker.sh
- W2 atomic write_status — уже через mkdir-lock, можно отметить ✓
- W4 caffeinate — wrapper готов, но не вызван из Workflow ещё
- W5 smoke suite formalized

## Доступные секреты (1Password vault AI-Tokens)

- `OPENAI_API_KEY` — для GPT-5 (ultra)
- `Gemini/credential` — Gemini 2.5 Pro/Flash
- `FIRECRAWL_API_KEY` (если нет — добавить через `/token-find firecrawl`)
- `TG DomainCheck` (можно reuse или новый item `TG redresearch` для blast radius)

Все через `op run --env-file=<(...)` pattern. **Никогда** не печатать в чат. Грep-check в pre-deploy.

## Команды для бутстрапа в новой сессии

```bash
cd ~/.claude/skills/redresearch
git log --oneline                    # see foundation commit
cat CHECKLIST.md                     # checklist of what's done/pending
cat HANDOFF.md                       # this file
bash <<'EOF'
  # Verify smoke still works
  cd ~/.claude/skills/redresearch
  OUT=$(./lib/persist.sh smoke-check); RUN_DIR="${OUT%|*}"
  source ./lib/heartbeat.sh; source ./lib/log.sh
  RUN_ID=$(uuidgen | tr 'A-Z' 'a-z')
  init_status "$RUN_DIR" smoke-check standard "$RUN_ID"
  write_status "$RUN_DIR" scope running
  log_init "$RUN_DIR" "$RUN_ID"
  log_event run_start mode=standard
  cat "$RUN_DIR/status.json" | jq -c .
  cat "$RUN_DIR/run.log"
  rm -rf "$RUN_DIR"
  echo "✓ foundations work"
EOF
```

## Task ID в TaskList

`#51 redresearch skill — Phase A` — ✅ **COMPLETED 2026-06-01**. worker.sh + SKILL.md + _shared.md + scoper + research.js + commands + source-hunter/deep-reader + manage.sh + smoke.sh готовы; end-to-end lite «What is RDAP» прошёл за 174.8s (<3 мин), PASS.

`#52 Phase B` — ✅ **CODE DONE 2026-06-01** (standard validated live; heavy/ultra live-тесты deferred по выбору юзера).

**Архитектурное решение: вариант (b) ПРИНЯТ** — heavy/ultra идут через async Workflow в живой сессии (он non-blocking); `worker.sh` остаётся C2-обёрткой/для тестов; fully-detached `research-runner.py` НЕ пишем (firecrawl/agent — session-bound MCP). F7 resume = Workflow-native `resumeFromRunId`.

Сделано в Phase B:
- ✅ **B1** роли-файлы: synth-claude, judge, fact-checker, synth-gemini, synth-gpt5 (+ wired в research.js через roleRef).
- ✅ **B2** deep-reader content budget (≤~2500 слов/источник) + SKILL.md honest cost.
- ✅ **B3** `lib/cross-model-research.sh` (topic/report/sources; op-run self-wrap; offline-tested).
- ✅ **B4** F7 idempotency через Workflow resume + `set_workflow_id`.
- ✅ **B5** F14: meta.json git_rev/prompt_versions/temperatures + `--replay` (live-tested, 58s, 3 agents).
- ✅ **B6** standard tier validated LIVE (Gemini Flash fired + judge adjudicated, 12 sources, coverage 0.92, secrets-grep 0). **Bug fixed**: judge final_report_md теперь аппендится (был replace → затирал synth-отчёт). Unit-tested 6/6.

Открыто (когда реально понадобится heavy/ultra):
- live **heavy** тест (Gemini Pro + fact-checker) → валидирует Verify-фазу + deep template + W4 caffeinate (`pmset -g assertions`).
- live **ultra** тест (GPT-5 + Gemini Pro via cross-model-research.sh) → валидирует op-run cross-model + meta-judge + C4 grep-check на live cross-model run.
- TG notify для heavy/ultra ready (item `TG redresearch` или reuse).
- (опц.) research-runner.py + вариант (a/c) если понадобится session-independent cron.

## Дополнительные context references

- redplan SKILL.md и workflow/panel.js: `~/.claude/skills/plan-panel/` — pattern для копирования
- Plan iterations + reviews: `$CLAUDECORE_PATH/.plan-panel/redresearch-v1/`, `$CLAUDECORE_PATH/.plan-panel/2026-06-01_17-23-42-redresearch-v1/`, `2026-06-01_17-37-47-redresearch-phase-a-v2/`, `2026-06-01_17-46-38-redresearch-phase-a-v3-local/`
- Meta-judge с 18 priority actions от ultra v1: `2026-06-01_17-23-42-redresearch-v1/meta-judge.md`

## Sanity checks before merging end-state

- [ ] `/research "What is RDAP"` → lite mode chat answer в <3 мин
- [ ] `/research "GDPR cookie consent 2026"` → heavy mode background → TG ping → report.md в `~/Library/Application Support/redresearch/runs/<TS>-<slug>/report.md`
- [ ] kill -9 worker → next /research detect stale → resume prompt
- [ ] grep secrets in run.log = 0 hits для любого run
- [ ] /research-cleanup --older-than 30d удаляет старые runs

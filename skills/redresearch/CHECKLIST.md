# Implementation Checklist (from v3 heavy-review, 5 critical + 5 warnings)

> Pattern: review нашёл 5 critical, переписывать v4 не имеет смысла. Эти пункты — обязательные при имплементации. Каждый ставит `[x]` когда сделано в коде.

## 🔴 CRITICAL (must do before any deployment)

- [x] **C1 Data residency** — `runs/` НЕ в `$CLAUDECORE_PATH` (Yandex.Disk). `lib/persist.sh` форсит `~/Library/Application Support/redresearch/runs/` + REFUSED-guard если `REDRESEARCH_DATA_DIR` внутри CLAUDECORE_PATH (exit 2). Smoke-tested.
- [x] **C2 SIGKILL recovery (correct)** — `worker_pid`=$$ в `status.json`, primary stale-detector = `kill -0 $pid` (`detect_stale`). `workflow/worker.sh` (parent) делает `wait $child; rc=$?; write_status`. Child SIGKILL → parent пишет `failed exit=137`. Parent SIGKILL → нет trap, dead pid → next launch stale. Оба сценария smoke-tested. (Subtlety: child спавнится в subshell с disarmed traps, иначе set -e+EXIT-trap портит rc.)
- [x] **C3 F10 observability** — `lib/log.sh` → `run.log` JSONL append-only, поля `{ts, run_id, event_type, ...kv}`, allowlist event_type, secrets-scrubber. Smoke-tested (valid JSONL + scrub + allowlist reject).
- [~] **C4 Secrets hygiene** — NotebookLM-части N/A (выпилен). Сделано+tested: `log.sh` scrubber (sk-/AIza/ghp_/op:///JWT), grep-check 0-hits в `commands/research.md` pre-show, e2e secrets-grep = 0. Открыто (Phase B): grep-check внутри live cross-model.sh run (heavy/ultra не гонялись в Phase A).
- [x] **C5 Retention/cleanup** — `lib/manage.sh cleanup [--older-than 30d] [--dry-run]` + `/research-cleanup`. Не трогает live-running run (pid-guard). Smoke-tested. `--fresh` флаг прокинут в hunt.

## 🟡 WARNING (inline при коде)

- [x] **W1 Worker↔Workflow contract** — exit codes table в `workflow/worker.sh` (0=ok, 1=generic, 2=BUSY, 3=schema, 4=missing, 64=usage, 137=SIGKILL). `phase_max_seconds[mode]` = `detect_stale` per-mode timeouts в heartbeat. Smoke-tested (full table).
- [x] **W2 Atomic write_status** — mkdir-lock на отдельный `$RUN_DIR/.status.lockdir` (POSIX, без flock). Транзакция status+phase+heartbeat+(exit_code) → tmp → `mv -f`. Smoke-tested (10 concurrent → valid JSON, lock не leak). NB: исправлен set -e abort (return 0) + zsh-портируемость (RETURN-trap убран, `status`→`st`).
- [x] ~~**W3 Cookie expiry handler**~~ — N/A, NotebookLM выпилен (A0.5 verdict=FORBIDDEN)
- [~] **W4 caffeinate flags** — `lib/run-with-caffeinate.sh` готов: `-dims` + `-t` динамически из `scoper.estimated_seconds + 30%` (потолок 90мин). Wired в `commands/research.md` для heavy/ultra background. Не нужен для lite/standard foreground. DoD `pmset -g assertions` — при live heavy run (Phase B).
- [x] **W5 Smoke test suite** — `tests/smoke.sh` без живых API: persist+C1, heartbeat (init→completed, stale, 10 concurrent), log (scrub+allowlist), worker (W1+C2 SIGKILL+BUSY+stale-steal), manage (C5). 33/33 pass.

## Inline-нот для Phase B (когда дойдём)

- [x] **F6** prompt injection — `roles/deep-reader.md` §F6 (контент = ДАННЫЕ не инструкции) + URL deny-list (private-IP/file://localhost) в deep-reader + research.js reader prompt.
- [x] **F7** idempotency — **option b**: Workflow-native resume. `set_workflow_id` персистит `workflow_run_id` в status.json; `/research-resume` → `resumeFromRunId` (cached agents skip). Phase-маркеры `phases/<phase>.done` сняты — они были для dropped headless-runner; Workflow чекпойнтит на agent-granularity нативно. Smoke-tested.
- [x] **F14** reproducibility — meta.json: `model_ids` + `prompt_versions` + `temperatures` + `git_rev`; `--replay` (cached sources+claims → synth→judge без re-fetch). Live-tested (B5).

## Pivot triggers (если что-то ломает план)

- **NotebookLM ToS = forbidden** → выпиливаем A1, B3. Heavy/ultra работают на Claude+GPT-5+Gemini direct API. План становится проще
- **NotebookLM cookies живут <3d** → автоматизация ротации делается невыносимой → выпиливаем тоже
- **Yandex.Disk выясняется что не sync файлы вне CLAUDECORE_PATH** → нужен другой path для index/pointers

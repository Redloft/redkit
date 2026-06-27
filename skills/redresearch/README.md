# redresearch

Multi-agent research для Claude Code по модели **redplan**: scoper решает дёшево → фан-аут ролей по mode → judge синтезирует и валидирует цитаты. Не «один длинный поиск», а конвейер с разделением труда и обязательной проверкой источников.

**Status (2026-06-01):** Phase A + Phase B — code complete, закоммичено. lite и standard валидированы end-to-end живьём. heavy/ultra — код готов и offline-проверен, живые тесты отложены (стоят денег/времени). 34/34 smoke зелёные.

---

## Что делает

`/research <тема>` → cited `report.md` с confidence-рейтингами. Каждый нетривиальный факт — с `[N]` на источник. Источники только публичный web (firecrawl/WebSearch) + direct API (Claude/GPT-5/Gemini). Никакого reverse-engineered API.

```
scoper (Haiku, routing)
  → source-hunter (находит+ранжирует источники)
    → deep-reader ×N (извлекает claims с дословными цитатами, parallel)
      → synth (собирает cited report.md)
        → [standard+] synth-gemini (второе мнение, Gemini)
          → [heavy/ultra] fact-checker (cite coverage)
            → judge (gaps + verdict; lite=Haiku, иначе Fable)
              → [ultra] meta-judge (GPT-5 + Gemini Pro cross-model)
```

## Режимы

| Mode | Когда | Sources | Models | Время | Output |
|---|---|---:|---|---|---|
| **lite** | факт / короткий вопрос | 3-5 | Claude (haiku read/judge, sonnet synth) | <3 мин | brief, в чат |
| **standard** | обзор, 3-5 углов | 8-12 | + Gemini Flash | ~5-8 мин | standard, в чат |
| **heavy** | academic/legal, нужны цитаты | 15-25 | Claude(fable) + Gemini Pro + fact-checker | 10-25 мин | deep, background+TG |
| **ultra** | critical, третье мнение | 30+ | + GPT-5 + meta-judge | 20-45 мин | deep, background+TG |

На Max Claude-токены = $0; платны только Gemini/GPT-5 (standard+). lite ≈ ~1M субагент-токенов (см. SKILL.md cost footnote).

## Команды

| Команда | Что делает |
|---|---|
| `/research <topic>` | новое исследование (флаги `--lite/--standard/--heavy/--ultra/--fresh`) |
| `/research-list` | список run'ов |
| `/research-status <slug>` | статус + liveness |
| `/research-resume <slug>` | продолжить прерванный (Workflow `resumeFromRunId`) |
| `/research-replay <slug>` | пересобрать отчёт из кэша без re-fetch (итерация промптов) |
| `/research-cleanup [--older-than 30d]` | retention (не трогает running) |
| `/research-share <slug>` | отдать report.md |

## Ключевые решения

- **Local-first (C1):** run'ы в `~/Library/Application Support/redresearch/`, НЕ в Яндекс.Диске — scraped-контент не синкается в RU cloud. `persist.sh` форсит путь + guard.
- **NotebookLM выпилен** (A0.5 ToS audit = FORBIDDEN, reverse-engineering ban). Long-context grounding замещён Gemini 2.5 Pro (2M context) — легально. См. `lib/NOTEBOOKLM-TOS-VERDICT.md`.
- **Background = async Workflow в живой сессии** (вариант b): firecrawl/agents — session-bound MCP, поэтому fully-detached `research-runner.py` не пишем. `worker.sh` остаётся C2-обёрткой.
- **Tool policy:** WebSearch/WebFetch первичны (бесплатны, global policy), firecrawl — эскалация. Экономит credits.
- **Секреты:** только через `op run` (GPT-5) / env (Gemini); scrubber в логах; grep-check 0-hits перед показом.
- **F6 prompt-injection:** контент страниц — ДАННЫЕ, не инструкции; URL deny-list (private-IP/file://).

## Файлы

```
SKILL.md            entry, triggers, flow, modes, acceptance
_shared.md          контракт ролей: JSONL-схемы, confidence rubric, cite [N], шаблоны
commands/research.md  authoritative caller flow
roles/              scoper, source-hunter, deep-reader, synth-claude, judge,
                    fact-checker, synth-gemini, synth-gpt5
workflow/           research.js (orchestrator), worker.sh (C2 bg wrapper)
lib/                persist, heartbeat, log, manage (C5), run-with-caffeinate (W4),
                    cross-model.sh + cross-model-research.sh
tests/smoke.sh      34 hermetic checks (no live API)
HANDOFF.md          статус + Phase B остаток (heavy/ultra live)
CHECKLIST.md        C1-C5 / W1-W5 / F6/F7/F14 — что закрыто
```

## Тесты

```bash
bash tests/smoke.sh        # 34 hermetic (persist/heartbeat/log/worker C2+W1/manage)
```
Живьём валидированы: lite (×2, <3мин, PASS), standard (Gemini + judge-adjudication, secrets-grep 0), --replay (58с). Открыто: live heavy/ultra (Gemini Pro/GPT-5/fact-checker/meta-judge), TG notify.

## Происхождение

Спроектирован через 3 итерации `plan-panel` (ultra→heavy→local pivot). 5 critical + 5 warning из ревью — `CHECKLIST.md`, закрыты при имплементации. Зеркалит структуру `~/.claude/skills/plan-panel/`.

# Role: synth-gpt5

**Model**: GPT-5 (OpenAI)
**Activation**: ultra only — Phase 6 (CrossModel meta-judge), вместе с Gemini Pro
**Invocation**: прямой API-вызов через `lib/cross-model-research.sh` (op run wrapped)
**Key**: `OPENAI_API_KEY` в 1Password (`op://AI-Tokens/OpenAI/credential`). **Только через `op run`, никогда не печатать.**

## Зачем GPT-5 здесь

Ultra-режим — для critical-тем, где нужно **третье независимое мнение**. GPT-5 (другой вендор, другой training) ловит то, что Claude и Gemini вместе пропустили. Meta-judge синтезирует три точки зрения → verdict может стать строже.

## Вызов (через op run, секрет только в дочернем процессе)

Не вызывать curl к OpenAI напрямую с ключом в команде. Использовать адаптер:
```bash
bash ~/.claude/skills/redresearch/lib/cross-model-research.sh <topic_file> <report_file> <sources_file>
```
Адаптер сам делает `op run --env-file=<(echo 'OPENAI_API_KEY=op://AI-Tokens/OpenAI/credential') -- ...`, параллельно зовёт GPT-5 + Gemini Pro, отдаёт агрегированный JSON `{gpt, gemini, errors, usage}`.

## Что просит адаптер у GPT-5

Передаёт `topic` + `report_md` + `sources` + Claude judge-вывод. Просит:
1. Что Claude/Gemini **упустили** (углы, которые GPT видит лучше)?
2. С какими выводами **не согласен** + обоснование?
3. 2-3 главных дополнительных **concern** по теме?
4. Overall **confidence** в отчёте (0-1).

## Output → meta-judge

GPT-вывод (как и Gemini-вывод) идёт в meta-judge agent, который синтезирует:
```json
{
  "final_verdict": "PASS|NEEDS-WORK|FAIL|UNCERTAIN",
  "confidence": 0.9,
  "agreement_summary": {"all_three": [...], "two_of_three": [...], "unique_to_claude": [...], "unique_to_gpt": [...], "unique_to_gemini": [...]},
  "added_by_gpt": ["..."],
  "added_by_gemini": ["..."],
  "disputes": [{"point": "...", "claude": "...", "gpt": "...", "gemini": "..."}],
  "final_report_md": "<опц. ДОБАВКА '## Cross-model synthesis' — аппендится после synth-отчёта, НЕ замена>",
  "summary": "..."
}
```

## Стоимость

GPT-5 платный (~$5/M in + $20/M out). Ultra cross-model часть **всегда тратит API** даже на Max-плане. Поэтому ultra → `needs_user_confirmation=true`. Оценка: +$0.10-0.20 на отчёт.

## Anti-patterns

- ❌ **Никогда** не `op read` / не печатать `OPENAI_API_KEY`. Только через адаптер с `op run`.
- ❌ Не `curl -v` / `2>&1` — verbose может слить Authorization header (см. CLAUDE.md secrets protocol).
- ❌ Не запускать ultra без user confirmation (это деньги).
- ❌ Не считать GPT истиной — это одно из трёх мнений, meta-judge взвешивает.

## Self-check

- [ ] Вызов только через cross-model-research.sh (op run)
- [ ] Ключ не в stdout/логах/команде
- [ ] При фейле GPT — meta-judge синтезирует из 2 источников (degraded), не падает

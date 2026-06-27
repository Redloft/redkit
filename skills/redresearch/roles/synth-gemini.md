# Role: synth-gemini

**Model**: Gemini 2.5 Flash (standard) / Gemini 2.5 Pro (heavy, ultra)
**Activation**: standard / heavy / ultra — Phase 3, ПОСЛЕ synth-claude (второе мнение)
**Invocation**: НЕ субагент Claude — это прямой API-вызов Gemini через Bash/curl
**Key**: `$GEMINI_API_KEY` уже в env (из `~/.zshenv`). **Никогда не печатать значение.**

## Зачем Gemini здесь

Две функции:
1. **Независимое второе мнение** — другая модель видит другие слабости отчёта. Снижает single-model bias.
2. **Long-context grounding** (heavy/ultra) — Gemini 2.5 Pro держит 2M токенов контекста. Это **легальная замена** grounded Q&A, ради которой раньше рассматривался NotebookLM (выпилен, A0.5 FORBIDDEN). Pro может принять ВСЕ сырые источники в контекст и проверить выводы против них.

## Вызов (через Bash, граceful — фейл НЕ фатален)

```bash
# $GEMINI_API_KEY в env. НЕ эхоить. PROMPT — переменная с задачей.
curl -s -X POST \
  "https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent?key=$GEMINI_API_KEY" \
  -H 'Content-Type: application/json' \
  -d @<(jq -nc --arg p "$PROMPT" '{contents:[{parts:[{text:$p}]}],generationConfig:{temperature:0.3}}')
```
`MODEL` = `gemini-2.5-flash` (standard) либо `gemini-2.5-pro` (heavy/ultra).

Если API недоступен / ошибка / нет ключа → верни `{"error": "..."}` и продолжай. Отчёт остаётся Claude-only (degraded, не сломан).

## Что просить у Gemini (PROMPT)

Передать: `topic` + `report_md` + список `sources` (+ для heavy/ultra сырые claims для grounding). Спросить:
1. Что в отчёте может быть **неточно / устарело / переврано**?
2. Какие важные аспекты темы **пропущены**?
3. Есть ли утверждения, **не подкреплённые** перечисленными источниками?
4. Overall **confidence** в отчёте (0-1).

## Output (краткое резюме для judge)

Верни компактное резюме ответа Gemini: его top-замечания + confidence. Judge учтёт это как второе мнение (не как истину — Gemini тоже может ошибаться).

```json
{
  "model": "gemini-2.5-pro",
  "inaccuracies": ["..."],
  "missing": ["..."],
  "unsupported": ["..."],
  "confidence": 0.85,
  "error": null
}
```

## Anti-patterns

- ❌ **Никогда** не печатать `$GEMINI_API_KEY` (ни в логах, ни в echo, ни в URL в stdout).
- ❌ Не падать если Gemini недоступен — graceful degrade.
- ❌ Не подменять Claude-отчёт Gemini-версией — это ВТОРОЕ мнение, синтез/judge решает.
- ❌ Не слать в Gemini секреты/PII из контекста.

## Self-check

- [ ] Ключ не попал в stdout/лог
- [ ] При ошибке вернул error, не уронил run
- [ ] Резюме компактное (judge не нужен весь ответ Gemini дословно)

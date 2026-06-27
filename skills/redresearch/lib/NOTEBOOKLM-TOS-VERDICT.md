# NotebookLM Automation — ToS Verdict

**Date**: 2026-06-01  
**Auditor**: redresearch Phase A0.5 (BLOCKING step)  
**Verdict**: **🟥 FORBIDDEN** (for Phase 1)  
**Decision**: NotebookLM выпиливается из плана. Heavy/ultra режимы работают на Claude+GPT-5+Gemini direct API без NotebookLM.

## Evidence (verbatim quotes)

### Google Terms of Service (https://policies.google.com/terms)

> "using automated means to access content from any of our services in violation of the machine-readable instructions on our web pages (for example, robots.txt files that disallow crawling, training, or other activities)"

> "reverse engineering our services or underlying technology, such as our machine learning models, to extract trade secrets or other proprietary information, except as allowed by applicable law"

> "using AI-generated content from our services to develop machine learning models or related AI technology"

### notebooklm-py disclaimer (own README, https://github.com/teng-lin/notebooklm-py)

> "This library uses undocumented Google APIs that can change without notice. Not affiliated with Google. Use at Your Own Risk"

### NotebookLM privacy (https://support.google.com/notebooklm/answer/17004255)

> "The content in NotebookLM will not be used to directly train our foundational AI models, unless you choose to provide feedback."

(Это хорошо для приватности uploaded content, но не разрешает automation поверх.)

## Analysis

| Risk | Likelihood | Severity |
|---|---|---|
| Account suspension Google за reverse-engineered API | medium-high | HIGH (теряю access ко всем Google services под `zcreative.spb@gmail.com`) |
| API ломается без notice (notebooklm-py сами признают) | high | MEDIUM (нужно реписывать клиент) |
| Legal exposure за upload scraped third-party content | low-medium | MEDIUM (copyright неясен для transformative AI use) |
| Cookies expiry / re-auth headache | high | MEDIUM (UX боль) |

**Tradeoff**: NotebookLM даёт grounded Q&A с цитатами, но **то же самое мы можем сделать локально**: Claude/Gemini получают scraped sources как context, инструкция «cite source_id [N] for each claim», fact-checker валидирует. Чистый Anthropic/OpenAI/Google API без reverse-engineering.

## Implications для плана

### Что выпиливается из Phase 1
- ❌ Step A1 — NotebookLM auth setup → **SKIP полностью**
- ❌ Role `notebooklm-loader` (Phase B B3) → **SKIP**
- ❌ 1Password item `NotebookLM Local` → не создаём
- ❌ `lib/notebooklm-client.py` → не пишем
- ❌ Cookies lifecycle / expiry handler / W3 из checklist → не нужны

### Что остаётся (упрощённая architecture)

| Mode | Sources | Models | Cross-verify |
|---|---|---|---|
| lite | 3-5 web | Claude | — |
| standard | 8-12 web | Claude + Gemini Flash | — |
| heavy | 15-25 (web + PDFs via firecrawl) | Claude + Gemini Pro | — |
| ultra | 30+ | Claude + GPT-5 + Gemini Pro | ✓ panel + judge |

PDFs обрабатываются через `firecrawl_scrape` (он умеет PDF extraction) или `firecrawl_extract`. Grounded Q&A замещается на: sources → Claude/Gemini в context window → instruction «every claim must cite source_id [N]» → fact-checker валидирует cite coverage.

### Что Phase 1 теряет (acceptable trade)

- Audio overview (NotebookLM фича) — никогда не использовал, не критично
- Long context grounded Q&A (NotebookLM удерживает 1M+ tokens of sources) — частично замещается **Gemini 2.5 Pro context** (2M tokens) — Gemini может сам сыграть эту роль легально
- Цитаты "by NotebookLM" — у нас будут "by Claude/Gemini с обязательной cite check" 

## Future re-eval

Если когда-то Google официально откроет NotebookLM API (есть слухи о Gemini Files API расширении) → переоценить. Сейчас даже opt-in `--notebooklm-experimental` flag не делаем — поддерживать broken-API код дорогая разовая ставка.

## Updates to CHECKLIST.md

- W3 (cookie expiry handler) → **remove**
- Pivot trigger «NotebookLM ToS=forbidden» → **TRIGGERED, applied**

## Action items

- [x] A0.5 ToS verdict зафиксирован
- [ ] Обновить SKILL.md без mentions NotebookLM
- [ ] Архитектурный diagram без B3
- [ ] Phase B B4 synth panel: добавить инструкцию «Gemini Pro используется ТАКЖЕ для long-context grounding (вместо NotebookLM)»

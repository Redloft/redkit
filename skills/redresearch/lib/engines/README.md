# SourceEngine — единый контракт движков поиска источников

Введён plan-panel 2026-07-20 (critical #3) чтобы новые движки подключались единообразно,
а `source-hunter`/synth/judge видели degraded вместо тихого пустого списка. Купирует
заявленный «engine sprawl».

## Контракт (обязателен для каждого адаптера)
```
stdin:  <query-строка>
stdout: {"engine":"<id>","status":"ok|partial|failed","results":[
           {"url":..., "title":..., "snippet":..., "score":num, "source_id":"<id>"}
        ]}
Правила:
- НИКОГДА не бросает (fail-open): сеть/ключ/парс-сбой → {"status":"failed","results":[]}, exit 0.
  Это включает и провал `op run` (просроченный токен/переименован item/op не на PATH): ключ
  берётся с ЗАХВАТОМ вывода дочернего процесса (не exec), невалидный вывод → контрактный fail.
- Приватность: query проходит fail-closed scrub (_shared/external-judge/scrub.sh) ДО egress.
- Секреты: ключ из 1Password через op run, в curl --config (не argv/ps), без -v/2>&1.
- Тумблер <ID>_ENABLE читает САМ адаптер (defense-in-depth): при "0" → fail() ДО платного вызова.
- Observability: каждая fail-точка пишет ОДНУ строку причины в stderr (без query/ключа).
- --self-test-offline: проверяет нормализацию ответа на фикстуре без сети (exit 0/1).

score — ENGINE-LOCAL эвристика релевантности, НЕ сравнима между движками (exa: нейро 0-1;
perplexity: rank по позиции 1..0; serper/websearch: rank). dedup использует score лишь как
мягкий выбор «какую копию читать» — провенанс (_engines) склеивается ВСЕГДА независимо от score.
```

## Движки
| id | файл | ключ (1Password) | тумблер | режимы |
|----|------|------------------|---------|--------|
| exa | `exa.sh` | `Exa API` / EXA_API_KEY | `EXA_ENABLE` | standard+ |
| tavily | `tavily.sh` | `Tavily API` / TAVILY_API_KEY | `TAVILY_ENABLE` | quick+ (LLM-native, есть .answer) |
| perplexity | `perplexity.sh` | `Perplexity API` / PPLX_API_KEY | `PPLX_ENABLE` | heavy/ultra |
| academic | (MCP `firecrawl_research_*`, вызывает агент, не shell) | — (firecrawl уже есть) | `ACADEMIC_ENABLE` | heavy/ultra |
| serper/websearch | встроенные инструменты агента source-hunter | — | всегда | все |

## Дедуп (обязательный пост-шаг, `lib/source_dedup.py`)
Результаты ВСЕХ движков слить и прогнать через `source_dedup.py` перед deep-reader:
```
cat all_results.json | python3 lib/source_dedup.py   # → deduped, _canonical_key + _engines[]
```
canonical-key: arxiv abs↔pdf → один; DOI > URL; strip tracking/scheme/www/slash/fragment.
Так judge/C4 отличают «два источника» от «один найден двумя движками», deep-reader читает раз.

## Бюджет-гард (обязателен для платных: exa, perplexity, tavily) — РЕАЛИЗОВАН
`lib/budget_guard.py` — атомарный (fcntl.flock) счётчик, pessimistic reserve ДО вызова API.
Подключён ко всем трём платным адаптерам (`reserve <engine>` перед curl: rc=3 over→fail,
rc=1 err→fail-open+видимая диагностика). Лимиты: `EXA_BUDGET_USD_DAY`, `PPLX_BUDGET_USD_DAY`,
`TAVILY_BUDGET_USD_DAY` (env, default $1/день/движок). Иначе параллельный sweep обошёл бы лимит.
firecrawl (академ, ходит через MCP не per-call) — разовый floor-alert `lib/firecrawl_floor.sh` (<150).

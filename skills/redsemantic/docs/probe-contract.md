# probe.sh — output contract (Phase R1)

`lib/adapters/probe.sh` решает graceful degradation: какие источники РЕАЛЬНО дадут данные под фактический region/site. Два режима.

## Режимы
- **presence (default, дёшево, без сети):** `probe.sh` / `probe.sh --names` — как раньше: проверяет НАЛИЧИЕ credential-полей. Для dry-контекстов и быстрого скоупинга.
- **smoke (`--smoke`, реальный прогон):** делает лёгкий data-запрос под region/site → отличает «credentialed» от «returns_data». Закрывает баг: DataForSEO (RU=санкции) и GSC (property не привязана) проходили presence как live, но возвращали ПУСТО.

## Вызов
```
probe.sh [--names]                          # presence
probe.sh --smoke [--region <r>] [--site <url>] [--names]
```

## Output (stdout, JSON; human-диагностика в stderr)
```jsonc
{
  "available": ["suggest","wordstat",...],         // presence (credentialed) — backward-compat
  "detail":    { "suggest":true, "wordstat":true, "dataforseo":true, "search-console":true },
  "smoke": {                                        // только при --smoke
    "suggest":        { "credentialed":true, "returns_data":true,  "reason":"ok" },
    "wordstat":       { "credentialed":true, "returns_data":true,  "reason":"topRequests ok" },
    "dataforseo":     { "credentialed":true, "returns_data":false, "reason":"RU keyword/SERP заблокирован (санкции) — geo-check" },
    "search-console": { "credentialed":true, "returns_data":false, "reason":"property не привязана к OAuth / 0 sites" }
  }
}
```
- `--names` (presence): credentialed-адаптеры. `--names --smoke`: только адаптеры с `returns_data:true` (для adapter-листа оркестратора).
- **reason** — короткая человекочитаемая причина; БЕЗ raw-ответа API (особенно GSC — без поисковых запросов, PII).

## Exit protocol
`0` — ≥1 адаптер `returns_data:true`. `2` — credentialed есть, но никто не вернул данных (degraded — оркестратор предупреждает). `3` — внутренняя ошибка probe. (presence-режим всегда `0`.)

## Стоимость smoke
suggest/wordstat/GSC — бесплатны. DataForSEO RU → `--geo-check` (БЕЗ вызова). DataForSEO intl → дешёвый `--probe` data-ping. Делается только при `--smoke`.

## GSC / PII
Для `search-console` smoke возвращает только `returns_data` + (опц.) count, НИКОГДА raw-запросы. GSC-ответ не персистится.

## Секреты
Все smoke-вызовы — через `op run` внутри адаптеров; probe их не печатает (см. `~/.claude/CLAUDE.md`). Без `curl -v`/`2>&1`.

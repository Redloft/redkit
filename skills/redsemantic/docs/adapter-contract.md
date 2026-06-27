# DataForSEO adapter — frozen contract (Phase 1a)

Замороженный контракт `lib/adapters/dataforseo.sh` (multi-method). Все потребители (redsemantic, redloft seo, audit-site, redresearch, anthropic-skills:seo) полагаются на него. Менять — только с bump `schema_version`.

## 1. Вызов
```
dataforseo.sh <method> [args...] [--flags]
dataforseo.sh --probe                 # readiness gate
dataforseo.sh <keyword>               # БЭК-КОМПАТ: алиас на `related` (deprecation в stderr)
```
Методы: `related · suggestions · volume · overview · intent · ranked · competitors · serp · onpage · tech · business · ai-vis`. Сервис: `--geo-check <region>`.

## 2. Output envelope (stdout) — ЕДИНЫЙ для всех методов

**Success** (exit 0):
```json
{ "ok": true, "source": "dataforseo", "method": "overview", "schema_version": 1,
  "cost_estimate": 0.0114, "cache_hit": false, "data": { ... } }
```
**Error** (exit ≠ 0):
```json
{ "ok": false, "source": "dataforseo", "method": "overview",
  "error_code": "cap_exceeded", "error_message": "per-run cap 50 reached" }
```

Caller ОБЯЗАН: проверить `$?` И `jq -e .ok` ДО потребления `.data`. `degraded` ≠ выдуманные числа — нет данных = `ok:false`, не пустой success.

## 3. Типизированные `data` по методам (НЕ через keyword-схему)
| method | data |
|---|---|
| related, suggestions, volume, overview, intent | `{ keywords: [ {phrase, freq, intent?, difficulty?} ] }` |
| ranked | `{ domain, items: [ {phrase, freq, position, url} ] }` |
| competitors | `{ domain, items: [ {competitor_domain, intersections, avg_position} ] }` |
| serp | `{ keyword, results: [ {type, position, title, url} ], paa: [..], featured: [..] }` |
| onpage | `{ url, onpage_score, checks: { ...on-page signals } }` |
| tech | `{ domain, technologies:{group:{...}}, groups:[...] }` (geo-независим) |
| business | `{ query, listings:[ {title, rating, reviews, address, domain} ] }` (Maps SERP, geo-restricted) |
| ai-vis | `{ target, citations: [ {engine, cited, snippet?} ] }` |

`freq` — только из живого ответа; нет источника → `null` (не выдумывать).

**Гео-доступность:** keyword/SERP/Labs/business (related/suggestions/volume/overview/intent/ranked/competitors/serp/business) — **НЕТ данных по РФ/РБ** (Google Ads-санкции) → для RU дают `geo_unsupported` без траты; роутинг на Wordstat. URL/domain-методы (onpage/tech) — **geo-независимы**, работают для РФ. Оркестратор узнаёт через `--geo-check <region>` (exit0=supported).

## 4. error_code enum
`creds_missing` (item/поля пусты) · `not_verified` (--probe: status≠20000) · `cap_exceeded` (per-run/daily count или $) · `bad_input` (injection/валидация) · `ssrf_blocked` (url-guard) · `http_<code>` (HTTP не 2xx) · `api_<status>` (DataForSEO status_code≠20000) · `timeout` · `parse_error`.

## 5. cost-log (stderr, 1 строка на live-вызов; cache-hit не логируется как трата)
```
DFS_COST {"method":"overview","cost_estimate":0.0114,"cache_hit":false,"run_total":0.034,"run_calls":3}
```
Оркестратор агрегирует `run_total`/`run_calls` в свой return-envelope/artifact. Без args/кредов в строке.

## 6. cost_estimate (грубо, из прайсинга 2026)
serp $0.0006 (live $0.002) · related/suggestions/ranked/competitors/overview/keyword_ideas $0.01+$0.0001×items · intent $0.001+$0.0001×kw · volume $0.001+$0.0001×kw · onpage $0.000125×pages · ai-vis $0.01.

## 7. Cost-cap (env)
`DFS_RUN_ID` (прокид оркестратором; иначе PID) · `DFS_MAX_CALLS` (def 50, per-run count) · `DFS_MAX_COST_USD` (per-run $) · `DFS_DAILY_HARD` ($/день, exit≠0) · `DFS_DAILY_SOFT` ($/день alert). Атомарность — **mkdir-lock** (на macOS нет flock); check-then-act внутри одного lock.

## 8. Кэш
`DFS_CACHE_DIR` (def `~/.cache/dataforseo`, проверка «вне Яндекс.Диска»). Ключ `sha256(method+sorted_args+region+lang)`. Sidecar `<key>.meta` `{cached_at, ttl, status_code}`. TTL: serp 1д · volume 7д · overview/related/suggestions/intent 7д · ranked/onpage/competitors 3д · ai-vis 1д. **Не кэшировать `ok:false`.** PII-методы (ranked/competitors/onpage/ai-vis) → подпапка `<DFS_PROJECT_SLUG>/`, `chmod 700`. cache-hit бесплатен и не считается против cap.

## 9. Безопасность
- Креды только через `op run` + `--netrc-file` (не `curl -u`; нет в ps aux); `set +x`.
- `_validate_input`: keyword без shell-метасимволов/backticks; domain `^[a-z0-9.-]+$`; url https + `validate_url` (reuse `redloft/lib/url-guard.sh`).
- Без `-v`/`2>&1` (Basic/Api-Key leak).

## 10. Флаги управления / тест
`DFS_DISABLED=1` (kill-switch: любой вызов → `ok:false,error_code:disabled`) · `DFS_METHODS_ENABLED="overview,ranked"` (whitelist новых методов; пусто = все) · `DFS_FIXTURE_DIR` (читать `<dir>/<method>.json` вместо curl — hermetic) · `--record` (записать живой ответ в fixture).

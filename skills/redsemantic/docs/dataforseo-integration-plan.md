# План v2: интеграция DataForSEO во все релевантные скиллы (+ cost-модель)

> v2 — после прогона через plan-panel (NEEDS-WORK@0.90, 8 ролей). Закрыты 3 критичных дефекта (нерабочий cost-cap, отсутствие per-method контракта, неопределённая exit-семантика) + 2 gap (SSRF, утечка кредов в ps aux) + resolved-конфликты. Changelog панели — в конце.

## Context / проблема

DataForSEO подключён (item `AI-Tokens/DataForSEO`, Basic auth, адаптер `redsemantic/lib/adapters/dataforseo.sh` с 1 методом `related_keywords`), используется на ~1%. У него 10+ семейств API (SERP, Keywords Data, Labs, On-Page, Backlinks, Domain Analytics, Business Data, AI Optimization), ложащихся на существующие скиллы и закрывающих их дыры (живые Google-объёмы, конкурентная семантика, тех-SEO-аудит, измерение GEO-цитируемости, source-discovery). Цель: **единый multi-method адаптер** + cost-модель + поэтапный rollout под бюджет.

Аккаунт: auth ✅ (self-test 20000), но требует **верификации + баланс** (мин депозит $50) — Phase 0 блокирует всё.

## Прайсинг (per-call, 2026; источники в конце)
- **SERP**: standard $0.0006, live $0.002 /запрос.
- **Labs**: $0.01/task + $0.0001/item (related/suggestions/ranked/keyword_ideas/keyword_overview/serp_competitors/bulk_keyword_difficulty); search_intent $0.001+$0.0001/kw; historical_rank $0.1+$0.001/item; clickstream ×2.
- **Keywords Data** google_ads/search_volume: ~$0.001/task + $0.0001/kw.
- **On-Page** instant_pages: ~$0.000125/стр.
- **AI Optimization** ai_summary: ~$0.01/task.
Вывод: Labs дёшев и предсказуем; `keyword_overview` отдаёт volume+difficulty+intent+trend в одном вызове.

---

## Архитектура adapter-core (Phase 1) — ужесточена

Расширить `redsemantic/lib/adapters/dataforseo.sh` до multi-method (подкоманда первым аргументом). **Решение по развилке (DR):** адаптер остаётся в `redsemantic` (data-layer-владелец); промоутить в `~/.claude/skills/_shared/` только если его начнёт звать >1 скилл (тогда + symlink, item tag `scope-global`). Никаких открытых развилок в коде.

### Методы
```
dataforseo.sh <method> <args...>
  related|suggestions <kw> [--limit]      Labs
  volume      <kw,...>                     Keywords Data google_ads search_volume
  overview    <kw,...>                     Labs keyword_overview (vol+diff+intent+trend)
  intent      <kw,...>                     Labs search_intent
  ranked      <domain> [--limit]           Labs ranked_keywords
  competitors <domain>                     Labs serp_competitors
  serp        <kw> [--region][--live]      SERP google/organic (+PAA/featured)
  onpage      <url>                        On-Page instant_pages
  ai-vis      <kw|domain>                  AI Optimization [exploratory]
  --probe                                  readiness gate (см. ниже)
```
Бэк-компат: голый `dataforseo.sh <keyword>` (без метода) → алиас на `related` (deprecation-нота в stderr). `dataforseo_v1.sh` — бэкап перед рефактором. `smoke.sh` обновляется синхронно; acceptance = существующие DFS-тесты зелёные после рефактора.

### 🔴 FIX-1 (v3) — рабочий cost-cap, атомарный + cost-based + hard-stop
Env-счётчик не переживает отдельные bash-процессы из `semantic.js`. ⚠️ `flock` на macOS НЕТ → используем **mkdir-lock** (POSIX-atomic, как `heartbeat.sh`/`context.sh`). Атомарный **read-check-increment-write под одним lock** ПЕРЕД каждым `_call()`:
- **per-run**: файл `$TMPDIR/dfs-cap/<DFS_RUN_ID>` (RUN_ID из оркестратора); счётчики **count И cost($)**; превышение `DFS_MAX_CALLS` (def 50) ИЛИ `DFS_MAX_COST_USD` → exit≠0 `cap_exceeded`.
- **global daily hard-stop**: `~/.cache/dataforseo/spend-YYYY-MM-DD.tally` (строка `<ISO>\t<method>\t<cost>\t<run_id>`), под тем же lock; `DFS_DAILY_HARD` ($, exit≠0) + `DFS_DAILY_SOFT` (alert). Ловит параллель/cron, которые per-run RUN_ID-изоляция пропускает.
- check-then-act **внутри одного lock** (не TOCTOU); recovery при битом tally = fail-open (не падать) + warning, но in-run cap всё равно держит.
- cache-hit **не считается** против cap.
- Acceptance: 60 параллельных вызовов при cap=50 → ровно 50 проходят; loop по overview упирается в `DFS_MAX_COST_USD`.

### 🔴 FIX-2 — замороженный per-method контракт вывода (`docs/adapter-contract.md`)
Единый envelope, НЕ прогонять не-keyword методы через keyword-форму:
```
success: {ok:true, source:"dataforseo", method, schema_version:1, cost_estimate, data:{…}}
error:   {ok:false, method, error_code, error_message}
```
Типизированные `data` по методам: keyword-методы → `{keywords:[{phrase,freq,intent?,difficulty?}]}`; `ranked`/`competitors` → `{domain, items:[…]}`; `onpage` → `{url, checks:{…}}`; `ai-vis` → `{target, citations:[…]}`. Контракт заморожен ДО кодинга Phase 1.

### 🔴 FIX-3 — exit/degradation-семантика
success = exit 0 + payload; любая ошибка/недоступность = exit≠0 + `{ok:false,error_code}` на stdout. Коды: `creds_missing|not_verified|cap_exceeded|http_<code>|api_<status>|ssrf_blocked|parse_error`. Callers проверяют `$?` и `jq .ok` ДО потребления. Закрывает «нечестные null» из risk-листа: degraded ≠ выдуманные числа.

### 🕳 GAP-1 — SSRF на `onpage <url>` / `ai-vis`
URL уходит в реальный краулер DataForSEO. Перед платным вызовом — guard (reuse `redloft/lib/url-guard.sh` `validate_url`): только https, отсечь RFC1918/link-local/loopback/metadata. Блок → exit≠0 `error_code:ssrf_blocked`.

### 🕳 GAP-2 — креды в `ps aux` (есть уже сейчас в `related`)
`curl -u "$LOGIN:$PASS"` виден в process table. Заменить на **`--netrc-file`** (netrc-файл собирается в op-run child, 600), `set +x` вокруг. Чинится в т.ч. для существующего метода.

### 🔴 FIX-4 (v3) — shell-injection guard (все методы)
v2 закрыл только SSRF, но `keyword='$(...)'` через bash-интерполяцию в URL/body не экранирован. `_validate_input()`: whitelist по типу arg (keyword — без `` $`;|&<>(){} ``-метасимволов и backticks; domain — `^[a-z0-9.-]+$`; url — https + `validate_url`); параметры в запрос только через `jq --arg` / `curl --data-urlencode`, НЕ через bash-интерполяцию. Acceptance: `keyword='$(id)'` не исполняется и режется на валидации (`error_code:bad_input`).

### 🔴 PII-at-rest (v3, перенос из Phase 4 в Phase 1)
Кэш PII-методов (ranked/competitors/onpage/ai-vis/business) пишется на диск → риск sync в Яндекс.Диск. В **Phase 1** cache-write pipeline: per-slug путь `~/.cache/dataforseo/<DFS_PROJECT_SLUG>/` для PII-методов, `/shared/` для публичных, `chmod 700`, проверить что `~/.cache` ВНЕ Я.Диска (иначе override `DFS_CACHE_DIR`). Business Data до Phase 4 — кэш запрещён.

### Кэш (resolved-конфликт: `~/.cache`, XDG)
`~/.cache/dataforseo/`, ключ `sha256(method + sorted_args + region + lang)`, sidecar `{cached_at, ttl, status_code}`. Per-method TTL: SERP 1д / volume 7д / ranked,onpage 3д / ai-vis 1д. **Никогда не кэшировать `status≠20000`.** Project-slug-изоляция для competitor/PII-данных. `.gitignore`. Cache-hit не платит и не считается против cap.

### probe granularity + kill-switch
`probe.sh` → `{dataforseo_ok, dataforseo_verified, dataforseo_balance}`; `dataforseo.sh --probe` → exit0 только если `status==20000 AND balance>0`. Phase 0 live-smoke зовёт `--probe` первым и аборт при фейле. Kill-switch: `DFS_DISABLED=1` (вырубить во всех уже-мигрированных скиллах) + `DFS_METHODS_ENABLED` (rollout-флаг, default off для новых методов).

### Observability + hermetic dry-run
Единый cost-log: структурная строка в stderr на каждый вызов (`method, cost_estimate, cache_hit, run_total`) → оркестратор агрегирует в return-envelope/artifact (делает $15–35/мес проверяемым). Dry-run: `DFS_FIXTURE_DIR` + `--record` (записать живой ответ как фикстуру), тесты гоняют на фикстурах без трат.

---

## Per-skill интеграция (без изменений по сути; gated по `--probe`)

1. **redsemantic** (приоритет 1): harvest += `overview` (Google-объёмы 2-й живой источник к Wordstat) + `ranked <competitor>`; cluster += `serp`-overlap + `intent`; structure += PAA→FAQ + difficulty→приоритет. Затрагивает `roles/{harvester,clusterer,architect}.md` + `workflow/semantic.js` (+ прокид `DFS_RUN_ID`).
2. **redloft → стадия `seo`** (приоритет 2): `serp_competitors` + `ranked` + `difficulty`. Новый `redloft/stages/seo/prompt.md` + envelope.
3. **audit-site** (приоритет 2): On-Page (тех-SEO глубже Lighthouse) + AI Optimization (GEO-**результат**) + SERP rank-tracking. Gated.
4. **anthropic-skills:seo** (приоритет 3): тот же набор; **не дублировать** с audit-site — общий adapter-core, разные потребители (resolved: дублируется только тонкий вызов, логика в адаптере).
5. **redresearch** (приоритет 3): SERP source-discovery (доп. к firecrawl) + Business Data + Domain Analytics. `roles/source-hunter.md`.
6. **domain-check** (приоритет 4): Domain Analytics WHOIS — **по умолчанию skip**.

---

## Cost-модель (сценарии) — без изменений
- redsemantic lite ≈ $0.06–0.10 · standard ≈ $0.25–0.40 · heavy ≈ $0.80–1.20.
- audit-site (1 сайт) ≈ $0.07–0.12 · redloft seo ≈ $0.05–0.08 · redresearch SERP ≈ $0.006.
- Месячно (~30 redsemantic + 20 audit-site + 50 redloft) ≈ **$15–35/мес**; депозит $50 = 1.5–3 мес. Главный риск — не цена за вызов, а runaway-loop → закрыт FIX-1 (flock-cap).

---

## Rollout (фазы) — Phase 2 разбит (resolved)

- **Phase 0 — unblock** (на пользователе): верифицировать аккаунт DataForSEO + депозит $50. `--probe` зелёный = gate пройден.
- **Phase 1 — adapter-core** (декомпозировано, v3): **1a** `docs/adapter-contract.md` (envelope+cost-log+коды) · **1b** `dataforseo.sh` core: `_call()` + netrc + `_validate_input` (injection) + SSRF + exit-семантика + envelope + методы + `--probe` + бэк-компат + kill-switch · **1c** cost-cap (mkdir-lock per-run count+$ / global daily hard) + кэш (sha256, TTL, slug-изоляция PII, chmod700) + fixtures (`DFS_FIXTURE_DIR`/`--record`) · **1d** hermetic-тесты + обновить consumers (harvester role) + бэкап v1 + smoke. Acceptance (hermetic, до Phase 0): `DFS_MAX_CALLS=1`→2-й падает; 60 параллельных при cap=50→ровно 50; `keyword='$(id)'` режется; SSRF-URL блок; `ps aux` без кредов; smoke зелёный.
- **Phase 2a** — redsemantic: `overview` + `ranked` в harvest (минимальный adapter-add). Обновить dryrun (canned методы via fixture).
- **Phase 2b** — redsemantic: SERP-overlap кластеризация как новая post-harvest стадия в `semantic.js` (отдельная сессия).
- **Phase 3** — audit-site + redloft seo: On-Page + ai-vis + competitors.
- **Phase 4** — redresearch + anthropic seo: SERP-discovery, Business Data (+ **PII-страйп** отзывов из кэша — gap data-роли).
- **Phase 5** — domain-check (опц./skip).

Каждая фаза: метод → self-test → интеграция → hermetic dry-run (fixture) → опц. живой smoke на 1 кейсе с cost-логом.

## Acceptance (Done-when)
- adapter-core: flock cost-cap (per-run+global) рабочий, envelope-контракт заморожен, exit-семантика определена, SSRF-guard, netrc (нет кредов в ps aux), кэш с TTL, `--probe`, kill-switch, cost-log, fixture dry-run.
- Каждый скилл: hermetic dry-run зелёный + методы gated по `--probe`.
- Cost-лог per-run виден пользователю; secrets-протокол соблюдён (op run, без verbose, без -u).

---

## Changelog (что изменила панель v1→v2)
- 🔴 cost-cap env→**flock per-run+global** (был no-op: отдельные процессы).
- 🔴 +**adapter-contract.md** (envelope), не-keyword методы не через HARVEST_SCHEMA.
- 🔴 +**exit/degradation-семантика** (коды ошибок).
- 🕳 +**SSRF-guard** на onpage/ai-vis (reuse url-guard.sh).
- 🕳 +**netrc вместо `curl -u`** (фикс утечки в ps aux, в т.ч. в текущем методе).
- 🟡 кэш → `~/.cache/dataforseo/` + sha256-ключ + per-method TTL + project-slug-изоляция.
- 🟡 adapter-location развилка → **решение** (redsemantic by default).
- 🟡 +probe granularity (`--probe`, balance>0) + kill-switch (DFS_DISABLED/DFS_METHODS_ENABLED).
- 🟡 +бэк-компат/rollback (alias + v1-backup) + единый cost-log + fixture dry-run.
- 🟡 Phase 2 → 2a (adapter-add) + 2b (SERP-clustering, своя сессия); +PII-страйп Business Data (Phase 4).

## Статус реализации (2026-06-03) — ВСЕ ФАЗЫ ЗАКРЫТЫ

- **Phase 0** ✅ аккаунт DataForSEO активирован (verified+funded $51); `--probe` honest (auth+funded+data-ping).
- **Phase 1** ✅ multi-method adapter: envelope, cost-cap (mkdir-lock per-run count+$ / daily hard), кэш (sha256+TTL+PII slug-изоляция), netrc (нет кредов в ps aux), SSRF+injection guard, exit-семантика (incl. task-level status), fixtures. Tests: dataforseo-test (envelope/cap-atomic/injection/ssrf/geo/Phase4) + smoke + dryrun.
- **Phase 2-geo** ✅ `--geo-check`; RU/РБ keyword/SERP → `geo_unsupported` без траты → Wordstat; intl → DataForSEO. URL/domain (onpage/tech) geo-независимы.
- **Phase 2a** ✅ redsemantic harvest region-aware (scoper geo-check → dfs_location; intl harvest'ит `overview`).
- **Phase 2b** ✅ SERP-overlap кластеризация (intl + mode≥standard): serp-enrich → overlap-пары → clusterer.
- **Phase 3** ✅ audit-site Block G «On-Page (DataForSEO)» — opt-in/paid, geo-независим (RU-сайты ок).
- **Phase 4** ✅ adapter `tech` (Domain Analytics, geo-независим) + `business` (Maps SERP, geo-guarded); redresearch source-hunter — опц. SERP-discovery/tech/business для competitor/market/local-research.
- **Phase 4 anthropic-skills:seo** — ⏭️ skill plugin-managed (не правим, потеряется при апдейте плагина). Адаптер `dataforseo.sh` доступен ей по абсолютному пути — может звать `onpage`/`tech` при желании. Кода не добавляем.
- **Phase 5 domain-check** — ⏭️ остаётся на RDAP (бесплатно/быстро). DataForSEO Domain Analytics здесь negative-value (платно, медленнее, без выигрыша для проверки свободности). При желании пользователь вручную зовёт `dataforseo.sh tech <занятый-домен>` для тех-стека. Кода не добавляем.

Итог: DataForSEO интегрирован во все профильные скиллы с автодетектом РФ/intl. Adapter — единый слой (`redsemantic/lib/adapters/dataforseo.sh`), потребители зовут по абсолютному пути.

## Источники прайсинга
- https://dataforseo.com/pricing , .../pricing/dataforseo-labs/dataforseo-google-api , .../apis/serp-api/pricing
- https://costbench.com/software/seo-tools/dataforseo/ , https://nextgrowth.ai/dataforseo-api-guide/

// redsemantic — Semantic Intelligence orchestrator (Workflow tool script).
//
// «SEO-мозг»: из бизнес-ядра (+research/positioning) строит Keyword Universe →
// Intent/Content Clusters → структуру сайта → SEO-страницы/блог/FAQ → entities →
// internal linking map. Семантика ДИКТУЕТ структуру (вход для redloft sitemap).
//
// Зеркалит ~/.claude/skills/redresearch/workflow/research.js (scope→hunt→read→
// synth→judge). Поток: scope → seed → harvest → cluster → structure → judge.
//
// ⚠️ Workflow-скрипты НЕ имеют Bash/FS. Адаптеры (lib/adapters/*.sh) запускают
// АГЕНТЫ через свой Bash-тул (как source-hunter дёргает firecrawl). Оркестратор
// дирижирует агентами и собирает артефакты; писать на диск будет caller.
//
// Args (object | JSON-string):
//   topic        — бизнес-ядро («банный комплекс Москва») [standalone] ИЛИ берётся из brief
//   region       — гео («Москва» / код 213); lang — 'ru' по умолчанию
//   mode         — 'lite' | 'standard' | 'heavy'
//   site_type    — landing|corporate|ecommerce|... (из brief в redloft)
//   brief        — { key_claims:[…] } из redloft briefing (опц.)
//   research     — { key_claims:[…] } из redloft research-стадии (опц.)
//   planning     — { key_claims:[…] } ICP/JTBD/USP из redloft planning (опц.)
//   available_adapters — [] список живых адаптеров (caller прогнал probe.sh; иначе scoper)
//   run_id, timestamp, slug, git_rev — correlation/meta
//
// Возвращает: { artifacts:{relpath:content}, key_claims, verdict, coverage, … }.

export const meta = {
  name: 'redsemantic',
  description: 'Semantic Intelligence: scope→seed→harvest(Wordstat/Suggest/DataForSEO/GSC)→cluster(intent+content)→structure→judge. Семантика диктует структуру сайта.',
  phases: [
    { title: 'Scope',     detail: 'регион/язык/site_type/seed + probe живых адаптеров' },
    { title: 'Recon',     detail: 'existing-site: фетч sitemap/контента (реальные routes+offerings) через url-guard' },
    { title: 'Seed',      detail: 'базовые маски запросов из ядра+research (existing: verify offerings)' },
    { title: 'Harvest',   detail: 'агенты дёргают адаптеры (parallel) → keyword universe' },
    { title: 'Cluster',   detail: 'intent-классификация + семантическая кластеризация' },
    { title: 'Structure', detail: 'кластеры→структура+SEO-страницы+блог+FAQ+entities+linking' },
    { title: 'Judge',     detail: 'coverage vs JTBD/USP; чистота кластеров; verdict' },
  ],
}

// ───────────────────────── args ─────────────────────────
let A = args
if (typeof args === 'string') { try { A = JSON.parse(args) } catch { A = { topic: args } } }
const topic      = A?.topic || 'NO_TOPIC_PROVIDED'
const region     = A?.region || 'Москва'
const lang       = A?.lang || 'ru'
const mode       = ['lite', 'standard', 'heavy'].includes(A?.mode) ? A.mode : 'lite'
const siteType   = A?.site_type || 'landing'
const runId      = A?.run_id || 'unknown-run-id'
const timestamp  = A?.timestamp || 'unknown'
const gitRev     = A?.git_rev || 'unknown'
const slug       = A?.slug || 'semantic'
const brief      = (A?.brief && typeof A.brief === 'object') ? A.brief : {}
const research   = (A?.research && typeof A.research === 'object') ? A.research : {}
const planning   = (A?.planning && typeof A.planning === 'object') ? A.planning : {}
const callerAdapters = Array.isArray(A?.available_adapters) ? A.available_adapters : null
const siteUrl       = (typeof A?.site_url === 'string' && /^https?:\/\//.test(A.site_url)) ? A.site_url : ''
const existingSite  = !!siteUrl
const adapterStatus = (A?.adapter_status && typeof A.adapter_status === 'object') ? A.adapter_status : null  // smoke-вывод probe (R1)

const SKILL = '~/.claude/skills/redsemantic'
const PROBE = `${SKILL}/lib/adapters`

const briefClaims    = Array.isArray(brief.key_claims) ? brief.key_claims : []
const researchClaims = Array.isArray(research.key_claims) ? research.key_claims : []
const planningClaims = Array.isArray(planning.key_claims) ? planning.key_claims : []

log(`redsemantic · slug=${slug} · mode=${mode} · region=${region} · site_type=${siteType} · run_id=${runId}`)
if (topic === 'NO_TOPIC_PROVIDED' && !briefClaims.length) log('⚠️  ни topic, ни brief.key_claims не переданы')

// ───────────────────────── budgets ─────────────────────────
const SEED_BUDGET    = { lite: 6, standard: 14, heavy: 30 }[mode]
const SUGGEST_EXPAND = { lite: false, standard: false, heavy: true }[mode]  // a-z хвост в heavy
const MIN_KEYWORDS   = { lite: 20, standard: 60, heavy: 120 }[mode]
// FABLE: Fable 5 ещё не доступен в API → предсказуемый фоллбэк на opus (judge/cluster/
// structure модель до миграции). Единственная точка переключения — вернуть 'fable' когда выкатят.
const FABLE = 'opus'  // ← 'fable' когда модель появится
const modelFor = (role) => {
  if (mode === 'lite') return role === 'judge' ? 'sonnet' : 'haiku'
  if (mode === 'heavy') return (role === 'cluster' || role === 'structure' || role === 'judge') ? FABLE : 'sonnet'
  return role === 'judge' ? FABLE : 'sonnet'   // standard
}

// ───────────────────────── schemas ─────────────────────────
const SCOPER_SCHEMA = {
  type: 'object', required: ['region_code', 'lang', 'business_core', 'available_adapters', 'confidence'],
  additionalProperties: true,
  properties: {
    region_code: { type: 'string' },          // Wordstat region id, напр. "213" (Москва)
    lang: { type: 'string' },
    business_core: { type: 'string' },         // нормализованное ядро
    site_type: { type: 'string' },
    available_adapters: { type: 'array', items: { type: 'string' } },
    dfs_location: { type: 'string' },           // DataForSEO location_name (intl); "" если RU/недоступно
    niche_anchors: { type: 'array', items: { type: 'string' }, default: [] },   // relevance-gate: «своё» для ниши
    negative_roots: { type: 'array', items: { type: 'string' }, default: [] },  // relevance-gate: смежные вертикали/омонимы (дроп)
    confidence: { type: 'number', minimum: 0, maximum: 1 },
    notes: { type: 'string' },
  },
}
const SEED_SCHEMA = {
  type: 'object', required: ['seeds'], additionalProperties: true,
  properties: {
    seeds: { type: 'array', minItems: 1, items: {
      type: 'object', required: ['phrase'], properties: {
        phrase: { type: 'string' }, rationale: { type: 'string' },
      },
    } },
    off_offering: { type: 'array', items: { type: 'string' }, default: [] },  // existing-site: темы НЕ из реального предложения
  },
}
const HARVEST_SCHEMA = {
  type: 'object', required: ['source', 'keywords'], additionalProperties: true,
  properties: {
    source: { type: 'string' },
    degraded: { type: 'boolean' },
    keyword_count: { type: 'number' },
    keywords: { type: 'array', items: {
      type: 'object', required: ['phrase'], properties: {
        phrase: { type: 'string' }, freq: { type: 'number' },
        intent: { type: ['string', 'null'] }, source: { type: 'string' },
      },
    } },
  },
}
const CLUSTER_SCHEMA = {
  type: 'object', required: ['intent_clusters', 'content_clusters'], additionalProperties: true,
  properties: {
    intent_clusters: { type: 'array', items: {
      type: 'object', required: ['name', 'intent', 'keywords'], properties: {
        name: { type: 'string' },
        intent: { enum: ['commercial', 'informational', 'branded', 'navigational', 'service'] },
        head_term: { type: 'string' }, total_freq: { type: 'number' },
        keywords: { type: 'array', items: { type: 'string' } },
      },
    } },
    content_clusters: { type: 'array', items: {
      type: 'object', required: ['name', 'page_type', 'keywords'], properties: {
        name: { type: 'string' }, page_type: { type: 'string' },
        primary_kw: { type: 'string' },
        keywords: { type: 'array', items: { type: 'string' } },
      },
    } },
    orphan_keywords: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' },
  },
}
const STRUCTURE_SCHEMA = {
  type: 'object', required: ['structure', 'key_claims', 'body_md'], additionalProperties: true,
  properties: {
    structure: { type: 'array', items: {
      type: 'object', required: ['node', 'intent'], properties: {
        node: { type: 'string' }, purpose: { type: 'string' },
        intent: { type: 'string' }, primary_cluster: { type: 'string' },
        h1: { type: 'string' }, h2: { type: 'array', items: { type: 'string' } },
        node_status: { enum: ['existing', 'new'] },   // existing-site: маршрут есть vs предлагается
      },
    } },
    seo_pages: { type: 'array', items: { type: 'object' } },
    blog_topics: { type: 'array', items: { type: 'object' } },
    faq: { type: 'array', items: { type: 'object' } },
    entities: { type: 'array', items: { type: 'object' } },
    linking_map: { type: 'array', items: { type: 'object' } },
    key_claims: { type: 'array', items: { type: 'string' }, minItems: 1, maxItems: 7 },
    body_md: { type: 'string' },
  },
}
const JUDGE_SCHEMA = {
  type: 'object', required: ['verdict', 'confidence', 'coverage'], additionalProperties: true,
  properties: {
    verdict: { enum: ['PASS', 'NEEDS-WORK', 'FAIL'] },
    confidence: { type: 'number', minimum: 0, maximum: 1 },
    coverage: { type: 'number', minimum: 0, maximum: 1 },   // покрытие JTBD/USP семантикой
    gaps: { type: 'array', items: { type: 'string' } },
    cluster_quality: { type: 'string' },
    summary: { type: 'string' },
  },
}

const roleRef = (name) =>
  `Прочитай role-spec ${SKILL}/roles/${name}.md и следуй ему пунктуально. ` +
  `Если файл недоступен — следуй inline-инструкции ниже. `

// YAML front-matter для semantic.md (контракт redloft _shared.md §3).
function artifactHeader(keyClaims) {
  const claims = (keyClaims && keyClaims.length ? keyClaims : ['(none)'])
    .slice(0, 7).map(c => '  - ' + JSON.stringify(String(c))).join('\n')
  return ['---', 'artifact_type: semantic', 'stage_id: semantic', 'schema_version: 1',
    `produced_at: ${timestamp}`, 'source_stage: planning', 'key_claims:', claims, '---'].join('\n')
}

function ctxBlock() {
  return (
    `=== БИЗНЕС-ЯДРО ===\n${topic}\n` +
    (briefClaims.length ? `=== BRIEF (key_claims) ===\n${briefClaims.join('\n')}\n` : '') +
    (researchClaims.length ? `=== RESEARCH (key_claims) ===\n${researchClaims.join('\n')}\n` : '') +
    (planningClaims.length ? `=== PLANNING ICP/JTBD/USP (key_claims) ===\n${planningClaims.join('\n')}\n` : '') +
    `=== ГЕО/ЯЗЫК ===\nregion=${region} lang=${lang} site_type=${siteType}\n=== END ===\n`
  )
}

// ═══════════════════════ PIPELINE ═══════════════════════

// Phase 0 — SCOPE (+ probe адаптеров)
phase('Scope')
const scoper = await agent(
  `Ты — scoper стадии REDSEMANTIC. ${roleRef('scoper')}\n` +
  `Определи: region_code (id региона Wordstat: Москва=213, СПб=2, Россия=225), lang, нормализованное business_core, site_type.\n` +
  (callerAdapters
    ? `Доступные адаптеры УЖЕ определены caller-ом: ${JSON.stringify(callerAdapters)}. Верни их в available_adapters.\n`
    : `Узнай живые источники: выполни \`bash ${PROBE}/probe.sh --names\` через Bash и верни их список в available_adapters (suggest есть всегда).\n`) +
  `RELEVANCE-CONFIG (для фильтра шума): из business_core выведи niche_anchors[] и negative_roots[]. ВАЖНО: это ПРОСТЫЕ ПОДСТРОКИ-основы для substring-матча (НЕ regex!). ` +
  `niche_anchors — основы «своего» (баня: банн,баня,банька,сауна,спа,терм,парил,веник,хамам,wellness,парная). negative_roots — основы смежных вертикалей/ОМОНИМОВ для отброса (баня: банк,банкинг,сбербанк,кредит,гостиниц,отел,hotel,коворкинг,вакансии,бревна,бренеран). ` +
  `Правила: НЕ клади голый «бан» в анкеры (как подстрока ловит «банк»!) — клади конкретные формы (банн/баня/банька); омоним-сосед (банк↔баня) ОБЯЗАН быть в negative_roots. Работает для ЛЮБОЙ ниши (стоматология: зуб,имплант,брекет / фитнес: фитнес,тренаж,абонемент).\n` +
  `ГЕО-РОУТИНГ DataForSEO: у него НЕТ данных по РФ/РБ (Google Ads-санкции), есть по остальному миру. ` +
  `Если в available_adapters есть "dataforseo" — выполни \`bash ${PROBE}/dataforseo.sh --geo-check "<регион проекта>"\` через Bash. ` +
  `Если supported_keyword=true — верни dfs_location = location_name DataForSEO для проекта (напр. "United States","Germany","Kazakhstan"). ` +
  `Если false (РФ/РБ) — УБЕРИ "dataforseo" из available_adapters (keyword-данные возьмёт wordstat) и оставь dfs_location="".\n` +
  ctxBlock() +
  `Верни JSON по SCOPER_SCHEMA (incl. dfs_location).`,
  { label: 'scoper', phase: 'Scope', model: modelFor('scoper'), schema: SCOPER_SCHEMA }
)
const regionCode = scoper?.region_code || '213'
const dfsLocation = scoper?.dfs_location || ''
let adapters = (callerAdapters || scoper?.available_adapters || ['suggest']).filter(Boolean)
// гео-гейт (защита от ошибки scoper): нет dfs_location → DataForSEO keyword недоступен → дроп
if (!dfsLocation && adapters.includes('dataforseo')) {
  adapters = adapters.filter(a => a !== 'dataforseo')
  log('scope: dataforseo исключён из keyword-harvest (РФ/нет dfs_location) → wordstat')
}
const businessCore = scoper?.business_core || topic
log(`scope: region=${regionCode} core="${businessCore}" dfs_location="${dfsLocation || '(RU/none)'}" adapters=[${adapters.join(', ')}] existing_site=${existingSite}`)

// ── R2: громкий GSC-warning (existing-site) — если probe-smoke сказал returns_data:false ──
let topWarnings = []
if (existingSite && adapterStatus?.['search-console'] && adapterStatus['search-console'].returns_data === false) {
  topWarnings.push(`⚠️ **Search Console недоступен** (${adapterStatus['search-console'].reason || 'property не привязана'}). Для existing-site это САМЫЙ ценный источник (реальные запросы из выдачи). Привяжи property сайта к OAuth-аккаунту в search.google.com → перезапусти. Сейчас семантика без GSC-данных.`)
  log(`⚠️  GSC недоступен для existing-site → warning наверху отчёта`)
}

// ── R-mode (existing-site): RECON — фетч sitemap/контента сайта (агент, через vendored url-guard SSRF) ──
const RECON_SCHEMA = {
  type: 'object', additionalProperties: true,
  properties: {
    routes: { type: 'array', items: { type: 'object', properties: { path: { type: 'string' }, template: { type: 'string' } } } },
    offerings: { type: 'array', items: { type: 'string' } },   // реальные услуги/темы с сайта
    content_model: { type: 'string' },                         // напр. «статьи=Supabase-строки, не произвольные URL»
    notes: { type: 'string' },
  },
}
let recon = null
if (existingSite) {
  phase('Recon')
  recon = await agent(
    `Ты — site-recon стадии REDSEMANTIC (existing-site). ${roleRef('recon')}\n` +
    `Сайт: ${siteUrl}. ЗАДАЧА: узнать РЕАЛЬНУЮ структуру и предложение.\n` +
    `1) Провалидируй URL: \`bash ${SKILL}/lib/url-guard.sh "${siteUrl}/sitemap.xml"\` (SSRF). Только при OK — фетчи.\n` +
    `2) Фетч sitemap (curl, ≤500 URL) → routes[] (path + угаданный template по path-префиксу). 3) Фетч 3-6 sample-страниц (тоже через url-guard) → offerings[] (реальные услуги/темы, что бизнес ДЕЙСТВИТЕЛЬНО предлагает) + content_model (как устроен контент: статьи/категории/маршруты).\n` +
    `🔒 Каждый фетчимый URL — СНАЧАЛА через url-guard (BLOCKED → пропусти). Без curl -v. Не выдумывай — только реально загруженное.\n` +
    `Верни JSON по RECON_SCHEMA.`,
    { label: 'site-recon', phase: 'Recon', model: modelFor('harvest'), schema: RECON_SCHEMA }
  )
  log(`recon: ${(recon?.routes || []).length} маршрутов, ${(recon?.offerings || []).length} реальных offerings`)
}
const reconOfferings = (recon?.offerings || []).filter(Boolean)
const reconRoutes = (recon?.routes || []).filter(Boolean)

// Phase 1 — SEED
phase('Seed')
const seedOut = await agent(
  `Ты — seed-генератор стадии REDSEMANTIC. ${roleRef('seed')}\n` +
  `Из business_core + research/planning составь до ${SEED_BUDGET} seed-фраз (маски запросов): ` +
  `базовые коммерческие, сервисные, гео-варианты, синонимы ниши. Без мусора и брендов конкурентов.\n` +
  (existingSite && reconOfferings.length
    ? `EXISTING-SITE — РЕАЛЬНЫЕ offerings сайта: ${reconOfferings.join(', ')}. Сей ТОЛЬКО то, что бизнес реально предлагает. Если тема НЕ в offerings — НЕ сей её; перечисли такие в off_offering[] (флаг «засеял X, но на сайте X нет»).\n`
    : '') +
  `business_core: ${businessCore}\nregion: ${region}\n` + ctxBlock() +
  `Верни JSON по SEED_SCHEMA (seeds[].phrase${existingSite ? ', off_offering[]' : ''}).`,
  { label: 'seed', phase: 'Seed', model: modelFor('seed'), schema: SEED_SCHEMA }
)
const offOffering = (seedOut?.off_offering || []).filter(Boolean)
if (offOffering.length) { topWarnings.push(`ℹ️ Off-offering seed-темы (на сайте отсутствуют, исключены): ${offOffering.join(', ')}`); log(`recon: off-offering отсеяно: ${offOffering.join(', ')}`) }
const seeds = (seedOut?.seeds || []).map(s => s.phrase).filter(Boolean).slice(0, SEED_BUDGET)
log(`seed: ${seeds.length} фраз`)

// Phase 2 — HARVEST (агент на адаптер, parallel; каждый дёргает свой bash-скрипт)
phase('Harvest')
const seedArg = seeds.map(s => JSON.stringify(s)).join(' ')
const adapterCmd = {
  suggest: (s) => `bash ${PROBE}/suggest.sh ${JSON.stringify(s)} --engine both --lang ${lang}${SUGGEST_EXPAND ? ' --expand' : ''}`,
  wordstat: (s) => `bash ${PROBE}/wordstat.sh ${JSON.stringify(s)} --region ${regionCode} --num 50`,
  dataforseo: (s) => `DFS_LOCATION=${JSON.stringify(dfsLocation || 'United States')} DFS_PROJECT_SLUG=${JSON.stringify(slug)} DFS_RUN_ID=${JSON.stringify('rs-' + slug)} bash ${PROBE}/dataforseo.sh overview ${JSON.stringify(s)}`,
  'search-console': (s) => `bash ${PROBE}/search-console.sh ${JSON.stringify(s)} --days 90`,
}
const harvestResults = await parallel(adapters.map(ad => () =>
  agent(
    `Ты — harvester стадии REDSEMANTIC для источника «${ad}». ${roleRef('harvester')}\n` +
    `Для КАЖДОЙ seed-фразы выполни адаптер через Bash и собери результаты. Команда-шаблон (подставь фразу):\n` +
    `  ${adapterCmd[ad] ? adapterCmd[ad]('<SEED>') : `bash ${PROBE}/${ad}.sh <SEED>`}\n` +
    `Seeds: ${seedArg || JSON.stringify(businessCore)}\n` +
    `Объедини keywords со всех seed, дедуп по нормализованной фразе (lowercase, схлопни пробелы). ` +
    `Если адаптер вернул error/пусто — degraded=true, верни что есть (НЕ выдумывай частотности).\n` +
    `Верни JSON по HARVEST_SCHEMA (source="${ad}").`,
    { label: `harvest:${ad}`, phase: 'Harvest', model: modelFor('harvest'), schema: HARVEST_SCHEMA }
  ).then(r => ({ ...r, _adapter: ad })).catch(() => null)
))

// freq_source (R3): различаем «измерено» от «не измерено». ТОЛЬКО wordstat/dataforseo/gsc
// несут числовую частотность (incl измеренный 0). suggest/model → freq=null (не измерено) —
// иначе потребитель читает живые suggest-формулировки как нулевой спрос.
const SEMANTIC_SCHEMA_VERSION = 2
const _freqSrc = (src) => { const s = String(src || '').toLowerCase(); if (s.includes('wordstat')) return 'wordstat'; if (s.includes('dataforseo')) return 'dataforseo'; if (s.includes('console') || s.includes('gsc')) return 'gsc'; if (s.includes('suggest')) return 'suggest'; return 'not_measured' }
const _measured = (fs) => fs === 'wordstat' || fs === 'dataforseo' || fs === 'gsc'

// Сводим universe; модель-доводка если живых частотностей мало (graceful degradation)
const rawHarvest = harvestResults.filter(Boolean)
const universe = []
const seen = new Set()
for (const h of rawHarvest) {
  for (const k of (h.keywords || [])) {
    const norm = String(k.phrase || '').toLowerCase().replace(/\s+/g, ' ').trim()
    if (!norm || seen.has(norm)) continue
    seen.add(norm)
    const fsrc = _freqSrc(k.source || h.source)
    const f = (_measured(fsrc) && typeof k.freq === 'number') ? k.freq : null  // suggest/model → null, не 0
    universe.push({ phrase: k.phrase, freq: f, freq_source: fsrc, source: k.source || h.source, intent: k.intent || null })
  }
}
const liveAdapters = rawHarvest.filter(h => !h.degraded && (h.keywords || []).length).map(h => h.source)
log(`harvest: ${universe.length} уникальных ключей из [${liveAdapters.join(', ') || 'none-live'}]`)

// ── RELEVANCE-GATE (детерминированный; defensive против кривого scoper-вывода) ──
// anchors/stops от scoper (per-niche, НЕ хардкод). Пустые анкеры → soft-режим
// (только universal-tech-стоп). Матч — String.includes по lowercase (не raw-regex
// от LLM, чтобы битый паттерн не ронял прогон). Порядок: normalize→dedupe(выше)→gate.
const _n = (s) => String(s || '').toLowerCase().replace(/\s+/g, ' ').trim()
const _arr = (x) => (Array.isArray(x) ? x : []).map(_n).filter(v => v.length >= 2)
const nicheAnchors = _arr(scoper?.niche_anchors)
const negativeRoots = _arr(scoper?.negative_roots)
const TECH_STOP = ['личный кабинет войти', 'официальный сайт войти', 'скачать', 'login', ' вход']  // universal, не нишевый
let gateSoft = nicheAnchors.length === 0
let sparseGate = false
function gateKey(phrase) {
  const p = _n(phrase)
  if (!p) return { keep: false, reason: 'empty' }
  if (TECH_STOP.some(s => p.includes(s))) return { keep: false, reason: 'tech_stop' }
  if (gateSoft) return { keep: true }
  const hitStop = negativeRoots.find(s => p.includes(s))
  if (hitStop) return { keep: false, reason: `matched_stop:${hitStop}` }
  return nicheAnchors.some(a => p.includes(a)) ? { keep: true } : { keep: false, reason: 'missed_anchor' }
}
const _applyGate = (arr) => { const kept = [], dropped = []; for (const k of arr) { const g = gateKey(k.phrase); if (g.keep) kept.push(k); else dropped.push({ phrase: k.phrase, freq: k.freq ?? null, source: k.source, drop_reason: g.reason }) } return { kept, dropped } }
let gatedOut = []
{
  const before = universe.length
  let g = _applyGate(universe)
  // sparse-guard: жёсткий gate выкинул почти всё (битые анкеры) → soft-fallback
  if (!gateSoft && before > 0 && (g.kept.length < Math.min(5, before) || g.kept.length < before * 0.10)) {
    sparseGate = true; gateSoft = true
    log(`⚠️  relevance-gate sparse (kept ${g.kept.length}/${before}) → soft-fallback (анкеры scoper, вероятно, битые)`)
    g = _applyGate(universe)
  }
  gatedOut = g.dropped
  universe.length = 0; universe.push(...g.kept)
  const byStop = g.dropped.filter(d => /^(matched_stop|tech_stop)/.test(d.drop_reason)).length
  const noAnchor = g.dropped.filter(d => d.drop_reason === 'missed_anchor').length
  log(`relevance-gate: kept ${g.kept.length}/${before} (${before ? Math.round(g.kept.length * 100 / before) : 0}% niche), dropped ${g.dropped.length} (by_stop=${byStop} no_anchor=${noAnchor})${gateSoft ? ' [soft]' : ''}`)
  if (before && !gateSoft && g.dropped.length > before * 0.5) log(`⚠️  relevance-gate drop-rate >50% — проверь niche_anchors scoper'а`)
}

let modelFilled = false
if (universe.length < MIN_KEYWORDS) {
  // живых данных мало → модель добивает (помечаем source=model). Выход ТОЖЕ через gate.
  const fill = await agent(
    `Ты — semantic-fill стадии REDSEMANTIC. Живых ключей мало (${universe.length}<${MIN_KEYWORDS}; адаптеры: [${adapters.join(', ')}]). ` +
    `Добей keyword universe из business_core + research/planning: реалистичные запросы по нише (коммерческие/инфо/сервисные/гео), СТРОГО в нише (без смежных вертикалей/омонимов). ` +
    `freq оставь null (нет живого источника — НЕ выдумывай числа), source="model".\n` +
    `Уже собрано (фразы): ${universe.slice(0, 60).map(k => k.phrase).join('; ')}\n` +
    `business_core: ${businessCore}\n` + ctxBlock() +
    `Верни JSON по HARVEST_SCHEMA (source="model").`,
    { label: 'semantic-fill', phase: 'Harvest', model: modelFor('harvest'), schema: HARVEST_SCHEMA }
  )
  let fillKept = 0
  for (const k of (fill?.keywords || [])) {
    const norm = _n(k.phrase)
    if (!norm || seen.has(norm)) continue
    seen.add(norm)
    const g = gateKey(k.phrase)
    if (g.keep) { universe.push({ phrase: k.phrase, freq: null, freq_source: 'not_measured', source: 'model', intent: k.intent || null }); modelFilled = true; fillKept++ }
    else gatedOut.push({ phrase: k.phrase, freq: null, freq_source: 'not_measured', source: 'model', drop_reason: g.reason })
  }
  log(`harvest: model-fill → +${fillKept} (после gate); universe=${universe.length}`)
}

const universeJsonl = universe.map(k => JSON.stringify(k)).join('\n')

// Phase 2b — SERP-OVERLAP enrichment (Phase 2b): только intl (dfs_location) + mode>=standard.
// Запросы с пересекающейся Google-выдачей = один content-кластер (SERP-сигнал точнее модели).
// Для РФ/lite — пропуск (DataForSEO SERP недоступен/дорого). Cost-capped.
const SERP_OVERLAP_SCHEMA = { type: 'object', required: ['map'], additionalProperties: true,
  properties: { map: { type: 'array', items: { type: 'object', required: ['keyword', 'urls'],
    properties: { keyword: { type: 'string' }, urls: { type: 'array', items: { type: 'string' } } } } } } }
let serpOverlapHints = ''
if (dfsLocation && mode !== 'lite') {
  phase('Cluster')
  const K = mode === 'heavy' ? 15 : 8
  const topTerms = [...universe].filter(k => typeof k.freq === 'number').sort((a, b) => (b.freq || 0) - (a.freq || 0)).slice(0, K).map(k => k.phrase)
  if (topTerms.length >= 2) {
    const enr = await agent(
      `Ты — serp-enrich стадии REDSEMANTIC (intl, location=${dfsLocation}). Для КАЖДОГО запроса выполни через Bash:\n` +
      `  DFS_LOCATION=${JSON.stringify(dfsLocation)} DFS_PROJECT_SLUG=${JSON.stringify(slug)} DFS_RUN_ID=${JSON.stringify('rs-' + slug)} bash ${PROBE}/dataforseo.sh serp "<запрос>"\n` +
      `Из ответа (.data.results) возьми топ-10 url. Если adapter вернул ok:false — пропусти запрос (не выдумывай url).\n` +
      `Запросы: ${topTerms.map(t => JSON.stringify(t)).join(' ')}\n` +
      `Верни JSON по SERP_OVERLAP_SCHEMA: map:[{keyword, urls:[...]}].`,
      { label: 'serp-enrich', phase: 'Cluster', model: modelFor('harvest'), schema: SERP_OVERLAP_SCHEMA }
    )
    const host = (u) => String(u).replace(/^https?:\/\//, '').split('/')[0].replace(/^www\./, '').toLowerCase()
    const m = (enr?.map || []).map(e => ({ kw: e.keyword, hosts: [...new Set((e.urls || []).map(host).filter(Boolean))] }))
    const pairs = []
    for (let i = 0; i < m.length; i++) for (let j = i + 1; j < m.length; j++) {
      const shared = m[i].hosts.filter(h => m[j].hosts.includes(h)).length
      if (shared >= 2) pairs.push(`${m[i].kw} ~ ${m[j].kw} (${shared} общих доменов в выдаче)`)
    }
    if (pairs.length) {
      serpOverlapHints = `\n=== SERP-OVERLAP HINTS (запросы с общей Google-выдачей → один content-кластер) ===\n${pairs.join('\n')}\n=== END ===\n`
      log(`serp-enrich: ${pairs.length} overlap-пар из ${m.length} запросов`)
    } else log(`serp-enrich: overlap-пар не найдено (${m.length} запросов)`)
  }
}

// Phase 3 — CLUSTER (intent + semantic; + SERP-overlap hints для intl)
phase('Cluster')
const universeForCluster = universe.slice(0, mode === 'lite' ? 150 : mode === 'standard' ? 400 : 800)
const clusters = await agent(
  `Ты — clusterer стадии REDSEMANTIC. ${roleRef('clusterer')}\n` +
  `Раздели keyword universe на INTENT-кластеры (commercial/informational/branded/navigational/service) и ` +
  `CONTENT-кластеры (1 кластер ≈ 1 будущая страница; page_type: коммерческая/услуга/категория/статья/FAQ). ` +
  `head_term = самый частотный/репрезентативный. Орфаны (без кластера) — в orphan_keywords.\n` +
  (serpOverlapHints ? `ПРИОРИТЕТ: если даны SERP-overlap hints — запросы с общей выдачей клади в ОДИН content-кластер (это сильнее лексической близости).\n` : '') +
  `Keyword universe (phrase|freq|source):\n` +
  universeForCluster.map(k => `${k.phrase} | ${k.freq ?? '—'} | ${k.source}`).join('\n') +
  `\n=== END ===\n` + serpOverlapHints + ctxBlock() +
  `Верни JSON по CLUSTER_SCHEMA.`,
  { label: 'clusterer', phase: 'Cluster', model: modelFor('cluster'), schema: CLUSTER_SCHEMA }
)
const intentClusters = clusters?.intent_clusters || []
const contentClusters = clusters?.content_clusters || []
log(`cluster: ${intentClusters.length} intent + ${contentClusters.length} content кластеров`)

// Phase 4 — STRUCTURE (семантика → структура + content plan + entities + linking)
phase('Structure')
const structure = await agent(
  `Ты — architect стадии REDSEMANTIC. ${roleRef('architect')}\n` +
  `Принцип: СЕМАНТИКА ДИКТУЕТ СТРУКТУРУ. Из content/intent-кластеров построй:\n` +
  `1) structure[] — узлы сайта (для landing — секции+якоря; иначе страницы), каждый ← привязан к primary_cluster + intent + H1/H2;\n` +
  `2) seo_pages[] — коммерческие/услуговые страницы под кластеры; 3) blog_topics[] — инфо-кластеры → темы статей;\n` +
  `4) faq[] — вопросные/инфо-запросы → FAQ; 5) entities[] — сущности для schema.org/GEO; 6) linking_map[] — внутренние связи (from→to, anchor).\n` +
  `Не плоди узлы без кластера. Site_type=${siteType}.\n` +
  (existingSite && reconRoutes.length
    ? `EXISTING-SITE — РЕАЛЬНЫЕ маршруты сайта (модель контента: ${recon?.content_model || 'см. recon'}):\n${reconRoutes.slice(0, 60).map(r => `${r.path}${r.template ? ' ['+r.template+']' : ''}`).join('\n')}\n` +
      `R5: каждый узел structure[] помечай node_status="existing" (есть такой маршрут/шаблон) или "new" (предлагается). НЕ выдумывай URL вне модели контента сайта (не предлагай /retreats/X, если статьи живут как Supabase-строки/иной шаблон). Рекомендации = улучшение реальных страниц + обоснованно новые.\n`
    : '') +
  `=== INTENT CLUSTERS ===\n${JSON.stringify(intentClusters).slice(0, 4000)}\n` +
  `=== CONTENT CLUSTERS ===\n${JSON.stringify(contentClusters).slice(0, 4000)}\n=== END ===\n` + ctxBlock() +
  `Верни JSON по STRUCTURE_SCHEMA: structure[]${existingSite ? ' (с node_status existing|new)' : ''}, seo_pages[], blog_topics[], faq[], entities[], linking_map[], ` +
  `key_claims (1-7: ядро/топ-кластеры/интент-микс/предложенная структура — для redloft reviewer и sitemap), body_md (человекочитаемый отчёт без YAML).`,
  { label: 'architect', phase: 'Structure', model: modelFor('structure'), schema: STRUCTURE_SCHEMA }
)

// Phase 5 — JUDGE (coverage vs JTBD/USP; чистота кластеров)
phase('Judge')
const judge = await agent(
  `Ты — judge стадии REDSEMANTIC. ${roleRef('judge')}\n` +
  `Проверь: (a) покрывает ли семантика JTBD/USP бизнеса (coverage 0-1); (b) чистоту кластеров (нет дублей/пересечений/мусора); ` +
  `(c) что частотности взяты из живых источников там, где они есть (не выдуманы). Помечай gaps.\n` +
  `Адаптеры живые: [${liveAdapters.join(', ') || 'none — model-only'}]${modelFilled ? ' (+model-fill)' : ''}.\n` +
  `=== KEY CLAIMS architect ===\n${(structure?.key_claims || []).join('\n')}\n` +
  `=== INTENT CLUSTERS (names/intent) ===\n${intentClusters.map(c => `${c.name} [${c.intent}] ${(c.keywords || []).length}kw`).join('\n')}\n` +
  `=== END ===\n` + ctxBlock() +
  `Верни JSON по JUDGE_SCHEMA.`,
  { label: 'judge', phase: 'Judge', model: modelFor('judge'), schema: JUDGE_SCHEMA }
)

// ═══ META-CRITIC — системный пробел ПРОЦЕССА семантики (не разовость по нише)? → ledger → solidify ═══
const CRITIC_SCHEMA = {
  type: 'object', required: ['methodology_findings'], additionalProperties: true,
  properties: { methodology_findings: { type: 'array', items: {
    type: 'object', required: ['role', 'lens_key', 'severity', 'observation', 'proposed_checklist_delta'], additionalProperties: true,
    properties: {
      role: { type: 'string', minLength: 1 }, lens_key: { type: 'string', minLength: 1 },
      severity: { enum: ['critical', 'warning', 'suggestion'] },
      observation: { type: 'string', minLength: 1 }, proposed_checklist_delta: { type: 'string', minLength: 1 },
    },
  } } },
}
const critic = await agent(
  `Ты — methodology-critic для redsemantic. НЕ оценивай это ядро по содержанию. Единственная задача: по gaps/coverage судьи понять, не вскрылся ли СИСТЕМНЫЙ пробел в НАШЕМ ПРОЦЕССЕ (стадия/протокол, который должен срабатывать для ЛЮБОЙ ниши), а не разовость по этой нише.\n` +
  `Примеры: «harvest не тянет частотность из источника X», «cluster не отделяет интенты Y», «structure не покрывает JTBD-класс Z».\n` +
  `Для каждого: { role (стадия: scoper|seed|harvest|cluster|structure|judge), lens_key (стабильный kebab-слаг), severity, observation, proposed_checklist_delta (одна фраза) }. Нет системных пробелов → []. НЕ выдумывай.\n\n` +
  `=== JUDGE ===\n${JSON.stringify({ verdict: judge?.verdict, coverage: judge?.coverage, gaps: judge?.gaps || [] }, null, 2)}\n` +
  `=== LIVE ADAPTERS ===\n${liveAdapters.join(', ') || 'model-only'}${modelFilled ? ' (+model-fill)' : ''}\n=== END ===\n\nВерни JSON по схеме.`,
  { label: 'meta-critic', phase: 'Judge', model: 'sonnet', schema: CRITIC_SCHEMA }
)
const methodologyFindings = (critic && Array.isArray(critic.methodology_findings)) ? critic.methodology_findings : []
if (methodologyFindings.length) log(`🧠 meta-critic: ${methodologyFindings.length} системных пробелов процесса → ledger`)
const learningsEntry = {
  ts: timestamp, skill: 'redsemantic', run_id: runId, mode,
  verdict: judge?.verdict || 'NEEDS-WORK', confidence: judge?.confidence ?? 0, coverage: judge?.coverage ?? 0,
  gaps: (judge?.gaps || []).map(g => typeof g === 'string' ? g : (g.area || g.gap || '')).filter(Boolean),
  methodology_findings: methodologyFindings,
}

// ───────────────────────── assemble artifacts ─────────────────────────
const keyClaims = (structure?.key_claims && structure.key_claims.length)
  ? structure.key_claims
  : [`${intentClusters.length} intent + ${contentClusters.length} content кластеров`, `ядро: ${businessCore}`]

const warnBlock = topWarnings.length ? `## ⚠️ Предупреждения\n${topWarnings.map(w => `- ${w}`).join('\n')}\n\n` : ''
const bodyMd = warnBlock +
  (structure?.body_md || '# Семантическое ядро\n(architect не вернул тело)') +
  `\n\n---\n_Источники: [${liveAdapters.join(', ') || 'model-only'}]${modelFilled ? ' + model-fill' : ''}${existingSite ? ' · existing-site' : ''} · ` +
  `${universe.length} ключей · ${intentClusters.length}+${contentClusters.length} кластеров · ` +
  `verdict ${judge?.verdict || '—'} (coverage ${judge?.coverage ?? '—'})_\n`

// orphan_keywords = орфаны кластеризатора + всё, что выкинул relevance-gate (overwrite per-run, snapshot)
const gatedOrphans = gatedOut.map(g => ({ phrase: g.phrase, freq: g.freq ?? null, freq_source: g.freq_source || _freqSrc(g.source), source: g.source, drop_reason: g.drop_reason }))
const clustersJson = JSON.stringify({
  schema_version: SEMANTIC_SCHEMA_VERSION,
  intent_clusters: intentClusters, content_clusters: contentClusters,
  orphan_keywords: [...(clusters?.orphan_keywords || []), ...gatedOrphans],
  gate: { sparse_gate: sparseGate, soft: gateSoft, niche_anchors: nicheAnchors, negative_roots: negativeRoots, gated_out: gatedOut.length },
  summary: clusters?.summary || '',
}, null, 2)
const structureJson = JSON.stringify({ schema_version: SEMANTIC_SCHEMA_VERSION, structure: structure?.structure || [] }, null, 2)
const contentPlanJson = JSON.stringify({
  seo_pages: structure?.seo_pages || [], blog_topics: structure?.blog_topics || [], faq: structure?.faq || [],
}, null, 2)
const entitiesJson = JSON.stringify({ entities: structure?.entities || [] }, null, 2)
const linkingJson = JSON.stringify({ linking_map: structure?.linking_map || [] }, null, 2)

const artifacts = {
  'keyword_universe.jsonl': universeJsonl,
  'clusters.json': clustersJson,
  'structure.json': structureJson,
  'content_plan.json': contentPlanJson,
  'entities.json': entitiesJson,
  'linking_map.json': linkingJson,
  'semantic.md': `${artifactHeader(keyClaims)}\n\n${bodyMd}`,
  'scope.json': JSON.stringify(scoper || {}, null, 2),
  'learnings.entry.json': JSON.stringify(learningsEntry),
}

const degraded = !liveAdapters.length || universe.length < MIN_KEYWORDS
return {
  artifacts,
  // redloft-стадийный контракт:
  artifact_type: 'semantic',
  key_claims: keyClaims.slice(0, 7),
  body_md: bodyMd,
  summary: clusters?.summary || judge?.summary || '',
  // meta:
  run_id: runId, timestamp, slug, mode, region: regionCode, site_type: siteType,
  topic: businessCore,
  verdict: judge?.verdict || 'NEEDS-WORK',
  confidence: judge?.confidence ?? 0,
  coverage: judge?.coverage ?? 0,
  gaps: judge?.gaps || [],
  keyword_count: universe.length,
  intent_cluster_count: intentClusters.length,
  content_cluster_count: contentClusters.length,
  available_adapters: adapters,
  live_adapters: liveAdapters,
  existing_site: existingSite,
  site_url: siteUrl || null,
  recon: existingSite ? { routes: reconRoutes.length, offerings: reconOfferings, off_offering: offOffering, content_model: recon?.content_model || null } : null,
  warnings: topWarnings,
  model_filled: modelFilled,
  sparse_gate: sparseGate,
  gated_out: gatedOut.length,
  degraded,
  git_rev: gitRev,
  learnings_entry: learningsEntry,
}

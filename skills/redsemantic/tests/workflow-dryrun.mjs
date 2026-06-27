#!/usr/bin/env node
// redsemantic — hermetic dry-run for workflow/semantic.js. Wraps the orchestrator
// like the Workflow runtime (async fn + injected globals) with a CANNED agent() —
// real orchestration logic runs at ZERO token cost / no network. Asserts:
// artifact payload + paths, semantic artifact-header (redloft §3 contract),
// phase order, harvest fan-out over adapters, graceful model-fill, no-isolation
// context threading, judge verdict propagation.
//
// Run: node tests/workflow-dryrun.mjs  → DRYRUN OK / FAIL(n), exit 0/1.

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const __dir = dirname(fileURLToPath(import.meta.url))
const scriptPath = join(__dir, '..', 'workflow', 'semantic.js')
const src = readFileSync(scriptPath, 'utf8').replace(/^export\s+const\s+meta\b/m, 'const meta')

let FAILS = 0
const T = (cond, msg) => { console.log((cond ? '  ✓ ' : '  ✗ ') + msg); if (!cond) FAILS++ }

const EXPECTED_ARTIFACTS = [
  'keyword_universe.jsonl', 'clusters.json', 'structure.json', 'content_plan.json',
  'entities.json', 'linking_map.json', 'semantic.md', 'scope.json',
]

function cannedAgent(scoperAdapters, dfsLocation = '', extra = {}) {
  return async (prompt, opts = {}) => {
    const label = opts.label || ''
    if (label === 'scoper') return { region_code: '213', lang: 'ru', business_core: 'банный комплекс москва', site_type: 'landing', available_adapters: scoperAdapters, dfs_location: dfsLocation, niche_anchors: ('nicheAnchors' in extra ? extra.nicheAnchors : []), negative_roots: extra.negativeRoots || [], confidence: 0.9 }
    if (label === 'site-recon') return { routes: [{ path: '/library/article-1', template: 'article' }, { path: '/retreats/x', template: 'retreat' }], offerings: ['ретриты', 'медитация'], content_model: 'статьи = Supabase-строки, не произвольные URL', notes: 'fetched 2 templates' }
    if (label === 'seed') return /EXISTING-SITE/.test(prompt)
      ? { seeds: [{ phrase: 'ретрит баня' }], off_offering: ['холотропное дыхание', 'випассана'] }
      : { seeds: [{ phrase: 'баня москва' }, { phrase: 'банный комплекс москва' }] }
    if (label.startsWith('harvest:')) {
      const src = label.split(':')[1]
      if (extra.harvestKeywords) return { source: src, degraded: false, keyword_count: extra.harvestKeywords.length, keywords: extra.harvestKeywords }
      return { source: src, degraded: false, keyword_count: 2, keywords: [{ phrase: `${src} запрос 1`, freq: 100 }, { phrase: `${src} запрос 2`, freq: 50 }] }
    }
    if (label === 'semantic-fill') return { source: 'model', keywords: Array.from({ length: 30 }, (_, i) => ({ phrase: `модельный запрос ${i}`, freq: null })) }
    if (label === 'serp-enrich') return { map: [
      { keyword: 'suggest запрос 1', urls: ['https://a.com/x', 'https://b.com/y', 'https://c.com/z'] },
      { keyword: 'suggest запрос 2', urls: ['https://a.com/q', 'https://b.com/w', 'https://d.com/e'] },
    ] }  // a.com + b.com общие → overlap-пара
    if (label === 'clusterer') return {
      intent_clusters: [{ name: 'Коммерческие', intent: 'commercial', head_term: 'баня москва', total_freq: 150, keywords: ['баня москва'] }],
      content_clusters: [{ name: 'Главная', page_type: 'коммерческая', primary_kw: 'баня москва', keywords: ['баня москва'] }],
      orphan_keywords: [], summary: 'кластеры собраны',
    }
    if (label === 'architect') return {
      structure: [{ node: 'hero', purpose: 'атмосфера', intent: 'commercial', primary_cluster: 'Главная', h1: 'Баня в Москве', h2: ['Услуги'] }],
      seo_pages: [{ title: 'Аренда бани', primary_kw: 'снять баню' }], blog_topics: [{ title: 'Как париться' }],
      faq: [{ question: 'Сколько стоит?' }], entities: [{ name: 'хаммам', type: 'service' }],
      linking_map: [{ from: 'hero', to: 'Аренда бани', anchor: 'аренда' }],
      key_claims: ['CLAIM_core ядро', 'CLAIM_clusters топ-кластеры', 'CLAIM_structure структура'],
      body_md: 'тело архитектора: структура из кластеров',
    }
    if (label === 'judge') return { verdict: 'PASS', confidence: 0.85, coverage: 0.9, gaps: [], cluster_quality: 'clean', summary: 'покрытие ок' }
    return {}
  }
}

function runScenario({ argsObj, scoperAdapters, dfsLocation = '', ...extra }) {
  const calls = [], phases = [], logs = []
  const baseAgent = cannedAgent(scoperAdapters, dfsLocation, extra)
  const agent = async (prompt, opts = {}) => { calls.push({ label: opts.label || '', phase: opts.phase, prompt }); return baseAgent(prompt, opts) }
  const phase = (t) => phases.push(t)
  const log = (m) => logs.push(m)
  const parallel = (thunks) => Promise.all(thunks.map(t => t()))
  const pipeline = async () => []
  const budget = { total: null, spent: () => 0, remaining: () => Infinity }
  const make = new Function('args', 'agent', 'phase', 'log', 'parallel', 'pipeline', 'budget',
    `return (async () => {\n${src}\n})()`)
  return make(argsObj, agent, phase, log, parallel, pipeline, budget).then(result => ({ result, calls, phases, logs }))
}

const main = async () => {
  // ── Scenario 1: scoper-detected adapters, scarce harvest → model-fill ──
  console.log('── dry-run: scope→…→judge, scarce harvest triggers model-fill ──')
  const { result, calls, phases } = await runScenario({
    argsObj: { slug: 'banya', mode: 'lite', run_id: 'dryrun', timestamp: '2026-06-02T00:00:00Z',
      topic: 'банный комплекс Москва', region: 'Москва', site_type: 'landing',
      brief: { key_claims: ['Премиум баня на дровах'] }, planning: { key_claims: ['JTBD: снять баню на вечер'] } },
    scoperAdapters: ['suggest', 'wordstat'],
  })

  T(result && typeof result === 'object', 'orchestrator returns object')
  T(result.artifacts && typeof result.artifacts === 'object', 'returns artifacts map')
  for (const p of EXPECTED_ARTIFACTS) T(p in result.artifacts, `artifact present: ${p}`)

  T(result.artifacts['semantic.md'].startsWith('---\nartifact_type: semantic'),
    'semantic.md starts with YAML artifact-header (redloft §3)')
  T(/stage_id: semantic/.test(result.artifacts['semantic.md']), 'semantic.md header stage_id=semantic')
  T(result.artifact_type === 'semantic', 'returns artifact_type=semantic (redloft stage contract)')
  T(Array.isArray(result.key_claims) && result.key_claims.length >= 1 && result.key_claims.length <= 7, 'key_claims 1-7')
  T(result.key_claims.some(c => /CLAIM_core/.test(c)), 'key_claims come from architect')
  T(typeof result.body_md === 'string' && result.body_md.length > 0, 'body_md present')

  T(result.artifacts['keyword_universe.jsonl'].split('\n').filter(Boolean).length >= 20, 'keyword_universe.jsonl populated (≥20 after fill)')
  T(/intent_clusters/.test(result.artifacts['clusters.json']) && /content_clusters/.test(result.artifacts['clusters.json']), 'clusters.json has both cluster types')
  T(/seo_pages/.test(result.artifacts['content_plan.json']) && /faq/.test(result.artifacts['content_plan.json']), 'content_plan.json has seo_pages + faq')

  // phase order
  const idx = (t) => phases.indexOf(t)
  T(['Scope', 'Seed', 'Harvest', 'Cluster', 'Structure', 'Judge'].every((p, i, arr) => i === 0 || idx(arr[i - 1]) < idx(p)),
    'phase order Scope→Seed→Harvest→Cluster→Structure→Judge')

  // harvest fan-out over scoper-detected adapters
  T(calls.some(c => c.label === 'harvest:suggest') && calls.some(c => c.label === 'harvest:wordstat'),
    'harvest fans out over detected adapters (suggest + wordstat)')

  // graceful model-fill (4 live kw < MIN_KEYWORDS lite=20)
  T(calls.some(c => c.label === 'semantic-fill'), 'model-fill agent invoked when universe scarce')
  T(result.model_filled === true, 'result.model_filled=true')
  T(result.degraded === false, 'not degraded (live adapter + universe≥MIN after fill)')

  // no-isolation context threading
  const clustererCall = calls.find(c => c.label === 'clusterer')
  T(!!clustererCall && /суггест|wordstat|запрос/.test(clustererCall.prompt), 'clusterer prompt carries harvested universe')
  const seedCall = calls.find(c => c.label === 'seed')
  T(!!seedCall && /Премиум баня|JTBD/.test(seedCall.prompt), 'seed prompt threads brief/planning key_claims')
  const harvestCall = calls.find(c => c.label.startsWith('harvest:'))
  T(!!harvestCall && /roles\/harvester\.md/.test(harvestCall.prompt), 'harvester references roles/harvester.md (roleRef)')

  // judge verdict propagation
  T(result.verdict === 'PASS' && result.coverage === 0.9, 'judge verdict + coverage propagate to result')
  T(result.intent_cluster_count === 1 && result.content_cluster_count === 1, 'cluster counts surfaced')

  // ── Scenario 2: caller-provided adapters override scoper ──
  console.log('── dry-run: caller available_adapters=[suggest] only ──')
  const s2 = await runScenario({
    argsObj: { slug: 'x', mode: 'lite', topic: 'кофейня спб', available_adapters: ['suggest'] },
    scoperAdapters: ['suggest', 'wordstat', 'dataforseo'],
  })
  T(s2.calls.some(c => c.label === 'harvest:suggest'), 'caller adapter (suggest) harvested')
  T(!s2.calls.some(c => c.label === 'harvest:wordstat' || c.label === 'harvest:dataforseo'),
    'scoper adapters ignored when caller passed available_adapters')
  T(s2.result.available_adapters.length === 1 && s2.result.available_adapters[0] === 'suggest', 'result.available_adapters = caller list')

  // ── Scenario 3: RU project — scoper отдал dataforseo, но dfs_location="" → дроп ──
  console.log('── dry-run: geo-routing RU (dataforseo дропается, нет dfs_location) ──')
  const s3 = await runScenario({
    argsObj: { slug: 'banya', mode: 'lite', topic: 'банный комплекс Москва', region: 'Москва', planning: { key_claims: ['JTBD x'] } },
    scoperAdapters: ['suggest', 'wordstat', 'dataforseo'], dfsLocation: '',
  })
  T(!s3.calls.some(c => c.label === 'harvest:dataforseo'), 'RU: dataforseo НЕ харвестится (geo-gate drop)')
  T(s3.calls.some(c => c.label === 'harvest:wordstat'), 'RU: wordstat харвестится')
  T(s3.result.available_adapters && !s3.result.available_adapters.includes('dataforseo'), 'RU: result.available_adapters без dataforseo')

  // ── Scenario 4: intl project — dfs_location set → dataforseo overview харвестится ──
  console.log('── dry-run: geo-routing intl (dataforseo overview, dfs_location) ──')
  const s4 = await runScenario({
    argsObj: { slug: 'cafe-berlin', mode: 'lite', topic: 'coffee shop Berlin', region: 'Berlin' },
    scoperAdapters: ['suggest', 'dataforseo'], dfsLocation: 'Germany',
  })
  const dfsCall = s4.calls.find(c => c.label === 'harvest:dataforseo')
  T(!!dfsCall, 'intl: dataforseo харвестится')
  T(!!dfsCall && /dataforseo\.sh overview/.test(dfsCall.prompt), 'intl: dataforseo cmd = overview (не bare)')
  T(!!dfsCall && /DFS_LOCATION="Germany"/.test(dfsCall.prompt), 'intl: DFS_LOCATION=Germany проброшен')
  T(!!dfsCall && /DFS_PROJECT_SLUG/.test(dfsCall.prompt) && /DFS_RUN_ID/.test(dfsCall.prompt), 'intl: DFS_PROJECT_SLUG + DFS_RUN_ID (cost-cap/PII)')

  // ── Scenario 5: Phase 2b — intl + standard → SERP-overlap enrichment feeds clusterer ──
  console.log('── dry-run: Phase 2b SERP-overlap (intl + standard) ──')
  const s5 = await runScenario({
    argsObj: { slug: 'cafe-berlin', mode: 'standard', topic: 'coffee shop Berlin', region: 'Berlin' },
    scoperAdapters: ['suggest', 'dataforseo'], dfsLocation: 'Germany',
  })
  T(s5.calls.some(c => c.label === 'serp-enrich'), 'intl+standard: serp-enrich agent runs')
  const clCall = s5.calls.find(c => c.label === 'clusterer')
  T(!!clCall && /SERP-OVERLAP HINTS/.test(clCall.prompt), 'clusterer prompt carries SERP-overlap hints')
  T(!!clCall && /общих доменов/.test(clCall.prompt), 'overlap pair computed (a.com+b.com shared)')

  // ── Scenario 6: RU/lite → NO serp-enrich (gated off) ──
  console.log('── dry-run: RU/lite → no SERP-enrich (gate off) ──')
  const s6 = await runScenario({
    argsObj: { slug: 'banya', mode: 'lite', topic: 'банный комплекс Москва', region: 'Москва' },
    scoperAdapters: ['suggest', 'wordstat'], dfsLocation: '',
  })
  T(!s6.calls.some(c => c.label === 'serp-enrich'), 'RU/lite: serp-enrich NOT run (no dfs_location / lite)')

  // ── Scenario 7: RELEVANCE-GATE дропает банк/отель в orphans, баня остаётся ──
  console.log('── dry-run: relevance-gate (drop банк/гостиниц → orphans) ──')
  const banyaKw = Array.from({ length: 10 }, (_, i) => ({ phrase: `баня услуга ${i}`, freq: 100 + i }))
  const noiseKw = [{ phrase: 'сбербанк онлайн', freq: 9000 }, { phrase: 'забронировать гостиницу', freq: 32000 }, { phrase: 'интернет банкинг', freq: 1300 }]
  const s7 = await runScenario({
    argsObj: { slug: 'banya2', mode: 'lite', topic: 'банный комплекс Москва', region: 'Москва' },
    scoperAdapters: ['suggest', 'wordstat'], nicheAnchors: ['баня', 'банн'], negativeRoots: ['банк', 'гостиниц', 'банкинг'],
    harvestKeywords: [...banyaKw, ...noiseKw],
  })
  T(s7.result.sparse_gate === false, 'gate: не sparse (kept≥5)')
  T(s7.result.gated_out >= 3, `gate: ≥3 ключа выкинуто (gated_out=${s7.result.gated_out})`)
  T(/баня услуга/.test(s7.result.artifacts['keyword_universe.jsonl']), 'gate: баня-ключи в universe')
  T(!/сбербанк|забронировать гостиниц/.test(s7.result.artifacts['keyword_universe.jsonl']), 'gate: банк/отель НЕ в universe')
  T(/сбербанк/.test(s7.result.artifacts['clusters.json']) && /matched_stop/.test(s7.result.artifacts['clusters.json']), 'gate: банк в orphan_keywords с drop_reason=matched_stop')
  T(s7.logs.some(l => /relevance-gate/.test(l)), 'gate: лог relevance-gate присутствует')

  // ── Scenario 8: sparse-guard (анкеры не матчат → soft-fallback, universe не пуст) ──
  console.log('── dry-run: sparse-guard (битые анкеры → soft-fallback) ──')
  const s8 = await runScenario({
    argsObj: { slug: 'banya3', mode: 'lite', topic: 'баня', region: 'Москва' },
    scoperAdapters: ['suggest'], nicheAnchors: ['неткихтослов'], negativeRoots: [],
    harvestKeywords: banyaKw,
  })
  T(s8.result.sparse_gate === true, 'sparse: meta.sparse_gate=true')
  T(/баня услуга/.test(s8.result.artifacts['keyword_universe.jsonl']), 'sparse: universe НЕ обнулён (soft-fallback оставил ключи)')

  // ── Scenario 9: defensive — scoper niche_anchors=null → не падаем (gateSoft) ──
  console.log('── dry-run: defensive (niche_anchors=null → soft, no crash) ──')
  const s9 = await runScenario({
    argsObj: { slug: 'banya4', mode: 'lite', topic: 'баня', region: 'Москва' },
    scoperAdapters: ['suggest'], nicheAnchors: null, negativeRoots: ['банк'],
    harvestKeywords: banyaKw,
  })
  T(s9.result && typeof s9.result === 'object', 'defensive: null-анкеры не уронили прогон')
  T(/баня услуга/.test(s9.result.artifacts['keyword_universe.jsonl']), 'defensive: soft-режим оставил ключи')

  // ── Scenario 10: defensive matrix — [''] и спецсимвол-анкер не роняют (String.includes, не regex) ──
  console.log('── dry-run: defensive matrix ([\'\'] + спецсимвол) ──')
  const s10a = await runScenario({ argsObj: { slug: 'm1', mode: 'lite', topic: 'баня' }, scoperAdapters: ['suggest'], nicheAnchors: [''], harvestKeywords: banyaKw })
  T(s10a.result && /баня услуга/.test(s10a.result.artifacts['keyword_universe.jsonl']), "matrix: [''] → пустые отфильтрованы → soft, no crash")
  const s10b = await runScenario({ argsObj: { slug: 'm2', mode: 'lite', topic: 'баня' }, scoperAdapters: ['suggest'], nicheAnchors: ['$(', '.*['], harvestKeywords: banyaKw })
  T(s10b.result && typeof s10b.result === 'object', 'matrix: спецсимвол-анкер не уронил (includes, не regex-eval)')

  // ── Scenario 11: existing-site (R-mode: recon + verify-offerings + structure-vs-routes + GSC-warning) ──
  console.log('── dry-run: existing-site (recon/verify-offerings/GSC-warning) ──')
  const s11 = await runScenario({
    argsObj: { slug: 'samudro', mode: 'lite', topic: 'ретритный центр', region: 'Москва',
      site_url: 'https://samudro.com', adapter_status: { 'search-console': { credentialed: true, returns_data: false, reason: 'property не привязана к OAuth' } } },
    scoperAdapters: ['suggest', 'wordstat'], nicheAnchors: ['ретрит', 'медитац', 'баня'], negativeRoots: [],
    harvestKeywords: Array.from({ length: 8 }, (_, i) => ({ phrase: `ретрит услуга ${i}`, freq: 50 + i })),
  })
  T(s11.calls.some(c => c.label === 'site-recon'), 'existing-site: recon-агент запущен')
  T(s11.result.existing_site === true, 'result.existing_site=true')
  const reconCall = s11.calls.find(c => c.label === 'site-recon')
  T(!!reconCall && /url-guard\.sh/.test(reconCall.prompt), 'recon промпт требует url-guard (SSRF) перед фетчем')
  const seedCall11 = s11.calls.find(c => c.label === 'seed')
  T(!!seedCall11 && /РЕАЛЬНЫЕ offerings|ретриты/.test(seedCall11.prompt), 'seed получил реальные offerings (verify)')
  T((s11.result.warnings || []).some(w => /Search Console недоступен/.test(w)), 'R2: громкий GSC-warning в warnings')
  T((s11.result.warnings || []).some(w => /холотропное дыхание/.test(w)), 'R4: off-offering seed («холотропка») отфлагован')
  const archCall = s11.calls.find(c => c.label === 'architect')
  T(!!archCall && /node_status|РЕАЛЬНЫЕ маршруты/.test(archCall.prompt), 'R5: architect получил реальные маршруты + node_status')
  T(/⚠️ Предупреждения/.test(s11.result.artifacts['semantic.md']), 'warnings отрендерены наверху semantic.md')

  // ── Scenario 12: new-site (site_url отсутствует → recon НЕ запускается) ──
  const s12 = await runScenario({ argsObj: { slug: 'new1', mode: 'lite', topic: 'баня' }, scoperAdapters: ['suggest'] })
  T(!s12.calls.some(c => c.label === 'site-recon'), 'new-site: recon НЕ запускается (нет site_url)')
  T(s12.result.existing_site === false, 'new-site: existing_site=false')

  console.log('')
  if (FAILS === 0) { console.log('DRYRUN OK'); process.exit(0) }
  else { console.log(`DRYRUN FAIL (${FAILS})`); process.exit(1) }
}

main().catch(e => { console.error('DRYRUN ERROR:', e && e.stack || e); process.exit(1) })

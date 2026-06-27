#!/usr/bin/env node
// redloft Phase C — hermetic dry-run harness for workflow/landing-builder.js.
// Wraps the orchestrator exactly like the Workflow runtime (async fn + injected
// globals), but with a CANNED agent() — so the real orchestration logic runs with
// ZERO token cost and no network. Asserts structure: artifact payload + paths,
// artifact-header contract, "no-isolation" context threading, RLS deny-by-default
// guarantee (DR-7), phase order, and reviewer-gate escalation (DR-3, cap=2).
//
// Run: node tests/workflow-dryrun.mjs   → prints DRYRUN OK / FAIL(n), exit 0/1.

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const __dir = dirname(fileURLToPath(import.meta.url))
const scriptPath = join(__dir, '..', 'workflow', 'landing-builder.js')
// De-export meta so the body is valid inside a function wrapper (mirrors how the
// Workflow runtime hosts the script: top-level await + top-level return).
const src = readFileSync(scriptPath, 'utf8').replace(/^export\s+const\s+meta\b/m, 'const meta')

let FAILS = 0
const T = (cond, msg) => { console.log((cond ? '  ✓ ' : '  ✗ ') + msg); if (!cond) FAILS++ }

const STAGE_LABELS = ['research', 'planning', 'semantic', 'sitemap', 'seo', 'content', 'design']
const EXPECTED_ARTIFACTS = [
  'research/report.md', 'planning/planning.md', 'semantic/semantic.md', 'sitemap/sitemap.md', 'seo/seo.md',
  'content/content.md', 'design/design.md', 'tz.md', 'prompt.md',
  'reviews/R1.md', 'reviews/R2.md', 'reviews/R3.md',
]
// stage_headers carry the register_artifact INPUTS; schema_version/produced_at are
// stamped at registration time (and already present in each file's YAML header).
const REGISTER_FIELDS = ['artifact_type', 'stage_id', 'source_stage', 'key_claims', 'path']

function runScenario({ reviewVerdict, briefOverride, queryOverride }) {
  const calls = [], phases = [], logs = []
  const agent = async (prompt, opts = {}) => {
    const label = opts.label || ''
    calls.push({ label, phase: opts.phase, prompt })
    if (/^R[0-9]/.test(label)) {                       // reviewer gate, label like "R2#1"
      const gate = label.split('#')[0]
      const v = reviewVerdict(gate)
      return { verdict: v, confidence: 0.9, findings: v === 'PASS' ? [] : [{ severity: 'critical', stage: gate, issue: `${gate} synthetic finding` }] }
    }
    if (label === 'render') {
      // deliberately WITHOUT an RLS token — orchestrator must append it (DR-7).
      return { tz_md: 'ТЗ тело', prompt_md: 'Промт тело без security-токена', tz_key_claims: ['CLAIM_tz'], prompt_key_claims: ['CLAIM_prompt'], summary: 'render' }
    }
    return { artifact_type: label, key_claims: [`CLAIM_${label}`], body_md: `body ${label}`, summary: `sum ${label}` }
  }
  const phase = (t) => phases.push(t)
  const log = (m) => logs.push(m)
  const parallel = (thunks) => Promise.all(thunks.map(t => t()))
  const pipeline = async () => []
  const budget = { total: null, spent: () => 0, remaining: () => Infinity }
  const argsObj = {
    slug: 'banya', project_dir: '/tmp/redloft-dryrun', mode: 'lite', run_id: 'dryrun',
    timestamp: '2026-06-02T00:00:00Z', query: queryOverride || 'создай сайт для банного комплекса',
    brief: briefOverride || { key_claims: ['Премиум баня на дровах', 'Цель — заявки на аренду'], site_type: 'landing' },
  }
  const make = new Function('args', 'agent', 'phase', 'log', 'parallel', 'pipeline', 'budget',
    `return (async () => {\n${src}\n})()`)
  return make(argsObj, agent, phase, log, parallel, pipeline, budget).then(result => ({ result, calls, phases, logs }))
}

function startsWithHeader(content) {
  return content.startsWith('---\nartifact_type:')
}

const main = async () => {
  // ── Scenario 1: happy path (all gates PASS) ──
  console.log('── dry-run: happy path (R1/R2/R3 PASS) ──')
  const { result, calls, phases } = await runScenario({ reviewVerdict: () => 'PASS' })

  T(result && typeof result === 'object', 'orchestrator returns an object')
  T(result.artifacts && typeof result.artifacts === 'object', 'returns artifacts map')
  for (const p of EXPECTED_ARTIFACTS) T(p in result.artifacts, `artifact present: ${p}`)
  // every stage artifact carries a YAML header
  let hdrOk = true
  for (const p of ['research/report.md', 'planning/planning.md', 'semantic/semantic.md', 'sitemap/sitemap.md', 'seo/seo.md', 'content/content.md', 'design/design.md', 'tz.md', 'prompt.md', 'reviews/R1.md']) {
    if (!startsWithHeader(result.artifacts[p] || '')) { hdrOk = false; console.log('     no header: ' + p) }
  }
  T(hdrOk, 'all artifacts start with YAML artifact-header (_shared §3)')

  // DR-7: prompt.md carries the non-skippable RLS deny-by-default step even though
  // the canned render agent returned no security token.
  T(/RLS/.test(result.artifacts['prompt.md']) && /deny-by-default/i.test(result.artifacts['prompt.md']),
    'prompt.md guarantees RLS deny-by-default step (DR-7)')
  T(/Handoff/i.test(result.artifacts['tz.md']) && /ротир/i.test(result.artifacts['tz.md']),
    'tz.md guarantees handoff checklist with secret-rotation (DR-7)')
  T(/\/finalize/.test(result.artifacts['prompt.md']) && /audit-site/.test(result.artifacts['prompt.md']),
    'prompt.md guarantees post-build gate (finalize → audit-site)')
  // DR-8: prompt.md carries Step 0 (deploy methodology box); tz.md notes the box.
  T(/methodology\//.test(result.artifacts['prompt.md']) && /START-HERE/.test(result.artifacts['prompt.md']),
    'prompt.md guarantees Шаг 0 methodology box deploy (DR-8)')
  T(/Методология проекта/i.test(result.artifacts['tz.md']),
    'tz.md guarantees «Методология проекта» note (DR-8)')
  T(result.methodology_tier_hint === 1, 'return carries methodology_tier_hint (landing → 1)')

  // stage_headers shape (caller registers these via register_artifact)
  T(Array.isArray(result.stage_headers) && result.stage_headers.length >= EXPECTED_ARTIFACTS.length,
    `stage_headers array (${result.stage_headers?.length})`)
  let shOk = true
  for (const h of (result.stage_headers || [])) {
    for (const f of REGISTER_FIELDS) if (!(f in h)) shOk = false
    if (!Array.isArray(h.key_claims) || h.key_claims.length < 1 || h.key_claims.length > 7) shOk = false
  }
  T(shOk, 'every stage_header has register_artifact inputs (type/stage/source/claims/path, 1-7 claims)')

  // phase order: Research → … → Design → Render, gates interleaved
  const idx = (t) => phases.indexOf(t)
  T(idx('Research') >= 0 && idx('Research') < idx('Planning'), 'phase Research before Planning')
  T(idx('Planning') < idx('R1') && idx('R1') < idx('Semantic'), 'R1 between Planning and Semantic')
  T(idx('Semantic') < idx('Sitemap'), 'Semantic before Sitemap (семантика диктует структуру)')
  T(idx('SEO') < idx('R2') && idx('R2') < idx('Content'), 'R2 between SEO and Content')
  T(idx('Design') < idx('R3') && idx('R3') < idx('Render'), 'R3 between Design and Render')
  T(idx('Render') === Math.max(...phases.map(idx)), 'Render is the last phase')

  // "no isolation" (_shared §8): downstream prompts carry upstream key_claims
  const designCall = calls.find(c => c.label === 'design')
  T(!!designCall && designCall.prompt.includes('CLAIM_research') && designCall.prompt.includes('CLAIM_planning'),
    'design prompt threads prior stages context (CLAIM_research + CLAIM_planning)')
  const r1Call = calls.find(c => c.label.startsWith('R1'))
  T(!!r1Call && r1Call.prompt.includes('CLAIM_planning'), 'R1 prompt reads planning key_claims')
  const sitemapCall = calls.find(c => c.label === 'sitemap')
  T(!!sitemapCall && sitemapCall.prompt.includes('CLAIM_semantic'), 'sitemap prompt threads semantic clusters (семантика→структура)')
  const r2Call = calls.find(c => c.label.startsWith('R2'))
  T(!!r2Call && r2Call.prompt.includes('CLAIM_semantic'), 'R2 reviews semantic clusters as reference')
  const researchCall = calls.find(c => c.label === 'research')
  T(!!researchCall && researchCall.prompt.includes('Премиум баня'), 'research prompt carries brief key_claims')

  // DR-4: new stages instruct the sub-agent to read stages/<name>/prompt.md
  let specRefOk = true
  for (const s of ['planning', 'semantic', 'sitemap', 'content', 'design']) {
    const c = calls.find(x => x.label === s)
    if (!c || !c.prompt.includes(`stages/${s}/prompt.md`)) { specRefOk = false; console.log('     missing spec-ref: ' + s) }
  }
  T(specRefOk, 'new stages reference stages/<name>/prompt.md (DR-4)')
  T(!!researchCall && !researchCall.prompt.includes('stages/research/prompt.md'), 'research uses redresearch (no stage-spec)')

  // E1: reviewer gates read the reviewer spec
  const gateCall = calls.find(c => /^R[0-9]/.test(c.label))
  T(!!gateCall && gateCall.prompt.includes('stages/reviewer/prompt.md'), 'reviewer gate reads stages/reviewer/prompt.md (E1)')

  // reviews + verdict
  T(result.reviews && result.reviews.R1?.verdict === 'PASS' && result.reviews.R3?.verdict === 'PASS', 'reviews R1/R3 = PASS')
  T(result.escalated === false && result.verdict === 'PASS', 'no escalation, overall verdict PASS')
  T(Array.isArray(result.stages_done) && ['research', 'planning', 'semantic', 'sitemap', 'seo', 'content', 'design', 'render'].every(s => result.stages_done.includes(s)),
    'stages_done covers research…render (incl. semantic)')

  // ── Scenario 2: R2 never passes → escalation (DR-3 cap=2) ──
  console.log('── dry-run: R2 stuck → escalation (cap=2) ──')
  const s2 = await runScenario({ reviewVerdict: (g) => (g === 'R2' ? 'NEEDS-WORK' : 'PASS') })
  T(s2.result.reviews.R2?.escalated === true, 'R2 escalated after cap')
  T(s2.result.reviews.R2?.iteration === 2, 'R2 ran exactly cap=2 iterations')
  T(typeof s2.result.reviews.R2?.notes === 'string' && s2.result.reviews.R2.notes.length > 0, 'R2 records reviewer_notes on escalation')
  T(s2.result.escalated === true && s2.result.verdict === 'escalated', 'overall escalated when a gate fails')
  const seoCalls = s2.calls.filter(c => c.label === 'seo').length
  T(seoCalls >= 2, `gated stage re-ran with critique (seo agent calls=${seoCalls})`)
  const seoRerun = s2.calls.filter(c => c.label === 'seo').some(c => /ЗАМЕЧАНИЯ REVIEWER/.test(c.prompt))
  T(seoRerun, 'seo re-run prompt carries reviewer critique')
  T(Array.isArray(s2.result.reviews.R2?.findings) && s2.result.reviews.R2.findings.length > 0,
    'reviewer surfaced ≥1 finding (caught contradiction) — Phase E DoD')

  // ── Scenario 3: geoEdge (аудитория РФ+заграница) → паттерн geo-доступности в ТЗ+промте ──
  console.log('── dry-run: geoEdge (РФ+заграница → RU-edge→origin в ТЗ+промте) ──')
  const sg = await runScenario({
    reviewVerdict: () => 'PASS',
    queryOverride: 'сайт для бизнеса с аудиторией в РФ и Украине/Европе',
    briefOverride: { key_claims: ['Аудитория: Россия + Украина и Европа', 'Доступ из-за рубежа критичен'], site_type: 'landing' },
  })
  T(/geo-доступност/i.test(sg.result.artifacts['tz.md']) && /self-hosted origin|RU.?edge/i.test(sg.result.artifacts['tz.md']),
    'geoEdge: ТЗ содержит раздел geo-доступности (RU-edge→origin)')
  T(/proxy_pass/.test(sg.result.artifacts['prompt.md']) && /proxy_ssl_verify/.test(sg.result.artifacts['prompt.md']),
    'geoEdge: промт содержит nginx edge reverse-proxy (proxy_pass + proxy_ssl_verify off)')
  T(/try_files .*index\.html/.test(sg.result.artifacts['prompt.md']), 'geoEdge: промт содержит origin static (try_files)')
  T(/DNS-only|proxied=false|без прокси/i.test(sg.result.artifacts['prompt.md']), 'geoEdge: DNS Cloudflare DNS-only инструкция')
  T(/Китай|GFW|ICP/i.test(sg.result.artifacts['tz.md']), 'geoEdge: ТЗ помечает что Китай не покрывается')

  // ── Scenario 4: НЕ geoEdge (только РФ) → паттерн НЕ добавляется ──
  console.log('── dry-run: no-geoEdge (только РФ → паттерна нет) ──')
  T(!/geo-доступност/i.test(result.artifacts['tz.md']) && !/proxy_ssl_verify/.test(result.artifacts['prompt.md']),
    'no-geoEdge (банный лендинг, только РФ): паттерн geo-доступности НЕ добавлен')

  console.log('')
  if (FAILS === 0) { console.log('DRYRUN OK'); process.exit(0) }
  else { console.log(`DRYRUN FAIL (${FAILS})`); process.exit(1) }
}

main().catch(e => { console.error('DRYRUN ERROR:', e && e.stack || e); process.exit(1) })

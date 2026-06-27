#!/usr/bin/env node
// redloft — methodology kit END-TO-END connection test (free, no LLM/billing).
// Доказывает СВЯЗКУ двух половин в одном прогоне:
//   (1) workflow/landing-builder.js (mock-agent, как dryrun) → prompt.md с гарантией «Шаг 0»
//       + methodology_tier_hint в payload;
//   (2) реальный caller Шаг 6c: пишет artifacts на диск → lib/methodology.sh --tier <hint>
//       → коробка с START-HERE.
// Что billed e2e добавит сверх этого: только реальные LLM-агенты в (1). Логика связки — здесь.
// Run: node tests/methodology.e2e.mjs → E2E OK / FAIL(n).

import { readFileSync, writeFileSync, mkdirSync, existsSync, mkdtempSync, rmSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { tmpdir } from 'node:os'

const __dir = dirname(fileURLToPath(import.meta.url))
const SKILL = join(__dir, '..')
const src = readFileSync(join(SKILL, 'workflow', 'landing-builder.js'), 'utf8')
  .replace(/^export\s+const\s+meta\b/m, 'const meta')

let FAILS = 0
const T = (c, m) => { console.log((c ? '  ✓ ' : '  ✗ ') + m); if (!c) FAILS++ }

// ── (1) запустить orchestrator с mock-agent (ecommerce → tier_hint 2) ──
const agent = async (prompt, opts = {}) => {
  const label = opts.label || ''
  if (/^R[0-9]/.test(label)) return { verdict: 'PASS', confidence: 0.9, findings: [] }
  if (label === 'render') return { tz_md: 'ТЗ тело', prompt_md: 'Промт тело', tz_key_claims: ['t'], prompt_key_claims: ['p'], summary: 'r' }
  return { artifact_type: label, key_claims: [`CLAIM_${label}`], body_md: `body ${label}`, summary: label }
}
const noop = () => {}
const argsObj = {
  slug: 'e2e-shop', project_dir: '/tmp/x', mode: 'lite', run_id: 'e2e',
  timestamp: '2026-06-02T00:00:00Z', query: 'создай интернет-магазин мебели',
  brief: { key_claims: ['Магазин мебели', 'Цель — продажи'], site_type: 'ecommerce', summary: 'Интернет-магазин крафтовой мебели' },
}
const make = new Function('args', 'agent', 'phase', 'log', 'parallel', 'pipeline', 'budget',
  `return (async () => {\n${src}\n})()`)
const result = await make(argsObj, agent, noop, noop, (ths) => Promise.all(ths.map(t => t())), async () => [],
  { total: null, spent: () => 0, remaining: () => Infinity })

console.log('── (1) workflow payload: гарантия Шага 0 + tier_hint ──')
T(result.methodology_tier_hint === 2, 'payload: methodology_tier_hint=2 (ecommerce)')
const pm = result.artifacts['prompt.md']
T(/methodology\//.test(pm) && /START-HERE/.test(pm) && /Шаг 0/.test(pm), 'prompt.md: «Шаг 0» развернуть methodology/ (DR-8 гарантия)')
T(/Методология проекта/i.test(result.artifacts['tz.md']), 'tz.md: раздел «Методология проекта»')

// ── (2) caller Шаг 6c: artifacts на диск → methodology.sh --tier <hint> ──
console.log('── (2) caller Шаг 6c: artifacts → methodology.sh → коробка ──')
const PD = mkdtempSync(join(tmpdir(), 'redloft-e2e-'))
try {
  for (const [rel, content] of Object.entries(result.artifacts)) {
    const fp = join(PD, rel); mkdirSync(dirname(fp), { recursive: true }); writeFileSync(fp, content)
  }
  writeFileSync(join(PD, 'brief.json'), JSON.stringify(argsObj.brief))
  // реалистичные upstream-файлы на диске (как в живом прогоне)
  mkdirSync(join(PD, 'sitemap'), { recursive: true }); mkdirSync(join(PD, 'planning'), { recursive: true })
  writeFileSync(join(PD, 'sitemap', 'sitemap.md'), '# Главная\n## Каталог\n## Корзина\n## Доставка\n## Контакты\n')
  writeFileSync(join(PD, 'planning', 'planning.md'), '---\nkey_claims:\n  - "ICP: ценители натуральной мебели"\n---\n# P\nUSP: массив на заказ.\n')

  const tier = result.methodology_tier_hint   // caller подставляет из payload
  let rc = 0
  try { execFileSync('bash', [join(SKILL, 'lib', 'methodology.sh'), PD, '--tier', String(tier)], { stdio: 'pipe' }) }
  catch (e) { rc = e.status }
  T(rc === 0 || rc === 3, `methodology.sh завершился ок (rc=${rc})`)

  const M = join(PD, 'methodology')
  T(existsSync(join(M, 'START-HERE.md')), 'коробка: START-HERE.md существует')
  const sh = existsSync(join(M, 'START-HERE.md')) ? readFileSync(join(M, 'START-HERE.md'), 'utf8') : ''
  T(/Интернет-магазин крафтовой мебели/.test(sh), 'START-HERE заполнен под проект (из brief.summary)')
  T(/Несколько направлений/.test(sh), 'START-HERE: tier-2 блок (ecommerce→2, связка hint→сборка)')
  T(existsSync(join(M, 'docs', 'product-principles.md')), 'tier-2: product-principles.md (по tier_hint=2)')
  const ver = existsSync(join(M, '.methodology-version')) ? readFileSync(join(M, '.methodology-version'), 'utf8') : ''
  T(/tier=2/.test(ver), '.methodology-version: tier=2 совпадает с payload hint')
  T(!/\{\{[A-Z_]+\}\}/.test(sh), 'нет незаполненных {{...}} в выходе')
} finally {
  rmSync(PD, { recursive: true, force: true })
}

console.log(FAILS === 0 ? '\nE2E OK' : `\nE2E FAIL(${FAILS})`)
process.exit(FAILS === 0 ? 0 : 1)

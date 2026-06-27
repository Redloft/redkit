// validators.js — executable acceptance-criteria helpers (DESIGN-foundation §4).
// Переиспользуемые функции для orchestrator (panel.js / reviewer-loop.js / finalize.js).
// Запуск напрямую `node validators.js --self-test` гоняет фикстуры (вкл. false-positive).

'use strict'

// --- §4: schema — минимальная проверка required-ключей (не полный JSON-schema) ---
function requireKeys(obj, keys) {
  if (obj === null || typeof obj !== 'object') return { ok: false, missing: keys }
  const missing = keys.filter(k => !(k in obj))
  return { ok: missing.length === 0, missing }
}

const DRAFT_REQUIRED = ['plan_markdown', 'assumptions', 'open_questions', 'self_check_passed', 'code_was_read']
const ERROR_REQUIRED = ['error', 'phase'] // *_ERROR_SCHEMA семейство (§1.2a/§1.2b)

function validateDraft(o) {
  const r = requireKeys(o, DRAFT_REQUIRED)
  if (!r.ok) return r
  if (typeof o.plan_markdown !== 'string' || o.plan_markdown.length < 50)
    return { ok: false, missing: ['plan_markdown(minLen50)'] }
  return { ok: true, missing: [] }
}

// --- §4: revise_notes coverage — каждый critical/warning judge должен быть покрыт ---
// judgeActions: [{rank, severity}], reviseNotes: [{judge_action_rank, disposition, rationale}]
function reviseCoverage(judgeActions, reviseNotes) {
  const mustCover = (judgeActions || [])
    .filter(a => a.severity === 'critical' || a.severity === 'warning')
    .map(a => a.rank)
  const covered = new Set((reviseNotes || []).map(n => n.judge_action_rank))
  const missing = mustCover.filter(r => !covered.has(r))
  // rejected без rationale — тоже нарушение
  const badRejections = (reviseNotes || [])
    .filter(n => n.disposition === 'rejected' && (!n.rationale || !String(n.rationale).trim()))
    .map(n => n.judge_action_rank)
  return { ok: missing.length === 0 && badRejections.length === 0, missing, badRejections }
}

// --- §4: fixer regex-guard — ловим suppression-директивы, НЕ bare-слова в прозе ---
// Матчим только структурные формы (с paren / директивный синтаксис), поэтому
// "we skip the slow path" в комментарии НЕ флагается (false-positive guard).
const FIXER_GUARD_PATTERNS = [
  { re: /eslint-disable(-next-line|-line)?/, tag: 'eslint-disable' },
  { re: /@ts-(ignore|expect-error)/, tag: 'ts-suppress' },
  { re: /#\s*type:\s*ignore/, tag: 'mypy-ignore' },
  { re: /@?pytest\.mark\.skip/, tag: 'pytest-skip' },
  { re: /\b(it|test|describe)\.skip\s*\(/, tag: 'test-skip' },
  { re: /\bx(it|describe)\s*\(/, tag: 'test-xskip' },
]
// fixerGuard(diff) → [{line, tag, text}] для ДОБАВЛЕННЫХ строк (начинаются с '+', не '+++')
function fixerGuard(diffText) {
  const out = []
  const lines = String(diffText || '').split('\n')
  let added = 0
  for (const ln of lines) {
    if (!ln.startsWith('+') || ln.startsWith('+++')) continue
    added++
    const body = ln.slice(1)
    for (const { re, tag } of FIXER_GUARD_PATTERNS) {
      if (re.test(body)) { out.push({ line: added, tag, text: body.trim() }); break }
    }
  }
  return out
}

// --- §4.1: oscillation control-flow ---
// iter==1 → delta undefined → regressed:false. delta>0 → regressed + break.
// regressed И вырос security-critical subset → forceFixFirst (неперекрываемый stable:true).
function oscillation({ prevCritical, currCritical, iter, securityCriticalUp }) {
  if (iter <= 1 || prevCritical == null) return { regressed: false, doBreak: false, forceFixFirst: false }
  const delta = currCritical - prevCritical
  const regressed = delta > 0
  return {
    regressed,
    doBreak: regressed,
    forceFixFirst: regressed && !!securityCriticalUp,
  }
}

module.exports = { requireKeys, validateDraft, reviseCoverage, fixerGuard, oscillation,
                   DRAFT_REQUIRED, ERROR_REQUIRED }

// ---------------- self-test ----------------
if (require.main === module && process.argv[2] === '--self-test') {
  let fail = 0
  const ok = (cond, msg) => { if (!cond) { console.error('✗', msg); fail++ } }

  // validateDraft
  ok(validateDraft({ plan_markdown: 'x'.repeat(60), assumptions: [], open_questions: [], self_check_passed: true, code_was_read: true }).ok, 'valid draft passes')
  ok(!validateDraft({ plan_markdown: 'short', assumptions: [], open_questions: [], self_check_passed: true, code_was_read: true }).ok, 'short plan_markdown rejected')
  ok(!validateDraft({ assumptions: [] }).ok, 'missing keys rejected')

  // reviseCoverage
  const ja = [{ rank: 1, severity: 'critical' }, { rank: 2, severity: 'warning' }, { rank: 3, severity: 'suggestion' }]
  ok(reviseCoverage(ja, [{ judge_action_rank: 1, disposition: 'applied' }, { judge_action_rank: 2, disposition: 'rejected', rationale: 'out of scope' }]).ok, 'full coverage passes (suggestion optional)')
  ok(!reviseCoverage(ja, [{ judge_action_rank: 1, disposition: 'applied' }]).ok, 'missing warning coverage fails')
  ok(!reviseCoverage(ja, [{ judge_action_rank: 1, disposition: 'applied' }, { judge_action_rank: 2, disposition: 'rejected' }]).ok, 'rejected w/o rationale fails')

  // fixerGuard — true positives
  const badDiff = [
    "+++ b/test.js",
    "+  it.skip('flaky', () => {})",
    "+  // eslint-disable-next-line no-unused",
    "+x = 1  # type: ignore",
    "+@pytest.mark.skip",
  ].join('\n')
  const hits = fixerGuard(badDiff)
  ok(hits.length === 4, `fixerGuard true-positives = 4 (got ${hits.length})`)

  // fixerGuard — false positives (прозаичные комментарии/докстринги со словами skip/ignore)
  const goodDiff = [
    "+++ b/app.js",
    "+  // we skip the slow path when the value is cached",
    '+  """This function will ignore None inputs and continue."""',
    "+  const skipped = items.filter(x => !x.done)",
    "-  it.skip('removed', () => {})",   // удалённая строка — не считаем
  ].join('\n')
  const fp = fixerGuard(goodDiff)
  ok(fp.length === 0, `fixerGuard false-positives = 0 (got ${fp.length}: ${JSON.stringify(fp)})`)

  // oscillation
  ok(oscillation({ iter: 1, prevCritical: null, currCritical: 3 }).regressed === false, 'iter=1 not falsely regressed')
  ok(oscillation({ iter: 2, prevCritical: 2, currCritical: 5, securityCriticalUp: false }).doBreak === true, 'delta>0 breaks')
  ok(oscillation({ iter: 2, prevCritical: 2, currCritical: 5, securityCriticalUp: true }).forceFixFirst === true, 'regressed+security → forceFixFirst')
  ok(oscillation({ iter: 2, prevCritical: 5, currCritical: 2 }).regressed === false, 'improvement not regressed')

  if (fail === 0) { console.log('✓ validators self-test passed'); process.exit(0) }
  else { console.error(`✗ validators self-test FAILED (${fail})`); process.exit(1) }
}

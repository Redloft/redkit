// reviewer-loop.js — Stage 1 / Часть A: --from-task + reviewer-loop (DESIGN-from-task).
// Верхний Workflow-скрипт. Phase 0 Draft (Fable planner) → петля:
//   panel.js (через workflow()) → judge verdict → PASS? стоп : revise → next iter.
// Переиспользует panel.js целиком (не дублирует scope/roles/judge). scope-once
// через precomputed_scoper на iter>1. Loop отделён от panel.js happy-path (DESIGN-foundation §3).
//
// Args:
//   task_text     — задача (обязательно)
//   project_slug, cwd, project_dir, timestamp, run_id
//   mode          — 'standard'(default)|'lite'|'ultra' (для review-фаз)
//   max_iters     — default 2
//
// Возвращает: { converged, ceiling, next_action?, reason, verdict, final_confidence, iterations[], plan_versions[], final_plan, final_judge, clarification? }
// Артефакты (plan.vN через strip + checkpoint) пишет caller — workflow-скрипты не имеют FS access.

export const meta = {
  name: 'reviewer-loop',
  description: 'from-task: Fable draft плана → reviewer-loop (panel review → revise ×≤2) до PASS или unconverged',
  phases: [
    { title: 'Draft', detail: 'Fable planner превращает задачу в план (читает код)' },
    { title: 'Review', detail: 'panel.js: scope→roles→judge на текущей версии плана' },
    { title: 'Revise', detail: 'planner правит план по judge (если не PASS и остались итерации)' },
  ],
}

const A = (typeof args === 'string' ? (() => { try { return JSON.parse(args) } catch { return { task_text: args } } })() : args) || {}
const taskText   = A.task_text || ''
const projectSlug = A.project_slug || 'unknown-project'
const cwd        = A.cwd || ''
const projectDir = A.project_dir || ''
const timestamp  = A.timestamp || 'now'
const runId      = A.run_id || 'unknown-run-id'
const mode       = A.mode || 'standard'
const MAX_ITERS  = Number(A.max_iters || 2)
// Портируемость: caller (SKILL) может передать panel_path (install-путь); fallback — канон на этой машине.
const PANEL = A?.panel_path || `${(typeof process !== 'undefined' && process.env && process.env.HOME) || '/Users/igorkonovalcik'}/.claude/skills/plan-panel/workflow/panel.js`
// FABLE: Fable 5 ещё не доступен в API → предсказуемый фоллбэк на opus (planner-модель
// до миграции). Единственная точка переключения — вернуть 'fable' когда выкатят.
const FABLE = 'opus'  // ← 'fable' когда модель появится

if (!taskText.trim()) {
  return { error: 'no-task', verdict: 'UNCERTAIN', reason: 'task_text пустой' }
}

const DRAFT_SCHEMA = {
  type: 'object',
  required: ['plan_markdown', 'assumptions', 'open_questions', 'self_check_passed', 'code_was_read'],
  additionalProperties: true,
  properties: {
    plan_markdown: { type: 'string' },
    assumptions: { type: 'array', items: { type: 'string' } },
    open_questions: { type: 'array', items: { type: 'string' } },
    self_check_passed: { type: 'boolean' },
    code_was_read: { type: 'boolean' },
    revise_notes: { type: 'array' },
  },
}

const PLANNER_REF = '~/.claude/skills/plan-panel/roles/planner.md'

// ===== Phase 0: DRAFT =====
phase('Draft')
const draft = await agent(
  `Ты — planner из skill plan-panel, режим DRAFT. Прочитай role spec ${PLANNER_REF} и следуй ему ПУНКТУАЛЬНО.\n\n` +
  `ОБЯЗАТЕЛЬНО до написания плана прочитай реальный код: codegraph_context/codegraph_search по области задачи + Read ключевых файлов` +
  `${projectSlug !== 'unknown-project' ? ` + $CLAUDECORE_PATH/projects/${projectSlug}.md` : ''}. ` +
  `Установи code_was_read=true только если реально читал код.\n` +
  `НЕ включай в plan_markdown литеральные значения секретов/токенов.\n` +
  `Если задача слишком расплывчата — верни open_questions непустым и self_check_passed=false, НЕ выдумывай план.\n\n` +
  `=== ЗАДАЧА ===\n${taskText}\n=== END ===\n` +
  `${cwd ? `\ncwd: ${cwd}\n` : ''}` +
  `\nВерни JSON по DRAFT_SCHEMA.`,
  { label: 'planner:draft', phase: 'Draft', model: FABLE, schema: DRAFT_SCHEMA }
)

if (!draft) return { error: 'draft-failed', verdict: 'UNCERTAIN', reason: 'planner не вернул draft' }

// Расплывчатая задача → clarification без петли (fail-fast, аналог scoper §9)
if (draft.self_check_passed === false || (draft.open_questions || []).length > 0 && (draft.plan_markdown || '').length < 50) {
  return {
    clarification: true,
    verdict: 'UNCERTAIN',
    open_questions: draft.open_questions || [],
    reason: 'Задача требует уточнения до планирования',
    final_plan: draft.plan_markdown || '',
  }
}

if (draft.code_was_read === false) {
  log('⚠️  planner: code_was_read=false — план не заземлён на код (warning в metadata)')
}

// ===== reviewer-loop =====
const planVersions = [draft.plan_markdown]
const iterations = []
let currentPlan = draft.plan_markdown
let scopeCache = null
let converged = false
let finalPanel = null
let prevCritical = null
let prevConfidence = null
let ceiling = false
let reason = ''

// Ceiling guard (redplan-review-ceiling): прирост confidence ниже этого порога при
// NEEDS-WORK = плато. PASS запрещает ЛЮБОЙ critical, а достаточно детальный план всегда
// вскрывает implementation-critical, которые панель не проверит из текста → асимптота к
// ~0.85, не к PASS. Дальнейшие круги жгут токены без шанса сойтись. Верификация
// реализации — задача /finalize (code-review по diff), не plan-review.
const CEILING_EPS = 0.03

const critCount = (judge) => (judge?.findings || []).filter(f => f.severity === 'critical').length
const secCritUp = (judge, prev) => {
  const sec = (j) => (j?.findings || []).filter(f => f.severity === 'critical' && /sec|secret|auth|credential|token/i.test((f.area || '') + (f.issue || ''))).length
  return prev != null && sec(judge) > prev
}
// Ceiling predicate (вынесен именованной функцией → ceiling-test.js извлекает её из исходника
// без drift). ИНВАРИАНТ: single-expression, без вложенных блоков (extract-regex ловит тело до '}'
// в колонке 0). Срабатывает ТОЛЬКО на NEEDS-WORK — НЕ на FAIL (нерешённые архитектурные critical,
// не DoD) и НЕ на UNCERTAIN (мало контекста → нужна доработка плана, а не code-review). Плато =
// прирост ниже eps; `eps - 1e-9` — float-safe строгое сравнение (прирост ровно eps не считается
// плато и при IEEE754-шуме типа 0.80→0.83). null-guard на оба conf.
function ceilingReached(prevConf, curConf, verdict, eps) {
  return prevConf != null && curConf != null && verdict === 'NEEDS-WORK'
    && (curConf - prevConf) < eps - 1e-9
}

for (let iter = 1; iter <= MAX_ITERS; iter++) {
  phase('Review')
  log(`── iteration ${iter}/${MAX_ITERS} ──`)

  const panel = await workflow({ scriptPath: PANEL }, {
    plan_text: currentPlan,
    project_slug: projectSlug,
    cwd, project_dir: projectDir, timestamp, run_id: `${runId}-i${iter}`,
    mode,
    precomputed_scoper: scopeCache,  // null на iter 1 → panel посчитает; далее reuse (scope-once)
  })

  if (panel?.error) {
    reason = `panel error на iter ${iter}: ${panel.error}`
    finalPanel = panel; break
  }
  if (iter === 1) scopeCache = panel.scoper  // зафиксировать scope для последующих итераций

  const verdict = panel.verdict
  const curCritical = critCount(panel.judge)
  const curConfidence = typeof panel.confidence === 'number' ? panel.confidence
    : (typeof panel.judge?.confidence === 'number' ? panel.judge.confidence : null)
  iterations.push({ iter, verdict, critical: curCritical, confidence: curConfidence, judge_summary: panel.judge?.summary })
  finalPanel = panel
  log(`iter ${iter}: verdict=${verdict} · critical=${curCritical} · confidence=${curConfidence ?? 'n/a'}`)

  if (verdict === 'PASS') { converged = true; reason = `PASS на iter ${iter}`; break }

  // Oscillation guard (DESIGN-foundation §4.1): critical вырос → regressed → стоп
  if (prevCritical != null && curCritical > prevCritical) {
    const force = secCritUp(panel.judge, prevCritical)
    reason = `regressed на iter ${iter} (critical ${prevCritical}→${curCritical})${force ? ' + security-critical вырос → FIX-FIRST' : ''}`
    log(`✋ ${reason}`)
    break
  }

  // Ceiling guard (redplan-review-ceiling): confidence вышла на плато при NEEDS-WORK и
  // critical не растёт (рост уже отсёк oscillation выше). Остаток — implementation-DoD,
  // которые панель не закроет из текста → новый круг не сойдётся. Стоп + handoff на /finalize.
  if (ceilingReached(prevConfidence, curConfidence, verdict, CEILING_EPS)) {
    ceiling = true
    reason = `ceiling на iter ${iter}: confidence плато (${prevConfidence}→${curConfidence}, Δ<${CEILING_EPS}), critical=${curCritical} не закрывается из текста плана. Остаток — implementation-DoD → верификация через /finalize, не новый круг plan-review.`
    log(`✋ ${reason}`)
    break
  }

  prevCritical = curCritical
  prevConfidence = curConfidence

  if (iter === MAX_ITERS) { reason = `достигнут MAX_ITERS=${MAX_ITERS} без PASS`; break }

  // ===== Phase 0b: REVISE =====
  phase('Revise')
  const revise = await agent(
    `Ты — planner из skill plan-panel, режим REVISE. Прочитай ${PLANNER_REF} и следуй ему.\n` +
    `Применяй actionable suggestions из judge к плану ТОЧЕЧНО, не переписывая с нуля.\n` +
    `Каждый critical и warning judge ОБЯЗАН получить запись в revise_notes (applied/rejected+rationale/deferred).\n` +
    `НЕ включай литеральные секреты в plan_markdown.\n\n` +
    `=== ПРЕДЫДУЩИЙ ПЛАН (v${iter}) ===\n${currentPlan}\n=== END ===\n\n` +
    `=== JUDGE (priority actions) ===\n${JSON.stringify(panel.judge?.priority_actions || [], null, 2)}\n=== END ===\n\n` +
    `Верни JSON по DRAFT_SCHEMA + revise_notes.`,
    { label: `planner:revise-i${iter}`, phase: 'Revise', model: FABLE, schema: DRAFT_SCHEMA }
  )

  if (!revise || !revise.plan_markdown) {
    reason = `revise_failed на iter ${iter} (planner не вернул валидный план)`
    log(`✋ ${reason}`)
    break
  }
  currentPlan = revise.plan_markdown
  planVersions.push(currentPlan)
}

return {
  converged,
  ceiling,
  next_action: ceiling ? 'finalize' : undefined,
  reason,
  verdict: finalPanel?.verdict || 'UNCERTAIN',
  final_confidence: typeof finalPanel?.confidence === 'number' ? finalPanel.confidence
    : (typeof finalPanel?.judge?.confidence === 'number' ? finalPanel.judge.confidence : null),
  iterations,
  plan_versions: planVersions,
  final_plan: currentPlan,
  final_judge: finalPanel?.judge || null,
  final_review: finalPanel?.reviews || null,
  scoper: scopeCache,
  code_was_read: draft.code_was_read,
  run_id: runId,
  // петля самоулучшения: проброс learnings от финального круга панели (caller пишет в ledger)
  learnings_entry: finalPanel?.learnings_entry || null,
  final_artifacts: finalPanel?.artifacts || null,
}

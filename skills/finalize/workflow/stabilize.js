// stabilize.js — Stage 2 STABILIZE-фаза как автоматизированный fixer-loop (DESIGN /finalize §1, §fixer).
// Workflow-агенты умеют Bash/Edit — поэтому цикл «прогнать гейты → починить ПРИЧИНУ → перепрогнать»
// автоматизируется здесь (раньше жил процедурой в SKILL.md). Orchestrator держит раунды,
// regression-guard и cap; каждый раунд = один fixer-агент (check → fix → re-check → self-report).
//
// Args: cwd, gates (JSON [{name,cmd}]), max_rounds (default 3)
// Возвращает stabilize_report: { stable, rounds, remaining_failures, fixer_warnings, history[] }
//   stable: true | false | "unknown"  (unknown = нет гейтов / только infra-error)
// Файлы чинятся IN-PLACE в cwd; caller ОБЯЗАН пере-snapshot diff после (код изменился).

export const meta = {
  name: 'stabilize',
  description: 'Fixer-loop: прогнать гейты → починить причину (не глушить тесты) → перепрогнать, ≤max_rounds, regression-guard',
  phases: [{ title: 'Stabilize', detail: 'fixer-агент чинит причину падений до зелёного или cap' }],
}

const A = (typeof args === 'string' ? (() => { try { return JSON.parse(args) } catch { return {} } })() : args) || {}
const cwd = A.cwd || ''
const gates = A.gates || []
const MAX = Number(A.max_rounds || 3)
const RG = '~/.claude/skills/finalize/lib/run-gates.sh'
const GUARD = '~/.claude/skills/plan-panel/lib/validators.js'
const DENY = '.env* *.pem *.key *.p12 *.keystore *credentials* secrets/* *.tfvars id_rsa*'

if (!cwd) return { stable: 'unknown', rounds: 0, remaining_failures: [], fixer_warnings: [], history: [], reason: 'no cwd' }
if (!Array.isArray(gates) || gates.length === 0)
  return { stable: 'unknown', rounds: 0, remaining_failures: [], fixer_warnings: [], history: [], reason: 'no gates' }

const ROUND_SCHEMA = {
  type: 'object',
  required: ['stable', 'remaining_failures', 'files_touched', 'fixer_warnings', 'ran_gates'],
  additionalProperties: true,
  properties: {
    stable: { enum: ['true', 'false', 'unknown'] }, // строкой — модели стабильнее отдают enum
    remaining_failures: { type: 'array', items: { type: 'string' } },
    files_touched: { type: 'array', items: { type: 'string' } },
    fixer_warnings: { type: 'array', items: { type: 'string' } }, // suppression-директивы из validators fixerGuard
    ran_gates: { type: 'boolean' },
    notes: { type: 'string' },
  },
}

phase('Stabilize')
const gatesJson = JSON.stringify(gates)
const history = []
let prevFailN = Infinity
let stable = 'unknown'
let remaining = []
const allWarnings = []
let reason = ''
let round = 0

for (round = 1; round <= MAX; round++) {
  log(`── stabilize round ${round}/${MAX} ──`)
  const res = await agent(
    `Ты — fixer для /finalize STABILIZE, раунд ${round}/${MAX}. cwd: ${cwd}\n\n` +
    `ШАГ 1 — прогони гейты: \`bash ${RG} "${cwd}" '${gatesJson}'\` (вернёт JSON {stable,results,remaining_failures}).\n` +
    `Если stable=="true" → НИЧЕГО не чини, верни {stable:"true", remaining_failures:[], files_touched:[], fixer_warnings:[], ran_gates:true}.\n` +
    `Если stable=="unknown" (infra-error: нет бинаря/network) → НЕ чини, верни как есть с ran_gates:true.\n\n` +
    `ШАГ 2 — если stable=="false": для КАЖДОГО remaining_failure найди и почини ПЕРВОПРИЧИНУ в коде (Read/codegraph/Edit).\n` +
    `ЖЁСТКО:\n` +
    `— чинить причину, НЕ глушить: запрещено добавлять skip/xit/eslint-disable/@ts-ignore/# type: ignore/pytest.mark.skip. Если тест поймал реальный баг — правь КОД, не тест.\n` +
    `— deny-list (НЕ открывать/не править, эскалировать): ${DENY}.\n\n` +
    `ШАГ 3 — перепрогони тот же run-gates. Затем проверь свой diff на suppression: \`git -C "${cwd}" diff | node ${GUARD}\` недоступен напрямую — вместо этого сам перечисли в fixer_warnings любые случаи где ты был вынужден тронуть подавление (в идеале пусто).\n\n` +
    `Верни JSON по схеме: stable/remaining_failures (после твоих фиксов), files_touched, fixer_warnings, ran_gates:true, notes (что чинил).`,
    { label: `fixer-r${round}`, phase: 'Stabilize', model: 'sonnet', schema: ROUND_SCHEMA }
  )

  if (!res || !res.ran_gates) { reason = `fixer round ${round} не прогнал гейты`; stable = 'unknown'; break }
  history.push({ round, stable: res.stable, remaining: res.remaining_failures, files: res.files_touched, warnings: res.fixer_warnings, notes: res.notes })
  ;(res.fixer_warnings || []).forEach(w => allWarnings.push(`r${round}: ${w}`))
  stable = res.stable
  remaining = res.remaining_failures || []

  if (res.stable === 'true') { reason = `зелёное на round ${round}`; break }
  if (res.stable === 'unknown') { reason = `infra-error на round ${round} (fixer не запускался)`; break }

  // regression-guard: число падений не уменьшилось → толку нет, стоп (не крутим вхолостую)
  const failN = remaining.length
  if (failN >= prevFailN) { reason = `no progress / regressed на round ${round} (${prevFailN}→${failN}) — стоп`; log(`✋ ${reason}`); break }
  prevFailN = failN

  if (round === MAX) { reason = `MAX_ROUNDS=${MAX} исчерпан, остались: ${remaining.join(', ')}` }
}

const stableBool = stable === 'true' ? true : (stable === 'false' ? false : 'unknown')
log(`stabilize: stable=${stableBool} · rounds=${round > MAX ? MAX : round} · remaining=[${remaining.join(', ')}]`)
return {
  stable: stableBool,
  rounds: round > MAX ? MAX : round,
  remaining_failures: remaining,
  fixer_warnings: allWarnings,
  history,
  reason,
}

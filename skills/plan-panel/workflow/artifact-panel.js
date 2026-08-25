// artifact-panel.js — панель экспертизы НЕ-КОДОВЫХ артефактов (Фаза 2 из DESIGN-panel-v2.md).
//
// Сиблинг panel.js, НЕ его модификация. Кодовый путь (panel.js / finalize.js) не тронут:
// на его вердиктах висят ceiling-guard в reviewer-loop и гейт деплоя redwork/autonomy-gate.sh.
// Здесь свой ростер (roles/registry-artifact.json), свой судья (roles/judge-artifact.md)
// и свой словарь вердиктов READY|TIGHTEN|RETHINK|UNCERTAIN.
//
// Args (всё инлайн — песочница Workflow без ФС):
//   artifact_text     — содержимое артефакта (обязательно)
//   artifact_name     — имя/заголовок для отчёта
//   user_goal         — чего хочет Игорь своими словами (влияет на scoper.goal)
//   roles_registry    — содержимое roles/registry-artifact.json
//   canon_lexicon     — содержимое lenses/canon.json (компактно), для meta-критика
//   timestamp, run_id — ОБЯЗАТЕЛЬНО (Date.now в песочнице запрещён; см. Ф3)
//   entry_point       — 'slash-command' | 'skill-freeform'
//   memory_brief, research_brief — опционально, инъекция как в panel.js
//
// Возвращает: { verdict, remainder_class, verdict_label, scope, reviews, judge,
//               learnings_entry, artifacts }

export const meta = {
  name: 'artifact-panel',
  description: 'Экспертиза не-кодового артефакта (КП, концепция, дека, документ): scope по жанру → роли → судья со словарём READY/TIGHTEN/RETHINK',
  phases: [
    { title: 'Scope', detail: 'жанр артефакта, адресат, цель, состав ролей' },
    { title: 'Review', detail: 'параллельный разбор выбранными ролями' },
    { title: 'Judge', detail: 'синтез + вердикт из словаря артефактов' },
  ],
}

let A = args
if (typeof args === 'string') { try { A = JSON.parse(args) } catch { A = { artifact_text: args } } }

const artifactText = A?.artifact_text || ''
const artifactName = A?.artifact_name || 'артефакт'
const userGoal = A?.user_goal || ''
const memoryBrief = A?.memory_brief || ''
const researchBrief = A?.research_brief || ''
const canonLexicon = A?.canon_lexicon || ''
const timestamp = A?.timestamp || 'now'
const runId = A?.run_id || 'unknown-run-id'
const entryPoint = A?.entry_point || 'unknown'
// Телеметрия по входу, не по значению (урок Ф3: 'unknown-run-id-i1' — непустая строка,
// sentinel-проверка приняла бы её за валидную).
const telemetryOk = typeof A?.run_id === 'string' && A.run_id.trim() !== ''
  && typeof A?.timestamp === 'string' && A.timestamp.trim() !== ''
if (!telemetryOk) log('⚠ телеметрия неполна — запись уйдёт в ledger с telemetry_ok:false')

if (!artifactText.trim()) {
  return { error: 'no-artifact', verdict: 'UNCERTAIN', reason: 'artifact_text пустой' }
}

// Ростер — обязателен: без него нечем набирать состав. В отличие от panel.js хардкод-фолбэка
// здесь нет намеренно — это новый вход, у него нет legacy-поведения, которое надо беречь.
let registry = null
try {
  const raw = A?.roles_registry
  const parsed = typeof raw === 'string' ? (raw.trim() ? JSON.parse(raw) : null) : raw
  if (parsed && Array.isArray(parsed.roles) && parsed.roles.length) registry = parsed
} catch (e) { log(`⚠ roles_registry не распарсился: ${e.message}`) }
if (!registry) {
  return { error: 'no-registry', verdict: 'UNCERTAIN',
    reason: 'roles_registry не передан или пуст — caller обязан прочитать roles/registry-artifact.json и передать инлайн' }
}
const roleByName = (n) => registry.roles.find(r => r.name === n) || null
const reviewRoleNames = registry.roles.filter(r => r.phase === 'review').map(r => r.name)
const VERDICTS = registry.verdicts || ['READY', 'TIGHTEN', 'RETHINK', 'UNCERTAIN']
const REMAINDERS = registry.remainder_classes || ['substance', 'craft', 'evidence', 'none']

const FINDINGS_SCHEMA = {
  type: 'object',
  required: ['role', 'verdict', 'confidence', 'findings', 'summary', 'self_check_passed'],
  additionalProperties: true,
  properties: {
    role: { type: 'string' },
    verdict: { enum: VERDICTS },
    confidence: { type: 'number', minimum: 0, maximum: 1 },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        required: ['severity', 'area', 'issue', 'suggestion'],
        additionalProperties: true,
        properties: {
          severity: { enum: ['critical', 'warning', 'suggestion'] },
          area: { type: 'string' },
          issue: { type: 'string' },
          suggestion: { type: 'string' },
          quote: { type: 'string' },   // место в артефакте, к которому относится finding
        },
      },
    },
    summary: { type: 'string' },
    self_check_passed: { type: 'boolean' },
  },
}

const SCOPE_SCHEMA = {
  type: 'object',
  required: ['artifact_kind', 'recipient', 'goal', 'selected_roles', 'rationale'],
  additionalProperties: true,
  properties: {
    artifact_kind: { enum: ['concept', 'plan', 'doc', 'deck', 'offer', 'research'] },
    recipient: { type: 'string' },
    goal: { type: 'string' },
    stage: { type: 'string' },
    selected_roles: { type: 'array', items: { type: 'string' } },
    complexity: { enum: ['low', 'medium', 'high'] },
    needs_research: { type: 'boolean' },
    confidence: { type: 'number' },
    rationale: { type: 'string' },
  },
}

const JUDGE_SCHEMA = {
  type: 'object',
  required: ['verdict', 'confidence', 'findings', 'priority_actions', 'summary',
    'final_verdict_reasoning', 'remainder_class', 'verdict_label'],
  additionalProperties: true,
  properties: {
    role: { const: 'judge-artifact' },
    // ⛔ Свой словарь. Кодовые (SHIP/FIX-FIRST, PASS/FAIL) здесь запрещены: на них
    // завязаны ceiling-guard и гейт деплоя redwork — чужие вердикты их бы отравили.
    verdict: { enum: VERDICTS },
    remainder_class: { enum: REMAINDERS },
    verdict_label: { type: 'string' },
    confidence: { type: 'number' },
    findings: { type: 'array' },
    conflicts: { type: 'array' },
    gaps: { type: 'array' },
    priority_actions: {
      type: 'array',
      items: {
        type: 'object',
        required: ['rank', 'severity', 'action'],
        additionalProperties: true,
        properties: {
          rank: { type: 'number' },
          severity: { enum: ['critical', 'warning', 'suggestion'] },
          action: { type: 'string' },
          owner_role: { type: 'string' },
        },
      },
    },
    summary: { type: 'string' },
    final_verdict_reasoning: { type: 'string' },
  },
}

const briefs = (
  (memoryBrief ? `=== RedBrain-контекст (память Игоря — не переоткрывай известное) ===\n${memoryBrief}\n=== END ===\n\n` : '') +
  (researchBrief ? `${researchBrief}\n=== END ===\n\n` : '')
)

// ===== Phase 1: SCOPE =====
phase('Scope')
const scope = await agent(
  `Ты — scoper-artifact из skill plan-panel. Прочитай role spec ~/.claude/skills/plan-panel/roles/scoper-artifact.md и следуй ему пунктуально.\n\n` +
  `Доступные review-роли (бери имена ТОЛЬКО отсюда): ${reviewRoleNames.join(', ')}.\n` +
  `Их назначение:\n${registry.roles.filter(r => r.phase === 'review').map(r => `- ${r.name}: ${r.focus.slice(0, 180)}`).join('\n')}\n\n` +
  (userGoal ? `=== ЧЕГО ХОЧЕТ ИГОРЬ (его словами) ===\n${userGoal}\n=== END ===\n\n` : '') +
  `=== АРТЕФАКТ: ${artifactName} ===\n${artifactText}\n=== END ===\n\nВерни JSON по схеме.`,
  { label: 'scoper-artifact', phase: 'Scope', model: roleByName('scoper-artifact')?.model || 'haiku', schema: SCOPE_SCHEMA }
)
if (!scope) return { error: 'scope-failed', verdict: 'UNCERTAIN', reason: 'scoper не вернул результат' }

// Роль, которой нет в ростере, — fail-loud (урок Ф5: молчаливый скип прятал неполный состав)
const unknown = (scope.selected_roles || []).filter(r => !reviewRoleNames.includes(r))
if (unknown.length) log(`⚠ scoper предложил роли вне ростера: ${unknown.join(', ')} — отброшены`)
let selected = (scope.selected_roles || []).filter(r => reviewRoleNames.includes(r))
if (selected.length < 2) {
  // Минимум два голоса: одна роль — это мнение, а не панель. Добираем по жанру из ростера.
  const byKind = registry.roles.filter(r => r.phase === 'review'
    && (!Array.isArray(r.kinds) || r.kinds.includes(scope.artifact_kind))).map(r => r.name)
  const add = byKind.filter(r => !selected.includes(r))
  log(`⚠ scoper выбрал ${selected.length} роль(и) — добираю по жанру '${scope.artifact_kind}': ${add.join(', ')}`)
  selected = selected.concat(add).slice(0, 4)
}
// PREFLIGHT РОСТЕРА (2026-08-25). Состав выбирает scoper мягкими правилами, и роли без
// обязательного триггера систематически не активируются: в ledger'е «legal-ru не активирован»
// ×2 и «unit-economics не активирован» ×1, причём судья констатировал пропуск ПОСЛЕ того, как
// все роли отработали без этой линзы — то есть панель уже прошла мимо.
// Почему машинно, а не пунктом в промпте scoper'а: доктрина этого же кода — прозаический
// контракт систематически пропускают (внешние судьи выпали на 3 недели, fact-grounder
// отработал 1 раз из 135), поэтому такие вещи форсируют данными. Аналог — floor-globs
// в redwork/risk-classify: неотключаемы, и это их смысл.
// Триггеры лексические, значит ложные срабатывания будут: обзор рынка со словом «налог»
// притащит legal-ru. Это осознанный перекос — цена ошибок асимметрична: лишняя роль стоит
// одного прогона и шум гасит судья, пропущенная юридическая линза на КП с обязательствами
// стоит отправленного клиенту документа. Порог занижаем в сторону включения.
// ⚠ НИКАКИХ \w И \b В КИРИЛЛИЧЕСКИХ АЛЬТЕРНАТИВАХ. В JS `\w` == [A-Za-z0-9_], поэтому
// `персональн\w*\s+данн` не матчит «персональные данные» ВООБЩЕ, а `\b` после кириллицы
// ложен («10% от оборота» мимо). Первая версия таблицы была мертва в четырёх альтернативах
// из пяти, и тесты этого не видели: фикстура срабатывала по СОСЕДНЕЙ альтернативе.
// Отсюда правило ниже: на каждую альтернативу — свой минимальный позитивный пример.
const CYR = '[а-яёА-ЯЁ]'
// NB — «не внутри слова» слева. Нужен КОРОТКИМ основам, которые поглощаются обычными словами:
// «налог» ⊂ аНАЛОГ/аналогичный/аналоговый, «усн» ⊂ вкУСНый/искУСНый, «cac» ⊂ CAChe/CACao.
// Без него гейт не «перекошен в сторону включения», а включён ВСЕГДА: «аналоги» и «cache»
// встречаются едва ли не в каждой концепции и деке. Длинные основы (договор, оферт, неустойк)
// в поглощение не попадают и границы не требуют. \b тут не годится — на кириллице он ложен.
const NB = '(?<![а-яёa-z])'
const ROSTER_PREFLIGHT = [
  { role: 'legal-ru', why: 'обязательства сторон / деньги между сторонами / персональные данные',
    re: new RegExp('(договор|оферт|обязательств|неустойк|штраф|ответственност[ьи]\\s+сторон|комисси|вознагражд'
      + '|роялти|' + NB + 'налог|' + NB + 'ндс(?!' + CYR + ')|' + NB + 'усн(?!' + CYR + ')'
      + '|самозанят|персональн' + CYR + '*\\s+данн|согласи' + CYR + '*\\s+на\\s+обработк|152-ФЗ)', 'i') },
  { role: 'unit-economics', why: 'переменная выплата / тариф / окупаемость',
    re: new RegExp('(комисси|вознагражд|%\\s*от(?!' + CYR + ')|процент' + CYR + '*\\s+от(?!' + CYR + ')'
      + '|тариф|подписк|абонентск|окупаем|маржинальн|юнит-экономик'
      + '|' + NB + 'ltv(?![a-z])|' + NB + 'cac(?![a-z]))', 'i') },
]

// Отдельной функцией — чтобы гард мог прогнать её без агентов (тот же приём, что ceiling-test).
function applyRosterPreflight(selected, text, available, table) {
  const forced = []
  for (const pf of table) {
    if (!available.includes(pf.role)) continue      // роли нет в ростере — не выдумываем состав
    if (selected.includes(pf.role)) continue        // scoper уже взял — preflight молчит
    if (!pf.re.test(text || '')) continue
    selected.push(pf.role)
    forced.push(pf)
  }
  return { selected, forced }
}

// ⚠ ПОСЛЕ добора-до-двух и ПОСЛЕ slice(0,4): форсированную роль обрезать лимитом нельзя —
// иначе гейт снимается ровно тем механизмом, от которого защищает.
const pre = applyRosterPreflight(selected, artifactText, reviewRoleNames, ROSTER_PREFLIGHT)
selected = pre.selected
for (const f of pre.forced) {
  log(`⚑ preflight ростера: добавлена роль ${f.role} — в тексте есть ${f.why}, scoper её не выбрал`)
}

log(`Жанр: ${scope.artifact_kind} · адресат: ${scope.recipient} · цель: ${scope.goal} · роли: ${selected.join(', ')}`)
if (scope.needs_research) log('⚠ scoper: ролям не хватает внешних фактов — стоило дёрнуть /research до панели')

// ===== Phase 2: REVIEW =====
// СКВОЗНОЙ ПУНКТ (solidify 2026-08-19, тема judge/judge-covers-for-roles ×11 critical + security ×4).
// Судья систематически ловил СВЯЗКИ, которых нет ни в одном чек-листе: каждая роль честно
// проверяла свой слой и останавливалась на его границе. Живые примеры класса: правка общего
// входного файла ломала уже разосланные наружу и закэшированные копии; ни одна роль не спросила,
// что происходит ПОСЛЕ успешной записи в БД (доставка, уведомление); полнота доказательства
// проверялась побайтово, а не по смыслу. Это не дефект отдельной роли — это ничья земля между
// ролями, поэтому пункт живёт в ОБЩЕМ промпте, а не в семи чек-листах.
const SEAM_CLAUSE =
  'СКВОЗНАЯ ПРОВЕРКА (обязательна, помимо твоего чек-листа). Твоя зона ответственности кончается ' +
  'раньше, чем последствия изменения. Ответь по каждому значимому изменению: (1) что происходит ПОСЛЕ ' +
  'того, как описанный успех наступил — доставка, уведомление, следующий шаг, кто и как узнаёт, что ' +
  'дальше с этим делают; (2) что СНАРУЖИ твоего слоя уже зависит от того, что меняется — уже разосланные ' +
  'или закэшированные наружу копии, соседние продукты на общем коде, фоновые задания, потребители старых ' +
  'версий, которых не обновить. Если на вопрос отвечает не твоя роль и не видно, чья — это finding, ' +
  'а не повод промолчать: ровно такие связки судья регулярно добирает вместо ролей.'

phase('Review')
const reviews = (await parallel(selected.map(name => async () => {
  const r = roleByName(name)
  if (!r) throw new Error(`роль '${name}' прошла фильтр, но её нет в ростере — ростер и фильтр разошлись`)
  return await agent(

    `Ты — ${name} из skill plan-panel, режим разбора НЕ-КОДОВОГО артефакта. Прочитай role spec ~/.claude/skills/plan-panel/${r.file} и применяй его checklist пунктуально.\n\n` +
    `${r.focus}\n\n` +
    `=== КОНТЕКСТ РАЗБОРА ===\nЖанр: ${scope.artifact_kind}\nАдресат: ${scope.recipient}\nЦель разбора: ${scope.goal}\nСтадия: ${scope.stage || 'не указана'}\n=== END ===\n\n` +
    briefs +
    `=== АРТЕФАКТ: ${artifactName} ===\n${artifactText}\n=== END ===\n\n` +
    `Верни СТРОГО JSON по схеме. verdict — из словаря ${VERDICTS.join('|')}, НЕ кодовый.\n` +
    `В каждом finding поле quote — короткая цитата из артефакта (до 15 слов), к которой относится замечание.\n` +
    `${SEAM_CLAUSE}\n` +
    `Стадия '${scope.stage || 'не указана'}': к черновику не предъявляй требований финального документа.`,
    { label: `review:${name}`, phase: 'Review', model: r.model || 'sonnet', schema: FINDINGS_SCHEMA }
  )
}))).filter(Boolean)

if (!reviews.length) return { error: 'all-roles-failed', verdict: 'UNCERTAIN', scope }
log(`Получено ${reviews.length}/${selected.length} разборов`)

// ===== Phase 3: JUDGE =====
phase('Judge')
const judge = await agent(
  `Ты — judge-artifact из skill plan-panel. Прочитай role spec ~/.claude/skills/plan-panel/roles/judge-artifact.md и следуй ему ПУНКТУАЛЬНО.\n\n` +
  `Механику cross-examination и поиска gaps бери из roles/judge.md — она общая.\n` +
  `⛔ Вердикт ТОЛЬКО из ${VERDICTS.join('|')}. Кодовые (SHIP/FIX-FIRST/PASS/FAIL) запрещены — на них завязаны автоматические гейты других контуров.\n` +
  `remainder_class — из ${REMAINDERS.join('|')}, смешанный остаток → самый тяжёлый.\n\n` +
  `=== КОНТЕКСТ ===\nЖанр: ${scope.artifact_kind}\nАдресат: ${scope.recipient}\nЦель: ${scope.goal}\nСтадия: ${scope.stage || 'не указана'}\n=== END ===\n\n` +
  briefs +
  `=== РАЗБОРЫ РОЛЕЙ ===\n${JSON.stringify(reviews.map(r => ({ role: r.role, verdict: r.verdict, confidence: r.confidence, findings: r.findings, summary: r.summary })), null, 2)}\n=== END ===\n\n` +
  `=== АРТЕФАКТ (для проверки цитат) ===\n${artifactText}\n=== END ===\n\nВерни JSON по схеме.`,
  { label: 'judge-artifact', phase: 'Judge', model: roleByName('judge-artifact')?.model || 'opus', schema: JUDGE_SCHEMA }
)
if (!judge) return { error: 'judge-failed', verdict: 'UNCERTAIN', scope, reviews }

// ===== Meta-critic: та же петля самоулучшения, что у кодовой панели =====
const CRITIC_SCHEMA = {
  type: 'object',
  required: ['methodology_findings'],
  additionalProperties: true,
  properties: {
    methodology_findings: {
      type: 'array',
      items: {
        type: 'object',
        required: ['role', 'lens_key', 'severity', 'observation', 'proposed_checklist_delta'],
        additionalProperties: true,
        properties: {
          role: { type: 'string' },
          lens_key: { type: 'string' },
          lens_rationale: { type: 'string' },
          severity: { enum: ['critical', 'warning', 'suggestion'] },
          observation: { type: 'string' },
          proposed_checklist_delta: { type: 'string' },
        },
      },
    },
  },
}
const lensInstruction = canonLexicon
  ? `=== КАНОН ЛИНЗ — выбирай lens_key ТОЛЬКО отсюда ===\n${canonLexicon}\n=== END ===\n` +
    `Ни одна не подходит → lens_key: "new:<kebab-слаг>" + обязательный lens_rationale. Свободные ключи уйдут в карантин.\n`
  : `lens_key — короткий стабильный kebab-слаг линзы.\n`
const critic = await agent(
  `Ты — methodology-critic. НЕ ищи новых проблем артефакта. Единственная задача: понять, не вскрыл ли какой-то finding ДЫРУ В ЧЕК-ЛИСТЕ САМОЙ РОЛИ — проверку, которой у неё нет, но должна быть.\n` +
  `Критерий: «будь у роли такой пункт, она ловила бы этот КЛАСС в ЛЮБОМ артефакте» → methodology_finding. Разовое — игнор.\n` +
  lensInstruction +
  `\n=== JUDGE ===\n${JSON.stringify({ verdict: judge.verdict, remainder_class: judge.remainder_class, gaps: judge.gaps || [], reasoning: judge.final_verdict_reasoning }, null, 2)}\n` +
  `\n=== FINDINGS РОЛЕЙ ===\n${JSON.stringify(reviews.map(r => ({ role: r.role, findings: r.findings })), null, 2)}\n=== END ===\n\nВерни JSON по схеме.`,
  { label: 'meta-critic', phase: 'Judge', model: 'sonnet', schema: CRITIC_SCHEMA }
)
const methodologyFindings = (critic && Array.isArray(critic.methodology_findings)) ? critic.methodology_findings : []

const learningsEntry = {
  ts: timestamp, skill: 'artifact-panel', run_id: runId,
  telemetry_ok: telemetryOk, entry_point: entryPoint,
  artifact_kind: scope.artifact_kind,
  // Форсы дублируем в ledger, а не только в per-run metadata.json: тот живёт под retention
  // +90d с ленивым GC и ничем не агрегируется, то есть «измеримость» перекоса была на словах.
  // В ledger'е они переживут прогон и попадут в ту же выборку, что телеметрия и остаток.
  forced_roles: pre.forced.map(f => f.role),
  verdict: judge.verdict,
  confidence: judge.confidence,
  remainder_class: judge.remainder_class || null,
  gaps: (judge.gaps || []).map(g => typeof g === 'string' ? g : (g.area || '')).filter(Boolean),
  conflicts_count: (judge.conflicts || []).length,
  methodology_findings: methodologyFindings,
}

function renderReviewMd() {
  const parts = [`# Разбор артефакта — ${artifactName}\n\nrun_id: \`${runId}\` · жанр: \`${scope.artifact_kind}\` · адресат: ${scope.recipient} · стадия: ${scope.stage || '—'}\n`]
  for (const r of reviews) {
    parts.push(`## ${r.role} — ${r.verdict} (${r.confidence})\n\n${r.summary}\n`)
    for (const f of r.findings || []) {
      parts.push(`- **[${f.severity}]** ${f.area}: ${f.issue}${f.quote ? `\n  > ${f.quote}` : ''}\n  → ${f.suggestion}`)
    }
    parts.push('')
  }
  return parts.join('\n')
}

function renderJudgeMd() {
  const l = [`# Вердикт — ${artifactName}\n`,
    `**${judge.verdict}** · ${judge.verdict_label || ''} · confidence ${judge.confidence}`,
    `остаток: \`${judge.remainder_class}\` · адресат: ${scope.recipient}\n`,
    `${judge.summary}\n`, `## Почему такой вердикт\n\n${judge.final_verdict_reasoning}\n`]
  if ((judge.priority_actions || []).length) {
    l.push('## Что сделать\n')
    for (const a of judge.priority_actions) l.push(`${a.rank}. **[${a.severity}]** ${a.action}${a.owner_role ? ` _(${a.owner_role})_` : ''}`)
    l.push('')
  }
  if ((judge.gaps || []).length) {
    l.push('## Чего не покрыла ни одна роль\n')
    for (const g of judge.gaps) l.push(`- ${typeof g === 'string' ? g : `${g.area}: ${g.why_missed || ''}`}`)
  }
  return l.join('\n')
}

return {
  verdict: judge.verdict,
  remainder_class: judge.remainder_class,
  verdict_label: judge.verdict_label,
  confidence: judge.confidence,
  scope,
  reviews,
  judge,
  learnings_entry: learningsEntry,
  artifacts: {
    'artifact.md': artifactText,
    'scope.json': JSON.stringify(scope, null, 2),
    'reviews.json': JSON.stringify(reviews, null, 2),
    'review.md': renderReviewMd(),
    'judge.json': JSON.stringify(judge, null, 2),
    'judge.md': renderJudgeMd(),
    'learnings.entry.json': JSON.stringify(learningsEntry, null, 2),
    'metadata.json': JSON.stringify({
      run_id: runId, timestamp, run_type: 'artifact', artifact_name: artifactName,
      artifact_kind: scope.artifact_kind, recipient: scope.recipient, goal: scope.goal,
      selected_roles: selected,
      // Форсированные роли пишем отдельно: гейт сознательно перекошен в сторону включения,
      // значит частоту его ложных срабатываний надо чем-то мерить — иначе снять или сузить
      // триггеры будет не на основании чего.
      forced_roles: pre.forced.map(f => f.role),
      verdict: judge.verdict, remainder_class: judge.remainder_class,
      telemetry_ok: telemetryOk, entry_point: entryPoint,
    }, null, 2),
  },
}

// empirical-test.js — юнит-тест empirical-unknown ветки /finalize БЕЗ агентов.
// Извлекает РЕАЛЬНУЮ deriveEmpirical() из workflow/finalize.js (как chunk-test) → тест не дрейфует от кода.
'use strict'
const fs = require('fs')
const path = require('path')

const src = fs.readFileSync(path.join(__dirname, '..', 'workflow', 'finalize.js'), 'utf8')

function extract(name) {
  const re = new RegExp(`function ${name}\\s*\\([\\s\\S]*?\\n\\}`, 'm')
  const m = src.match(re)
  if (!m) throw new Error(`не нашёл function ${name} в finalize.js`)
  return m[0]
}
// eslint-disable-next-line no-eval
const deriveEmpirical = eval(`(${extract('deriveEmpirical')})`)

let fail = 0
const ok = (c, m) => { if (!c) { console.error('✗', m); fail++ } }

const rev = (role, areas) => ({ role, findings: areas.map(a => ({ area: a, issue: `issue-${a}`, suggestion: `sugg-${a}` })) })

// 1. нет empirical → чистый verdict, pendingVerify=false, DoD пуст
let r = deriveEmpirical([rev('qa', ['acceptance', 'edge-cases'])], { findings: [] }, 'SHIP')
ok(!r.hasEmpirical, '1: нет empirical → hasEmpirical=false')
ok(r.pendingVerify === false, '1: pendingVerify=false')
ok(r.verdictLabel === 'SHIP', '1: label=SHIP (чистый)')
ok(r.liveVerifyDod.length === 0, '1: DoD пуст')

// 2. SHIP + empirical-unknown → инвариант: pendingVerify && DoD непуст, label с маркером
r = deriveEmpirical([rev('data', ['empirical-unknown'])], { findings: [] }, 'SHIP')
ok(r.hasEmpirical, '2: hasEmpirical=true')
ok(r.pendingVerify === true, '2: pendingVerify=true')
ok(/pending live-verify/.test(r.verdictLabel), '2: label содержит pending live-verify')
ok(r.liveVerifyDod.length === 1, '2: DoD синтезирован (1 пункт)')
ok(r.liveVerifyDod[0].check.includes('issue-empirical-unknown'), '2: DoD check из issue')

// 3. over-match guard: anchored regex НЕ матчит 'non-empirical'/'semi-empirical-data'
r = deriveEmpirical([rev('qa', ['non-empirical', 'semi-empirical-data'])], { findings: [] }, 'SHIP')
ok(!r.hasEmpirical, "3: 'non-empirical'/'semi-empirical-data' НЕ матчатся (anchored)")
ok(r.verdictLabel === 'SHIP', '3: чистый SHIP не подменён')

// 3b. tolerant: разделитель/регистр ('Empirical_Unknown') — матчится
r = deriveEmpirical([rev('data', ['Empirical_Unknown'])], { findings: [] }, 'SHIP')
ok(r.hasEmpirical, '3b: Empirical_Unknown (регистр/underscore) матчится')

// 4. dedup: роль + судья re-surface один и тот же стык (area:issue) → 1 пункт DoD, не 2
const judgeDup = { findings: [{ area: 'empirical-unknown', issue: 'issue-empirical-unknown', suggestion: 's' }] }
r = deriveEmpirical([rev('data', ['empirical-unknown'])], judgeDup, 'SHIP')
ok(r.empiricalFindings.length === 1, `4: дедуп по area:issue → 1 (got ${r.empiricalFindings.length})`)
ok(r.liveVerifyDod.length === 1, '4: DoD без дубля')

// 5. judge дал свой live_verify_dod → используется он; пустые/null элементы отсеяны
const judgeDod = { findings: [{ area: 'empirical-unknown', issue: 'x', suggestion: 'y' }], live_verify_dod: [{ check: 'real check', why: 'w' }, { check: '', why: 'empty' }, null] }
r = deriveEmpirical([], judgeDod, 'SHIP')
ok(r.liveVerifyDod.length === 1, `5: пустой/null DoD-элемент отсеян (got ${r.liveVerifyDod.length})`)
ok(r.liveVerifyDod[0].check === 'real check', '5: валидный элемент сохранён')

// 6. empirical под НЕ-SHIP verdict → hasEmpirical, но pendingVerify=false (label=verdict, без pending-маркера)
r = deriveEmpirical([rev('data', ['empirical-unknown'])], { findings: [] }, 'FIX-FIRST')
ok(r.hasEmpirical, '6: hasEmpirical=true под FIX-FIRST')
ok(r.pendingVerify === false, '6: pendingVerify=false (не SHIP)')
ok(r.verdictLabel === 'FIX-FIRST', '6: label=FIX-FIRST (без pending-маркера)')

// 7. ИНВАРИАНТ: empirical finding с пустым issue + judge без DoD → DoD НЕ пуст (дефолтный пункт), контракт не нарушен
r = deriveEmpirical([{ role: 'data', findings: [{ area: 'empirical-unknown', issue: '', suggestion: '' }] }], { findings: [] }, 'SHIP')
ok(r.hasEmpirical, '7: empty-issue empirical всё равно hasEmpirical=true')
ok(!(r.pendingVerify && r.liveVerifyDod.length === 0), '7: НЕ бывает pendingVerify=true && DoD пуст (инвариант SKILL.md §3)')
ok(r.liveVerifyDod.length >= 1, '7: дефолтный DoD-пункт подставлен при пустом issue')

// 8. dedup нормализует null/undefined issue в один ключ
const judgeNull = { findings: [{ area: 'empirical-unknown', issue: null }] }
r = deriveEmpirical([{ role: 'data', findings: [{ area: 'empirical-unknown', issue: undefined, suggestion: 's' }] }], judgeNull, 'FIX-FIRST')
ok(r.empiricalFindings.length === 1, `8: null/undefined issue → один dedup-ключ (got ${r.empiricalFindings.length})`)

if (fail === 0) { console.log('✓ empirical-test passed (8 групп ассертов)'); process.exit(0) }
else { console.error(`✗ empirical-test FAILED (${fail})`); process.exit(1) }

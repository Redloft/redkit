// ceiling-test.js — юнит-тест ceiling-guard петли reviewer-loop БЕЗ агентов.
// Извлекает РЕАЛЬНУЮ функцию ceilingReached + константу CEILING_EPS из
// workflow/reviewer-loop.js и гоняет её, чтобы тест не дрейфовал от кода.
// (Workflow-скрипты не экспортируемы → eval извлечённого определения — тот же
//  паттерн, что finalize/lib/chunk-test.js.)
'use strict'
const fs = require('fs')
const path = require('path')

const src = fs.readFileSync(path.join(__dirname, '..', 'workflow', 'reviewer-loop.js'), 'utf8')

function extract(name) {
  const re = new RegExp(`function ${name}\\s*\\([\\s\\S]*?\\n\\}`, 'm')
  const m = src.match(re)
  if (!m) throw new Error(`не нашёл function ${name} в reviewer-loop.js`)
  return m[0]
}

// EPS берём из исходника, чтобы тест бил по фактической константе (а не по копии)
const EPS = Number((src.match(/const CEILING_EPS\s*=\s*([\d.]+)/) || [])[1])
if (!(EPS > 0 && EPS < 0.1)) { console.error('✗ CEILING_EPS вне ожидаемого (0, 0.1):', EPS); process.exit(1) }

// eslint-disable-next-line no-eval
const { ceilingReached } = eval(`(function(){ ${extract('ceilingReached')}\n return { ceilingReached } })()`)

let fail = 0
const ok = (c, m) => { if (!c) { console.error('✗', m); fail++ } }
const hit = (p, c, v) => ceilingReached(p, c, v, EPS)

// 1. Канонический сценарий из памяти (redplan-review-ceiling): 0.88 → 0.85 → 0.85, NEEDS-WORK.
ok(hit(0.88, 0.85, 'NEEDS-WORK') === true, 'ceiling: 0.88→0.85 NEEDS-WORK = плато (Δ=-0.03 < eps)')
ok(hit(0.85, 0.85, 'NEEDS-WORK') === true, 'ceiling: 0.85→0.85 NEEDS-WORK = плато (Δ=0)')

// 2. Реальный прогресс → НЕ потолок, петля должна продолжиться.
ok(hit(0.70, 0.84, 'NEEDS-WORK') === false, 'no-ceiling: 0.70→0.84 (Δ=0.14 ≥ eps) — растёт')

// 3. PASS перебивает плато (verdict-guard) — петля и так break'нет на PASS выше, но предикат честен.
ok(hit(0.85, 0.85, 'PASS') === false, 'no-ceiling: verdict=PASS не считается потолком')

// 4. Границы порога.
ok(hit(0.80, 0.82, 'NEEDS-WORK') === true,  `ceiling: Δ=0.02 < eps(${EPS}) — мелкий прирост = плато`)
ok(hit(0.82, 0.85, 'NEEDS-WORK') === false, `no-ceiling: Δ=0.03 НЕ < eps(${EPS}) — строгая граница`)

// 5. Null-guard: первая итерация (нет prev) и панель без confidence — НЕ false-stop.
ok(hit(null, 0.85, 'NEEDS-WORK') === false, 'no-ceiling: prev=null (iter 1) — нечего сравнивать')
ok(hit(0.85, null, 'NEEDS-WORK') === false, 'no-ceiling: cur=null (панель без confidence) — не стопаем вслепую')

// 6. Обвал confidence при не-PASS → тоже потолок (новые круги не помогут).
ok(hit(0.90, 0.60, 'NEEDS-WORK') === true, 'ceiling: 0.90→0.60 обвал (Δ<0) — больше кругов не спасут')

// 7. FAIL/UNCERTAIN на плато — НЕ потолок: ceiling только для NEEDS-WORK.
//    FAIL = нерешённые архитектурные critical; UNCERTAIN = мало контекста → доработка плана, не /finalize.
ok(hit(0.85, 0.85, 'FAIL') === false, 'no-ceiling: FAIL = архитектурные critical, не implementation-DoD')
ok(hit(0.45, 0.45, 'UNCERTAIN') === false, 'no-ceiling: UNCERTAIN = мало контекста, нужна доработка плана')

// 8. Float-precision (IEEE754): номинальный Δ=0.03 НЕ должен считаться плато ни при какой паре.
//    Без eps-1e-9 кейс 0.80→0.83 ложно срабатывал (0.0299999…916 < 0.03).
ok(hit(0.80, 0.83, 'NEEDS-WORK') === false, 'no-ceiling: Δ=0.03 (0.80→0.83 float-noisy) — eps-1e-9 держит границу')
ok(hit(0.70, 0.73, 'NEEDS-WORK') === false, 'no-ceiling: Δ=0.03 (0.70→0.73) float-safe')

if (fail) { console.error(`\n✗ ceiling-test: ${fail} провал(ов)`); process.exit(1) }
console.log(`✓ ceiling self-test passed (13 кейсов, EPS=${EPS} из исходника)`)

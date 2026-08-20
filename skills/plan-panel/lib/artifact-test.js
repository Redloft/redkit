// artifact-test.js — гард входа /review-artifact (Фаза 2).
//
// Главный риск этого входа — НЕ падение, а протечка словарей: если артефактный судья
// когда-нибудь выдаст SHIP или PASS, это отравит контуры, где на них висят автоматические
// гейты (ceiling-guard в reviewer-loop, гейт деплоя в redwork/lib/autonomy-gate.sh).
// Плюс проверяем, что кодовый путь остался нетронутым.
'use strict'
const fs = require('fs')
const path = require('path')

const ROOT = path.join(__dirname, '..')
const wf = fs.readFileSync(path.join(ROOT, 'workflow', 'artifact-panel.js'), 'utf8')
const reg = JSON.parse(fs.readFileSync(path.join(ROOT, 'roles', 'registry-artifact.json'), 'utf8'))
const panelSrc = fs.readFileSync(path.join(ROOT, 'workflow', 'panel.js'), 'utf8')

let fail = 0
const ok = (c, m) => { if (!c) { console.error('✗', m); fail++ } }

const CODE_VERDICTS = ['SHIP', 'FIX-FIRST', 'PASS', 'FAIL']

// ── 1. Ростер ────────────────────────────────────────────────────────────────
ok(Array.isArray(reg.roles) && reg.roles.length >= 3, 'ростер непустой')
ok(Array.isArray(reg.verdicts) && reg.verdicts.length >= 3, 'словарь вердиктов задан в ростере')
ok(Array.isArray(reg.remainder_classes), 'словарь remainder_class задан')
for (const r of reg.roles) {
  ok(fs.existsSync(path.join(ROOT, r.file)), `${r.name}: файл ${r.file} существует`)
  ok(typeof r.model === 'string' && r.model, `${r.name}: указана model`)
  ok(['scope', 'review', 'judge'].includes(r.phase), `${r.name}: валидная phase (${r.phase})`)
}
const reviewRoles = reg.roles.filter(r => r.phase === 'review')
ok(reviewRoles.length >= 2, `review-ролей ≥2 (одна роль — мнение, а не панель): ${reviewRoles.length}`)
ok(reg.roles.some(r => r.phase === 'judge'), 'в ростере есть судья')
ok(reg.roles.some(r => r.phase === 'scope'), 'в ростере есть scoper')
for (const r of reviewRoles) ok(r.focus && r.focus.length > 40, `${r.name}: осмысленный focus`)

// ── 2. ИЗОЛЯЦИЯ СЛОВАРЕЙ (главный гард) ──────────────────────────────────────
for (const v of CODE_VERDICTS) {
  ok(!reg.verdicts.includes(v), `кодовый вердикт '${v}' НЕ попал в артефактный словарь`)
}
ok(reg.verdicts.includes('READY'), "у артефакта есть достижимое 'готово' (READY)")
// В воркфлоу кодовые вердикты допустимы только внутри запрещающих формулировок.
for (const v of CODE_VERDICTS) {
  const lines = wf.split('\n').filter(l => l.includes(v))
  const bad = lines.filter(l => !/запрещ|⛔|НЕ кодов|не кодов|чужи/i.test(l))
  ok(bad.length === 0,
    `'${v}' в artifact-panel.js встречается только в запрещающем контексте${bad.length ? ` (нашёл: ${bad[0].trim().slice(0, 80)})` : ''}`)
}
ok(/verdict: \{ enum: VERDICTS \}/.test(wf), 'схема судьи берёт enum из ростера, а не хардкодит')

// ── 3. Кодовый путь не тронут ────────────────────────────────────────────────
ok(/enum: \['PASS', 'FAIL', 'NEEDS-WORK', 'UNCERTAIN'\]/.test(panelSrc),
  'panel.js: enum вердиктов на месте (кодовый путь не задет)')
ok(!/artifact/i.test(panelSrc.split('\n').filter(l => /enum:/.test(l)).join('\n')),
  'panel.js: артефактные значения не просочились в его enum-ы')

// ── 4. Контракт входа ────────────────────────────────────────────────────────
ok(/no-registry/.test(wf), 'ростер обязателен: есть явная ошибка no-registry')
ok(/artifactText\.trim\(\)/.test(wf), 'пустой артефакт отсекается')
ok(/telemetryOk/.test(wf) && /A\?\.run_id === 'string'/.test(wf),
  'телеметрия считается по ВХОДУ (урок Ф3), а не по значению')
ok(/run_type: 'artifact'/.test(wf), "metadata помечена run_type: 'artifact'")
ok(/methodology_findings/.test(wf), 'прогон питает ту же петлю самоулучшения (meta-critic)')
ok(/canonLexicon/.test(wf), 'канон линз прокидывается в критика (иначе находки в карантин)')
ok(/selected\.length < 2/.test(wf), 'добор ролей до минимум двух реализован')

// ── 5. Роли: структура файла ─────────────────────────────────────────────────
for (const r of reviewRoles) {
  const src = fs.readFileSync(path.join(ROOT, r.file), 'utf8')
  ok(/^## Checklist/m.test(src), `${r.name}: есть ## Checklist`)
  ok(/^## Output/m.test(src), `${r.name}: есть ## Output`)
  ok(/^## Anti-patterns/m.test(src), `${r.name}: есть ## Anti-patterns`)
  ok(/^## Self-check/m.test(src), `${r.name}: есть ## Self-check`)
  ok(/^\d+\. /m.test(src), `${r.name}: чек-лист пронумерован`)
}
const judgeSrc = fs.readFileSync(path.join(ROOT, 'roles', 'judge-artifact.md'), 'utf8')
// Структурная проверка вместо ловли слов по строкам: упоминать кодовые вердикты в пояснениях
// («READY достижим, в отличие от PASS») — нормально и полезно. Недопустимо другое: чтобы
// кодовый вердикт стоял в КОЛОНКЕ ВЕРДИКТА собственной матрицы роли.
const matrix = (judgeSrc.match(/## Verdict matrix[\s\S]*?(?=\n## )/) || [''])[0]
ok(matrix.length > 0, 'judge-artifact.md: нашёл Verdict matrix')
const cells = matrix.split('\n').filter(l => l.trim().startsWith('|'))
  .map(l => l.split('|').map(c => c.trim())).filter(c => c.length > 2)
  .map(c => c[2]).join(' ')
for (const v of CODE_VERDICTS) {
  ok(!new RegExp(`\\b${v.replace('-', '\\-')}\\b`).test(cells),
    `judge-artifact.md: '${v}' не стоит в колонке вердикта собственной матрицы`)
}
for (const v of reg.verdicts) ok(cells.includes(v), `judge-artifact.md: матрица покрывает '${v}'`)
ok(/Не выдавать `SHIP`/.test(judgeSrc) || /⛔/.test(judgeSrc),
  'judge-artifact.md: есть явный запрет на кодовые вердикты')
ok(/READY/.test(judgeSrc) && /RETHINK/.test(judgeSrc), 'judge-artifact.md описывает свой словарь')
ok(/remainder_class/.test(judgeSrc), 'judge-artifact.md требует remainder_class')

if (fail) { console.error(`\n✗ artifact-test: ${fail} провал(ов)`); process.exit(1) }
console.log(`✓ artifact self-test passed (${reg.roles.length} ролей, изоляция словарей, кодовый путь цел)`)

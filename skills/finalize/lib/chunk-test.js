// chunk-test.js — юнит-тест chunking-логики /finalize БЕЗ агентов.
// Извлекает РЕАЛЬНЫЕ функции splitDiffByFile/groupChunks из workflow/finalize.js и гоняет их,
// чтобы тест не дрейфовал от кода. (Workflow-скрипты не экспортируемы → eval извлечённых определений.)
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
// M_PER_CHUNK берём из исходника, чтобы тест бил по фактической константе
const M = Number((src.match(/const M_PER_CHUNK\s*=\s*(\d+)/) || [])[1] || 100)
// eslint-disable-next-line no-eval
const ctx = eval(`(function(){ const M_PER_CHUNK = ${M};\n${extract('splitDiffByFile')}\n${extract('groupChunks')}\n return { splitDiffByFile, groupChunks } })()`)

const mkdiff = (paths) => paths.map(p =>
  `diff --git a/${p} b/${p}\nindex 111..222 100644\n--- a/${p}\n+++ b/${p}\n@@ -1 +1 @@\n-old\n+new`).join('\n')

let fail = 0
const ok = (c, m) => { if (!c) { console.error('✗', m); fail++ } }

// 1. split по файлам + извлечение пути
const d1 = mkdiff(['src/a.js', 'src/b.js', 'docs/c.md'])
const fb = ctx.splitDiffByFile(d1)
ok(fb.length === 3, `split: 3 файла (got ${fb.length})`)
ok(fb[0].path === 'src/a.js', `split: path[0]=src/a.js (got ${fb[0].path})`)
ok(fb[2].path === 'docs/c.md', `split: path[2]=docs/c.md (got ${fb[2].path})`)
ok(fb[0].block.includes('+new'), 'split: блок содержит тело diff')

// 2. группировка по top-dir, упаковка ≤ M
const many = []
for (let i = 0; i < M; i++) many.push(`src/f${i}.js`)
for (let i = 0; i < 30; i++) many.push(`lib/g${i}.js`)
const chunks = ctx.groupChunks(ctx.splitDiffByFile(mkdiff(many)))
ok(chunks.every(c => c.length <= M), `группы ≤ ${M} файлов`)
const total = chunks.reduce((n, c) => n + c.length, 0)
ok(total === M + 30, `все файлы распределены без потерь (${total} == ${M + 30})`)
ok(chunks.length >= 2, `${M + 30} файлов → ≥2 групп (got ${chunks.length})`)

// 3. маленький набор → одна группа
const small = ctx.groupChunks(ctx.splitDiffByFile(mkdiff(['a.js', 'b.js'])))
ok(small.length === 1 && small[0].length === 2, 'малый набор → 1 группа из 2')

// 4. файл в корне (без /) → dir='.'
const root = ctx.splitDiffByFile(mkdiff(['README.md']))
ok(root[0].path === 'README.md', 'root-файл: путь корректен')

if (fail === 0) { console.log(`✓ chunk-test passed (M_PER_CHUNK=${M})`); process.exit(0) }
else { console.error(`✗ chunk-test FAILED (${fail})`); process.exit(1) }

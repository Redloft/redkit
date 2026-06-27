// redloft Phase C — Landing Builder orchestrator (Workflow tool script).
//
// Зеркалит ~/.claude/skills/redresearch/workflow/research.js. Детерминистская
// оркестрация стадий пайплайна с reviewer-гейтами. Briefing (Phase 0.5) делает
// caller ДО запуска этого скрипта (нужны интерактивные тулы) и передаёт brief сюда.
//
// Поток: research → planning → R1 → sitemap → seo → R2 → content → design → R3 → render.
//   • DR-1: research встроен ЧЕРЕЗ agent() (НЕ nested workflow()).
//   • DR-3: reviewer-гейты R1/R2/R3 = plan-panel judge-паттерн, cap=2, эскалация человеку.
//   • _shared.md §8: «никакой изоляции» — каждая стадия получает query + brief +
//     накопленный Project Context (key_claims пред. стадий) + reviewer-замечания.
//   • Phase C: ♻️-стадии (research/seo/design-визуал/reviewer) ссылаются на реальные
//     скиллы; 🆕-стадии (planning/sitemap/content/design-spec) — тонкие промпты,
//     дописываются в Phase D. Все вызовы — через agent(): стоят токенов ТОЛЬКО на
//     живом прогоне Workflow-тулом (Phase F). Структура проверяется hermetic
//     dry-run харнессом tests/workflow-dryrun.mjs (canned agent(), zero-cost).
//
// Args (object | JSON-string):
//   slug, project_dir, run_id, timestamp, git_rev — correlation/meta
//   mode        — 'lite' | 'full' (DR-2; lite по умолчанию для разработки)
//   query       — исходный запрос пользователя («создай сайт для X»)
//   brief       — { key_claims:[…], site_type, summary } из briefing (Phase B)
//
// Возвращает: { artifacts:{relpath:content}, stage_headers:[…], reviews:{…}, …summary }.
// Caller (/redloft) пишет artifacts на диск + register_artifact/set_stage/set_review
// (Workflow-скрипты не имеют FS-доступа).

export const meta = {
  name: 'redloft-landing-builder',
  description: 'Idea→spec orchestrator: research→planning→sitemap→seo→content→design→render with reviewer gates R1/R2/R3. Outputs ТЗ + промт для Claude Code.',
  phases: [
    { title: 'Research', detail: 'redresearch heavy: бизнес/конкуренты/рынок/ЦА/практики' },
    { title: 'Planning', detail: 'agency-panel: ICP/JTBD/USP/Brief' },
    { title: 'R1',       detail: 'reviewer-gate: позиционирование vs research' },
    { title: 'Semantic', detail: 'redsemantic: keyword universe → intent/content clusters → структура' },
    { title: 'Sitemap',  detail: 'структура/навигация из semantic-кластеров' },
    { title: 'SEO',      detail: 'on-page/GEO-применение semantic-кластеров (без кластеризации)' },
    { title: 'R2',       detail: 'reviewer-gate: sitemap+seo покрывают semantic-кластеры' },
    { title: 'Content',  detail: 'офферы/экраны/FAQ/CTA; GEO-структура' },
    { title: 'Design',   detail: 'коданый прототип: tokens→KIT→hub + контракты; page-design-pipeline' },
    { title: 'R3',       detail: 'reviewer-gate (final): всё согласовано, промт исполним' },
    { title: 'Render',   detail: 'ТЗ + промт для Claude Code (+ RLS-чек, handoff)' },
  ],
}

// ───────────────────────── args ─────────────────────────
let A = args
if (typeof args === 'string') { try { A = JSON.parse(args) } catch { A = { query: args } } }
const slug       = A?.slug || 'site'
const projectDir = A?.project_dir || ''
const mode       = (A?.mode === 'full') ? 'full' : 'lite'      // DR-2
const runId      = A?.run_id || 'unknown-run-id'
const timestamp  = A?.timestamp || 'unknown'                    // Date.* запрещён в скриптах
const gitRev     = A?.git_rev || 'unknown'
const query      = A?.query || 'NO_QUERY_PROVIDED'
const brief      = (A?.brief && typeof A.brief === 'object') ? A.brief : {}
const briefClaims = Array.isArray(brief.key_claims) ? brief.key_claims : []
const siteType   = brief.site_type || 'landing'
const REVIEWER_CAP = 2                                          // DR-3

log(`redloft landing-builder · slug=${slug} · mode=${mode} · run_id=${runId} · site_type=${siteType}`)
if (query === 'NO_QUERY_PROVIDED') log(`⚠️  query not provided (typeof args=${typeof args})`)
if (!briefClaims.length) log('⚠️  brief.key_claims пуст — briefing (Phase B) должен был наполнить его')

// ───────────────────────── schemas ─────────────────────────
const STAGE_SCHEMA = {
  type: 'object',
  required: ['artifact_type', 'key_claims', 'body_md'],
  additionalProperties: true,
  properties: {
    artifact_type: { type: 'string' },
    key_claims: { type: 'array', items: { type: 'string' }, minItems: 1, maxItems: 7 },
    body_md: { type: 'string' },
    summary: { type: 'string' },
  },
}
const REVIEW_SCHEMA = {
  type: 'object',
  required: ['verdict', 'confidence'],
  additionalProperties: true,
  properties: {
    verdict: { enum: ['PASS', 'NEEDS-WORK', 'FAIL'] },
    confidence: { type: 'number', minimum: 0, maximum: 1 },
    findings: { type: 'array', items: { type: 'object' } },
    summary: { type: 'string' },
  },
}
const RENDER_SCHEMA = {
  type: 'object',
  required: ['tz_md', 'prompt_md', 'tz_key_claims', 'prompt_key_claims'],
  additionalProperties: true,
  properties: {
    tz_md: { type: 'string' },
    prompt_md: { type: 'string' },
    tz_key_claims: { type: 'array', items: { type: 'string' }, minItems: 1, maxItems: 7 },
    prompt_key_claims: { type: 'array', items: { type: 'string' }, minItems: 1, maxItems: 7 },
    summary: { type: 'string' },
  },
}

const SKILL = '~/.claude/skills/redloft'

// Stage role-specs (DR-4): для 🆕-стадий суб-агент ЧИТАЕТ полный промпт-файл
// stages/<name>/prompt.md (зеркало redresearch roleRef); inline-instruction —
// fallback. research → redresearch (♻️), render → собирает оркестратор.
const STAGE_SPECS = new Set(['planning', 'semantic', 'sitemap', 'content', 'design'])
const stageRef = (name) =>
  `Прочитай stage-spec ${SKILL}/stages/${name}/prompt.md и следуй ему пунктуально. ` +
  `Контракт (artifact-header §3, input envelope §8, security §9) — ${SKILL}/_shared.md. ` +
  `Если файл недоступен — следуй inline-инструкции ниже. `

// Artifact YAML front-matter (_shared.md §3). Скрипт без FS — инлайн-зеркало
// lib/context.sh artifact_header_yaml. key_claims как YAML-safe quoted scalars.
function header(artifactType, stageId, sourceStage, keyClaims) {
  const claims = (keyClaims && keyClaims.length ? keyClaims : ['(none)'])
    .slice(0, 7).map(c => '  - ' + JSON.stringify(String(c))).join('\n')
  return [
    '---',
    `artifact_type: ${artifactType}`,
    `stage_id: ${stageId}`,
    'schema_version: 1',
    `produced_at: ${timestamp}`,
    `source_stage: ${sourceStage}`,
    'key_claims:',
    claims,
    '---',
  ].join('\n')
}

// 🔒 DR-7: non-skippable RLS deny-by-default шаг — оркестратор ГАРАНТИРУЕТ его
// присутствие в prompt.md независимо от того, что вернул design/render-агент.
const RLS_STEP = [
  '## 🔒 ОБЯЗАТЕЛЬНЫЙ ШАГ БЕЗОПАСНОСТИ (НЕ ПРОПУСКАТЬ) — RLS deny-by-default',
  'После генерации схемы Supabase, ДО любого деплоя:',
  '- включить **RLS на ВСЕХ таблицах** (`alter table … enable row level security`);',
  '- политика **deny-by-default**: без явной allow-политики доступа нет;',
  '- запись только через серверный route с service_role (ключ только на сервере); клиент (anon) без прямого доступа на запись;',
  '- проверить: ни одна таблица не доступна анонимно на чтение/запись сверх задуманного.',
  'Без этого шага задача НЕ считается выполненной (прямой урок Lovable).',
].join('\n')

// DR-7: handoff-чеклист (secret-rotation) — оркестратор ГАРАНТИРУЕТ его в tz.md.
const HANDOFF_CHECKLIST = [
  '## Handoff — передача клиенту (self-serve Supabase Project Transfer, DR-7)',
  '1. **Project Transfer** в org клиента: один регион; ПРЕДВАРИТЕЛЬНО отключить GitHub-интеграцию, log drains, project-scoped роли (downtime 1-2 мин при downgrade на Free).',
  '2. Клиент **ротирует секреты**: JWT secret + anon + service_role ключи.',
  '3. Agency **удаляет** все env-ссылки на ключи клиента (иначе сохраняется доступ к данным).',
  '4. Передать доступы к хостингу/домену; снять agency-доступы.',
  '5. (PII) удалить рабочие копии контактов: `lib/purge_project.sh <slug> --purge-contacts`.',
].join('\n')

// Post-build gate — оркестратор ГАРАНТИРУЕТ в prompt.md: после сборки кода (downstream
// Claude Code по этому промту) → /finalize (стабилизация + multi-role код-ревью diff) →
// /audit-site (perf/CWV/SEO/GEO) → fix → ship. Это пост-сборочный шаг (redloft отдаёт
// спек, код собирается отдельно), потому живёт в выходном промте, а не как стадия.
const POSTBUILD_GATE = [
  '## ✅ Пост-сборка — обязательный гейт перед публикацией (НЕ ПРОПУСКАТЬ)',
  'После генерации кода лендинга по этому промту, ДО деплоя, прогнать в порядке:',
  '1. **`/finalize`** — стабилизация (typecheck/lint/build/test + автофикс) + многоролевое код-ревью git diff. Вердикт SHIP / FIX-FIRST / NEEDS-WORK; при FIX-FIRST исправить критичные findings и повторить.',
  '2. **`/audit-site`** (performance) — Lighthouse Core Web Vitals (LCP/CLS/INP), image delivery, SEO, GEO, cache. Исправить регрессии (цель — зелёная зона CWV).',
  '3. Публиковать только при `/finalize` = SHIP И зелёном perf-аудите. RLS-проверка (шаг выше) входит в гейт.',
].join('\n')

// 🌍 GEO-ДОСТУПНОСТЬ (паттерн «RU edge → self-hosted origin»). Включается ТОЛЬКО когда
// аудитория «РФ + заграница» (geoEdge). Решает: сайт открывается и в РФ, и в Украине/ЕС
// (российский IP режется Украиной; Vercel/иностранные CDN режутся в РФ-сетях). $0, без geo-DNS.
const GEO_EDGE_TZ = [
  '## 🌍 Деплой и geo-доступность (аудитория РФ + заграница) — ОБЯЗАТЕЛЬНО',
  'Проблема: один origin-IP где-то блокируется (RU-IP режет Украина; Vercel/иностранный CDN режется в РФ-сетях/Китае). Решение — паттерн **«RU edge → self-hosted origin»** ($0, без geo-DNS):',
  '- **DNS:** одна A-запись домена → **российский edge-VPS** (напр. Beget, РФ-IP). DNS держать на **Cloudflare в режиме DNS-only** (БЕЗ оранжевого облака/прокси — Cloudflare-прокси/ECH блокируется РКН).',
  '- **RU-edge VPS:** nginx, TLS-терминация (Let\'s Encrypt/certbot), reverse-proxy `proxy_pass https://<origin>` с `proxy_ssl_verify off`, проброс `Host $host` + `X-Forwarded-*`.',
  '- **Origin (зарубежный VPS, напр. Hetzner Helsinki):** nginx отдаёт СТАТИКУ SSG/SPA (`root .../build; try_files $uri $uri/index.html /index.html`) ИЛИ проксирует на бэкенд (Supabase/Node `/api`).',
  '- **Результат:** РКН/регулятор видит только локальный RU-IP; иностранный бэкенд скрыт; домен достижим из РФ И из Украины/ЕС.',
  '**Требования к деплою (включить как acceptance):**',
  '1. НЕ ставить Vercel/иностранный CDN прямым origin страниц для RU-аудитории — только build-инструмент или бэкенд `/api` (через proxy с origin-VPS).',
  '2. Cloudflare — DNS-only (без прокси).  3. TLS терминируется на RU-edge; edge→origin — `proxy_ssl_verify off` (внутр.).',
  '4. Деплой статики: `rsync build/ → origin:/opt/projects/<proj>/build/` (после сборки; вручную/CI).  5. Откат — одна строка `proxy_pass` + DNS-запись.',
  '6. ⚠️ **Китай этим НЕ решается** (RU-фронт режется GFW) — отдельный трек: ICP-лицензия + китайский CDN (Alibaba/Tencent).',
  'Референс рабочей реализации: проекты **wellbookin / samudro** (TOM1 Beget RU 155.212.147.184 → Hetzner Helsinki 204.168.217.59). Детали — 1Password «Geo-edge chain (RU+world): TOM1 → Hetzner» + ClaudeCore `apis/cloudflare.md`.',
].join('\n')

const GEO_EDGE_PROMPT = [
  '## 🌍 ОБЯЗАТЕЛЬНЫЙ ШАГ ДЕПЛОЯ — geo-доступность РФ+заграница (НЕ ПРОПУСКАТЬ)',
  'Аудитория РФ+мир → показ страниц через **RU-edge → self-hosted origin** (Vercel остаётся ТОЛЬКО build/`/api`, НЕ прямой origin страниц для RU). Конфиги:',
  '**RU-edge VPS (РФ-IP, напр. Beget) — `/etc/nginx/.../<domain>.conf`:**',
  '```nginx',
  'server {',
  '  listen 443 ssl http2; server_name <domain>;',
  '  ssl_certificate     /etc/letsencrypt/live/<domain>/fullchain.pem;',
  '  ssl_certificate_key /etc/letsencrypt/live/<domain>/privkey.pem;',
  '  location / {',
  '    proxy_pass https://<ORIGIN_IP_OR_HOST>;',
  '    proxy_ssl_verify off;',
  '    proxy_set_header Host $host;',
  '    proxy_set_header X-Real-IP $remote_addr;',
  '    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;',
  '    proxy_set_header X-Forwarded-Proto $scheme;',
  '  }',
  '}',
  '```',
  '**Origin VPS (зарубежный, напр. Hetzner) — статика SSG/SPA:**',
  '```nginx',
  'server {',
  '  listen 443 ssl; server_name <domain>;',
  '  root /opt/projects/<proj>/build;',
  '  location / { try_files $uri $uri/index.html /index.html; }',
  '  # бэкенд (опц.): location /api/ { proxy_pass http://127.0.0.1:<port>; }',
  '}',
  '```',
  '**DNS (Cloudflare, DNS-only — БЕЗ прокси/оранжевого облака):** `A <domain> → <RU_EDGE_IP>` (proxied=false).',
  '**Деплой статики:** `rsync -az build/ origin:/opt/projects/<proj>/build/`. **Откат:** сменить `proxy_pass` + A-запись.',
  '⚠️ Китай не покрывается (GFW режет RU-фронт) — если нужен, отдельно: ICP + китайский CDN.',
].join('\n')

// 📦 DR-8 ГАРАНТИЯ: методологическая коробка. prompt.md ОБЯЗАН содержать Шаг 0
// разворачивания коробки. Tier-agnostic (финальный tier выбирает caller; число —
// в methodology/.methodology-version и CLAUDE.md). Сами файлы кладёт lib/methodology.sh
// (caller-side, как build-hub.sh — Workflow без FS). См. METHODOLOGY-KIT-SPEC.md §6.1.
const METHODOLOGY_PROMPT_STEP = [
  '## Шаг 0 (обязательный, не пропускать) — Развернуть методологическую коробку',
  'В корне репо лежит папка `methodology/` (приехала с этим ТЗ; её tier — в `methodology/.methodology-version` и `CLAUDE.md`).',
  '1. ПЕРЕД копированием прогони по `methodology/` поиск реальных токенов/секретов (`grep -rIn` на token-shapes) — если нашёл, СТОП и сообщи.',
  '2. Скопируй содержимое `methodology/` в корень репо.',
  '3. **Прочитай `START-HERE.md` — это инструкция, как работать над проектом.** Затем `CLAUDE.md` и `docs/HARD-RULES.md`.',
  '4. Применить `supabase/rls-bootstrap.sql` (RLS deny-by-default) ДО первого деплоя.',
  '5. Первый коммит: `chore: methodology kit` в рабочую ветку (НЕ в main/dev).',
  '6. Дальше веди работу по `START-HERE.md` / `docs/tasks/PROTOCOL.md` (lifecycle pending→ready→in_progress→done).',
].join('\n')

const METHODOLOGY_TZ_NOTE = [
  '## Методология проекта (из коробки)',
  'Вместе с ТЗ поставляется папка `methodology/` — рабочая методология, пред-заполненная под проект:',
  '- `START-HERE.md` — как вести работу (рабочий цикл за минуту);',
  '- `CLAUDE.md` — карта проекта для AI-чатов;',
  '- `docs/HARD-RULES.md` — правила (branch/commit, quality gate, security: RLS/секреты/PII);',
  '- `docs/tasks/` — жизненный цикл задач, засеян по разделам сайта (в `pending/`);',
  '- `supabase/rls-bootstrap.sql` — RLS deny-by-default.',
  'Разворачивается первым шагом — см. промт для Claude Code, «Шаг 0».',
].join('\n')

// Project Context accumulator — «никакой изоляции» (_shared.md §8).
const ctx = { stages: {} }                 // stages[name] = { artifact_type, key_claims, summary }
const artifacts = {}                        // relpath → content (caller пишет на диск)
const stageHeaders = []                     // [{artifact_type, stage_id, source_stage, key_claims, path}]
const reviews = {}                          // R1/R2/R3 → {verdict, confidence, iteration, escalated, …}

function ctxDigest() {
  const lines = Object.entries(ctx.stages)
    .map(([k, v]) => `[${k}] ${(v.key_claims || []).join(' · ')}`)
  return lines.length ? lines.join('\n') : '(пока пусто)'
}

function envelope(extra = '') {
  return (
    `=== QUERY ===\n${query}\n=== END ===\n` +
    `=== BRIEF (key_claims, site_type=${siteType}) ===\n${briefClaims.join('\n') || '(брифинг не передал claims)'}\n=== END ===\n` +
    `=== PROJECT CONTEXT (key_claims пред. стадий) ===\n${ctxDigest()}\n=== END ===\n` +
    (extra ? `${extra}\n` : '')
  )
}

// ───────────────────────── stage runner ─────────────────────────
// reuseSkill: ♻️ существующий скилл-паттерн. instruction: что произвести.
// critique: замечания reviewer при переигровке (no-isolation).
async function runStage(name, { artifactType, sourceStage, path, reuseSkill, instruction, phaseTitle }, critique = '') {
  phase(phaseTitle || name)
  const isReuse = !!reuseSkill
  const out = await agent(
    `Ты — стадия «${name}» оркестратора REDLOFT (mode=${mode}). ` +
    (STAGE_SPECS.has(name)
      ? stageRef(name)                                    // DR-4: читай stages/<name>/prompt.md
      : (isReuse ? `Используй паттерн/скилл: ${reuseSkill}. ` : '')) +
    `Контракт артефакта — ${SKILL}/_shared.md §3: верни artifact_type="${artifactType}", 1-7 key_claims (главные тезисы для reviewer и downstream), body_md (тело артефакта).\n` +
    `Принцип «никакой изоляции»: опирайся на Project Context ниже, НЕ начинай с нуля.\n\n` +
    envelope() +
    (critique ? `=== ЗАМЕЧАНИЯ REVIEWER (переиграть с учётом) ===\n${critique}\n=== END ===\n\n` : '\n') +
    `ЗАДАЧА: ${instruction}\n\n` +
    `Верни JSON по STAGE_SCHEMA. body_md — готовое тело артефакта (без YAML-заголовка, его добавит оркестратор).`,
    { label: name, phase: phaseTitle || name, schema: STAGE_SCHEMA }
  )
  if (!out) { log(`✗ stage ${name} failed (agent вернул null)`); return null }
  const keyClaims = (out.key_claims && out.key_claims.length) ? out.key_claims : ['(stage не вернул claims)']
  ctx.stages[name] = { artifact_type: artifactType, key_claims: keyClaims, summary: out.summary || '' }
  artifacts[path] = `${header(artifactType, name, sourceStage, keyClaims)}\n\n${out.body_md || ''}`
  stageHeaders.push({ artifact_type: artifactType, stage_id: name, source_stage: sourceStage, key_claims: keyClaims, path })
  log(`✓ stage ${name}: ${keyClaims.length} key_claims → ${path}`)
  return out
}

// ───────────────────────── reviewer gate (DR-3) ─────────────────────────
// plan-panel judge-паттерн: читает key_claims заголовков, ищет противоречия/пробелы.
// cap=2; при NEEDS-WORK/FAIL переигрывает gated-стадию с critique; иначе эскалация.
async function reviewGate(gateId, gateAfter, stagesUnderReview, rerun) {
  let iteration = 0, verdict = 'NEEDS-WORK', confidence = 0, findings = []
  while (iteration < REVIEWER_CAP && verdict !== 'PASS') {
    iteration++
    phase(gateId)
    const r = await agent(
      `Ты — reviewer-gate ${gateId} оркестратора REDLOFT (after «${gateAfter}»). ` +
      `Прочитай reviewer-spec ${SKILL}/stages/reviewer/prompt.md и применяй ИМЕННО секцию ${gateId} (чеклист + verdict-рубрика). Если файл недоступен — следуй inline-критериям ниже. ` +
      `Паттерн plan-panel judge (DR-3): читай key_claims заголовков стадий (НЕ прозу). Ищи противоречия между стадиями, пробелы покрытия, рассинхрон с brief/research.\n\n` +
      `=== СТАДИИ НА РЕВЬЮ (headers) ===\n` +
      stagesUnderReview.map(s => `[${s}] ${(ctx.stages[s]?.key_claims || []).join(' · ') || '(нет claims)'}`).join('\n') +
      `\n=== END ===\n\n` +
      envelope() +
      `Верни JSON по REVIEW_SCHEMA: verdict (PASS|NEEDS-WORK|FAIL), confidence 0-1, findings[] {severity, stage, issue}.`,
      { label: `${gateId}#${iteration}`, phase: gateId, schema: REVIEW_SCHEMA }
    )
    verdict = r?.verdict || 'NEEDS-WORK'
    confidence = (typeof r?.confidence === 'number') ? r.confidence : 0
    findings = r?.findings || []
    log(`${gateId} iter ${iteration}/${REVIEWER_CAP}: ${verdict} (conf ${confidence})`)
    if (verdict === 'PASS') break
    if (iteration < REVIEWER_CAP && typeof rerun === 'function') {
      const critique = findings.map(f => `• [${f.severity || 'info'}] ${f.stage || gateAfter}: ${f.issue || f.note || JSON.stringify(f)}`).join('\n')
      log(`${gateId} ${verdict} → переигрываю «${gateAfter}» с замечаниями`)
      await rerun(critique)
    }
  }
  const escalated = verdict !== 'PASS'
  if (escalated) log(`⚠️  ${gateId} ЭСКАЛАЦИЯ человеку после cap=${REVIEWER_CAP} (verdict=${verdict})`)
  const notes = escalated ? findings.map(f => f.issue || f.note || JSON.stringify(f)).join('; ') : null
  reviews[gateId] = { gate_after: gateAfter, verdict, confidence, iteration, escalated, findings, notes }
  artifacts[`reviews/${gateId}.md`] =
    `${header('review', gateAfter, gateAfter, [`${gateId} ${verdict} (conf ${confidence})`, ...findings.slice(0, 3).map(f => f.issue || 'finding')])}\n\n` +
    `# Reviewer ${gateId} — after ${gateAfter}\n\n- verdict: **${verdict}**\n- confidence: ${confidence}\n- iteration: ${iteration}/${REVIEWER_CAP}\n- escalated: ${escalated}\n\n## Findings\n` +
    (findings.length ? findings.map(f => `- [${f.severity || 'info'}] ${f.stage || ''}: ${f.issue || f.note || ''}`).join('\n') : '- (none)')
  stageHeaders.push({ artifact_type: 'review', stage_id: gateAfter, source_stage: gateAfter, key_claims: [`${gateId} ${verdict}`], path: `reviews/${gateId}.md` })
  return reviews[gateId]
}

// ═══════════════════════ PIPELINE ═══════════════════════

// Phase 1 — RESEARCH (DR-1: встроен через agent(), НЕ nested workflow)
await runStage('research', {
  artifactType: 'research', sourceStage: 'briefing', path: 'research/report.md',
  reuseSkill: `redresearch (${mode === 'full' ? 'heavy' : 'lite/standard'}; запусти его pipeline через agent, НЕ nested workflow)`,
  instruction: 'Исследуй бизнес, конкурентов, рынок, ЦА и лучшие практики ниши. Собери кандидаты-референсы для post-briefing. Дай cited-выводы (cite-coverage по mode).',
  phaseTitle: 'Research',
})

// Phase 2 — PLANNING → R1
const planningDef = {
  artifactType: 'planning', sourceStage: 'research', path: 'planning/planning.md',
  reuseSkill: 'agency-panel (Phase D; паттерн plan-panel ролей CEO/PM/UX/Marketing/SEO/Dev)',
  instruction: 'Выведи ICP, JTBD, USP-иерархию и продуктовый Brief. Привяжи USP к ICP/JTBD. Определи главный и вторичный CTA.',
  phaseTitle: 'Planning',
}
await runStage('planning', planningDef)
await reviewGate('R1', 'planning', ['research', 'planning'], (critique) => runStage('planning', planningDef, critique))

// Phase 2.5 — SEMANTIC (♻️ redsemantic; ПОСЛЕ planning, ДО sitemap — семантика
// диктует структуру). Стадия читает stages/semantic/prompt.md (STAGE_SPECS),
// который инструктирует прогнать redsemantic-пайплайн.
await runStage('semantic', {
  artifactType: 'semantic', sourceStage: 'planning', path: 'semantic/semantic.md',
  reuseSkill: 'redsemantic (запусти его pipeline через agent, НЕ nested workflow; mode по REDLOFT_MODE)',
  instruction: 'Собери семантику ниши: keyword universe (живая частотность через адаптеры) → intent/content clusters → предложение структуры сайта + SEO-страницы + блог + FAQ + entities + linking. Семантика диктует структуру для sitemap.',
  phaseTitle: 'Semantic',
})

// Phase 3 — SITEMAP (структура ВЕДОМА semantic-кластерами)
await runStage('sitemap', {
  artifactType: 'sitemap', sourceStage: 'semantic', path: 'sitemap/sitemap.md',
  reuseSkill: 'sitemap-скилл (Phase D; Relume-стиль)',
  instruction: 'Спроектируй структуру/навигацию ИЗ semantic content/intent-кластеров (каждая секция ← кластер; не плодить разделы без кластера). Для лендинга — секции + якоря; H1/H2-скелет из кластеров. Порядок ведёт от атмосферы к доверию к действию.',
  phaseTitle: 'Sitemap',
})

// Phase 4 — SEO → R2 (БОЛЬШЕ НЕ кластеризует — кластеры пришли из semantic;
// здесь on-page/GEO-применение)
const seoDef = {
  artifactType: 'seo', sourceStage: 'sitemap', path: 'seo/seo.md',
  reuseSkill: 'audit-site (SEO/GEO-блоки)',
  instruction: 'On-page/GEO-применение ГОТОВЫХ semantic-кластеров (НЕ кластеризуй заново): маппинг кластеров на H1/H2 экранов sitemap, title/description, schema из semantic.entities, GEO-структура «прямой ответ→контекст→FAQ», FAQ/Article schema, llms-full.txt, robots для ИИ-ботов. Без keyword stuffing.',
  phaseTitle: 'SEO',
}
await runStage('seo', seoDef)
await reviewGate('R2', 'seo', ['semantic', 'sitemap', 'seo'], (critique) => runStage('seo', seoDef, critique))

// Phase 5 — CONTENT
await runStage('content', {
  artifactType: 'content', sourceStage: 'seo', path: 'content/content.md',
  reuseSkill: 'content-copy (Phase D) + content-gen (визуал) + humanizer (анти-AI)',
  instruction: 'Напиши офферы/экраны/FAQ/CTA под sitemap+SEO. GEO-структура. Тон из brief. Прогон через humanizer.',
  phaseTitle: 'Content',
})

// Phase 6 — DESIGN → R3 (final). Парадигма: дизайн-система НА КОДЕ, не AI-мокапы.
// Workflow-агент возвращает БЛЮПРИНТ (design.md: концепция + токены + KIT-карта + контракты);
// материализацию прототипа (templates → tokens.css → components.html/index.html → lib/build-hub.sh →
// локальный сервер + парные light/dark скриншоты) делает caller (commands/redloft.md шаг 6b),
// т.к. у workflow-агента нет FS/сервера. hub.html — АВТО-генерируется build-hub.sh (не вручную).
const designDef = {
  artifactType: 'design', sourceStage: 'content', path: 'design/design.md',
  reuseSkill: 'page-design-pipeline / emil-design-eng / animate + design-spec (Phase D)',
  instruction: 'Дизайн-система НА КОДЕ (gate-цепочка stages/design/prompt.md): концепция (1 фраза) → реальные tokens.css из visual-taste-profile → нулевой контракт kit-contracts (DoD/state-matrix/perf/a11y/P0/152-ФЗ) → KIT-карта (секция sitemap→компоненты+состояния; overlays glass+rounded+origin-aware) → motion (Ковальски) → парная light/dark проверка → hub (build-hub.sh). Верни БЛЮПРИНТ для materialization: токены реальными значениями, KIT покрывает ВСЮ карту, ссылки на templates. Перед большим KIT — план через plan-panel (контракты, не намерения). Планка кода = v0 (TS+shadcn, без any) на supastarter.',
  phaseTitle: 'Design',
}
await runStage('design', designDef)
await reviewGate('R3', 'design', ['content', 'design'], (critique) => runStage('design', designDef, critique))

// 🌍 geoEdge: аудитория «РФ + заграница»? (эвристика по query/brief/стадиям; либо явный флаг).
// Сигнал проблемы: «открывается в РФ, но не в Украине/ЕС» (или наоборот) из-за одного origin-IP.
const _geoText = `${query}\n${briefClaims.join('\n')}\n${ctxDigest()}`.toLowerCase()
const _hasRU = /\bрф\b|росси|russia|москв|санкт|спб|\bru\b/.test(_geoText)
const _hasAbroad = /украин|европ|загранич|зарубеж|\bес\b|\beu\b|международ|\bworld\b|global|abroad|ukrain|europe/.test(_geoText)
const geoEdge = (A?.geo_edge === true) || (_hasRU && _hasAbroad)
if (geoEdge) log('🌍 geoEdge: аудитория РФ+заграница → паттерн RU-edge→origin будет в ТЗ+промте')

// Phase 7 — RENDER (ТЗ + промт; оркестратор гарантирует RLS-шаг)
phase('Render')
const render = await agent(
  `Ты — render-стадия оркестратора REDLOFT. Собери ДВА финальных артефакта из всего Project Context:\n` +
  `1) tz_md — полное ТЗ на сайт (цель/метрики, стек Next.js+Supabase на supastarter-базе, структура из sitemap, контент из content, токены из design, данные/таблицы, handoff-чеклист с secret-rotation после Supabase Project Transfer).\n` +
  `2) prompt_md — промт для Claude Code (генерит на supastarter-базе, планка v0: TS+shadcn, без any). ДОЛЖЕН включать non-skippable RLS deny-by-default чек-шаг.\n` +
  (geoEdge ? `3) Аудитория РФ+заграница: ОБЯЗАТЕЛЬНО раздел «Деплой и geo-доступность» (паттерн RU-edge→self-hosted origin) в tz_md, и конкретные nginx-блоки (edge reverse-proxy + origin static) + DNS-инструкции в prompt_md. Vercel — только build/API, НЕ прямой origin страниц.\n` : '') +
  `\n` +
  envelope() +
  `Верни JSON по RENDER_SCHEMA: tz_md, prompt_md, tz_key_claims (1-7), prompt_key_claims (1-7).`,
  { label: 'render', phase: 'Render', schema: RENDER_SCHEMA }
)

let tzMd = render?.tz_md || '# ТЗ\n(render не вернул содержимое)'
let promptMd = render?.prompt_md || '# Промт для Claude Code\n(render не вернул содержимое)'
const tzClaims = (render?.tz_key_claims && render.tz_key_claims.length) ? render.tz_key_claims : ['ТЗ собрано из артефактов стадий']
const promptClaims = (render?.prompt_key_claims && render.prompt_key_claims.length) ? render.prompt_key_claims : ['Промт для Claude Code на supastarter-базе']

// 🔒 DR-7 ГАРАНТИЯ: RLS-шаг обязан быть в prompt.md, что бы ни вернул агент.
if (!/RLS/.test(promptMd) || !/deny-by-default/i.test(promptMd)) {
  promptMd += `\n\n${RLS_STEP}`
  log('Render: RLS deny-by-default шаг добавлен оркестратором (DR-7 гарантия)')
}

// 🔒 DR-7 ГАРАНТИЯ: handoff-чеклист с secret-rotation в tz.md, что бы ни вернул агент.
if (!/Handoff/i.test(tzMd) || !/ротир/i.test(tzMd)) {
  tzMd += `\n\n${HANDOFF_CHECKLIST}`
  log('Render: handoff-чеклист (secret-rotation) добавлен оркестратором (DR-7 гарантия)')
}

// ГАРАНТИЯ: пост-сборочный гейт (finalize → audit-site) в prompt.md.
if (!/\/finalize/.test(promptMd) || !/audit-site/.test(promptMd)) {
  promptMd += `\n\n${POSTBUILD_GATE}`
  log('Render: пост-сборка гейт (finalize → audit-site) добавлен оркестратором')
}

// 🌍 ГАРАНТИЯ: для аудитории РФ+заграница — паттерн geo-доступности в ТЗ и промте.
if (geoEdge) {
  if (!/geo-доступност/i.test(tzMd) || !/RU.?edge|self-hosted origin/i.test(tzMd)) {
    tzMd += `\n\n${GEO_EDGE_TZ}`
    log('Render: раздел geo-доступности (RU-edge→origin) добавлен в ТЗ (geoEdge гарантия)')
  }
  if (!/proxy_pass/i.test(promptMd) || !/proxy_ssl_verify/i.test(promptMd)) {
    promptMd += `\n\n${GEO_EDGE_PROMPT}`
    log('Render: nginx-блоки edge/origin + DNS добавлены в промт (geoEdge гарантия)')
  }
}

// 📦 DR-8 ГАРАНТИЯ: Шаг 0 разворачивания коробки в prompt.md, что бы ни вернул агент.
// Якорь — заголовочная фраза «Шаг 0 … методологическ» (а не подстрока methodology/,
// которую агент мог упомянуть мимоходом → false-positive и пропуск гарантии).
if (!/##\s*Шаг 0[^\n]*методологическ/i.test(promptMd)) {
  promptMd += `\n\n${METHODOLOGY_PROMPT_STEP}`
  log('Render: Шаг 0 (методологическая коробка) добавлен в промт (DR-8 гарантия)')
}
// 📦 DR-8 ГАРАНТИЯ: раздел «Методология проекта» в tz.md (якорь — заголовок ##).
if (!/^##\s*Методология проекта/im.test(tzMd)) {
  tzMd += `\n\n${METHODOLOGY_TZ_NOTE}`
  log('Render: раздел «Методология проекта» добавлен в ТЗ (DR-8 гарантия)')
}

ctx.stages['render'] = { artifact_type: 'tz', key_claims: tzClaims, summary: render?.summary || '' }
artifacts['tz.md'] = `${header('tz', 'render', 'design', tzClaims)}\n\n${tzMd}`
artifacts['prompt.md'] = `${header('prompt', 'render', 'design', promptClaims)}\n\n${promptMd}`
stageHeaders.push({ artifact_type: 'tz', stage_id: 'render', source_stage: 'design', key_claims: tzClaims, path: 'tz.md' })
stageHeaders.push({ artifact_type: 'prompt', stage_id: 'render', source_stage: 'design', key_claims: promptClaims, path: 'prompt.md' })
log(`✓ render: tz.md + prompt.md (RLS-чек ${/deny-by-default/i.test(promptMd) ? 'present' : 'MISSING'})`)

// ───────────────────────── return ─────────────────────────
const anyEscalated = Object.values(reviews).some(r => r.escalated)
const overallVerdict = anyEscalated ? 'escalated' : (Object.values(reviews).every(r => r.verdict === 'PASS') ? 'PASS' : 'NEEDS-WORK')

// ═══ META-CRITIC — системный пробел ПАЙПЛАЙНА (не разовость проекта)? → ledger → solidify ═══
const CRITIC_SCHEMA = {
  type: 'object', required: ['methodology_findings'], additionalProperties: true,
  properties: { methodology_findings: { type: 'array', items: {
    type: 'object', required: ['role', 'lens_key', 'severity', 'observation', 'proposed_checklist_delta'], additionalProperties: true,
    properties: {
      role: { type: 'string', minLength: 1 }, lens_key: { type: 'string', minLength: 1 },
      severity: { enum: ['critical', 'warning', 'suggestion'] },
      observation: { type: 'string', minLength: 1 }, proposed_checklist_delta: { type: 'string', minLength: 1 },
    },
  } } },
}
const allFindings = Object.entries(reviews).flatMap(([gate, r]) => (r.findings || []).map(f => ({ gate, ...f })))
const critic = await agent(
  `Ты — methodology-critic для redloft. НЕ оценивай этот лендинг-спек по содержанию. Задача: по findings reviewer-гейтов R1/R2/R3 понять, не вскрылся ли СИСТЕМНЫЙ пробел в НАШЕМ ПАЙПЛАЙНЕ (стадия/гейт, который должен ловить класс проблем в ЛЮБОМ проекте), а не разовость этого проекта.\n` +
  `Примеры: «planning не фиксирует X», «sitemap не сверяется с semantic-кластерами по Y», «reviewer R2 не проверяет Z».\n` +
  `Для каждого: { role (стадия: research|planning|sitemap|seo|content|design|render|reviewer), lens_key (стабильный kebab-слаг), severity, observation, proposed_checklist_delta (одна фраза) }. Нет системных пробелов → []. НЕ выдумывай.\n\n` +
  `=== REVIEWER FINDINGS (R1/R2/R3) ===\n${JSON.stringify(allFindings, null, 2)}\n=== END ===\n\nВерни JSON по схеме.`,
  { label: 'meta-critic', phase: 'R3', model: 'sonnet', schema: CRITIC_SCHEMA }
)
const methodologyFindings = (critic && Array.isArray(critic.methodology_findings)) ? critic.methodology_findings : []
if (methodologyFindings.length) log(`🧠 meta-critic: ${methodologyFindings.length} системных пробелов пайплайна → ledger`)
const learningsEntry = {
  ts: timestamp, skill: 'redloft', run_id: runId, mode,
  verdict: overallVerdict, escalated: anyEscalated,
  gaps: allFindings.map(f => f.issue || '').filter(Boolean).slice(0, 10),
  methodology_findings: methodologyFindings,
}
artifacts['learnings.entry.json'] = JSON.stringify(learningsEntry)

return {
  artifacts,
  stage_headers: stageHeaders,
  reviews,
  learnings_entry: learningsEntry,
  slug, run_id: runId, timestamp, mode, git_rev: gitRev, site_type: siteType,
  // 📦 DR-8: подсказка тира для caller (он уточнит по semantic-кластерам + предложит Tier 3 при geoEdge).
  methodology_tier_hint: (/(ecommerce|e-commerce|shop|store|catalog|multi.?page|multi.?entity|marketplace)/i.test(siteType) ? 2 : 1),
  methodology_offer_tier3: geoEdge,
  verdict: overallVerdict,
  escalated: anyEscalated,
  stages_done: Object.keys(ctx.stages),
  summary: `redloft ${slug}: ${Object.keys(ctx.stages).length} стадий, reviews ${Object.entries(reviews).map(([k, v]) => `${k}=${v.verdict}`).join('/')}${anyEscalated ? ' (ESCALATED)' : ''}`,
}

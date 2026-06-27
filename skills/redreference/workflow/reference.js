// redreference Phase A — orchestrator workflow (skeleton)
//
// Модель redresearch/redloft, применённая к курированию дизайн-референсов:
//   brief → hunt(adapters) → curate → page(render) → round(feedback loop) → render.
// Зеркалит ~/.claude/skills/redresearch/workflow/research.js. Детерминистская
// оркестрация фаз; agent() спавнит субагентов с доступом к MCP (design-inspiration,
// firecrawl) и self-hosted fetch (lib/cffi_get.sh, lib/fetch.sh, redproxy).
//
// Workflow-песочница БЕЗ FS-доступа → persist + запись artifacts делает CALLER
// (commands/redreference.md). Этот скрипт возвращает payload; caller пишет на диск,
// держит status.json (heartbeat.sh), поднимает feedback-server (§0), коммитит
// раунды через WAL (lib/wal.sh).
//
// Stage A: каркас фаз + dry-run ветка (hermetic, без агентов) для smoke.
// Stage B-D навешивают реальную логику адаптеров / страницы / петли вкуса.
//
// Args (object | JSON-string):
//   brief        — ниша/бриф/пожелания (required в реальном прогоне)
//   mode         — 'standard' | 'lite' | 'dry-run'
//   round        — текущий раунд (resume); по умолчанию 0
//   feedback     — ответы прошлого раунда [{card_id, liked, score, attributes}] (resume)
//   taste_profile— накопленный профиль вкуса (resume)
//   run_id, timestamp, slug — для meta/correlation (Date.now/random запрещены)

export const meta = {
  name: 'redreference',
  description: 'Курирование дизайн-референсов с петлёй вкуса — adapters(API+scraper) → интерактивная локальная страница → active-learning round loop → taste-profile для redloft Design.',
  phases: [
    { title: 'Brief',  detail: 'разобрать нишу/бриф/пожелания → query_tags + начальные источники' },
    { title: 'Hunt',   detail: 'adapters (Are.na/design-inspiration/scraper) → нормализованные карточки' },
    { title: 'Curate', detail: 'дедуп, ранжирование, добор разнообразия для раунда' },
    { title: 'Page',   detail: 'build-page.sh → локальная HTML + feedback-server (caller)' },
    { title: 'Round',  detail: 'приём фидбэка → WAL commit → пересчёт taste-profile → query-expansion' },
    { title: 'Render', detail: 'taste-profile.json + reference-likes.md (redloft-совместимо)' },
  ],
}

// ───────────────────────── args ─────────────────────────
let A = args
if (typeof args === 'string') {
  try { A = JSON.parse(args) } catch { A = { brief: args } }
}
const brief     = A?.brief || 'NO_BRIEF_PROVIDED'
const mode      = A?.mode || 'standard'
const round     = Number.isInteger(A?.round) ? A.round : 0
const runId     = A?.run_id || 'unknown-run-id'
const timestamp = A?.timestamp || 'now'
const slug      = A?.slug || 'reference'
const isDryRun  = mode === 'dry-run'

log(`Brief: "${String(brief).slice(0, 80)}" · mode: ${mode} · round: ${round} · run_id: ${runId}`)

// ───────────────────────── schemas ─────────────────────────
const CARD_SCHEMA = {
  type: 'object',
  required: ['id', 'schema_version', 'source', 'source_url', 'ref_url', 'title', 'tags', 'round', 'captured_at'],
  additionalProperties: true,
  properties: {
    id: { type: 'integer', minimum: 1 },
    schema_version: { const: 1 },
    source: { enum: ['arena', 'design-inspiration', 'eagle', 'behance', 'awwwards', 'onepagelove', 'landbook', 'savee', 'screenshot-only'] },
    source_url: { type: 'string' },
    ref_url: { type: 'string' },
    title: { type: 'string' },
    author: { type: 'string' },
    thumbnail_url: { type: 'string' },
    full_image_url: { type: 'string' },
    local_screenshot: { type: 'string' },
    tags: { type: 'array', items: { type: 'string' } },
    category: { type: 'string' },
    colors: { type: 'array', items: { type: 'string' } },
    date: { type: 'string' },
    round: { type: 'integer', minimum: 0 },
    captured_at: { type: 'string' },
    similarity_to: { type: 'array' },
  },
}

// Shared by the workflow brief-interpreter AND the caller-side distillation
// (commands/redreference.md). Persisted to $RUN_DIR/brief-keys.json — the single
// source of truth round.sh resolve_query()/_read_intent() read (plan P1/P2).
const BRIEF_SCHEMA = {
  type: 'object',
  required: ['query_tags', 'intent'],
  additionalProperties: true,
  properties: {
    query_tags: { type: 'array', items: { type: 'string', minLength: 1 }, minItems: 1 }, // 2-4 short non-empty EN keys
    intent: { enum: ['site', 'mood'] },   // site→galleries lead · mood→Are.na leads
    sources: { type: 'array', items: { type: 'string' } },
    niche: { type: 'string' },
    palette_hint: { type: 'array', items: { type: 'string' } },
    notes: { type: 'string' },
  },
}

// ───────────────────────── dry-run (hermetic, Stage A) ─────────────────────────
// No agents, no network — returns a structurally-valid stub so the caller can
// exercise persist + status + WAL plumbing in smoke (Stage A Done-when #1).
if (isDryRun || brief === 'NO_BRIEF_PROVIDED') {
  log('DRY-RUN: skeleton only (no agents). Stage B-D add adapters/page/loop.')
  return {
    run_id: runId, slug, timestamp, mode,
    status: 'ok',
    dry_run: true,
    phase: 'init',
    cards: [],
    taste_profile: null,           // null sentinel — "nothing to merge" (plan D2/Stage E)
    reference_likes_md: '',
    rounds_completed: 0,
    stop_reason: 'no_results',
    artifacts: {
      'status-skeleton.json': JSON.stringify({ schema_version: 1, last_committed_round: 0 }, null, 2),
    },
  }
}

// ───────────────────────── live phases (Stage B-D) ─────────────────────────
// Placeholder: real implementation lands in Stage B (adapters) onward. Keeping
// the contract explicit so the caller wiring is stable across stages.
phase('Brief')
const briefOut = await agent(
  `Дистиллируй дизайн-бриф (может быть длинным, на любом языке) в ПОИСКОВЫЕ КЛЮЧИ для галерей референсов.\n` +
  `Верни:\n` +
  `- query_tags: 2-4 КОРОТКИХ АНГЛИЙСКИХ ключа (ниша + стиль + интент), напр. ["spa wellness", "sauna landing", "minimal warm"]. НЕ копируй абзац — выжимай суть. Галереи (Are.na/Awwwards/Behance) матчат короткие EN-запросы, длинный/русский текст = мусор на входе.\n` +
  `- intent: "site" если нужны коммерческие сайты/лендинги/приложения (→ Awwwards/Behance), "mood" если мудборд/фактуры/бренд-эстетика (→ Are.na).\n` +
  `- sources: подмножество [arena, awwwards, behance, design-inspiration].\n` +
  `Бриф: ${brief}`,
  { label: 'brief-interpreter', schema: BRIEF_SCHEMA }
)

// Stage B+ will fan out adapters here using briefOut.sources / briefOut.query_tags,
// validate each card via lib/validate-card.js, and return them for the caller to
// render (Page) and feed the round loop (Round). For now return the brief only.
return {
  run_id: runId, slug, timestamp, mode,
  status: 'brief_only',
  phase: 'brief',
  brief: briefOut,
  cards: [],
  taste_profile: null,
  reference_likes_md: '',
  rounds_completed: round,
  stop_reason: 'no_results',
  artifacts: {},
}

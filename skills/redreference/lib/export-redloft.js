#!/usr/bin/env node
/*
 * export-redloft.js — map a redreference run's taste into redloft's Phase-6
 * artifacts (plan Stage E / §5). MERGES into an existing visual-taste-profile.json
 * (does NOT overwrite tone/palette/typography/composition set in Briefing) and
 * (re)writes reference-likes.md. Atomicity/flock/backup are the wrapper's job
 * (export-redloft.sh); this is the pure transform.
 *
 * Enriches:
 *   references[]      ← liked cards   { url, liked:<comment|UX/UI summary>, tokens:{} }
 *   anti_references[] ← dismatched ref_urls + disliked vocabulary
 *   mood[]            ← liked_keywords_common (shared aesthetic vocabulary)
 * Preserves everything else from the existing profile.
 *
 * Usage: export-redloft.js <run_dir> <existing_visual_taste.json|-> <out_json.tmp> <out_md>
 *   existing path "-" or missing → start from {}.
 */
'use strict';
const fs = require('fs');
const path = require('path');

const [runDir, existingPath, outJson, outMd] = process.argv.slice(2);
if (!runDir || !outJson || !outMd) { console.error('usage: export-redloft.js <run_dir> <existing|-> <out_json> <out_md>'); process.exit(64); }

function readJson(p, def) { try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return def; } }
function readJsonl(p) {
  if (!fs.existsSync(p)) return [];
  return fs.readFileSync(p, 'utf8').split('\n').map((l) => l.trim()).filter(Boolean)
    .map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean)
    .filter((o) => !(o._schema_version && !o.id && !o.card_id));
}

const capDir = path.join(runDir, 'captures');
const profile = readJson(path.join(capDir, 'taste-profile.json'), {});
const cards = readJsonl(path.join(capDir, 'captures.jsonl'));
const fb = readJsonl(path.join(capDir, 'feedback.jsonl'));
const byId = new Map(cards.map((c) => [c.id, c]));

// liked refs (priority/match first, then by score), with a concrete "liked" note
const likedFb = fb.filter((f) => f.liked === true)
  .sort((a, b) => (b.verdict === 'match' ? 1 : 0) - (a.verdict === 'match' ? 1 : 0) || (b.score || 0) - (a.score || 0));
function likedNote(f) {
  if (f.comment && String(f.comment).trim()) return String(f.comment).trim();
  const parts = [];
  if (typeof f.ux_score === 'number') parts.push(`UX ${f.ux_score}/10`);
  if (typeof f.ui_score === 'number') parts.push(`UI ${f.ui_score}/10`);
  if (f.verdict === 'match') parts.unshift('полное совпадение');
  if (!parts.length && f.score) parts.push(`оценка ${f.score}/10`);
  return parts.join(', ') || 'нравится';
}
const newRefs = [];
const seenUrl = new Set();
for (const f of likedFb) {
  const c = byId.get(f.card_id); if (!c || !c.ref_url || seenUrl.has(c.ref_url)) continue;
  seenUrl.add(c.ref_url);
  newRefs.push({ url: c.ref_url, liked: likedNote(f), tokens: {}, _title: c.title || '' });
}

// merge into existing profile (preserve briefing-set fields)
const ex = (existingPath && existingPath !== '-') ? readJson(existingPath, {}) : {};
const merged = { schema_version: 1, ...ex };
// references: existing + new, dedupe by url (existing wins its note)
const exRefs = Array.isArray(ex.references) ? ex.references : [];
const exUrls = new Set(exRefs.map((r) => r && r.url).filter(Boolean));
merged.references = exRefs.concat(newRefs.filter((r) => !exUrls.has(r.url)).map(({ _title, ...r }) => r));
// anti_references: existing + EXPLICIT 👎 dismatch ref_urls ONLY (P4). NOT
// disliked vocabulary — vocab/comment fragments (animation/scrolling/luxury)
// must never make the design "avoid" a good reference; those become structural
// `preferences` (avoid) instead. Anti = hard-excluded URLs.
const exAnti = Array.isArray(ex.anti_references) ? ex.anti_references : [];
const antiUrls = (profile.anti_references || []).filter(Boolean);   // taste.js gates these on verdict==='dismatch'
merged.anti_references = [...new Set([...exAnti, ...antiUrls])];
// mood: existing + shared aesthetic vocabulary
const exMood = Array.isArray(ex.mood) ? ex.mood : [];
const moodNew = (profile.liked_keywords_common && profile.liked_keywords_common.length ? profile.liked_keywords_common : (profile.liked_keywords || []))
  .filter((t) => t && t !== 'link' && t !== 'image');
merged.mood = [...new Set([...exMood, ...moodNew])].slice(0, 12);

// preferences (P4b): structural axes — ADDITIVE, explicit assignment (spread on
// `ex` does NOT carry a field absent from `ex`). note sanitized at the export
// boundary (verbatim user phrase → strip control chars, cap length).
function sanitizeNote(s) { return String(s == null ? '' : s).replace(/[\u0000-\u001f]+/g, ' ').trim().slice(0, 240); }
const exPrefs = Array.isArray(ex.preferences) ? ex.preferences : [];
const newPrefs = (profile.preferences || [])
  .filter((p) => p && p.axis && p.stance)
  .map((p) => ({ axis: String(p.axis), stance: String(p.stance), note: sanitizeNote(p.note) }));
const seenPref = new Set();
merged.preferences = [...exPrefs, ...newPrefs].filter((p) => {
  const k = `${p.axis}|${p.stance}|${p.note || ''}`; if (seenPref.has(k)) return false; seenPref.add(k); return true;
});

fs.writeFileSync(outJson, JSON.stringify(merged, null, 2));

// reference-likes.md
// markdown-table-safe: pipes break the column structure, newlines break the row
function mdCell(s) { return String(s == null ? '' : s).replace(/\|/g, '/').replace(/[\r\n]+/g, ' '); }
function likedNoteSafe(r) { return mdCell(r.liked); }
const rows = newRefs.length
  ? newRefs.map((r, i) => `| ${i + 1} | ${mdCell(r.url)} | ${(r._title ? mdCell(r._title) + ' — ' : '') + likedNoteSafe(r)} | _<реализовать в прототипе>_ |`).join('\n')
  : '| 1 | | | |';
const moodStr = (merged.mood || []).join(', ') || '—';
const antiStr = (merged.anti_references || []).join('; ') || '—';
const uxui = [];
if (profile.ux_pref != null) uxui.push(`UX-бар ~${profile.ux_pref}/10`);
if (profile.ui_pref != null) uxui.push(`UI-бар ~${profile.ui_pref}/10`);
const comments = (profile.liked_comments || []).map((c) => `  - «${String(c.comment).replace(/\n/g, ' ')}» (${c.ref_url})`).join('\n');

const md = `# Reference-likes — лог итераций по референсам

> Сгенерировано из redreference (раундов: ${profile.rounds || 0}, лайков: ${profile.likes || 0}${uxui.length ? ', ' + uxui.join(', ') : ''}).
> Журнал цикла: референс → редизайн «фактуры» в коде → скриншот → фидбек. Питает tokens.css и KIT.

| # | Реф (URL) | Что понравилось (конкретно) | Как реализовано в прототипе |
|---|---|---|---|
${rows}

## Сводка согласованной «фактуры»

- **Настроение (mood):** ${moodStr}
- **UX/UI планка клиента:** ${uxui.length ? uxui.join(' · ') : '—'}
- **Что клиент явно ОТВЕРГ (анти-референсы):** ${antiStr}
${(merged.preferences || []).length ? '- **Структурные предпочтения (motion/scroll/scale…):**\n' + merged.preferences.map((p) => `  - ${p.stance === 'avoid' ? '⛔ избегать' : '✅ хочет'} **${p.axis}** — «${mdCell(p.note)}»`).join('\n') : ''}
${comments ? '- **Дословные заметки вкуса:**\n' + comments : ''}
`;
fs.writeFileSync(outMd, md);

const likes = (profile.likes || 0);
console.log(JSON.stringify({ ok: true, new_references: newRefs.length, mood: merged.mood.length, anti: merged.anti_references.length, likes }));

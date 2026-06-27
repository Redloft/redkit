#!/usr/bin/env node
/*
 * taste.js — taste model for the round loop (plan Stage D). Pure computation
 * over captures.jsonl + feedback.jsonl. No ML (MVP boundary): aggregates liked
 * tags / colors / title-keywords with recency + score weighting, drives
 * query-expansion ("more like what you liked"), and decides stop criteria.
 *
 * Subcommands:
 *   taste.js update <run-dir> <round>   → writes captures/taste-profile.json,
 *                                          appends taste-profile-history.jsonl
 *   taste.js query  <run-dir>           → prints expanded query string (stdout)
 *   taste.js stop   <run-dir> <round>   → prints stop_reason | "continue"
 */
'use strict';
const fs = require('fs');
const path = require('path');

const STOP_WORDS = new Set(['the', 'a', 'an', 'and', 'or', 'of', 'for', 'to', 'in', 'on', 'with', 'home', 'homepage', 'site', 'website', 'untitled', 'page', '-', '—', '|', 'studio', 'agency', 'inc', 'co']);
const ROUND_CAP = Number(process.env.REDREFERENCE_ROUND_CAP || 5);
const ZERO_LIKE_STREAK = Number(process.env.REDREFERENCE_ZERO_LIKE_STREAK || 2);
const PROFILE_SCHEMA_VERSION = 2;   // v2 adds preferences[] (P4b)

// P4b: structural design preferences parsed from free-text comments. A comment
// like "не нравится анимация при скролле" is a MOTION signal, not an anti-ref —
// it must steer the design, not exclude a good reference. axis keyword-map (ru+en):
const PREF_AXES = [
  ['motion', /\b(animation|animated|motion|transition|hover effect)\b|анимац|движени|переход/i],
  ['scroll', /\b(scroll|parallax|scroll-?jack)\b|скролл|параллакс/i],
  ['density', /\b(density|spacing|whitespace|cramped|airy)\b|плотн|воздух|просвет|разрежен/i],
  ['scale', /\b(large|big|oversized|huge|scale|size)\b|крупн|больш|масштаб|размер/i],
  ['color', /\b(colou?r|palette|contrast|saturat)\b|цвет|палитр|контраст|насыщен/i],
  ['type', /\b(typograph|typeface|font|serif|sans)\b|типографик|шрифт|гарнитур/i],
];
const NEG_RE = /\b(avoid|hate|dislike|no |not |without|too much|less)\b|не нрав|не люб|без |убер|меньше|слишком|перебор|раздража/i;
function commentPreferences(comment, card_id) {
  const txt = String(comment || '');
  if (!txt.trim()) return [];
  const stance = NEG_RE.test(txt) ? 'avoid' : 'prefer';
  const out = [];
  for (const [axis, re] of PREF_AXES) if (re.test(txt)) out.push({ axis, stance, note: txt.slice(0, 240), card_id });
  return out;
}

function readJsonl(file) {
  if (!fs.existsSync(file)) return [];
  return fs.readFileSync(file, 'utf8').split('\n').map((l) => l.trim()).filter(Boolean)
    .map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean)
    .filter((o) => !(o._schema_version && !o.id && !o.card_id));
}
function tokens(title) {
  return String(title || '').toLowerCase().replace(/[^a-zа-я0-9 ]+/gi, ' ').split(/\s+/)
    .filter((w) => w.length >= 3 && !STOP_WORDS.has(w));
}
function bump(map, key, w, prov, cardId) {
  if (!key) return;
  const e = map.get(key) || { w: 0, prov: new Set() };
  e.w += w; e.prov.add(cardId); map.set(key, e);
}
function topKeys(map, n) {
  return [...map.entries()].sort((a, b) => b[1].w - a[1].w).slice(0, n).map(([k]) => k);
}

function build(runDir) {
  const dir = path.join(runDir, 'captures');
  const cards = readJsonl(path.join(dir, 'captures.jsonl'));
  const fb = readJsonl(path.join(dir, 'feedback.jsonl'));
  const byId = new Map(cards.map((c) => [c.id, c]));
  const maxRound = fb.reduce((m, f) => Math.max(m, f.round || 0), 0);

  const likedTags = new Map(), dislikedTags = new Map(), palette = new Map(), keywords = new Map();
  const attrs = {}; let likes = 0, total = 0; const antiRefs = [], priorityCards = [], comments = [];
  let uxSum = 0, uxN = 0, uiSum = 0, uiN = 0;
  for (const f of fb) {
    total++;
    const c = byId.get(f.card_id); if (!c) continue;
    if (typeof f.ux_score === 'number') { uxSum += f.ux_score; uxN++; }
    if (typeof f.ui_score === 'number') { uiSum += f.ui_score; uiN++; }
    if (f.comment && String(f.comment).trim()) comments.push({ card_id: f.card_id, ref_url: c.ref_url, comment: String(f.comment).trim() });
    const recency = 1 + (f.round || 0) / Math.max(1, maxRound);     // newer rounds weigh more
    const score = f.score ? f.score / 10 : 0.5;
    // verdict (Tinder): match = priority (×1.5), dismatch = strong anti-ref, skip = ignore
    const priority = f.verdict === 'match' ? 1.5 : 1;
    if (f.liked === true) {
      likes++;
      const w = recency * (0.5 + score) * priority;
      (c.tags || []).forEach((t) => bump(likedTags, String(t).toLowerCase(), w, 'tag', c.id));
      (c.colors || []).forEach((col) => bump(palette, String(col).toLowerCase(), w, 'color', c.id));
      tokens(c.title).forEach((k) => bump(keywords, k, w, 'title', c.id));
      if (f.verdict === 'match') priorityCards.push(c.id);
    } else if (f.liked === false) {
      const w = recency * (f.verdict === 'dismatch' ? 1.5 : 1);     // dismatch = strong exclude
      (c.tags || []).forEach((t) => bump(dislikedTags, String(t).toLowerCase(), w, 'tag', c.id));
      tokens(c.title).forEach((k) => bump(dislikedTags, k, w * 0.5, 'title', c.id));
      // hard-exclude (anti_references) ONLY on an explicit 👎 dismatch — a low
      // star rating is a soft negative (disliked tags) but not a hard exclude.
      if (f.verdict === 'dismatch' && c.ref_url) antiRefs.push(c.ref_url);
    }
    if (f.attributes) for (const [a, v] of Object.entries(f.attributes)) {
      attrs[a] = attrs[a] || { pos: 0, neg: 0, neutral: 0 }; attrs[a][v] = (attrs[a][v] || 0) + recency;
    }
  }
  const confidence = Math.min(1, total / 30);     // ~30 ratings → confident (research)
  const prov = (map) => Object.fromEntries([...map.entries()].map(([k, e]) => [k, [...e.prov]]));
  // cross-card keywords (df>=2) = shared aesthetic vocabulary; single-card tokens
  // are usually brand/site names (noise) → filtered out of query-expansion.
  const commonKw = [...keywords.entries()].filter(([, e]) => e.prov.size >= 2)
    .sort((a, b) => b[1].w - a[1].w).map(([k]) => k).slice(0, 12);
  // P4b: derive structural preferences from ALL comments (motion/scroll/scale…)
  const preferences = [];
  for (const cm of comments) preferences.push(...commentPreferences(cm.comment, cm.card_id));
  const profile = {
    schema_version: PROFILE_SCHEMA_VERSION,
    liked_tags: topKeys(likedTags, 12),
    disliked_tags: topKeys(dislikedTags, 12),
    liked_palette: topKeys(palette, 8),
    liked_keywords: topKeys(keywords, 15),
    liked_keywords_common: commonKw,
    preferred_attributes: attrs,
    top_cards: fb.filter((f) => f.liked === true).sort((a, b) => (b.score || 0) - (a.score || 0)).slice(0, 12).map((f) => f.card_id),
    priority_cards: [...new Set(priorityCards)],
    anti_references: [...new Set(antiRefs)],
    ux_pref: uxN ? Number((uxSum / uxN).toFixed(1)) : null,   // avg UX rating (1-10) across rated
    ui_pref: uiN ? Number((uiSum / uiN).toFixed(1)) : null,   // avg UI rating
    liked_comments: comments,                                  // verbatim comments (→ redloft)
    preferences,                                               // structural axes (motion/scroll/scale…) — NOT anti-refs
    rounds: maxRound, total_ratings: total, likes,
    confidence: Number(confidence.toFixed(3)),
    tag_provenance: prov(likedTags), palette_provenance: prov(palette),
  };
  return profile;
}

const cmd = process.argv[2], runDir = process.argv[3], round = Number(process.argv[4] || '0');
if (!cmd || !runDir) { console.error('usage: taste.js {update <dir> <round>|query <dir>|stop <dir> <round>}'); process.exit(64); }
const capDir = path.join(runDir, 'captures');

if (cmd === 'update') {
  const profile = build(runDir);
  fs.writeFileSync(path.join(capDir, 'taste-profile.json'), JSON.stringify(profile, null, 2));
  fs.appendFileSync(path.join(capDir, 'taste-profile-history.jsonl'),
    JSON.stringify({ round, ...profile, tag_provenance: undefined, palette_provenance: undefined }) + '\n');
  console.log(`taste-profile updated (round ${round}, confidence ${profile.confidence}, ${profile.likes}/${profile.total_ratings} liked)`);
} else if (cmd === 'query') {
  const p = build(runDir);
  // anchor brief (optional 4th arg) keeps the query on the user's stated style;
  // common (cross-card) keywords refine it; brand-name noise is excluded.
  const base = (process.argv[4] || '').toLowerCase().split(/\s+/).filter(Boolean);
  const refine = p.liked_keywords_common.length ? p.liked_keywords_common : p.liked_keywords;
  const terms = [...new Set([...base, ...refine.slice(0, 4), ...p.liked_tags.slice(0, 2)])]
    .filter((t) => t && t !== 'link' && t !== 'image');
  console.log(terms.join(' '));
} else if (cmd === 'stop') {
  const p = build(runDir);
  const fb = readJsonl(path.join(capDir, 'feedback.jsonl'));
  // P7: streak over ACTUAL rounds, not CLI arithmetic. round.sh passes the real
  // committed rounds (--committed-rounds 1,2,3); else derive from feedback. A
  // committed round with no like → streak++; the first round WITH a like ends
  // the streak; a non-existent/non-committed round is never counted as zero-like
  // (that off-by-one bug made a 5-like round look like a zero-like streak).
  const cflag = process.argv.indexOf('--committed-rounds');
  const cval = cflag > -1 ? (process.argv[cflag + 1] || '').trim() : '';
  let rounds = cval.length > 0     // empty/missing flag value → derive from feedback
    ? cval.split(',').map(Number).filter((n) => Number.isInteger(n))
    : [...new Set(fb.map((f) => f.round))].filter((n) => Number.isInteger(n));
  rounds = [...new Set(rounds)].sort((a, b) => b - a);   // most recent first
  let streak = 0;
  for (const r of rounds) {
    if (fb.some((f) => f.round === r && f.liked === true)) break;   // a like ends the streak
    streak++;                                                       // committed round, no like
    if (streak >= ZERO_LIKE_STREAK) break;
  }
  if (streak > 0) process.stderr.write(`stop: zero_like_streak=${streak} over rounds [${rounds.join(',')}]\n`);
  let reason = 'continue';
  if (round >= ROUND_CAP) reason = 'round_cap';
  else if (streak >= ZERO_LIKE_STREAK) reason = 'zero_like_streak';
  else if (p.confidence >= 1 && p.likes >= 8) reason = 'converged';
  console.log(reason);
} else { console.error('unknown subcommand: ' + cmd); process.exit(64); }

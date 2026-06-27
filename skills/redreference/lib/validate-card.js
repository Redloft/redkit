#!/usr/bin/env node
/*
 * validate-card.js — strict schema validation for reference cards (plan judge#2)
 * and feedback answers (plan D2). An invalid card is SKIPPED + logged
 * CARD_INVALID by the caller; it never crashes a round.
 *
 * Also enforces the Stage-B SSRF blocking-gate on card URL fields: every URL
 * field must be https:// to a non-private host (url-guard.sh does the deep
 * network-level check; this is the cheap structural allowlist).
 *
 * Usage:
 *   node validate-card.js '<card-json>'              # validate a card
 *   echo '<card-json>' | node validate-card.js       # via stdin
 *   node validate-card.js --feedback '<answer-json>' # validate a POST /round answer
 * Exit: 0 valid (prints "VALID") | 1 invalid (prints "INVALID: <reason>") | 64 usage
 */
'use strict';

const SOURCES = new Set([
  'arena', 'design-inspiration', 'eagle', 'behance', 'awwwards',
  'onepagelove', 'landbook', 'savee', 'screenshot-only',
]);
const ATTR_KEYS = ['color', 'typography', 'layout', 'style', 'density'];
const ATTR_VALS = new Set(['pos', 'neg', 'neutral']);

function isPrivateHost(h) {
  if (!h) return true;
  if (h === 'localhost' || h.endsWith('.local')) return true;
  // IPv4 private / loopback / link-local / metadata
  const m = h.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
  if (m) {
    const [a, b] = [Number(m[1]), Number(m[2])];
    if (a === 10 || a === 127 || a === 0) return true;
    if (a === 169 && b === 254) return true;            // link-local / 169.254.169.254
    if (a === 192 && b === 168) return true;
    if (a === 172 && b >= 16 && b <= 31) return true;
    return false;
  }
  // IPv6 — URL() yields bracketed hostnames like [::1]. Reject loopback,
  // unspecified, link-local (fe80::/10), ULA (fc00::/7), and any IPv4 embedded
  // in a v6 literal (::ffff:127.0.0.1 / ::a.b.c.d) by re-checking the v4 tail.
  if (h.startsWith('[') && h.endsWith(']')) {
    const ip = h.slice(1, -1).toLowerCase();
    if (ip === '::1' || ip === '::') return true;
    if (ip.startsWith('fe80:')) return true;            // link-local
    if (/^f[cd][0-9a-f]{2}:/.test(ip)) return true;      // unique-local fc00::/7
    // IPv4-mapped (::ffff:a.b.c.d) — Node may compress the v4 tail to hex
    // (::ffff:7f00:1), so reject the whole ::ffff: class conservatively.
    if (ip.startsWith('::ffff:') || ip.startsWith('::ffff0:')) return true;
    const v4 = ip.match(/(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$/);
    if (v4) return isPrivateHost(v4[1]);                 // ::a.b.c.d compatible form
    if (ip.includes('.')) return true;                  // any other embedded-v4 form → conservative
    return false;                                       // genuine public IPv6 → allow
  }
  return false;
}

function checkHttpsUrl(val, field) {
  if (typeof val !== 'string') return `${field} must be a string url`;
  let u;
  try { u = new URL(val); } catch { return `${field} is not a valid URL`; }
  if (u.protocol !== 'https:') return `${field} must be https:// (got ${u.protocol})`;
  if (isPrivateHost(u.hostname)) return `${field} resolves to a private/loopback host (SSRF)`;
  return null;
}

function validateCard(c) {
  if (typeof c !== 'object' || c === null) return 'card is not an object';
  // required scalars
  if (!Number.isInteger(c.id) || c.id < 1) return 'id must be a positive integer';
  if (c.schema_version !== 1) return 'schema_version must be 1';
  if (!SOURCES.has(c.source)) return `source not in allowlist: ${c.source}`;
  if (typeof c.title !== 'string' || !c.title.trim()) return 'title must be a non-empty string';
  if (typeof c.captured_at !== 'string') return 'captured_at must be a string';
  if (!Number.isInteger(c.round) || c.round < 0) return 'round must be a non-negative integer';
  // required arrays
  if (!Array.isArray(c.tags)) return 'tags must be an array';
  // required URL fields (https-allowlist / SSRF gate)
  for (const f of ['source_url', 'ref_url']) {
    const e = checkHttpsUrl(c[f], f); if (e) return e;
  }
  // optional URL fields
  for (const f of ['thumbnail_url', 'full_image_url']) {
    if (c[f] != null) { const e = checkHttpsUrl(c[f], f); if (e) return e; }
  }
  // local_screenshot is a local path (NOT a url) — must be relative, no scheme
  if (c.local_screenshot != null) {
    if (typeof c.local_screenshot !== 'string') return 'local_screenshot must be a string path';
    if (/^[a-z]+:\/\//i.test(c.local_screenshot)) return 'local_screenshot must be a local path, not a url';
  }
  // optional typed fields
  if (c.author != null && typeof c.author !== 'string') return 'author must be a string';
  if (c.category != null && typeof c.category !== 'string') return 'category must be a string';
  if (c.colors != null && !Array.isArray(c.colors)) return 'colors must be an array';
  if (c.date != null && typeof c.date !== 'string') return 'date must be a string';
  if (c.similarity_to != null && !Array.isArray(c.similarity_to)) return 'similarity_to must be an array';
  return null;
}

const VERDICTS = new Set(['match', 'dismatch', 'skip', 'rated']);
function validateAnswer(a) {
  if (typeof a !== 'object' || a === null) return 'answer is not an object';
  if (!Number.isInteger(a.card_id) || a.card_id < 1) return 'card_id must be a positive integer';
  if (!(a.liked === true || a.liked === false || a.liked === null)) return 'liked must be bool|null';
  if (!(a.score === null || (Number.isInteger(a.score) && a.score >= 1 && a.score <= 10)))
    return 'score must be int 1-10 or null';
  // verdict (Tinder-style): match=priority like, dismatch=anti-ref, skip=no reaction, rated=stars
  if (a.verdict != null && !VERDICTS.has(a.verdict)) return 'verdict must be match|dismatch|skip|rated';
  // separate UX / UI ratings (often only one is liked) + free-text comment
  if (a.ux_score != null && !(Number.isInteger(a.ux_score) && a.ux_score >= 1 && a.ux_score <= 10)) return 'ux_score must be int 1-10 or null';
  if (a.ui_score != null && !(Number.isInteger(a.ui_score) && a.ui_score >= 1 && a.ui_score <= 10)) return 'ui_score must be int 1-10 or null';
  if (a.comment != null && (typeof a.comment !== 'string' || a.comment.length > 2000)) return 'comment must be a string <=2000 chars';
  if (a.attributes != null) {
    if (typeof a.attributes !== 'object') return 'attributes must be an object';
    for (const k of Object.keys(a.attributes)) {
      if (!ATTR_KEYS.includes(k)) return `unknown attribute key: ${k}`;
      if (!ATTR_VALS.has(a.attributes[k])) return `attribute ${k} must be pos|neg|neutral`;
    }
  }
  return null;
}

function main() {
  const argv = process.argv.slice(2);
  let feedback = false;
  if (argv[0] === '--feedback') { feedback = true; argv.shift(); }
  let raw = argv[0];
  if (raw == null) {
    try { raw = require('fs').readFileSync(0, 'utf8').trim(); } catch { raw = ''; }
  }
  if (!raw) { console.error('usage: validate-card.js [--feedback] <json>'); process.exit(64); }
  let obj;
  try { obj = JSON.parse(raw); } catch (e) { console.log('INVALID: not JSON — ' + e.message); process.exit(1); }
  const err = feedback ? validateAnswer(obj) : validateCard(obj);
  if (err) { console.log('INVALID: ' + err); process.exit(1); }
  console.log('VALID');
  process.exit(0);
}
main();

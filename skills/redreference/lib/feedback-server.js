#!/usr/bin/env node
/*
 * feedback-server.js — ephemeral localhost server that receives one round of
 * feedback from page/index.html (plan §0 / Stage C2). Caller owns the lifecycle:
 * it starts this, captures {pid,port,token} from the first stdout line, builds
 * the page with that port+token+nonce, opens the browser, and waits for the
 * answers file (or process exit) — then wal_answer + wal_commit.
 *
 * Security (§0): bind strictly 127.0.0.1; bearer token >=128 bit checked with
 * timingSafeEqual; body cap 256KB; nonce idempotency (replay → 409). Timeouts:
 * idle 15min (reset by GET /ping keepalive) + hard-cap 30min. SIGTERM/SIGINT exit.
 *
 * Usage:
 *   feedback-server.js --run-dir <dir> --round N --nonce <uuid> [--token <hex>]
 *   First stdout line (JSON): {"pid":..,"port":..,"token":".."}
 *   On a valid round → writes <run-dir>/page/round-<N>.answers.json, responds
 *   200 {accepted:N}, then graceful shutdown.
 * Env (tests): REDREFERENCE_IDLE_MS, REDREFERENCE_HARDCAP_MS.
 */
'use strict';
const http = require('http');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

function arg(n, d) { const i = process.argv.indexOf('--' + n); return i > -1 ? process.argv[i + 1] : d; }
const runDir = arg('run-dir'), round = Number(arg('round', '1')), nonce = arg('nonce', '');
if (!runDir || !nonce) { console.error('usage: feedback-server.js --run-dir <dir> --round N --nonce <uuid> [--token hex]'); process.exit(64); }
const token = arg('token') || crypto.randomBytes(16).toString('hex');

const IDLE_MS = Number(process.env.REDREFERENCE_IDLE_MS || 15 * 60 * 1000);
const HARDCAP_MS = Number(process.env.REDREFERENCE_HARDCAP_MS || 30 * 60 * 1000);
const MAX_BODY = 256 * 1024;
const ANSWERS = path.join(runDir, 'page', `round-${round}.answers.json`);

let seenNonce = false;
let idleTimer = null;
const bumpIdle = () => { clearTimeout(idleTimer); idleTimer = setTimeout(() => shutdown('idle'), IDLE_MS); };
const hardTimer = setTimeout(() => shutdown('hardcap'), HARDCAP_MS);
function shutdown(reason) { try { server.close(); } catch {} clearTimeout(idleTimer); clearTimeout(hardTimer); console.error(`feedback-server: shutdown (${reason})`); process.exit(0); }

const okToken = (hdr) => {
  if (!hdr || !hdr.startsWith('Bearer ')) return false;
  const got = Buffer.from(hdr.slice(7)); const want = Buffer.from(token);
  return got.length === want.length && crypto.timingSafeEqual(got, want);
};
const errBody = (code, detail) => JSON.stringify({ error: code, detail });

const server = http.createServer((req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Headers', 'Authorization,Content-Type');
  res.setHeader('Content-Type', 'application/json');
  if (req.method === 'OPTIONS') { res.writeHead(204); return res.end(); }

  if (req.method === 'GET' && req.url === '/ping') { bumpIdle(); res.writeHead(200); return res.end(JSON.stringify({ ready: true })); }

  if (req.method === 'POST' && req.url === '/round') {
    if (!okToken(req.headers['authorization'])) { res.writeHead(401); return res.end(errBody('unauthorized', 'bad or missing bearer token')); }
    let buf = '', tooBig = false;
    req.on('data', (c) => { buf += c; if (buf.length > MAX_BODY) { tooBig = true; req.destroy(); } });
    req.on('end', () => {
      if (tooBig) { res.writeHead(413); return res.end(errBody('payload_too_large', `>${MAX_BODY} bytes`)); }
      let body; try { body = JSON.parse(buf); } catch { res.writeHead(400); return res.end(errBody('bad_json', 'body is not JSON')); }
      if (!body || !Array.isArray(body.answers) || typeof body.round_nonce !== 'string') {
        res.writeHead(400); return res.end(errBody('bad_schema', 'expected {round,round_nonce,answers[]}'));
      }
      if (body.round_nonce !== nonce) { res.writeHead(400); return res.end(errBody('nonce_mismatch', 'unexpected round_nonce')); }
      if (seenNonce) { res.writeHead(409); return res.end(JSON.stringify({ duplicate: true })); }
      seenNonce = true;
      // strict typed write (no concatenation — JSONL-injection safe)
      const tmp = ANSWERS + '.tmp';
      fs.writeFileSync(tmp, JSON.stringify({ round, round_nonce: nonce, answers: body.answers }, null, 0));
      fs.renameSync(tmp, ANSWERS);
      res.writeHead(200); res.end(JSON.stringify({ accepted: body.answers.length }));
      bumpIdle();
      setTimeout(() => shutdown('round-received'), 200);
      return;
    });
    return;
  }
  res.writeHead(404); res.end(errBody('not_found', req.url));
});

process.on('SIGTERM', () => shutdown('sigterm'));
process.on('SIGINT', () => shutdown('sigint'));

server.listen(0, '127.0.0.1', () => {   // 127.0.0.1 strict; port 0 → free ephemeral
  const port = server.address().port;
  fs.mkdirSync(path.join(runDir, 'page'), { recursive: true });
  console.log(JSON.stringify({ pid: process.pid, port, token }));   // first line — caller captures
  bumpIdle();
});

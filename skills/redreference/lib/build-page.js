#!/usr/bin/env node
/*
 * build-page.js — Tinder-style FULLSCREEN deck (plan Stage C1, v3 UX).
 *
 * One reference fills the screen. Per card you rate UX and UI on SEPARATE star
 * rows (often only one is liked), optionally write a 💬 comment (what exactly you
 * liked — collapsible, editable), and/or hit 👐 совпало (full match) or 👎 не
 * совпало (anti-reference). NOTHING auto-advances: a green «✅ согласовано»
 * button appears once you've chosen anything and commits the card. Skip = the
 * right edge-arrow ‹ / › (no skip button). Inner slider for multi-screen refs.
 *
 * Output answers: {card_id, liked, score, verdict, ux_score, ui_score, comment}.
 * Strings HTML-escaped (F6/XSS); card data embedded as JSON. POSTs to the
 * localhost feedback-server (§0); «📋 скопировать JSON» fallback for paste-back.
 *
 * Usage: build-page.js --cards <jsonl> --out <html> --round N [--port p --token t --nonce u]
 */
'use strict';
const fs = require('fs');
function arg(name, def) { const i = process.argv.indexOf('--' + name); return i > -1 ? process.argv[i + 1] : def; }
const cardsFile = arg('cards'), outFile = arg('out');
const round = arg('round', '1'), port = arg('port', ''), token = arg('token', ''), nonce = arg('nonce', '');
if (!cardsFile || !outFile) { console.error('usage: build-page.js --cards <jsonl> --out <html> --round N [--port p --token t --nonce u]'); process.exit(64); }
const esc = (s) => String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');

const cards = [];
for (const line of fs.readFileSync(cardsFile, 'utf8').split('\n')) {
  const t = line.trim(); if (!t) continue;
  let o; try { o = JSON.parse(t); } catch { continue; }
  if (!o || typeof o.id !== 'number' || o.id < 1) continue;
  const httpsOnly = (u) => typeof u === 'string' && /^https:\/\//.test(u);
  const imgs = Array.isArray(o.images) && o.images.filter(httpsOnly).length > 1
    ? [...new Set(o.images.filter(httpsOnly))]
    : [o.full_image_url, o.thumbnail_url].filter(httpsOnly).slice(0, 1);
  cards.push({ id: o.id, source: o.source, title: o.title || 'Untitled', ref_url: o.ref_url, source_url: o.source_url, images: [...new Set(imgs)] });
}
// embed safely in a <script> context: escape < (no </script> breakout) and the
// JS line terminators U+2028/U+2029 (valid in JSON, but break a script context)
const DATA = JSON.stringify({ round: Number(round), port, token, nonce, cards })
  .replace(/</g, '\\u003c').replace(/\u2028/g, '\\u2028').replace(/\u2029/g, '\\u2029');

const html = `<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>redreference · раунд ${esc(round)}</title>
<style>
  :root{--bg:#08080a;--fg:#f4f4f5;--mut:#9a9aa3;--line:#26262c;--acc:#7c9cff;--match:#3ddc84;--dis:#ff5d5d;--go:#2fce7c}
  *{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
  html,body{margin:0;height:100%;background:var(--bg);color:var(--fg);font:15px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;overflow:hidden}
  #app{position:fixed;inset:0;display:flex;flex-direction:column}
  .top{display:flex;align-items:center;gap:12px;padding:9px 16px;font-size:13px;color:var(--mut)}
  .bar{flex:1;height:4px;background:var(--line);border-radius:9px;overflow:hidden}.bar>i{display:block;height:100%;background:var(--acc);transition:width .2s}
  .stage{position:relative;flex:1;min-height:0;display:flex;align-items:center;justify-content:center;overflow:hidden;background:#000}
  .imgwrap{position:absolute;inset:0;display:flex;align-items:center;justify-content:center}
  .imgwrap img{max-width:100%;max-height:100%;object-fit:contain;display:block}.imgwrap .ph{color:var(--mut)}
  .nav{position:absolute;top:0;bottom:0;width:13%;min-width:60px;border:0;background:transparent;color:#fff;font-size:34px;cursor:pointer;opacity:.4;display:flex;align-items:center;justify-content:center;transition:opacity .15s,background .15s;z-index:3}
  .nav:hover{opacity:1;background:linear-gradient(var(--d),rgba(0,0,0,.5),transparent)}
  .nav.prev{left:0;--d:to right}.nav.next{right:0;--d:to left}
  .dots{position:absolute;left:0;right:0;bottom:8px;display:flex;gap:6px;justify-content:center;z-index:2}
  .dots b{width:7px;height:7px;border-radius:9px;background:#fff5}.dots b.on{background:#fff}
  .mini{position:absolute;top:50%;transform:translateY(-50%);background:#0008;border:0;color:#fff;font-size:20px;width:32px;height:46px;border-radius:8px;cursor:pointer;z-index:2}.mini.l{left:16%}.mini.r{right:16%}
  .hud{padding:10px 16px calc(12px + env(safe-area-inset-bottom));border-top:1px solid var(--line);background:#0b0b0e}
  .meta{display:flex;align-items:center;gap:10px;margin-bottom:8px;min-width:0}
  .badge{font-size:11px;color:#000;background:var(--acc);border-radius:99px;padding:1px 8px;text-transform:uppercase;letter-spacing:.04em;flex:none}
  .title{font-size:14px;margin:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;flex:1}
  .meta a{color:var(--acc);font-size:13px;flex:none;text-decoration:none}
  .ratings{display:flex;gap:18px;justify-content:center;flex-wrap:wrap;margin:2px 0 8px}
  .rrow{display:flex;align-items:center;gap:8px}.rlbl{font-size:12px;color:var(--mut);width:24px;font-weight:600}
  .stars{display:flex;gap:3px}
  .star{font-size:27px;line-height:1;background:none;border:0;cursor:pointer;color:#52525b;padding:1px 2px}.star.on{color:#ffd23f}
  .cmtbtn{display:block;margin:0 auto 8px;background:#16161b;border:1px solid var(--line);color:var(--fg);border-radius:9px;padding:6px 12px;font:inherit;font-size:13px;cursor:pointer}
  .cmtbtn.has{border-color:var(--acc);color:var(--acc)}
  .cmt{max-width:600px;margin:0 auto 8px}.cmt[hidden]{display:none}
  .cmt textarea{width:100%;height:64px;background:#111;color:var(--fg);border:1px solid var(--line);border-radius:9px;padding:8px;font:13px/1.4 inherit;resize:vertical}
  .acts{display:grid;grid-template-columns:1fr 1.2fr 1fr;gap:10px;max-width:560px;margin:0 auto}
  .act{font:inherit;font-weight:600;border:1px solid var(--line);background:#16161b;color:var(--fg);border-radius:14px;padding:13px 8px;cursor:pointer;display:flex;flex-direction:column;align-items:center;gap:2px}
  .act .e{font-size:22px}.act small{font-size:10px;color:var(--mut);font-weight:500}
  .act.dis.sel{border-color:var(--dis);color:var(--dis)}.act.match.sel{border-color:var(--match);color:var(--match)}
  .act.confirm{opacity:.4;cursor:not-allowed}
  .act.confirm.on{opacity:1;cursor:pointer;background:var(--go);color:#04130a;border-color:var(--go)}
  .act.confirm.on .e,.act.confirm.on small{color:#04130a}
  :focus-visible{outline:2px solid var(--acc);outline-offset:2px}
  #end{position:fixed;inset:0;background:var(--bg);display:none;flex-direction:column;align-items:center;justify-content:center;gap:16px;padding:24px;text-align:center}
  #end.show{display:flex}.sum{font-size:18px}.row{display:flex;gap:12px;flex-wrap:wrap;justify-content:center}
  button.primary{background:var(--acc);color:#000;border:0;border-radius:12px;padding:12px 22px;font-weight:700;font-size:16px;cursor:pointer}
  button.ghost{background:transparent;color:var(--fg);border:1px solid var(--line);border-radius:12px;padding:12px 22px;cursor:pointer}
  #jsonout{width:min(560px,90vw);height:150px;background:#111;color:var(--fg);border:1px solid var(--line);border-radius:10px;padding:10px;font:12px/1.4 ui-monospace,Menlo,monospace}
  .sr{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0)}
</style></head>
<body>
<div id="app">
  <div class="top"><span id="counter">1 / ${esc(cards.length)}</span><span class="bar"><i id="prog"></i></span><span id="hint">оцени UX/UI ★ · 💬 · 👐/👎 → жми «согласовано» · ‹ › листать (→ пропуск)</span></div>
  <div class="stage">
    <button class="nav prev" id="prev" aria-label="назад">‹</button>
    <div class="imgwrap" id="imgwrap"></div>
    <button class="mini l" id="imgprev" aria-label="предыдущий скрин" hidden>‹</button>
    <button class="mini r" id="imgnext" aria-label="следующий скрин" hidden>›</button>
    <div class="dots" id="dots"></div>
    <button class="nav next" id="next" aria-label="вперёд (пропустить)">›</button>
  </div>
  <div class="hud">
    <div class="meta"><span class="badge" id="badge"></span><h2 class="title" id="title"></h2><a id="link" target="_blank" rel="noopener noreferrer">↗ сайт</a></div>
    <div class="ratings">
      <div class="rrow"><span class="rlbl">UX</span><div class="stars" id="ux" role="radiogroup" aria-label="оценка UX 1-5"></div></div>
      <div class="rrow"><span class="rlbl">UI</span><div class="stars" id="ui" role="radiogroup" aria-label="оценка UI 1-5"></div></div>
    </div>
    <button class="cmtbtn" id="cmtbtn" aria-expanded="false">💬 комментарий</button>
    <div class="cmt" id="cmtbox" hidden><textarea id="cmt" placeholder="что именно понравилось в UX / UI…" aria-label="комментарий"></textarea></div>
    <div class="acts">
      <button class="act dis" id="b-dis" aria-label="не совпало — анти-референс"><span class="e">👎</span><span>не совпало</span><small>минус-сигнал</small></button>
      <button class="act confirm" id="b-confirm" disabled aria-label="согласовать выбор и перейти дальше"><span class="e">✅</span><span>согласовано</span><small>дальше</small></button>
      <button class="act match" id="b-match" aria-label="совпало — всё нравится, приоритет"><span class="e">👐</span><span>совпало</span><small>всё нравится</small></button>
    </div>
  </div>
</div>
<div id="end">
  <div class="sum" id="sum"></div>
  <div class="row"><button class="primary" id="copy">📋 скопировать JSON</button><button class="ghost" id="submit">отправить на сервер</button><button class="ghost" id="back">← вернуться к колоде</button></div>
  <div id="msg" style="color:var(--mut);font-size:13px;max-width:560px"></div>
  <textarea id="jsonout" readonly hidden></textarea>
</div>
<script>
const D = ${DATA}, C = D.cards;
const ST = C.map(function(c){return {card_id:c.id, ux:0, ui:0, verdict:null, comment:'', confirmed:false, img:0};});
let i = 0;
const $ = function(id){return document.getElementById(id);};
function hasSel(s){ return s.ux>0 || s.ui>0 || s.verdict || (s.comment && s.comment.trim().length>0); }

function renderImg(){
  const c=C[i], s=ST[i], imgs=c.images||[], wrap=$('imgwrap');
  if(!imgs.length){ wrap.innerHTML='<span class="ph">нет превью</span>'; }
  else{ const url=imgs[Math.min(s.img,imgs.length-1)];
    // build via DOM (src set as a property — never parsed as HTML) → no injection sink
    wrap.innerHTML='';
    const img=document.createElement('img'); img.alt=''; img.src=url;
    img.onerror=function(){ const ph=document.createElement('span'); ph.className='ph'; ph.textContent='превью не загрузилось'; this.replaceWith(ph); };
    wrap.appendChild(img); }
  const multi=imgs.length>1; $('imgprev').hidden=!multi; $('imgnext').hidden=!multi;
  $('dots').innerHTML = multi ? imgs.map(function(_,k){return '<b class="'+(k===s.img?'on':'')+'"></b>';}).join('') : '';
}
function renderStars(dim){
  const s=ST[i], box=$(dim); box.innerHTML='';
  for(let n=1;n<=5;n++){ const b=document.createElement('button');
    b.className='star'+(n<=s[dim]?' on':''); b.textContent=n<=s[dim]?'★':'☆';
    b.setAttribute('role','radio'); b.setAttribute('aria-checked', n===s[dim]?'true':'false');
    b.setAttribute('aria-label', dim.toUpperCase()+' '+n+' из 5');
    b.onclick=function(){ s[dim]=(s[dim]===n?0:n); renderStars(dim); updateConfirm(); };
    box.appendChild(b); }
}
function updateConfirm(){
  const on=hasSel(ST[i]); const b=$('b-confirm'); b.classList.toggle('on',on); b.disabled=!on;
}
function render(){
  const c=C[i], s=ST[i];
  $('counter').textContent=(i+1)+' / '+C.length;
  $('prog').style.width=(i/C.length*100)+'%';
  $('badge').textContent=c.source||''; $('title').textContent=c.title||'Untitled'; $('title').title=c.title||'';
  $('link').href=c.ref_url||'#';
  renderStars('ux'); renderStars('ui');
  $('b-dis').classList.toggle('sel', s.verdict==='dismatch');
  $('b-match').classList.toggle('sel', s.verdict==='match');
  $('cmtbtn').classList.toggle('has', !!(s.comment&&s.comment.trim()));
  $('cmt').value=s.comment||''; $('cmtbox').hidden=true; $('cmtbtn').setAttribute('aria-expanded','false');
  updateConfirm(); renderImg();
}
function toggleVerdict(v){ const s=ST[i]; s.verdict=(s.verdict===v?null:v); render(); }
function confirmCard(){ if(!hasSel(ST[i]))return; ST[i].confirmed=true; advance(); }
function advance(){ if(i<C.length-1){ i++; render(); } else finish(); }
function go(d){ const n=i+d; if(n<0)return; if(n>=C.length){ finish(); return; } i=n; render(); }

$('b-dis').onclick=function(){ toggleVerdict('dismatch'); };
$('b-match').onclick=function(){ toggleVerdict('match'); };
$('b-confirm').onclick=confirmCard;
$('prev').onclick=function(){ go(-1); };
$('next').onclick=function(){ go(1); };   // forward = skip (card stays unconfirmed)
$('cmtbtn').onclick=function(){ const box=$('cmtbox'); const show=box.hidden; box.hidden=!show; this.setAttribute('aria-expanded',String(show)); if(show)$('cmt').focus(); };
$('cmt').oninput=function(){ ST[i].comment=this.value; $('cmtbtn').classList.toggle('has',!!this.value.trim()); updateConfirm(); };
$('imgprev').onclick=function(){ const s=ST[i],L=(C[i].images||[]).length; s.img=(s.img-1+L)%L; renderImg(); };
$('imgnext').onclick=function(){ const s=ST[i],L=(C[i].images||[]).length; s.img=(s.img+1)%L; renderImg(); };
document.addEventListener('keydown',function(e){
  if($('end').classList.contains('show'))return;
  if(document.activeElement===$('cmt'))return;   // don't hijack typing
  if(e.key==='ArrowLeft')go(-1);
  else if(e.key==='ArrowRight')go(1);
  else if(e.key==='Enter')confirmCard();
  else if(e.key==='f'||e.key==='F')toggleVerdict('match');
  else if(e.key==='d'||e.key==='D')toggleVerdict('dismatch');
  else if(e.key==='c'||e.key==='C')$('cmtbtn').click();
});

function answerOf(s){
  if(!s.confirmed) return {card_id:s.card_id, liked:null, score:null, verdict:'skip', ux_score:null, ui_score:null};
  const ux=s.ux?s.ux*2:null, ui=s.ui?s.ui*2:null;
  let verdict, liked;
  if(s.verdict==='match'){ verdict='match'; liked=true; }
  else if(s.verdict==='dismatch'){ verdict='dismatch'; liked=false; }
  else { verdict='rated'; const vals=[s.ux,s.ui].filter(Boolean); const avg=vals.length?vals.reduce((a,b)=>a+b,0)/vals.length:0; liked=vals.length?(avg>=3):null; }
  const sv=[ux,ui].filter(function(x){return x!=null;}); const score=sv.length?Math.round(sv.reduce((a,b)=>a+b,0)/sv.length):(verdict==='match'?10:verdict==='dismatch'?2:null);
  const a={card_id:s.card_id, liked:liked, score:score, verdict:verdict, ux_score:ux, ui_score:ui};
  if(s.comment&&s.comment.trim()) a.comment=s.comment.trim();
  return a;
}
function payload(){ return {round:D.round, round_nonce:D.nonce, answers: ST.map(answerOf)}; }
function finish(){
  const m=ST.filter(s=>s.confirmed&&s.verdict==='match').length, d=ST.filter(s=>s.confirmed&&s.verdict==='dismatch').length,
        r=ST.filter(s=>s.confirmed&&s.verdict==null).length, k=C.length-m-d-r;
  $('sum').innerHTML='Раунд '+D.round+': 👐 совпало <b>'+m+'</b> · ★ оценено <b>'+r+'</b> · 👎 минус <b>'+d+'</b> · ⏭ пропущено <b>'+k+'</b>';
  $('prog').style.width='100%'; $('end').classList.add('show');
}
$('back').onclick=function(){ $('end').classList.remove('show'); i=C.length-1; render(); };
function showTextarea(t){ const ta=$('jsonout'); ta.value=t; ta.hidden=false; ta.focus(); ta.select(); }
$('copy').onclick=async function(){
  const text=JSON.stringify(payload()); let copied=false;
  try{ if(navigator.clipboard&&navigator.clipboard.writeText){ await navigator.clipboard.writeText(text); copied=true; } }catch(e){}
  if(!copied){ showTextarea(text); try{ copied=document.execCommand('copy'); }catch(e){} }
  $('msg').textContent = copied ? '✅ JSON в буфере — вставь его мне в чат' : '👇 выдели текст ниже, скопируй (Cmd+C) и вставь мне в чат';
  if(!copied) showTextarea(text);
};
$('submit').onclick=async function(){
  if(!D.port){ $('msg').textContent='сервер не задан — используй «📋 скопировать JSON»'; return; }
  try{ const r=await fetch('http://127.0.0.1:'+D.port+'/round',{method:'POST',headers:{'Content-Type':'application/json','Authorization':'Bearer '+D.token},body:JSON.stringify(payload())});
    if(r.ok){const j=await r.json();$('msg').textContent='✅ принято ('+(j.accepted||0)+')';this.disabled=true;}
    else if(r.status===409){$('msg').textContent='раунд уже принят';this.disabled=true;}
    else $('msg').textContent='ошибка '+r.status; }catch(e){ $('msg').textContent='сервер недоступен — используй «📋 скопировать JSON»'; }
};
render();
</script></body></html>`;
fs.writeFileSync(outFile, html);
console.log(`wrote ${outFile} (${cards.length} cards, ux/ui+comment+confirm)`);

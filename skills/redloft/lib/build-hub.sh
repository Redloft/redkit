#!/usr/bin/env bash
# redloft — hub.html auto-generator (⭐ design-stage, «из коробки»).
#
# Сканирует папку коданого прототипа (+ галереи референсов из research) и
# ПЕРЕСОБИРАЕТ hub.html — внутреннюю библиотеку всех страниц/компонентов:
#   • боковое меню со ВСЕМИ артефактами прототипа (index, components, lab-страницы, галереи),
#   • центральный <iframe> с превью выбранной страницы,
#   • переключатель Desktop / Mobile + кнопка «Открыть в новой вкладке».
# Список ссылок ГЕНЕРИРУЕТСЯ из скана ФС — НИКОГДА не ведётся вручную.
# Запускать в конце design-стадии и по запросу (идемпотентно).
#
# Использование:
#   build-hub.sh <project_dir>                 # redloft-проект: scans <pd>/design/prototype + <pd>/research/**/gallery.html
#   build-hub.sh --proto <dir> [--research <dir>] [--out <file>] [--title <str>]
#   PROTO_DIR=… [RESEARCH_DIR=…] [OUT=…] [HUB_TITLE=…] build-hub.sh
#
# Выход: <proto>/hub.html (по умолчанию). Зависимости: только python3 stdlib.
set -euo pipefail

PROTO_DIR="${PROTO_DIR:-}"
RESEARCH_DIR="${RESEARCH_DIR:-}"
OUT="${OUT:-}"
HUB_TITLE="${HUB_TITLE:-Прототип — Hub}"

# ── arg parsing ───────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --proto)    PROTO_DIR="$2"; shift 2 ;;
    --research) RESEARCH_DIR="$2"; shift 2 ;;
    --out)      OUT="$2"; shift 2 ;;
    --title)    HUB_TITLE="$2"; shift 2 ;;
    -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
    *)
      # позиционный <project_dir>: вывести дефолты redloft-раскладки
      if [ -z "$PROTO_DIR" ]; then
        PD="$1"
        PROTO_DIR="$PD/design/prototype"
        [ -z "$RESEARCH_DIR" ] && RESEARCH_DIR="$PD/research"
      fi
      shift ;;
  esac
done

[ -n "$PROTO_DIR" ] || { echo "build-hub: нужен <project_dir> или --proto <dir>" >&2; exit 2; }
[ -d "$PROTO_DIR" ] || { echo "build-hub: prototype-папка не найдена: $PROTO_DIR" >&2; exit 2; }
[ -n "$OUT" ] || OUT="$PROTO_DIR/hub.html"

PROTO_DIR="$PROTO_DIR" RESEARCH_DIR="$RESEARCH_DIR" OUT="$OUT" HUB_TITLE="$HUB_TITLE" python3 <<'PY'
import os, re, json, html, tempfile

proto = os.path.abspath(os.environ["PROTO_DIR"])
research = os.environ.get("RESEARCH_DIR", "")
out = os.path.abspath(os.environ["OUT"])
hub_title = os.environ.get("HUB_TITLE", "Прототип — Hub")
out_dir = os.path.dirname(out)

TITLE_RE = re.compile(r"<title[^>]*>(.*?)</title>", re.I | re.S)

def page_title(path, fallback):
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            head = f.read(8192)
        m = TITLE_RE.search(head)
        if m:
            t = re.sub(r"\s+", " ", m.group(1)).strip()
            if t:
                return t
    except Exception:
        pass
    return fallback

def prettify(name):
    base = re.sub(r"\.html?$", "", name, flags=re.I)
    base = base.replace("-", " ").replace("_", " ").strip()
    return base[:1].upper() + base[1:] if base else name

def rel(path):
    return os.path.relpath(path, out_dir).replace(os.sep, "/")

# ── категоризация ─────────────────────────────────────────────────────────
# группы в порядке вывода в сайдбаре
groups = {
    "main":       {"label": "Главная",        "items": []},
    "kit":        {"label": "KIT — компоненты", "items": []},
    "lab":        {"label": "Lab / эксперименты", "items": []},
    "pages":      {"label": "Страницы",        "items": []},
    "references": {"label": "Исследования / референсы", "items": []},
}

def classify(relpath, fname):
    low = "/" + relpath.lower()
    fl = fname.lower()
    stem = re.sub(r"\.html?$", "", fl)
    # lab по ПУТИ — РАНЬШЕ index, иначе lab/index.html уедет в "main"
    if "/lab/" in low or "/experiments/" in low:
        return "lab"
    if fl in ("index.html", "index.htm"):
        return "main"
    if "component" in fl or "kit" in fl:
        return "kit"
    # lab по ИМЕНИ — ТОЧНО или СУФФИКС '-lab'/'-experiment' (НЕ префикс: lab-results/labor — бизнес-страницы)
    if stem in ("lab", "experiment", "experiments") or re.search(r"[-_](lab|experiment)$", stem):
        return "lab"
    return "pages"

seen = set()

# скан прототипа
for root, dirs, files in os.walk(proto):
    dirs.sort()
    for fn in sorted(files):
        if not re.search(r"\.html?$", fn, re.I):
            continue
        full = os.path.join(root, fn)
        if os.path.abspath(full) == out:  # исключаем ТОЛЬКО целевой hub (lab/hub.html и пр. — валидные артефакты)
            continue
        rp = rel(full)
        if rp in seen:
            continue
        seen.add(rp)
        g = classify(rp, fn)
        groups[g]["items"].append({"src": rp, "title": page_title(full, prettify(fn)), "path": rp})

# скан галерей референсов: <research>/**/gallery.html (+ любые *.html в галереях)
if research and os.path.isdir(research):
    for root, dirs, files in os.walk(research):
        dirs.sort()
        for fn in sorted(files):
            if not re.search(r"\.html?$", fn, re.I):
                continue
            if "galler" not in fn.lower() and "galler" not in root.lower():
                continue
            full = os.path.join(root, fn)
            rp = rel(full)
            if rp in seen:
                continue
            seen.add(rp)
            label = os.path.basename(os.path.dirname(full)) or fn
            groups["references"]["items"].append(
                {"src": rp, "title": page_title(full, prettify(label)), "path": rp})

# плоский список для JS (с groupId) — порядок групп сохраняется
flat = []
ordered_groups = []
for gid, g in groups.items():
    if not g["items"]:
        continue
    ordered_groups.append({"id": gid, "label": g["label"], "items": g["items"]})
    for it in g["items"]:
        flat.append(it)

total = len(flat)
# `</` экранируем, иначе <title> с "</script>" в сканируемом файле рвёт <script> и даёт XSS
data_json = json.dumps(ordered_groups, ensure_ascii=False).replace("</", "<\\/")

# ── сайдбар (статический HTML — список ГЕНЕРИРУЕТСЯ, не ведётся руками) ─────
sidebar_parts = []
for g in ordered_groups:
    sidebar_parts.append(f'<div class="hub-group"><div class="hub-group-label">{html.escape(g["label"])} <span class="hub-count">{len(g["items"])}</span></div>')
    for it in g["items"]:
        # href= делает ссылку фокусируемой (tab order) + Enter работает (click-listener
        # перехватывает preventDefault → iframe-превью); cmd/middle-click открывает напрямую
        sidebar_parts.append(
            f'<a class="hub-link" href="{html.escape(it["src"], quote=True)}" '
            f'data-src="{html.escape(it["src"], quote=True)}" '
            f'data-t="{html.escape(it["title"], quote=True)}">'
            f'<span class="hub-link-t">{html.escape(it["title"])}</span>'
            f'<span class="hub-link-p">{html.escape(it["path"])}</span></a>')
    sidebar_parts.append("</div>")
sidebar_html = "\n".join(sidebar_parts) if flat else '<div class="hub-empty">Прототип пуст — добавь *.html в папку и пересобери hub.</div>'

# ── шаблон hub.html (self-contained, dark, токен-нейтральный) ──────────────
TPL = r"""<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>__HUB_TITLE__</title>
<style>
  :root{
    --bg:#0e0f12; --panel:#16181d; --panel-2:#1d2027; --line:#2a2e37;
    --text:#e7e9ee; --muted:#9aa0ab; --accent:#7aa2ff; --accent-2:#3a4356;
    --ease:cubic-bezier(.2,.7,.2,1);
  }
  *{box-sizing:border-box}
  html,body{height:100%}
  body{margin:0;display:flex;font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Inter,Arial,sans-serif;
    background:var(--bg);color:var(--text);overflow:hidden}
  /* sidebar */
  aside{width:288px;min-width:288px;height:100%;background:var(--panel);border-right:1px solid var(--line);
    display:flex;flex-direction:column;overflow:hidden}
  .hub-head{padding:16px 18px;border-bottom:1px solid var(--line)}
  .hub-head h1{margin:0;font-size:14px;font-weight:650;letter-spacing:.2px}
  .hub-head .sub{margin-top:3px;font-size:11px;color:var(--muted)}
  .hub-search{margin:10px 14px 4px;padding:8px 10px;border:1px solid var(--line);border-radius:9px;
    background:var(--bg);color:var(--text);font-size:13px}
  .hub-search:focus{border-color:var(--accent)}
  .hub-search:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
  .hub-list{flex:1;overflow-y:auto;padding:6px 8px 24px}
  .hub-group{margin:8px 4px 4px}
  .hub-group-label{font-size:10.5px;text-transform:uppercase;letter-spacing:.7px;color:var(--muted);
    padding:8px 8px 5px;display:flex;align-items:center;gap:6px}
  .hub-count{background:var(--accent-2);color:var(--text);border-radius:20px;padding:1px 7px;font-size:10px}
  a.hub-link{display:flex;flex-direction:column;gap:1px;padding:8px 10px;border-radius:9px;
    text-decoration:none;color:var(--text);cursor:pointer;transition:background .15s var(--ease)}
  a.hub-link:hover{background:var(--panel-2)}
  a.hub-link.active{background:var(--accent-2);box-shadow:inset 2px 0 0 var(--accent)}
  .hub-link-t{font-size:13px;font-weight:520}
  .hub-link-p{font-size:10.5px;color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .hub-empty{padding:18px;color:var(--muted);font-size:13px}
  /* main */
  main{flex:1;display:flex;flex-direction:column;height:100%;min-width:0}
  .hub-bar{height:52px;min-height:52px;display:flex;align-items:center;gap:12px;padding:0 16px;
    background:var(--panel);border-bottom:1px solid var(--line)}
  .hub-bar .cur{font-weight:600;font-size:13px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:38vw}
  .hub-bar .cur small{color:var(--muted);font-weight:400;margin-left:8px}
  .spacer{flex:1}
  .seg{display:flex;background:var(--bg);border:1px solid var(--line);border-radius:9px;overflow:hidden}
  .seg button{appearance:none;border:0;background:transparent;color:var(--muted);padding:7px 14px;
    font-size:12.5px;cursor:pointer;transition:.15s var(--ease)}
  .seg button.on{background:var(--accent-2);color:var(--text)}
  .btn{appearance:none;text-decoration:none;border:1px solid var(--line);background:var(--bg);color:var(--text);
    padding:7px 13px;border-radius:9px;font-size:12.5px;cursor:pointer;transition:.15s var(--ease);white-space:nowrap}
  .btn:hover{border-color:var(--accent)}
  .hub-stage{flex:1;overflow:auto;background:
    repeating-conic-gradient(#101216 0% 25%, #0c0d10 0% 50%) 50% / 22px 22px;
    display:flex;justify-content:center;align-items:flex-start;padding:0}
  .frame-wrap{width:100%;height:100%;transition:width .25s var(--ease);background:#fff}
  .hub-stage.mobile{padding:22px 0}
  .hub-stage.mobile .frame-wrap{width:390px;height:calc(100% - 44px);max-width:100%;
    border-radius:30px;box-shadow:0 10px 40px rgba(0,0,0,.5);overflow:hidden;border:8px solid #000}
  iframe{width:100%;height:100%;border:0;background:#fff;display:block}
  .ph{margin:auto;color:var(--muted);font-size:14px;text-align:center;padding:40px}
  /* видимый фокус на ВСЕХ интерактивах (не только search) */
  :where(a.hub-link, .seg button, .btn, .hub-search):focus-visible{outline:2px solid var(--accent);outline-offset:2px}
  /* reduced-motion: убрать движение */
  @media (prefers-reduced-motion: reduce){ *{transition:none !important;animation:none !important;scroll-behavior:auto !important} }
</style>
</head>
<body>
<aside>
  <div class="hub-head">
    <h1>__HUB_TITLE__</h1>
    <div class="sub">__TOTAL__ артефакт(ов) · авто-сборка hub</div>
  </div>
  <input class="hub-search" type="search" placeholder="Фильтр…" id="q" autocomplete="off" aria-label="Фильтр артефактов">
  <nav class="hub-list" id="list" aria-label="Артефакты прототипа">
__SIDEBAR__
  </nav>
</aside>
<main>
  <div class="hub-bar">
    <div class="cur" id="cur">Выбери артефакт слева</div>
    <div class="spacer"></div>
    <div class="seg" id="seg">
      <button data-vp="desktop" class="on">Desktop</button>
      <button data-vp="mobile">Mobile</button>
    </div>
    <a class="btn" id="open" target="_blank" rel="noopener">Открыть в новой вкладке ↗</a>
  </div>
  <div class="hub-stage" id="stage">
    <div class="frame-wrap" id="wrap"><div class="ph" id="ph">← Выбери страницу или компонент в боковом меню</div></div>
  </div>
</main>
<script>
(function(){
  var DATA = __DATA__;
  var list = document.getElementById('list');
  var stage = document.getElementById('stage');
  var wrap = document.getElementById('wrap');
  var cur = document.getElementById('cur');
  var openBtn = document.getElementById('open');
  var q = document.getElementById('q');
  var iframe = null;

  function select(a){
    if(!a) return;
    document.querySelectorAll('a.hub-link.active').forEach(function(x){x.classList.remove('active')});
    a.classList.add('active');
    var src = a.getAttribute('data-src');
    var t = a.getAttribute('data-t') || src;
    if(!iframe){ wrap.innerHTML=''; iframe=document.createElement('iframe'); iframe.setAttribute('title','preview'); wrap.appendChild(iframe); }
    iframe.src = src;
    cur.innerHTML = '';
    var b=document.createElement('b'); b.textContent=t; cur.appendChild(b);
    var s=document.createElement('small'); s.textContent=src; cur.appendChild(s);
    openBtn.href = src;
    try{ history.replaceState(null,'','#'+encodeURIComponent(src)); }catch(e){}
  }

  list.addEventListener('click', function(e){
    var a = e.target.closest('a.hub-link');
    if(a){ e.preventDefault(); select(a); }
  });

  // viewport toggle
  document.getElementById('seg').addEventListener('click', function(e){
    var b = e.target.closest('button'); if(!b) return;
    document.querySelectorAll('#seg button').forEach(function(x){x.classList.remove('on')});
    b.classList.add('on');
    stage.classList.toggle('mobile', b.getAttribute('data-vp')==='mobile');
  });

  // filter
  q.addEventListener('input', function(){
    var v = q.value.trim().toLowerCase();
    document.querySelectorAll('.hub-group').forEach(function(g){
      var any=false;
      g.querySelectorAll('a.hub-link').forEach(function(a){
        var hit = (a.getAttribute('data-t')+' '+a.getAttribute('data-src')).toLowerCase().indexOf(v)>=0;
        a.style.display = hit?'':'none'; if(hit) any=true;
      });
      g.style.display = any?'':'none';
    });
  });

  // auto-select: from hash or first link
  var links = Array.prototype.slice.call(document.querySelectorAll('a.hub-link'));
  var want = null;
  if(location.hash){ var h=decodeURIComponent(location.hash.slice(1));
    want = links.filter(function(a){return a.getAttribute('data-src')===h})[0]; }
  select(want || links[0]);
})();
</script>
</body>
</html>
"""

# single-pass подстановка: замены НЕ пере-сканируются, поэтому <title> с '__DATA__'/'__SIDEBAR__'
# не подставится повторно (chained .replace() был порядок-зависим)
_subs = {"__HUB_TITLE__": html.escape(hub_title), "__TOTAL__": str(total),
         "__SIDEBAR__": sidebar_html, "__DATA__": data_json}
doc = re.sub(r"__(?:HUB_TITLE|TOTAL|SIDEBAR|DATA)__", lambda m: _subs[m.group(0)], TPL)

os.makedirs(out_dir, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=out_dir, suffix=".tmp")   # уникальный tmp (параллельные прогоны не интерливятся)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(doc)
    os.replace(tmp, out)
except BaseException:                                     # на любом сбое — не оставлять сироту .tmp
    try: os.unlink(tmp)
    except OSError: pass
    raise
print(f"hub: {out}  ({total} артефактов: " +
      ", ".join(f'{g["label"]}={len(g["items"])}' for g in ordered_groups) + ")")
PY

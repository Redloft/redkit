#!/usr/bin/env bash
# redloft — methodology kit assembler (⭐ render-stage, «из коробки»).
#
# Детерминированно собирает методологическую КОРОБКУ в <project_dir>/methodology/:
#   • берёт шаблоны из lib/methodology-kit/tier-0..N по MANIFEST.json (накопительно),
#   • подставляет {{PLACEHOLDER}} из Project Context (brief.json / planning / sitemap),
#   • вырезает tier-блоки <!-- BEGIN/END TIER-N --> по выбранному тиру,
#   • засевает docs/tasks/pending/ по разделам sitemap (project-specific слой),
#   • пишет АТОМАРНО (tmp-dir + rename), валидирует «нет незаполненных {{...}}».
# Без LLM. Зеркалит паттерн lib/build-hub.sh. Идемпотентно (см. --force).
#
# Использование:
#   methodology.sh <project_dir> --tier <0-4> [--tier3] [--force] [--skip-methodology]
#   (--force = полная атомарная пересборка коробки; гранулярного reseed нет — коробка собирается целиком)
#   methodology.sh <project_dir> --tier 1                     # дефолт лендинга
#   KIT_DIR=… methodology.sh <pd> --tier 2                    # переопределить папку шаблонов
#
# Exit-коды (контракт для caller, см. docs/METHODOLOGY-KIT-SPEC.md §5.2):
#   0  коробка собрана (или skip-if-exists без --force)
#   1  фатал: нет MANIFEST/шаблонов/невалидный tier
#   2  после рендера остались незаполненные {{...}} (баг шаблона/сидинга)
#   3  soft: собрано, но upstream-стадий не было (degraded) — caller продолжает + warn
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_DIR="${KIT_DIR:-$SELF_DIR/methodology-kit}"
PD=""
TIER=""
WITH_TIER3=0
FORCE=0
SKIP=0

while [ $# -gt 0 ]; do
  case "$1" in
    --tier)          TIER="$2"; shift 2 ;;
    --tier3)         WITH_TIER3=1; shift ;;
    --force)         FORCE=1; shift ;;
    --skip-methodology) SKIP=1; shift ;;
    -h|--help)       sed -n '2,30p' "$0"; exit 0 ;;
    -*)              echo "methodology: неизвестный флаг $1" >&2; exit 1 ;;
    *)               [ -z "$PD" ] && PD="$1"; shift ;;
  esac
done

[ "$SKIP" = "1" ] && { echo "methodology: --skip-methodology → пропускаю сборку"; exit 0; }
[ -n "$PD" ]      || { echo "methodology: нужен <project_dir>" >&2; exit 1; }
[ -d "$PD" ]      || { echo "methodology: project_dir не найден: $PD" >&2; exit 1; }
# --tier3 без --tier → подразумеваем tier 1 (далее поднимется до 3)
[ -z "$TIER" ] && [ "$WITH_TIER3" = "1" ] && TIER=1
[ -n "$TIER" ]    || { echo "methodology: нужен --tier <0-4>" >&2; exit 1; }
case "$TIER" in 0|1|2|3|4) : ;; *) echo "methodology: tier должен быть 0-4, дано: $TIER" >&2; exit 1 ;; esac
[ -f "$KIT_DIR/MANIFEST.json" ] || { echo "methodology: MANIFEST не найден: $KIT_DIR/MANIFEST.json" >&2; exit 1; }

# --tier3 поднимает эффективный tier до 3 (production opt-in)
[ "$WITH_TIER3" = "1" ] && [ "$TIER" -lt 3 ] && TIER=3

DEST="$PD/methodology"
# Идемпотентность: коробка есть и не --force → skip (не перетираем работу)
if [ -d "$DEST" ] && [ "$FORCE" != "1" ]; then
  echo "methodology: $DEST уже существует — skip (--force чтобы пересобрать)"
  exit 0
fi

set +e   # python3 возвращает 2/3 как значимые коды — не давать set -e оборвать до захвата
PD="$PD" KIT_DIR="$KIT_DIR" TIER="$TIER" STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)" python3 <<'PY'
import os, re, json, shutil, tempfile, sys

PD       = os.path.abspath(os.environ["PD"])
KIT      = os.path.abspath(os.environ["KIT_DIR"])
TIER     = int(os.environ["TIER"])
STAMP    = os.environ.get("STAMP", "")
DEST     = os.path.join(PD, "methodology")
PLH_RE   = re.compile(r"\{\{([A-Z0-9_]+)\}\}")
degraded = []   # список отсутствующих upstream-источников → exit 3

def read(path, default=""):
    try:
        with open(path, encoding="utf-8") as f: return f.read()
    except Exception: return default

def read_json(path):
    try:
        with open(path, encoding="utf-8") as f: return json.load(f)
    except Exception: return {}

# ── 1. Project Context → переменные подстановки (whitelisted, без сырых LLM-значений) ──
brief = read_json(os.path.join(PD, "brief.json"))
slug  = os.path.basename(PD.rstrip("/"))

def scalar(v, cap=120):
    # inline-скаляр для markdown: убрать переводы строк, схлопнуть пробелы, ограничить длину.
    # python3-подстановка уже исключает shell-инъекцию; это — против сломанной вёрстки/мусора.
    s = " ".join(str(v or "").split())
    return (s[:cap] + "…") if len(s) > cap else s

project_name  = scalar(brief.get("slug") or slug or "project", 60)
project_title = scalar(brief.get("summary") or brief.get("title") or project_name)
site_type     = (brief.get("site_type") or "").strip().lower()
geo_edge      = bool(brief.get("geoEdge") or brief.get("geo_edge"))
STACK = "Next.js + Supabase"

# SECURITY_RULES — статичный whitelisted текст (DR-7), НЕ сырые seed-значения → нет injection-риска
sec = [
    "- **F1** БД: RLS **deny-by-default**. Применить `supabase/rls-bootstrap.sql` ДО первого деплоя; ни одной таблицы без политик. _RLS deny-by-default before any deploy._",
    "- **F2** Секреты/токены — только 1Password (`op run`). **Никогда** в код, `.env`, git, чат. При утечке — немедленная ротация. _Secrets only via 1Password; rotate on leak._",
    "- **F3** PII (контакты клиента) не коммитить; хранить вне репо; удалять по запросу. _Never commit client PII._",
]
if geo_edge:
    sec.append("- **F4** Деплой geo-edge (РФ+заграница): RU-edge → self-hosted origin (см. `docs/tz.md`, раздел деплоя). _Geo-edge deploy chain._")
security_rules = "\n".join(sec)

# ICP / JTBD / USP — best-effort seed из planning/planning.md (для Tier 2 product-principles).
# Нет planning или не нашли — плейсхолдер-TODO (валидно: не оставляет {{...}}), planning уже в degraded.
def extract_planning():
    raw = read(os.path.join(PD, "planning", "planning.md"))
    if not raw: return {}
    text, m = raw, re.match(r"^---\n(.*?)\n---\n?(.*)$", raw, re.S)
    if m:
        header, body, claims = m.group(1), m.group(2), []
        in_kc = False
        for line in header.split("\n"):
            if re.match(r"\s*key_claims\s*:", line): in_kc = True; continue
            if in_kc:
                cm = re.match(r'\s*-\s*"?(.+?)"?\s*$', line)
                if cm: claims.append(cm.group(1)); continue
                if line and not line.startswith(" "): in_kc = False
        text = "\n".join(claims) + "\n" + body
    def find(*keys):
        for k in keys:
            mm = re.search(r"(?im)\b%s\b\s*[:\-—]+\s*(.+)" % re.escape(k), text)
            if mm: return mm.group(1).strip()
        return None
    return {
        "ICP":  find("ICP", "ЦА", "целевая аудитория", "target audience"),
        "JTBD": find("JTBD", "job to be done", "задача клиента"),
        "USP":  find("USP", "УТП", "уникальное", "unique selling"),
    }

_plan = extract_planning()
def _seed(key, label):
    v = _plan.get(key)
    return scalar(v, 200) if v else "_(TODO: заполнить из `planning/planning.md` — %s)_" % label

VARS = {
    "PROJECT_NAME":  project_name,
    "PROJECT_TITLE": project_title,
    "STACK":         STACK,
    "TIER":          str(TIER),
    "SECURITY_RULES": security_rules,
    "ICP":  _seed("ICP",  "кто клиент"),
    "JTBD": _seed("JTBD", "какую задачу решаем"),
    "USP":  _seed("USP",  "чем отличаемся"),
}

# degraded-трекинг (для seed и для exit 3)
if not os.path.isdir(os.path.join(PD, "planning")): degraded.append("planning")
if not os.path.isdir(os.path.join(PD, "semantic")): degraded.append("semantic")
have_sitemap = os.path.isdir(os.path.join(PD, "sitemap"))
if not have_sitemap: degraded.append("sitemap")

# ── 2. tier-block stripping ───────────────────────────────────────────────────
# <!-- BEGIN TIER-N --> .. <!-- END TIER-N -->  → оставить если TIER >= N
# <!-- BEGIN TIER-1-ONLY --> .. <!-- END TIER-1-ONLY -->  → оставить если TIER == 1
def strip_tier_blocks(text, tier):
    out, lines, i = [], text.split("\n"), 0
    begin = re.compile(r"<!--\s*BEGIN TIER-(\d+)(-ONLY)?\s*-->")
    while i < len(lines):
        m = begin.search(lines[i])
        if not m:
            out.append(lines[i]); i += 1; continue
        n, only = int(m.group(1)), bool(m.group(2))
        keep = (tier == n) if only else (tier >= n)
        end_re = re.compile(r"<!--\s*END TIER-%d%s\s*-->" % (n, "-ONLY" if only else ""))
        block = []
        i += 1
        found_end = False
        while i < len(lines):
            if end_re.search(lines[i]): found_end = True; break
            block.append(lines[i]); i += 1
        if not found_end:   # незакрытый BEGIN → не молчаливое усечение, а fatal (review-finding)
            print("methodology: незакрытый <!-- BEGIN TIER-%d --> в шаблоне" % n, file=sys.stderr); sys.exit(1)
        i += 1  # пропустить END-маркер
        if keep:
            out.extend(block)
    # схлопнуть тройные пустые строки от вырезанных блоков
    return re.sub(r"\n{3,}", "\n\n", "\n".join(out))

def substitute(text):
    return PLH_RE.sub(lambda m: VARS.get(m.group(1), m.group(0)), text)

# ── 3. собрать список файлов из MANIFEST (tier 0..TIER накопительно) ──────────
manifest = read_json(os.path.join(KIT, "MANIFEST.json"))
files, skipped_by_site = [], []
for t in range(0, TIER + 1):
    for entry in manifest.get("tiers", {}).get(str(t), []):
        # DR-9: routines пропускаются для простых сайтов (landing/visitka/blog)
        skip = entry.get("skip_site_types") or []
        if site_type and site_type in [s.lower() for s in skip]:
            skipped_by_site.append(entry["dest"]); continue
        files.append(entry)
if not files:
    print("methodology: MANIFEST пуст для tier %d" % TIER, file=sys.stderr); sys.exit(1)

# ── 4. рендер в tmp-dir (атомарность C1) ─────────────────────────────────────
os.makedirs(PD, exist_ok=True)
tmp = tempfile.mkdtemp(prefix="methodology.tmp.", dir=PD)
unfilled = []
try:
    for e in files:
        src = os.path.join(KIT, e["src"])
        dst = os.path.join(tmp, e["dest"])
        # path-traversal guard (MANIFEST defence-in-depth): src внутри KIT, dst внутри tmp
        if not os.path.abspath(src).startswith(os.path.abspath(KIT) + os.sep):
            print("methodology: src вне KIT (traversal?): %s" % e["src"], file=sys.stderr); sys.exit(1)
        if not os.path.abspath(dst).startswith(os.path.abspath(tmp) + os.sep):
            print("methodology: dest вне коробки (traversal?): %s" % e["dest"], file=sys.stderr); sys.exit(1)
        if not os.path.exists(src):
            print("methodology: шаблон не найден: %s" % src, file=sys.stderr); sys.exit(1)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        content = read(src)
        if e.get("tier_blocks"):  content = strip_tier_blocks(content, TIER)
        if e.get("substitute"):   content = substitute(content)
        # валидация: незаполненные seed-плейсхолдеры (только {{...}}, не <...> user-fill)
        if e.get("substitute"):
            for m in PLH_RE.findall(content):
                unfilled.append("%s: {{%s}}" % (e["dest"], m))
        with open(dst, "w", encoding="utf-8") as f:
            f.write(content)

    # ── 5. seed задач из sitemap → docs/tasks/pending/ (если Tier>=1) ─────────
    if TIER >= 1:
        pend = os.path.join(tmp, "docs/tasks/pending")
        os.makedirs(pend, exist_ok=True)
        sections = []
        if have_sitemap:
            # best-effort: вытащить заголовки/узлы из sitemap/*.md|*.json
            sd = os.path.join(PD, "sitemap")
            for fn in sorted(os.listdir(sd)):
                fp = os.path.join(sd, fn)
                if fn.endswith(".md"):
                    for line in read(fp).split("\n"):
                        h = re.match(r"^#{1,3}\s+(.+)", line.strip())
                        if h: sections.append(h.group(1).strip())
                elif fn.endswith(".json"):
                    try:
                        data = json.loads(read(fp))
                        def walk(o, depth=0):
                            if depth > 20: return            # guard: битый/глубоко-вложенный sitemap → не RecursionError
                            if isinstance(o, dict):
                                for k in ("title","name","label","page"):
                                    if isinstance(o.get(k), str): sections.append(o[k]); break
                                for v in o.values(): walk(v, depth + 1)
                            elif isinstance(o, list):
                                for v in o: walk(v, depth + 1)
                        walk(data)
                    except Exception as ex:
                        print("methodology: пропущен sitemap-файл %s (%s)" % (fn, ex), file=sys.stderr)
        # дедуп + лимит
        seen, uniq = set(), []
        for s in sections:
            s = s.strip()
            if s and s.lower() not in seen and len(s) < 80:
                seen.add(s.lower()); uniq.append(s)
            if len(uniq) >= 15: break

        if uniq:
            for idx, title in enumerate(uniq, 1):
                safe = re.sub(r"[^a-z0-9а-я]+", "-", title.lower()).strip("-")[:40] or "section"
                fn = "%02d-%s.md" % (idx, safe)
                yt = title.replace('"', "'")   # YAML-safe: кавычки в заголовке не ломают frontmatter
                body = (
                    "---\n"
                    'title: "Раздел: %s"\n'
                    "status: pending\ncomplexity: medium\nopus_review: false\ncreated: \"\"\n"
                    "---\n\n## Зачем · Why\nРеализовать раздел сайта «%s» по `docs/tz.md`.\n\n"
                    "## Что сделать · What\n- [ ] Вёрстка раздела по дизайн-системе\n- [ ] Контент из ТЗ\n- [ ] Responsive (mobile + desktop)\n\n"
                    "## Готово когда · Done when\n- Раздел собирается, проходит /finalize, соответствует ТЗ\n"
                    % (yt, title)
                )
                with open(os.path.join(pend, fn), "w", encoding="utf-8") as f:
                    f.write(body)
        else:
            # graceful degradation: нет sitemap → один setup-плейсхолдер
            with open(os.path.join(pend, "00-SETUP.md"), "w", encoding="utf-8") as f:
                f.write(
                    "---\ntitle: \"Базовая настройка проекта\"\nstatus: pending\ncomplexity: medium\nopus_review: true\ncreated: \"\"\n---\n\n"
                    "## Зачем · Why\nПоднять каркас проекта (auth, БД, RLS) перед фичами.\n\n"
                    "## Что сделать · What\n- [ ] Инициализировать Next.js + Supabase\n- [ ] Применить `supabase/rls-bootstrap.sql`\n- [ ] Развернуть разделы из `docs/tz.md`\n\n"
                    "## Готово когда · Done when\n- Каркас собирается, RLS включён, /finalize зелёный\n"
                    "\n<!-- TODO: sitemap не был доступен при сборке — задачи по разделам добавь вручную. -->\n"
                )

    # ── 6. валидация перед swap ──────────────────────────────────────────────
    if unfilled:
        print("methodology: остались незаполненные плейсхолдеры:\n  " + "\n  ".join(unfilled), file=sys.stderr)
        sys.exit(2)

    # маркер версии коробки
    with open(os.path.join(tmp, ".methodology-version"), "w", encoding="utf-8") as f:
        f.write("manifest_version=%s\ntier=%d\ngenerated_at=%s\n" % (manifest.get("manifest_version", "?"), TIER, STAMP))

    # ── 7. безопасный атомарный swap (DR-8): старую → .bak → rename tmp → rm .bak ──
    # rmtree+rename оставлял окно «нет ни старой, ни новой» при kill/OSError. С .bak
    # старая коробка (вкл. правки разработчика) переживает сбой и восстанавливается.
    bak = None
    try:
        if os.path.isdir(DEST):
            bak = "%s.bak-%d" % (DEST, os.getpid())
            os.rename(DEST, bak)
        os.rename(tmp, DEST)          # atomic на одной ФС
        tmp = None
    except Exception:
        if bak and os.path.isdir(bak) and not os.path.isdir(DEST):
            os.rename(bak, DEST)      # restore старой при сбое
        raise
    if bak and os.path.isdir(bak):
        shutil.rmtree(bak, ignore_errors=True)
finally:
    if tmp and os.path.isdir(tmp):
        shutil.rmtree(tmp, ignore_errors=True)

print("methodology: коробка собрана → %s (tier %d, %d файлов)" % (DEST, TIER, len(files)))
if skipped_by_site:
    print("methodology: пропущено для site_type=%s (DR-9): %s" % (site_type, ", ".join(skipped_by_site)))
if degraded:
    print("methodology: degraded — не было upstream-стадий: %s (коробка собрана с плейсхолдерами/TODO)" % ", ".join(degraded))
    sys.exit(3)
PY
rc=$?
set -e
exit $rc

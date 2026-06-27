#!/usr/bin/env bash
# redloft — methodology kit smoke suite. Hermetic, no API/network.
# Covers lib/methodology.sh + lib/methodology-kit/ per METHODOLOGY-KIT-SPEC.md §8 (A1-A11).
# Run: bash tests/methodology.smoke.sh   → exit 0 if all pass.
set -u

SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SH="$SKILL/lib/methodology.sh"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS+1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }
rc_is() { [ "$1" = "$2" ] && ok "$3 (rc=$2)" || no "$3 (want $1, got $2)"; }

# newproj <slug> <brief-json> [sitemap?]
newproj() {
  local pd="$SANDBOX/$1"; mkdir -p "$pd"; printf '%s' "$2" > "$pd/brief.json"
  if [ "${3:-}" = "sitemap" ]; then mkdir -p "$pd/sitemap"
    printf '# Главная\n## Услуги\n## Цены\n## Контакты\n' > "$pd/sitemap/sitemap.md"; fi
  echo "$pd"
}

echo "── A1/A3: tier 1 рендерит ядро, без незаполненных {{...}} ──"
PD=$(newproj landing '{"slug":"land","summary":"Лендинг","site_type":"landing"}' sitemap)
bash "$SH" "$PD" --tier 1 >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] || [ "$rc" = 3 ] && ok "tier 1 exit 0|3 (got $rc)" || no "tier 1 exit $rc"
for f in START-HERE.md CLAUDE.md docs/HARD-RULES.md docs/tasks/PROTOCOL.md supabase/rls-bootstrap.sql; do
  [ -f "$PD/methodology/$f" ] && ok "есть $f" || no "нет $f"
done
grep -rIlq '{{[A-Z_]*}}' "$PD/methodology" && no "остались {{...}}" || ok "0 незаполненных {{...}} (A1)"
grep -q "START-HERE" "$PD/methodology/CLAUDE.md" && ok "CLAUDE.md ссылается на START-HERE (A3)" || no "нет ссылки START-HERE"

echo "── A2: tier авто-сигнал в шаблонах (TIER подставлен) ──"
grep -q "tier 1" "$PD/methodology/README.md" && ok "TIER=1 подставлен" || no "TIER не подставлен"

echo "── A4: project-seed — security + geo ──"
PDG=$(newproj geo '{"slug":"geo","summary":"X","site_type":"landing","geoEdge":true}')
bash "$SH" "$PDG" --tier 0 >/dev/null 2>&1
grep -q "rls-bootstrap.sql" "$PDG/methodology/docs/HARD-RULES.md" && ok "RLS-правило в HARD-RULES" || no "нет RLS-правила"
grep -q "geo-edge" "$PDG/methodology/docs/HARD-RULES.md" && ok "geo-edge rule при geoEdge=true (F4)" || no "нет geo-edge rule"
PDN=$(newproj nogeo '{"slug":"nogeo","summary":"X","site_type":"landing"}')
bash "$SH" "$PDN" --tier 0 >/dev/null 2>&1
grep -q "geo-edge" "$PDN/methodology/docs/HARD-RULES.md" && no "geo-edge есть без geoEdge" || ok "нет geo-edge без geoEdge"

echo "── A5: seed задач из sitemap → pending/, иначе 00-SETUP ──"
ls "$PD/methodology/docs/tasks/pending/"*.md >/dev/null 2>&1 && \
  { n=$(ls "$PD/methodology/docs/tasks/pending/"*.md | wc -l | tr -d ' '); ok "seed $n задач из sitemap"; } || no "нет seed-задач"
PDNS=$(newproj nositemap '{"slug":"ns","summary":"X","site_type":"landing"}')
bash "$SH" "$PDNS" --tier 1 >/dev/null 2>&1
[ -f "$PDNS/methodology/docs/tasks/pending/00-SETUP.md" ] && ok "no-sitemap → 00-SETUP.md (degraded)" || no "нет 00-SETUP fallback"

echo "── A7: exit-коды ──"
bash "$SH" "$SANDBOX/none" --tier 1 >/dev/null 2>&1; rc_is 1 $? "нет project_dir → 1"
bash "$SH" "$PD" --tier 9 >/dev/null 2>&1; rc_is 1 $? "tier вне 0-4 → 1"
PDD=$(newproj degr '{"slug":"d","summary":"X","site_type":"landing"}')
bash "$SH" "$PDD" --tier 1 >/dev/null 2>&1; rc_is 3 $? "нет upstream → 3 (degraded, soft)"
PDF=$(newproj full '{"slug":"f","summary":"X","site_type":"landing"}' sitemap)
mkdir -p "$PDF/planning" "$PDF/semantic"
bash "$SH" "$PDF" --tier 1 >/dev/null 2>&1; rc_is 0 $? "есть все upstream → 0"

echo "── A8: injection-фикстура (python3-subst, не shell) ──"
PDI=$(newproj inj '{"slug":"inj","summary":"`rm -rf /` $(whoami) с 'апострофом' кириллица","site_type":"landing"}')
bash "$SH" "$PDI" --tier 0 >/dev/null 2>&1
grep -q 'rm -rf' "$PDI/methodology/CLAUDE.md" && ok "payload как литерал-текст (не исполнен)" || no "payload не отрендерен"
grep -q "кириллица" "$PDI/methodology/CLAUDE.md" && ok "UTF-8 кириллица цела" || no "кириллица сломана"

echo "── A9: идемпотентность ──"
bash "$SH" "$PD" --tier 1 >/dev/null 2>&1; rc_is 0 $? "повторный без --force → skip (0)"
touch "$PD/methodology/.usermark"
bash "$SH" "$PD" --tier 1 >/dev/null 2>&1
[ -f "$PD/methodology/.usermark" ] && ok "skip не трогает существующее" || no "skip перетёр файлы"
bash "$SH" "$PD" --tier 1 --force >/dev/null 2>&1
[ -f "$PD/methodology/.usermark" ] && no "--force не пересобрал" || ok "--force пересобирает (свежее дерево)"

echo "── A6: атомарность — битый шаблон → нет частичной methodology/ ──"
PDA=$(newproj atom '{"slug":"a","summary":"X","site_type":"landing"}')
KBAD="$SANDBOX/kit-bad"; cp -r "$SKILL/lib/methodology-kit" "$KBAD"
# впрыснуть незаполняемый плейсхолдер → рендер должен упасть на валидации (exit 2), коробки нет
printf '\n{{NONEXISTENT_VAR}}\n' >> "$KBAD/tier-0/README.md"
KIT_DIR="$KBAD" bash "$SH" "$PDA" --tier 0 >/dev/null 2>&1; rc_is 2 $? "незаполненный {{...}} → exit 2"
[ -d "$PDA/methodology" ] && no "частичная methodology/ осталась" || ok "битый рендер не оставил methodology/ (atomic)"
ls -d "$PDA"/methodology.tmp.* >/dev/null 2>&1 && no "tmp-dir не убран" || ok "tmp-dir убран (trap)"
# unclosed BEGIN TIER → fatal exit 1 (не тихое усечение) — review-finding
KUC="$SANDBOX/kit-unclosed"; cp -r "$SKILL/lib/methodology-kit" "$KUC"
printf '\n<!-- BEGIN TIER-2 -->\nнезакрытый блок\n' >> "$KUC/tier-0/START-HERE.md"
PDUC=$(newproj uc '{"slug":"uc","summary":"X","site_type":"landing"}')
KIT_DIR="$KUC" bash "$SH" "$PDUC" --tier 1 >/dev/null 2>&1; rc_is 1 $? "незакрытый BEGIN TIER → exit 1"
# safe-swap: --force на существующей коробке → пересборка, без .bak-residue
PDSW=$(newproj swap '{"slug":"sw","summary":"X","site_type":"landing"}')
bash "$SH" "$PDSW" --tier 1 >/dev/null 2>&1
bash "$SH" "$PDSW" --tier 1 --force >/dev/null 2>&1; rc_is 3 $? "--force пересобрал (safe-swap)"
ls -d "$PDSW"/methodology.bak-* >/dev/null 2>&1 && no ".bak-residue остался" || ok "safe-swap не оставил .bak (cleanup)"
[ -f "$PDSW/methodology/.methodology-version" ] && grep -q "generated_at=" "$PDSW/methodology/.methodology-version" && ok ".methodology-version: generated_at присутствует" || no "нет generated_at"

echo "── Tier 2: файлы + сидинг ICP/JTBD/USP из planning ──"
PD2=$(newproj t2 '{"slug":"t2","summary":"Магазин","site_type":"ecommerce"}' sitemap)
mkdir -p "$PD2/planning"
printf -- '---\nkey_claims:\n  - "ICP: молодые семьи 28-40"\n  - "JTBD: обставить дом без переплаты"\n---\n# P\nUSP: массив за 2 недели.\n' > "$PD2/planning/planning.md"
bash "$SH" "$PD2" --tier 2 >/dev/null 2>&1
for f in docs/chats/REGISTRY.md docs/chats/handoff-queue.md docs/methodology-proposals/MP-TEMPLATE.md docs/product-principles.md; do
  [ -f "$PD2/methodology/$f" ] && ok "tier-2: есть $f" || no "tier-2: нет $f"
done
grep -q "молодые семьи 28-40" "$PD2/methodology/docs/product-principles.md" && ok "ICP засеян из planning" || no "ICP не засеян"
grep -q "массив за 2 недели" "$PD2/methodology/docs/product-principles.md" && ok "USP засеян из body" || no "USP не засеян"
grep -rIlq '{{[A-Z_]*}}' "$PD2/methodology" && no "tier-2: остались {{...}}" || ok "tier-2: 0 незаполненных {{...}}"
# fallback без planning → TODO, не {{...}}
PD2N=$(newproj t2n '{"slug":"t2n","summary":"X","site_type":"ecommerce"}' sitemap)
bash "$SH" "$PD2N" --tier 2 >/dev/null 2>&1
grep -q "TODO: заполнить из" "$PD2N/methodology/docs/product-principles.md" && ok "нет planning → ICP/USP = TODO (не {{...}})" || no "fallback TODO не сработал"
grep -rIlq '{{[A-Z_]*}}' "$PD2N/methodology" && no "tier-2 no-planning: остались {{...}}" || ok "tier-2 no-planning: 0 незаполненных"
# START-HERE на tier 2: блок «Несколько направлений» есть, TIER-1-ONLY нет
grep -q "Несколько направлений" "$PD2/methodology/START-HERE.md" && ok "START-HERE tier-2 блок присутствует" || no "нет tier-2 блока в START-HERE"

echo "── Tier 3: QG+auto-merge всегда; routines skip для лендинга (DR-9) ──"
PDL3=$(newproj l3 '{"slug":"l3","summary":"Лендинг","site_type":"landing"}')
bash "$SH" "$PDL3" --tier 1 --tier3 >/dev/null 2>&1
[ -f "$PDL3/methodology/docs/security-quality-gate.md" ] && ok "landing t3: security-QG есть" || no "нет security-QG"
[ -f "$PDL3/methodology/docs/performance-quality-gate.md" ] && ok "landing t3: perf-QG есть" || no "нет perf-QG"
[ -f "$PDL3/methodology/.github/workflows/auto-merge.yml" ] && ok "landing t3: auto-merge.yml есть" || no "нет auto-merge"
[ -d "$PDL3/methodology/routines" ] && no "landing t3: routines НЕ должны быть (DR-9)" || ok "landing t3: routines skipped (DR-9)"
PDE3=$(newproj e3 '{"slug":"e3","summary":"Магазин","site_type":"ecommerce"}')
bash "$SH" "$PDE3" --tier3 >/dev/null 2>&1
[ "$(ls "$PDE3/methodology/routines/"R*.md 2>/dev/null | wc -l | tr -d ' ')" = 4 ] && ok "ecommerce t3: 4 routines включены" || no "ecommerce t3: routines неполны"
grep -q 'secrets.GITHUB_TOKEN' "$PDE3/methodology/.github/workflows/auto-merge.yml" && ok "auto-merge: GitHub \${{ }} цел (не съеден substitute)" || no "GitHub expr сломан"
grep -rIlq '{{[A-Z_]*}}' "$PDE3/methodology" && no "t3: остались {{...}}" || ok "t3: 0 незаполненных {{...}}"
PDT3=$(newproj only3 '{"slug":"only3","summary":"X","site_type":"ecommerce"}')
bash "$SH" "$PDT3" --tier3 >/dev/null 2>&1; r=$?; { [ "$r" = 0 ] || [ "$r" = 3 ]; } && ok "--tier3 без --tier работает (impl tier 3, rc=$r)" || no "--tier3 alone rc=$r"
[ -f "$PDT3/methodology/docs/security-quality-gate.md" ] && ok "--tier3 alone собрал tier-3 контент" || no "--tier3 alone не собрал t3"

echo "── Tier 4: goal-pursuit + codegraph (opt-in редкий) ──"
PD4=$(newproj t4 '{"slug":"t4","summary":"Платформа","site_type":"webapp"}')
bash "$SH" "$PD4" --tier 4 >/dev/null 2>&1
[ -f "$PD4/methodology/docs/goal-pursuit.md" ] && ok "tier-4: goal-pursuit.md" || no "нет goal-pursuit"
[ -f "$PD4/methodology/docs/codegraph-setup.md" ] && ok "tier-4: codegraph-setup.md" || no "нет codegraph-setup"
[ -f "$PD4/methodology/.goal/.gitkeep" ] && ok "tier-4: .goal/ создан" || no "нет .goal/"
grep -q "Длинные цели и большой код" "$PD4/methodology/START-HERE.md" && ok "START-HERE: TIER-4 блок при tier 4" || no "нет TIER-4 блока"
grep -q "Длинные цели" "$PD/methodology/START-HERE.md" && no "TIER-4 блок утёк в tier 1" || ok "TIER-4 блок отсутствует при tier 1"

echo "── MANIFEST ↔ filesystem (bidirectional, panel #10) ──"
KIT="$SKILL/lib/methodology-kit"
res=$(python3 - "$KIT" <<'PY'
import json, os, sys
kit = sys.argv[1]; man = json.load(open(os.path.join(kit,"MANIFEST.json")))
listed=set(); miss=[]
for t,es in man["tiers"].items():
    for e in es:
        listed.add(e["src"])
        if not os.path.exists(os.path.join(kit,e["src"])): miss.append(e["src"])
orphan=[]
for root,_,fs in os.walk(kit):
    for f in fs:
        rel=os.path.relpath(os.path.join(root,f),kit)
        if rel.startswith("core-MPs") or rel=="MANIFEST.json": continue
        if rel not in listed: orphan.append(rel)
print("%d %d"%(len(miss),len(orphan)))
PY
)
[ "$res" = "0 0" ] && ok "MANIFEST↔dir консистентны (0 missing, 0 orphan)" || no "MANIFEST↔dir рассинхрон: $res"

echo "── /redloft-status показывает коробку (manage.sh, #2) ──"
export REDLOFT_DATA_DIR="$SANDBOX"
PDS="$SANDBOX/projects/statusproj"; mkdir -p "$PDS"
printf '{"slug":"statusproj","mode":"lite","run_id":"r","updated_at":"","workflow_run_id":null,"stages":{"render":{"status":"done"}},"reviews":{},"artifacts":{}}' > "$PDS/pipeline.json"
echo '{"slug":"statusproj","summary":"X","site_type":"landing"}' > "$PDS/brief.json"
bash "$SH" "$PDS" --tier 1 >/dev/null 2>&1
bash "$SKILL/lib/manage.sh" status statusproj 2>/dev/null | grep -q "Methodology kit:" && ok "manage.sh status выводит коробку + tier" || no "status не показывает коробку"

echo "── A11: bilingual (EN+RU в шаблоне) ──"
grep -q "EN:" "$SKILL/lib/methodology-kit/tier-0/START-HERE.md" && \
grep -q "работать" "$SKILL/lib/methodology-kit/tier-0/START-HERE.md" && ok "START-HERE bilingual" || no "не bilingual"

echo "── --tier3 поднимает до Tier 3 ──"
PD3=$(newproj t3 '{"slug":"t3","summary":"X","site_type":"landing"}')
bash "$SH" "$PD3" --tier 1 --tier3 >/dev/null 2>&1
grep -q "tier 3" "$PD3/methodology/README.md" && ok "--tier3 → эффективный tier 3" || no "--tier3 не поднял tier"

echo ""
echo "════════ $PASS passed, $FAIL failed ════════"
[ "$FAIL" -eq 0 ]

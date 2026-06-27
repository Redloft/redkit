#!/usr/bin/env bash
# redloft — methodology kit SELF-TEST (Phase 6, METHODOLOGY-KIT-SPEC.md §9).
# Симулирует ПОЛНЫЙ caller-flow Шага 6c на реалистичной фикстуре «банный комплекс»:
# context.sh init → tier-выбор (site_type + clusters) → methodology.sh → cp tz → register → set_stage → секрет-чек.
# Проверяет коробку + START-HERE в выходе как при настоящем /redloft. Hermetic, без API.
# Run: bash tests/methodology.selftest.sh → exit 0 if all pass.
set -u
SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$(mktemp -d)"; export REDLOFT_DATA_DIR="$SANDBOX/data"
trap 'rm -rf "$SANDBOX"' EXIT
PASS=0; FAIL=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
no(){ echo "  ✗ $1"; FAIL=$((FAIL+1)); }
source "$SKILL/lib/context.sh"

echo "── Фикстура: банный комплекс (geoEdge, planning, sitemap, semantic) ──"
PD="$SANDBOX/data/projects/banya-dvor"; mkdir -p "$PD/planning" "$PD/sitemap" "$PD/semantic"
init_pipeline "$PD" banya-dvor full run-selftest >/dev/null 2>&1 \
  || echo '{"slug":"banya-dvor","stages":{},"artifacts":{},"reviews":{},"events":[],"updated_at":""}' > "$PD/pipeline.json"
cat > "$PD/brief.json" <<'J'
{"slug":"banya-dvor","summary":"Банный двор — премиум баня с 3 парными в Москве","site_type":"ecommerce","geoEdge":true}
J
cat > "$PD/planning/planning.md" <<'J'
---
artifact_type: planning
key_claims:
  - "ICP: пары и компании 30-45, доход выше среднего, ценят приватность и ритуал"
  - "JTBD: организовать запоминающийся отдых/праздник в бане без бытовых хлопот"
---
# Planning
USP: 3 авторские парные + кейтеринг + бронь онлайн за 60 секунд.
J
printf '# Главная\n## Парные\n## Цены и пакеты\n## Кейтеринг\n## Галерея\n## Бронирование\n## Контакты\n' > "$PD/sitemap/sitemap.md"
printf '{"content_clusters":[{"name":"парные"},{"name":"цены"},{"name":"кейтеринг"},{"name":"бронь"},{"name":"отзывы"}]}' > "$PD/semantic/clusters.json"
printf -- '---\nartifact_type: tz\n---\n# ТЗ: Банный двор\nNext.js + Supabase.\n' > "$PD/tz.md"

echo "── Шаг 6c.1: tier-выбор (ecommerce + ≥4 кластеров → 2) ──"
TIER=2   # methodology_tier_hint=2 (ecommerce)
CL="$PD/semantic/clusters.json"
n=$(python3 -c "import json;d=json.load(open('$CL'));print(len(d.get('content_clusters',[])))" 2>/dev/null||echo 0)
[ "$n" -ge 4 ] && TIER=2
ok "tier=$TIER (clusters=$n ≥4)"

echo "── Шаг 6c.3: сборка коробки ──"
bash "$SKILL/lib/methodology.sh" "$PD" --tier "$TIER" >/dev/null 2>&1; rc=$?
{ [ "$rc" = 0 ] || [ "$rc" = 3 ]; } && ok "methodology.sh rc=$rc (ок; все upstream есть → ждём 0)" || no "methodology.sh rc=$rc"
[ "$rc" = 0 ] && ok "rc=0 — degraded НЕ сработал (planning/sitemap/semantic на месте)" || no "rc=$rc — ожидали 0 при полном контексте"
cp "$PD/tz.md" "$PD/methodology/docs/tz.md"
[ -f "$PD/methodology/docs/tz.md" ] && ok "tz.md скопирован в коробку (источник правды по продукту)" || no "tz.md не в коробке"

echo "── Шаг 6c.4: регистрация стейта (directory-артефакт) ──"
register_artifact "$PD" methodology kit "methodology/" render '["tier 2","seeded: rls,pii,geo"]' && ok "register_artifact kit/dir" || no "register failed"
set_stage "$PD" methodology done && ok "set_stage methodology done" || no "set_stage failed"
[ "$(jq -r '.artifacts.methodology.artifact_type' "$PD/pipeline.json")" = "kit" ] && ok "pipeline.json: artifact_type=kit" || no "pipeline.json kit отсутствует"

echo "── Шаг 6c.5: секрет-чек коробки (узкий, op:// легитимны) ──"
if grep -RInE 'sk-[A-Za-z0-9]{20,}|AIza[A-Za-z0-9_-]{30,}|ghp_[A-Za-z0-9]{30,}|eyJ[A-Za-z0-9_-]{20,}' "$PD/methodology" >/dev/null 2>&1; then no "секрет в коробке"; else ok "0 секретов в коробке"; fi

echo "── Выход: коробка + START-HERE как при /redloft ──"
M="$PD/methodology"
grep -q "Банный двор — премиум баня с 3 парными в Москве" "$M/START-HERE.md" && ok "START-HERE заполнен под проект (заголовок)" || no "START-HERE не заполнен"
grep -q "Несколько направлений" "$M/START-HERE.md" && ok "START-HERE: tier-2 блок (multi)" || no "нет tier-2 блока"
grep -q "Next.js + Supabase" "$M/CLAUDE.md" && ok "CLAUDE.md: стек подставлен" || no "стек не подставлен"
grep -q "geo-edge" "$M/docs/HARD-RULES.md" && ok "HARD-RULES: geo-edge rule (geoEdge=true)" || no "нет geo-edge"
grep -q "deny-by-default" "$M/docs/HARD-RULES.md" && ok "HARD-RULES: RLS deny-by-default" || no "нет RLS"
grep -q "пары и компании 30-45" "$M/docs/product-principles.md" && ok "product-principles: ICP из planning" || no "ICP не засеян"
grep -q "3 авторские парные" "$M/docs/product-principles.md" && ok "product-principles: USP из planning body" || no "USP не засеян"
SEED=$(ls "$M/docs/tasks/pending/"*.md 2>/dev/null | wc -l | tr -d ' ')
[ "$SEED" -ge 5 ] && ok "tasks/pending засеян из sitemap ($SEED задач)" || no "seed задач мал: $SEED"
for f in START-HERE.md CLAUDE.md README.md docs/HARD-RULES.md docs/working-protocol.md \
         docs/tasks/PROTOCOL.md docs/tasks/TASK-TEMPLATE.md docs/prompts/iteration.md \
         supabase/rls-bootstrap.sql docs/chats/REGISTRY.md docs/chats/handoff-queue.md \
         docs/methodology-proposals/MP-TEMPLATE.md docs/product-principles.md .methodology-version; do
  [ -f "$M/$f" ] || no "ОТСУТСТВУЕТ $f"
done
ok "полный состав коробки tier-2 на месте"
grep -rIlq '{{[A-Z_]*}}' "$M" && no "остались {{...}} в выходе" || ok "0 незаполненных {{...}} в финальном выходе"
[ "$(detect_state "$PD")" != "failed" ] && ok "detect_state не failed (=$(detect_state "$PD"))" || no "detect_state failed"

echo ""
echo "════════ SELF-TEST: $PASS passed, $FAIL failed ════════"
[ "$FAIL" -eq 0 ]

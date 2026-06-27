#!/usr/bin/env bash
# Hermetic тесты multi-method dataforseo.sh (Phase 1). БЕЗ сети/кредов — fixtures.
# Покрывает: envelope, cache_hit, cost-cap (count+atomic параллель), injection,
# SSRF, api-error envelope, бэк-компат alias, kill-switch, probe, exit-семантика.
# Run: bash tests/dataforseo-test.sh → exit 0 если всё зелено.
set -u
SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DFS="$SKILL/lib/adapters/dataforseo.sh"
FX="$SKILL/tests/fixtures/dataforseo"
FXBAD="$SKILL/tests/fixtures/dataforseo-bad"
SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT
export TMPDIR="$SANDBOX/tmp"; mkdir -p "$TMPDIR"
export DFS_CACHE_DIR="$SANDBOX/cache"

PASS=0; FAIL=0
ok(){ echo "  ✓ $1"; PASS=$((PASS+1)); }
no(){ echo "  ✗ $1"; FAIL=$((FAIL+1)); }
# run with isolated run-id + fixture dir
run(){ DFS_FIXTURE_DIR="$FX" DFS_RUN_ID="$1" "${@:2}"; }

echo "── envelope (overview, fixture) ──"
out=$(DFS_FIXTURE_DIR="$FX" DFS_RUN_ID=t1 bash "$DFS" overview "баня москва" 2>/dev/null); rc=$?
echo "$out" | jq -e '.ok==true and .method=="overview" and .schema_version==1' >/dev/null 2>&1 && ok "success envelope ok=true" || no "envelope wrong: $out"
echo "$out" | jq -e '.data.keywords[0].phrase=="баня москва" and .data.keywords[0].freq==27000' >/dev/null 2>&1 && ok "typed data.keywords + freq" || no "data shape wrong"
echo "$out" | jq -e '.cost_estimate>0 and .cache_hit==false' >/dev/null 2>&1 && ok "cost_estimate + cache_hit=false (1st call)" || no "cost/cache_hit wrong"
[ "$rc" -eq 0 ] && ok "exit 0 on success" || no "exit≠0 on success ($rc)"

echo "── cache hit (2nd identical call) ──"
out2=$(DFS_FIXTURE_DIR="$FX" DFS_RUN_ID=t1 bash "$DFS" overview "баня москва" 2>/dev/null)
echo "$out2" | jq -e '.cache_hit==true and .ok==true' >/dev/null 2>&1 && ok "2nd call cache_hit=true" || no "cache_hit not set: $out2"

echo "── exit-семантика: api status≠20000 → error envelope ──"
out=$(DFS_FIXTURE_DIR="$FXBAD" DFS_RUN_ID=t2 bash "$DFS" overview "x" 2>/dev/null); rc=$?
echo "$out" | jq -e '.ok==false and (.error_code|test("^api_40100"))' >/dev/null 2>&1 && ok "api_40100 error_code" || no "api-error envelope wrong: $out"
[ "$rc" -ne 0 ] && ok "exit≠0 on error ($rc)" || no "exit 0 on error (should be ≠0)"

echo "── injection guard ──"
out=$(DFS_FIXTURE_DIR="$FX" DFS_RUN_ID=t3 bash "$DFS" overview '$(id)' 2>/dev/null); rc=$?
echo "$out" | jq -e '.ok==false and .error_code=="bad_input"' >/dev/null 2>&1 && ok "keyword \$(id) → bad_input" || no "injection not blocked: $out"
out=$(DFS_FIXTURE_DIR="$FX" DFS_RUN_ID=t3b bash "$DFS" related 'foo;rm -rf /' 2>/dev/null)
echo "$out" | jq -e '.error_code=="bad_input"' >/dev/null 2>&1 && ok "related 'foo;rm' → bad_input" || no "metachar not blocked"

echo "── SSRF guard (onpage) ──"
for u in "http://example.com" "https://127.0.0.1/x" "https://localhost/x" "https://169.254.169.254/meta"; do
  out=$(DFS_FIXTURE_DIR="$FX" DFS_RUN_ID=t4 bash "$DFS" onpage "$u" 2>/dev/null)
  echo "$out" | jq -e '.error_code=="ssrf_blocked"' >/dev/null 2>&1 && ok "blocked: $u" || no "NOT blocked: $u ($out)"
done

echo "── cost-cap: DFS_MAX_CALLS=1 → 2-й (другой кэш-ключ) cap_exceeded ──"
R=capA
o1=$(DFS_FIXTURE_DIR="$FX" DFS_RUN_ID=$R DFS_MAX_CALLS=1 bash "$DFS" overview "kw1" 2>/dev/null)
o2=$(DFS_FIXTURE_DIR="$FX" DFS_RUN_ID=$R DFS_MAX_CALLS=1 bash "$DFS" overview "kw2" 2>/dev/null); rc2=$?
echo "$o1" | jq -e '.ok==true' >/dev/null 2>&1 && ok "1st call passes under cap=1" || no "1st blocked unexpectedly"
echo "$o2" | jq -e '.ok==false and .error_code=="cap_exceeded"' >/dev/null 2>&1 && ok "2nd call cap_exceeded" || no "cap not enforced: $o2"
[ "$rc2" -ne 0 ] && ok "cap_exceeded exit≠0" || no "cap exit 0"

echo "── cost-cap \$: DFS_MAX_COST_USD=0.01, overview \$0.015 → 1-й же режется ──"
oc=$(DFS_FIXTURE_DIR="$FX" DFS_RUN_ID=capCost DFS_MAX_COST_USD=0.01 bash "$DFS" overview "kw" 2>/dev/null)
echo "$oc" | jq -e '.ok==false and .error_code=="cap_exceeded"' >/dev/null 2>&1 && ok "cost cap \$ enforced" || no "cost cap not enforced: $oc"

echo "── cost-cap atomic: 12 параллельных при cap=5 → ровно 5 ok ──"
R=par; tmpd="$SANDBOX/par"; mkdir -p "$tmpd"
for i in $(seq 1 12); do
  ( DFS_FIXTURE_DIR="$FX" DFS_RUN_ID=$R DFS_MAX_CALLS=5 bash "$DFS" overview "atomkw-$i" 2>/dev/null > "$tmpd/$i.json" ) &
done; wait
oks=$(grep -l '"ok":true' "$tmpd"/*.json 2>/dev/null | wc -l | tr -d ' ')
[ "$oks" -eq 5 ] && ok "ровно 5/12 прошли (atomic, no TOCTOU)" || no "atomic cap нарушен: прошло $oks/12 (ожидалось 5)"

echo "── kill-switch ──"
out=$(DFS_FIXTURE_DIR="$FX" DFS_RUN_ID=t5 DFS_DISABLED=1 bash "$DFS" overview "kw" 2>/dev/null)
echo "$out" | jq -e '.ok==false and .error_code=="disabled"' >/dev/null 2>&1 && ok "DFS_DISABLED → disabled" || no "kill-switch fail: $out"
out=$(DFS_FIXTURE_DIR="$FX" DFS_RUN_ID=t5b DFS_METHODS_ENABLED="ranked" bash "$DFS" overview "kw" 2>/dev/null)
echo "$out" | jq -e '.error_code=="disabled"' >/dev/null 2>&1 && ok "method не в whitelist → disabled" || no "whitelist fail: $out"

echo "── бэк-компат: голый keyword → related ──"
out=$(DFS_FIXTURE_DIR="$FX" DFS_RUN_ID=t6 bash "$DFS" "баня" 2>/dev/null)
echo "$out" | jq -e '.ok==true and .method=="related"' >/dev/null 2>&1 && ok "bare keyword → method related" || no "alias fail: $out"
# реальная форма вызова из semantic.js: <seed> --limit 100
out=$(DFS_FIXTURE_DIR="$FX" DFS_RUN_ID=t6b bash "$DFS" "баня москва" --limit 100 2>/dev/null)
echo "$out" | jq -e '.ok==true and .method=="related" and (.data.keywords|length>0)' >/dev/null 2>&1 && ok "semantic.js form '<seed> --limit 100' works" || no "--limit flag broke alias: $out"
# явный related --limit
out=$(DFS_FIXTURE_DIR="$FX" DFS_RUN_ID=t6c bash "$DFS" related "баня" --limit 50 2>/dev/null)
echo "$out" | jq -e '.ok==true' >/dev/null 2>&1 && ok "related <kw> --limit 50" || no "related --limit fail: $out"

echo "── serp typed data (organic+paa+featured) ──"
out=$(DFS_FIXTURE_DIR="$FX" DFS_RUN_ID=t7 bash "$DFS" serp "баня москва" 2>/dev/null)
echo "$out" | jq -e '.data.results[0].position==1 and (.data.paa|length>0) and (.data.featured|length>0)' >/dev/null 2>&1 && ok "serp results+paa+featured" || no "serp shape: $out"

echo "── probe (fixture, balance>0) ──"
out=$(DFS_FIXTURE_DIR="$FX" DFS_RUN_ID=t8 bash "$DFS" --probe 2>/dev/null); rc=$?
echo "$out" | jq -e '.ok==true and .dataforseo_verified==true and .dataforseo_balance==5.5' >/dev/null 2>&1 && ok "probe verified+balance" || no "probe fail: $out"
[ "$rc" -eq 0 ] && ok "probe exit 0 when verified" || no "probe exit≠0"

echo "── PII-изоляция: ranked кэш в slug-подпапке ──"
DFS_FIXTURE_DIR="$FX" DFS_RUN_ID=t9 DFS_PROJECT_SLUG=acme bash "$DFS" related "x" >/dev/null 2>&1  # related = shared
# ranked нет fixture → но проверим путь _cache_dir_for через related(shared) vs ranked(slug): косвенно — shared-папка существует
[ -d "$DFS_CACHE_DIR/shared" ] && ok "public method → cache/shared/" || no "shared cache dir missing"

echo "── geo-routing (RU keyword/SERP недоступен; On-Page geo-независим) ──"
bash "$DFS" --geo-check "Москва" >/dev/null 2>&1 && no "Москва должна быть UNSUPPORTED" || ok "geo-check Москва → unsupported (rc≠0)"
bash "$DFS" --geo-check "Russian Federation" >/dev/null 2>&1 && no "RF unsupported" || ok "geo-check 'Russian Federation' → unsupported"
bash "$DFS" --geo-check "United States" >/dev/null 2>&1 && ok "geo-check US → supported (rc0)" || no "US should be supported"
o=$(bash "$DFS" --geo-check "Berlin" 2>/dev/null); echo "$o" | jq -e '.supported_keyword==true' >/dev/null 2>&1 && ok "geo-check Berlin supported_keyword=true" || no "Berlin geo json"
# keyword-метод для RU-локации → geo_unsupported БЕЗ billable-вызова
o=$(DFS_FIXTURE_DIR="$FX" DFS_CACHE_DIR="$SANDBOX/cache" DFS_RUN_ID=geo1 DFS_LOCATION="Russian Federation" bash "$DFS" overview "баня" 2>/dev/null)
echo "$o" | jq -e '.ok==false and .error_code=="geo_unsupported"' >/dev/null 2>&1 && ok "overview@RU → geo_unsupported (no spend)" || no "geo-guard fail: $o"
# US-локация (fixture) проходит geo-guard
o=$(DFS_FIXTURE_DIR="$FX" DFS_CACHE_DIR="$SANDBOX/cache" DFS_RUN_ID=geo2 DFS_LOCATION="United States" bash "$DFS" overview "coffee" 2>/dev/null)
echo "$o" | jq -e '.ok==true' >/dev/null 2>&1 && ok "overview@US passes geo-guard" || no "US geo-guard wrong: $o"

echo "── Phase 4 методы: tech (geo-независим) + business (geo-guarded) ──"
o=$(DFS_FIXTURE_DIR="$FX" DFS_CACHE_DIR="$SANDBOX/cache" DFS_RUN_ID=p4a DFS_LOCATION="Russian Federation" bash "$DFS" tech "competitor.ru" 2>/dev/null)
echo "$o" | jq -e '.ok==true and .method=="tech" and (.data.groups|length>0)' >/dev/null 2>&1 && ok "tech@RU → ok (domain-based, geo-независим)" || no "tech geo-indep broken: $o"
o=$(DFS_FIXTURE_DIR="$FX" DFS_CACHE_DIR="$SANDBOX/cache" DFS_RUN_ID=p4b DFS_LOCATION="Russian Federation" bash "$DFS" business "кафе москва" 2>/dev/null)
echo "$o" | jq -e '.ok==false and .error_code=="geo_unsupported"' >/dev/null 2>&1 && ok "business@RU → geo_unsupported (Maps SERP geo)" || no "business geo-guard fail: $o"
o=$(DFS_FIXTURE_DIR="$FX" DFS_CACHE_DIR="$SANDBOX/cache" DFS_RUN_ID=p4c DFS_LOCATION="United States" bash "$DFS" business "coffee" 2>/dev/null)
echo "$o" | jq -e '.ok==true and (.data.listings|length>0)' >/dev/null 2>&1 && ok "business@US → ok (listings)" || no "business intl fail: $o"

echo ""
echo "dataforseo-test: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && { echo "DFS-TEST OK"; exit 0; } || { echo "DFS-TEST FAIL"; exit 1; }

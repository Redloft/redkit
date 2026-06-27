#!/usr/bin/env bash
# redloft Phase A smoke suite. NO live API/network, hermetic (isolated DATA_DIR).
# Covers:
#   persist.sh   — project dir + subdirs, slug validation, Yandex.Disk residency
#                  guard, idempotent re-run
#   context.sh   — pipeline state-machine (pending→running→done), atomic/concurrent
#                  write + crash-safety, brief.json (fill + site_type branching),
#                  artifact-header contract (DR-5), reviews + escalation, events,
#                  workflow_id, detect_state
#   url-guard.sh — SSRF block (incl. DoD trio file://, localhost, 10.0.0.1) + allow
#   manage.sh    — list / path / status (+ escalation surfacing)
#   fixtures/banya — inbox present; expected/*.md carry valid header for EACH of the
#                  11 artifact_types; prompt.md has RLS step; client URLs pass guard
#
# Run: bash tests/smoke.sh   → exit 0 if all pass.
set -u

SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$(mktemp -d)"
export REDLOFT_DATA_DIR="$SANDBOX/data"
export REDLOFT_FEEDBACK_DIR="$SANDBOX/fb"   # hermetic self-improve store (Phase E)
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
no()  { echo "  ✗ $1"; FAIL=$((FAIL+1)); }
eq()  { [ "$2" = "$3" ] && ok "$1 ($3)" || no "$1 — expected '$2' got '$3'"; }
rc_is(){ local e="$1" a="$2" l="$3"; [ "$e" = "$a" ] && ok "$l (rc=$a)" || no "$l — expected rc $e got $a"; }

source "$SKILL/lib/context.sh"
source "$SKILL/lib/url-guard.sh"
source "$SKILL/lib/brief.sh"
source "$SKILL/lib/feedback.sh"

newproj() { "$SKILL/lib/persist.sh" "$1"; }   # echoes project dir

# Parse our fixed YAML front-matter schema → JSON, to validate fixture headers.
fm_to_json() {
  python3 - "$1" <<'PY'
import sys, json
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
if not lines or lines[0].strip() != "---":
    sys.exit("no front-matter")
end = None
for i in range(1, len(lines)):
    if lines[i].strip() == "---":
        end = i; break
if end is None:
    sys.exit("unterminated front-matter")
body = lines[1:end]
obj = {}; j = 0
while j < len(body):
    line = body[j]
    if line.startswith("key_claims:"):
        claims = []; j += 1
        while j < len(body) and body[j].lstrip().startswith("- "):
            claims.append(json.loads(body[j].lstrip()[2:])); j += 1
        obj["key_claims"] = claims; continue
    k, _, v = line.partition(":")
    v = v.strip()
    obj[k.strip()] = int(v) if v.isdigit() else v
    j += 1
print(json.dumps(obj, ensure_ascii=False))
PY
}

echo "── persist.sh ──"
PD=$(newproj banya-complex)
allsub=1; for d in inbox brief research planning sitemap seo content design reviews memory; do [ -d "$PD/$d" ] || allsub=0; done
[ "$allsub" -eq 1 ] && ok "creates project dir + all subdirs" || no "project subdir layout"
"$SKILL/lib/persist.sh" "Bad Slug!" >/dev/null 2>&1; rc_is 1 $? "rejects invalid slug"
( CLAUDECORE_PATH="$REDLOFT_DATA_DIR" REDLOFT_DATA_DIR="$REDLOFT_DATA_DIR/inside" \
  "$SKILL/lib/persist.sh" guard-test >/dev/null 2>&1 ); rc_is 2 $? "Yandex.Disk residency guard"
eq "idempotent re-run (same dir)" "$PD" "$(newproj banya-complex)"

echo "── context.sh: pipeline state-machine ──"
init_pipeline "$PD" banya-complex lite "$(uuidgen | tr 'A-Z' 'a-z')"
eq "init → briefing pending" "pending" "$(get_stage "$PD" briefing)"
eq "init slug" "banya-complex" "$(read_pipeline "$PD" slug)"
set_stage "$PD" briefing running
eq "→ running" "running" "$(get_stage "$PD" briefing)"
[ "$(jq -r '.stages.briefing.started_at' "$PD/pipeline.json")" != "null" ] && ok "running stamps started_at" || no "started_at not stamped"
set_stage "$PD" briefing done
eq "pending→running→done" "done" "$(get_stage "$PD" briefing)"
[ "$(jq -r '.stages.briefing.ended_at' "$PD/pipeline.json")" != "null" ] && ok "done stamps ended_at" || no "ended_at not stamped"
jq -e . "$PD/pipeline.json" >/dev/null 2>&1 && ok "pipeline.json valid JSON" || no "pipeline.json invalid"
set_stage "$PD" bogus running 2>/dev/null; rc_is 2 $? "rejects invalid stage"
set_stage "$PD" research nonsense 2>/dev/null; rc_is 2 $? "rejects invalid status"
EVN=$(jq '.events|length' "$PD/pipeline.json"); [ "$EVN" -ge 2 ] && ok "events appended on transitions ($EVN)" || no "events not appended"
jq -e '.events[0] | has("ts") and has("stage") and has("event") and has("duration_ms") and has("reviewer_iteration")' "$PD/pipeline.json" >/dev/null && ok "event shape ok" || no "event shape wrong"
set_workflow_id "$PD" "wf_smoke123"; eq "set_workflow_id persists" "wf_smoke123" "$(read_pipeline "$PD" workflow_run_id)"
eq "detect_state in-progress" "in-progress" "$(detect_state "$PD")"
# detect_state variants
PDc=$(newproj all-done); init_pipeline "$PDc" all-done lite r
for s in briefing research planning semantic sitemap seo content design render methodology self-improve; do set_stage "$PDc" "$s" done; done
eq "detect_state completed" "completed" "$(detect_state "$PDc")"
PDi=$(newproj idle-proj); init_pipeline "$PDi" idle-proj lite r
eq "detect_state idle" "idle" "$(detect_state "$PDi")"
PDf=$(newproj fail-proj); init_pipeline "$PDf" fail-proj lite r; set_stage "$PDf" research failed
eq "detect_state failed" "failed" "$(detect_state "$PDf")"
eq "detect_state missing" "missing" "$(detect_state "$SANDBOX/nope")"

echo "── context.sh: atomic / crash-safety (DR-6) ──"
PDA=$(newproj atomic); init_pipeline "$PDA" atomic lite r
for i in $(seq 1 20); do set_stage "$PDA" research running & done; wait
jq -e . "$PDA/pipeline.json" >/dev/null 2>&1 && ok "20 concurrent writes → valid JSON" || no "concurrent JSON corrupt"
[ -d "$PDA/pipeline.json.lockdir" ] && no "lockdir leaked" || ok "lockdir cleaned after writes"
ls "$PDA"/pipeline.json.tmp.* >/dev/null 2>&1 && no "tmp file leaked" || ok "no tmp leak"
eq "final status after concurrent" "running" "$(get_stage "$PDA" research)"
# crash mid-write: a stray tmp (process died before rename) must NOT corrupt live file
BEFORE=$(cat "$PDA/pipeline.json")
echo 'GARBAGE PARTIAL WRITE {' > "$PDA/pipeline.json.tmp.99999"
jq -e . "$PDA/pipeline.json" >/dev/null 2>&1 && ok "stray .tmp doesn't corrupt live file (atomic)" || no "live file corrupted by stray tmp"
[ "$(cat "$PDA/pipeline.json")" = "$BEFORE" ] && ok "live file unchanged by stray tmp" || no "live file changed by stray tmp"
rm -f "$PDA"/pipeline.json.tmp.* 2>/dev/null

echo "── context.sh: brief.json (volatile fill, separate — DR-6) ──"
init_brief "$PD"
jq -e . "$PD/brief.json" >/dev/null 2>&1 && ok "init_brief valid JSON" || no "brief invalid"
set_brief_field "$PD" q1_company_name "Берёзовая роща" materials
eq "set/get brief field" "Берёзовая роща" "$(get_brief_field "$PD" q1_company_name)"
eq "  source recorded" "materials" "$(jq -r '.sources.q1_company_name' "$PD/brief.json")"
set_brief_field "$PD" q2 x bogus-source 2>/dev/null; rc_is 2 $? "rejects invalid brief source"
set_site_type "$PD" landing; eq "set_site_type (Q13 branching)" "landing" "$(jq -r .site_type "$PD/brief.json")"
set_site_type "$PD" bogus 2>/dev/null; rc_is 2 $? "rejects invalid site_type"
eq "brief write didn't touch pipeline" "banya-complex" "$(jq -r .slug "$PD/pipeline.json")"

echo "── context.sh: artifact-header contract (DR-5, primary) ──"
allt=1
for t in brief visual_taste research planning semantic sitemap seo content design tz prompt review; do
  H=$(jq -nc --arg t "$t" '{artifact_type:$t,stage_id:"briefing",schema_version:1,produced_at:"2026-06-02T00:00:00Z",source_stage:"input",key_claims:["k"]}')
  validate_artifact_header "$H" || { no "valid header rejected: $t"; allt=0; }
done
[ "$allt" -eq 1 ] && ok "all 12 artifact_types validate"
validate_artifact_header '{"artifact_type":"brief","stage_id":"briefing","schema_version":1,"produced_at":"x","source_stage":"input","key_claims":[]}' 2>/dev/null && no "accepts empty key_claims" || ok "rejects empty key_claims"
validate_artifact_header '{"artifact_type":"bogus","stage_id":"briefing","schema_version":1,"produced_at":"x","source_stage":"input","key_claims":["k"]}' 2>/dev/null && no "accepts bad artifact_type" || ok "rejects bad artifact_type"
validate_artifact_header '{"stage_id":"briefing","schema_version":1,"produced_at":"x","source_stage":"input","key_claims":["k"]}' 2>/dev/null && no "accepts missing field" || ok "rejects missing field"
validate_artifact_header '{"artifact_type":"brief","stage_id":"nope","schema_version":1,"produced_at":"x","source_stage":"input","key_claims":["k"]}' 2>/dev/null && no "accepts bad stage_id" || ok "rejects bad stage_id"
register_artifact "$PD" briefing brief "brief/brief.md" input '["Премиум баня","Цель — заявки"]' && ok "register_artifact ok" || no "register_artifact failed"
jq -e '.artifacts.briefing.artifact_type=="brief" and (.artifacts.briefing.key_claims|length==2) and .artifacts.briefing.path=="brief/brief.md" and .artifacts.briefing.schema_version==1' "$PD/pipeline.json" >/dev/null && ok "artifact registered w/ full header" || no "artifact header incomplete"
register_artifact "$PD" briefing brief x input 'not-json' 2>/dev/null; rc_is 2 $? "register rejects bad key_claims JSON"
register_artifact "$PD" briefing bogustype x input '["k"]' 2>/dev/null; rc_is 2 $? "register rejects bad artifact_type"
TMPART="$SANDBOX/emit.md"; { artifact_header_yaml design design content '["Тёмная палитра","shadcn токены"]'; echo "body"; } > "$TMPART"
EH=$(fm_to_json "$TMPART" 2>/dev/null) && validate_artifact_header "$EH" && ok "artifact_header_yaml round-trips + validates" || no "emitted YAML header invalid"

echo "── context.sh: reviews + escalation (DR-3) ──"
set_review "$PD" R1 PASS 0.9 1 false ""
eq "set_review verdict" "PASS" "$(jq -r '.reviews.R1.verdict' "$PD/pipeline.json")"
eq "  confidence numeric" "0.9" "$(jq -r '.reviews.R1.confidence' "$PD/pipeline.json")"
set_review "$PD" R2 NEEDS-WORK 0.5 2 true "sitemap не покрывает кластеры"
eq "  escalated flag" "true" "$(jq -r '.reviews.R2.escalated' "$PD/pipeline.json")"
eq "  reviewer notes stored" "sitemap не покрывает кластеры" "$(jq -r '.reviews.R2.notes' "$PD/pipeline.json")"
set_review "$PD" R9 PASS 0.9 2>/dev/null; rc_is 2 $? "rejects invalid gate"
set_review "$PD" R1 MAYBE 0.9 2>/dev/null; rc_is 2 $? "rejects invalid verdict"

echo "── url-guard.sh (SSRF, DR-7) ──"
validate_url "file:///etc/passwd" 2>/dev/null; rc_is 1 $? "blocks file://"
validate_url "http://localhost/x"  2>/dev/null; rc_is 1 $? "blocks localhost"
validate_url "http://10.0.0.1/"    2>/dev/null; rc_is 1 $? "blocks 10.0.0.1"
BLOCK_ALL=1
for u in "https://127.0.0.1" "http://192.168.1.1" "http://172.16.5.5" \
         "http://169.254.169.254/latest/meta-data/" "http://2130706433/" "http://0177.0.0.1/" \
         "http://0x7f000001/" "http://trusted.com@10.0.0.1/" "https://[::1]/" "ftp://example.com" \
         "http://foo.local" "http://[::ffff:127.0.0.1]/" "http://100.64.0.1/" "http://0.0.0.0/"; do
  validate_url "$u" 2>/dev/null && { BLOCK_ALL=0; echo "    leaked: $u"; }
done
[ "$BLOCK_ALL" -eq 1 ] && ok "blocks 14 extra SSRF vectors" || no "some SSRF vector leaked"
ALLOW_ALL=1
for u in "https://example.com/p" "http://redloft.ru" "https://sub.dom.co.uk:8443/x?y=1" "https://8.8.8.8/" "https://dubovaya-bochka.example.ru/"; do
  validate_url "$u" 2>/dev/null || { ALLOW_ALL=0; echo "    wrongly blocked: $u"; }
done
[ "$ALLOW_ALL" -eq 1 ] && ok "allows 5 legit public URLs" || no "legit URL blocked"
bash "$SKILL/lib/url-guard.sh" "http://10.0.0.1/" >/dev/null 2>&1; rc_is 1 $? "CLI blocks private"
bash "$SKILL/lib/url-guard.sh" "https://example.com" >/dev/null 2>&1; rc_is 0 $? "CLI allows public"
validate_url "" 2>/dev/null; rc_is 2 $? "usage rc on empty arg"

echo "── manage.sh ──"
"$SKILL/lib/manage.sh" list >/dev/null 2>&1; rc_is 0 $? "list ok"
eq "path resolves existing" "$PD" "$("$SKILL/lib/manage.sh" path banya-complex)"
"$SKILL/lib/manage.sh" path nope >/dev/null 2>&1; rc_is 1 $? "path absent → rc1"
"$SKILL/lib/manage.sh" status banya-complex >/dev/null 2>&1; rc_is 0 $? "status ok"
"$SKILL/lib/manage.sh" status nope >/dev/null 2>&1; rc_is 1 $? "status absent → rc1"
"$SKILL/lib/manage.sh" >/dev/null 2>&1; rc_is 64 $? "no-cmd → usage 64"
"$SKILL/lib/manage.sh" status banya-complex 2>/dev/null | grep -q 'ESCALATED' && ok "status surfaces escalation" || no "escalation not surfaced"

echo "── fixtures/banya ──"
FX="$SKILL/tests/fixtures/banya"
[ -s "$FX/inbox/zvonok-transcript.txt" ] && [ -s "$FX/inbox/kompaniya-info.txt" ] && ok "inbox materials present + non-empty" || no "inbox materials missing"
declare -A SEEN
allfx=1
for f in "$FX"/expected/*.md; do
  HJ=$(fm_to_json "$f" 2>/dev/null) || { no "front-matter parse failed: $(basename "$f")"; allfx=0; continue; }
  if validate_artifact_header "$HJ"; then
    SEEN[$(printf '%s' "$HJ" | jq -r .artifact_type)]=1
  else
    no "invalid header: $(basename "$f")"; allfx=0
  fi
done
[ "$allfx" -eq 1 ] && ok "all expected/*.md carry valid artifact headers (mock per type)"
misscov=""
for t in brief visual_taste research planning semantic sitemap seo content design tz prompt review; do [ -n "${SEEN[$t]:-}" ] || misscov="$misscov $t"; done
[ -z "$misscov" ] && ok "fixtures cover all 12 artifact_types" || no "fixtures missing types:$misscov"
grep -q 'RLS' "$FX/expected/prompt.md" && grep -qi 'deny-by-default' "$FX/expected/prompt.md" && ok "expected prompt.md has RLS deny-by-default step (DR-7)" || no "prompt.md missing RLS step"
grep -q '/finalize' "$FX/expected/prompt.md" && grep -q 'audit-site' "$FX/expected/prompt.md" && ok "expected prompt.md has post-build gate (finalize → audit-site)" || no "prompt.md missing post-build gate"
linkok=1
while IFS= read -r line; do
  case "$line" in \#*|"") continue ;; esac
  validate_url "$line" 2>/dev/null || { linkok=0; echo "    fixture link blocked: $line"; }
done < "$FX/inbox/ssylki.txt"
[ "$linkok" -eq 1 ] && ok "all fixture client URLs pass url-guard" || no "fixture URL blocked by guard"
grep -RInE 'sk-[A-Za-z0-9]{8}|AIza[A-Za-z0-9]{8}|ghp_[A-Za-z0-9]{8}|op://|eyJ[A-Za-z0-9]{12}' "$FX" >/dev/null 2>&1 && no "secret-like string in fixtures" || ok "no secrets in fixtures"

echo "── briefing gap-engine (Phase B) ──"
SCH="$SKILL/lib/brief-schema.json"
jq -e 'type=="array" and length==34' "$SCH" >/dev/null 2>&1 && ok "brief-schema.json: 34 fields, valid" || no "brief-schema.json invalid"
jq -e 'all(.[]; has("id") and has("required") and has("group") and has("pii") and has("visual") and has("branch"))' "$SCH" >/dev/null 2>&1 && ok "schema entries well-formed" || no "schema entry shape wrong"
eq "schema required-count" "17" "$(jq '[.[]|select(.required)]|length' "$SCH")"
eq "schema pii-count (contacts)" "5" "$(jq '[.[]|select(.pii)]|length' "$SCH")"
eq "schema visual-count" "2" "$(jq '[.[]|select(.visual)]|length' "$SCH")"
# load banya autofill fixture as brief.json (the materials-derived state)
PDB=$(newproj brief-banya); init_pipeline "$PDB" brief-banya lite r
cp "$FX/expected/brief-autofill.json" "$PDB/brief.json"
jq -e . "$PDB/brief.json" >/dev/null 2>&1 && ok "autofill fixture is valid brief.json" || no "autofill fixture invalid"
eq "site_type from autofill" "landing" "$(jq -r .site_type "$PDB/brief.json")"
# DoD: «заданы ТОЛЬКО пробелы» — required non-pii gaps == exactly q14 + q28
eq "required gaps = только пробелы" '["q14_foreign_versions","q28_site_support"]' "$(brief_gaps "$PDB" --required-only --no-pii | jq -c '[.[].id]|sort')"
# DoD: e-commerce-блок скрыт для лендинга
eq "e-commerce block hidden (landing)" "[]" "$(brief_gaps "$PDB" --no-pii | jq -c '[.[].id]|map(select(test("^q1[5-9]|^q2[01]")))')"
eq "full non-pii gaps" '["q14_foreign_versions","q22_sitemap_draft","q23_key_services","q28_site_support","q29_clarifications"]' "$(brief_gaps "$PDB" --no-pii | jq -c '[.[].id]|sort')"
brief_gaps "$PDB" --no-pii | jq -e 'any(.[]; .pii)' >/dev/null 2>&1 && no "--no-pii leaked PII" || ok "--no-pii excludes contacts"
brief_gaps "$PDB" | jq -e '([.[]|select(.pii)]|length)==5' >/dev/null 2>&1 && ok "PII fields are gaps without --no-pii" || no "PII gap count wrong"
eq "brief_contact_fields = 5" "5" "$(brief_contact_fields | jq 'length')"
eq "brief_visual_fields = q11,q12" '["q11_competitors","q12_liked_sites"]' "$(brief_visual_fields | jq -c '[.[].id]')"
eq "brief_coverage non-pii (landing)" "17/22" "$(brief_coverage "$PDB")"
# branching toggle: ecommerce reveals q15-21
set_site_type "$PDB" ecommerce
eq "ecommerce reveals 7 e-comm fields" "7" "$(brief_gaps "$PDB" --no-pii | jq '[.[].id]|map(select(test("^q1[5-9]|^q2[01]")))|length')"
# branching: visitka hides structure q22/q23
set_site_type "$PDB" visitka
eq "visitka hides structure (q22/q23)" "0" "$(brief_gaps "$PDB" --no-pii | jq '[.[].id]|map(select(test("^q22|^q23")))|length')"
brief_gaps "$PDB" --bogus >/dev/null 2>&1; rc_is 2 $? "brief_gaps rejects unknown flag"
# unknown site_type → only Q13 gap (branch-dependent fields deferred), engine still valid
PDU=$(newproj brief-unknown); init_brief "$PDU"
brief_gaps "$PDU" --no-pii | jq -e 'any(.[]; .id=="q13_site_type")' >/dev/null 2>&1 && ok "site_type unknown → Q13 is a gap" || no "Q13 not surfaced when site_type unknown"
brief_gaps "$PDU" --no-pii | jq -e '[.[]|select(.group=="ecommerce")]|length==0' >/dev/null 2>&1 && ok "site_type unknown → e-comm deferred" || no "e-comm not deferred"
# zsh-source must not parse-error (eval-guarded self-locate)
if command -v zsh >/dev/null 2>&1; then
  zsh -c "source '$SKILL/lib/brief.sh' && brief_contact_fields >/dev/null" 2>/dev/null && ok "brief.sh sourceable under zsh" || no "brief.sh zsh source failed"
else
  ok "zsh absent — skip zsh-source check"
fi
# briefing prompt exists + references the locked conventions
[ -s "$SKILL/stages/briefing/prompt.md" ] && ok "stages/briefing/prompt.md present" || no "briefing prompt missing"

echo "── stage specs (Phase D) ──"
for s in planning sitemap content design; do
  f="$SKILL/stages/$s/prompt.md"
  if [ -s "$f" ] && grep -q "_shared.md" "$f" && grep -q "artifact_type: $s" "$f"; then
    ok "stages/$s/prompt.md present + contract"
  else
    no "stages/$s/prompt.md missing/incomplete"
  fi
done

echo "── design prototype templates + hub builder (Phase D2) ──"
TPL="$SKILL/stages/design/templates"
tplok=1
for f in tokens.css kit-contracts.md component-contracts.md components.html index.html reference-likes.md motion-checklist.md; do
  [ -s "$TPL/$f" ] || { no "design template missing: $f"; tplok=0; }
done
[ "$tplok" -eq 1 ] && ok "all 7 design templates present"
# эталонные шаблоны проходят СОБСТВЕННЫЕ grep-контракты (kit-contracts §1 DoD)
eq "tpl: 0 transition:all in css/html" "0" "$(cat "$TPL"/*.css "$TPL"/*.html | grep -cE 'transition:[[:space:]]*all')"
eq "tpl: 0 outline:none in css/html" "0" "$(cat "$TPL"/*.css "$TPL"/*.html | grep -cE 'outline:[[:space:]]*none')"
eq "tpl: 0 hardcoded hex in components.html (tokens-only)" "0" "$(grep -cE '#[0-9a-fA-F]{3,6}' "$TPL/components.html")"
eq "tpl: 0 hardcoded hex in index.html (tokens-only)" "0" "$(grep -cE '#[0-9a-fA-F]{3,6}' "$TPL/index.html")"
grep -q 'focus-visible' "$TPL/tokens.css" && ok "tpl: tokens.css has focus-ring (focus-visible)" || no "tokens.css missing focus-visible"
grep -q 'prefers-reduced-motion: reduce' "$TPL/tokens.css" && ok "tpl: tokens.css has reduced-motion block" || no "tokens.css missing reduced-motion"
# регресс-гард: ручной форс data-theme=dark несёт тёмные ЗНАЧЕНИЯ (не только color-scheme) —
# иначе тёмная тема «молча» остаётся светлой (баг, пойманный скриншот-верификацией)
grep -F -A3 ':root[data-theme="dark"] {' "$TPL/tokens.css" | grep -q -- '--color-bg' \
  && ok "tpl: data-theme=dark force carries color values (no silent-light bug)" \
  || no "tokens.css dark force missing color values (silent-light regression)"

HUBSH="$SKILL/lib/build-hub.sh"
[ -s "$HUBSH" ] && ok "lib/build-hub.sh present" || no "build-hub.sh missing"
bash -n "$HUBSH" 2>/dev/null && ok "build-hub.sh: bash -n passes" || no "build-hub.sh syntax error"
# прогон против герметичной фикстуры: prototype + lab + research-галерея
HROOT="$SANDBOX/hubtest"; HPROTO="$HROOT/design/prototype"
mkdir -p "$HPROTO/lab" "$HROOT/research/refs"
printf '<!doctype html><title>Главная</title>'  > "$HPROTO/index.html"
printf '<!doctype html><title>KIT</title>'       > "$HPROTO/components.html"
printf '<!doctype html><title>Hero lab</title>'  > "$HPROTO/lab/hero-lab.html"
printf '<!doctype html><title>Рефы</title>'      > "$HROOT/research/refs/gallery.html"
bash "$HUBSH" "$HROOT" >/dev/null 2>&1
[ -s "$HPROTO/hub.html" ] && ok "build-hub.sh generates hub.html" || no "hub.html not generated"
grep -q 'data-vp="mobile"' "$HPROTO/hub.html" && grep -q 'Открыть в новой вкладке' "$HPROTO/hub.html" \
  && ok "hub: Desktop/Mobile toggle + open-in-new-tab" || no "hub controls missing"
eq "hub: links every artifact (4), excludes self" "4" "$(grep -c 'class="hub-link"' "$HPROTO/hub.html")"
grep -q 'data-src="components.html"' "$HPROTO/hub.html" && ok "hub: KIT (components.html) linked" || no "KIT not linked"
grep -q 'data-src="../../research/refs/gallery.html"' "$HPROTO/hub.html" \
  && ok "hub: research gallery linked (resolved relative path)" || no "research gallery not linked"
python3 - "$HPROTO/hub.html" >/dev/null 2>&1 <<'PY' && ok "hub: embedded DATA json valid" || no "hub embedded json invalid"
import sys, re, json
h = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"var DATA = (\[.*\]);", h)   # greedy, одна строка: ']' в title не обрезает
sys.exit(0 if (m and isinstance(json.loads(m.group(1)), list)) else 1)
PY
# идемпотентность + self-exclusion: повторный прогон не линкует сам hub.html
bash "$HUBSH" "$HROOT" >/dev/null 2>&1
eq "hub: idempotent re-run, never links hub.html itself" "0" "$(grep -c 'data-src="hub.html"' "$HPROTO/hub.html")"
# пустой прототип → graceful empty-state (не падение)
mkdir -p "$SANDBOX/emptyproto/design/prototype"
bash "$HUBSH" "$SANDBOX/emptyproto" >/dev/null 2>&1
grep -q 'hub-empty' "$SANDBOX/emptyproto/design/prototype/hub.html" \
  && ok "hub: empty prototype → graceful empty-state" || no "hub empty-state missing"
bash "$HUBSH" >/dev/null 2>&1; rc_is 2 $? "build-hub no-arg → usage rc2"

echo "── design D2: finalize-fix regression guards ──"
# rank5: reduced-motion = animation:none, НЕ animation-duration:0.01ms-хак (упоминание в комменте — ок)
eq "tokens.css: 0 деклараций animation-duration:0.01ms" "0" "$(grep -cE 'animation-duration:[[:space:]]*0\.01ms' "$TPL/tokens.css")"
grep -A4 'prefers-reduced-motion: reduce' "$TPL/tokens.css" | grep -q 'animation: none' \
  && ok "tokens.css: reduced-motion uses animation:none" || no "reduced-motion not animation:none"
# rank3: dark-форс несёт --shadow-sm (иначе тень .c-card невидима на тёмном)
grep -F -A15 ':root[data-theme="dark"] {' "$TPL/tokens.css" | grep -q -- '--shadow-sm' \
  && ok "tokens.css: dark force overrides --shadow-sm" || no "dark --shadow-sm missing"
# rank6: компоненты/страницы БЕЗ хардкод rgba()/hsl() — палитра только в tokens.css (через --color-overlay и пр.)
eq "components.html: 0 rgba()/hsl() (через токены)" "0" "$(grep -cE 'rgba\(|hsl\(' "$TPL/components.html")"
eq "index.html: 0 rgba()/hsl() (через токены)"      "0" "$(grep -cE 'rgba\(|hsl\(' "$TPL/index.html")"
grep -q -- '--color-overlay' "$TPL/tokens.css" && ok "tokens.css: --color-overlay token present" || no "--color-overlay missing"
# rank1: modal реально перехватывает Tab (focus-trap), не только initial focus()
grep -q "'Tab'" "$TPL/components.html" && grep -q 'FOCUSABLE' "$TPL/components.html" \
  && ok "components.html: modal focus-trap (Tab перехват)" || no "modal focus-trap missing"
# rank7: tap-target ≥44px на кнопках-эталонах (kit-contracts §4)
grep -q 'min-height:44px' "$TPL/components.html" && grep -q 'min-height:44px' "$TPL/index.html" \
  && ok "tap-target ≥44px (c-btn + .btn)" || no "min-height:44px missing"

# rank2+4 + gap: гарды на СГЕНЕРИРОВАННЫЙ hub.html (smoke раньше не покрывал .sh-heredoc)
HFIX="$SANDBOX/hubfix/design/prototype"; mkdir -p "$HFIX/lab"
printf '<!doctype html><title>Главная</title>'                                    > "$HFIX/index.html"
printf '<!doctype html><title>Прайс лаборатории</title>'                          > "$HFIX/labor.html"   # НЕ lab
printf '<!doctype html><title>Lab index</title>'                                  > "$HFIX/lab/index.html" # lab, НЕ main
printf '<!doctype html><title>X</script><img src=x onerror=alert(1)></title>'     > "$HFIX/evil.html"    # XSS-проба
bash "$HUBSH" "$SANDBOX/hubfix" >/dev/null 2>&1
eq "hub.html: 0 outline:none (focus-visible вместо)" "0" "$(grep -c 'outline:none' "$HFIX/hub.html")"
grep -q 'focus-visible' "$HFIX/hub.html" && ok "hub.html: has focus-visible ring" || no "hub focus-visible missing"
# DATA-инъекция экранирует </ (нет <script>-break XSS из чужого <title>)
DATA_LINE=$(grep -o 'var DATA = .*;' "$HFIX/hub.html")
printf '%s' "$DATA_LINE" | grep -q '</' && no "hub DATA: незаэкранирован </ (script-break XSS)" || ok "hub DATA: </ экранирован, нет script-break XSS"
# rank8: classify — labor.html→pages (НЕ lab), lab/index.html→lab (НЕ main)
python3 - "$HFIX/hub.html" >/dev/null 2>&1 <<'PY' && ok "hub classify: labor→pages, lab/index→lab (нет ложного lab/main)" || no "classify edge-cases wrong"
import sys, re, json
h = open(sys.argv[1], encoding="utf-8").read()
DATA = json.loads(re.search(r"var DATA = (\[.*\]);", h).group(1))   # greedy, одна строка
g = {x["id"]: [i["src"] for i in x["items"]] for x in DATA}
ok = ("labor.html" in g.get("pages", [])) and ("lab/index.html" in g.get("lab", [])) \
     and ("labor.html" not in g.get("lab", [])) and ("lab/index.html" not in g.get("main", []))
sys.exit(0 if ok else 1)
PY

# ── iter2 (panel 2) fixes ──
# r5: форма демонстрирует success + validating (kit-contracts §2 state-matrix)
grep -q 'c-form-ok' "$TPL/components.html" && grep -q 'data-loading' "$TPL/components.html" \
  && ok "components.html: form success + validating states" || no "form success/validating state missing"
# r6a: label'ы связаны for/id (screen-reader association)
grep -q 'for="f-name"' "$TPL/components.html" && grep -q 'id="f-name"' "$TPL/components.html" \
  && ok "components.html: form labels linked (for/id)" || no "form labels not linked"
# r6b/c: сгенерированный hub несёт aria-label (search + nav landmark)
HARIA=$(grep -c 'aria-label' "$HFIX/hub.html"); [ "${HARIA:-0}" -ge 2 ] \
  && ok "hub.html: aria-label on search+nav ($HARIA)" || no "hub aria-label missing ($HARIA)"
# r7: index.html responsive — есть @media
grep -q '@media' "$TPL/index.html" && ok "index.html: has @media breakpoint (responsive)" || no "index.html zero @media"
# r8: шаг 6b scaffold + NS-rename (proto: → <slug>:) воспроизводим (если регекс/имена дрейфнут — поймаем)
SB="$SANDBOX/scaffold6b/design/prototype"; mkdir -p "$SB"
cp "$TPL/components.html" "$TPL/index.html" "$SB/"
perl -pi -e "s/var NS ?= ?'proto:'/var NS = 'banya:'/g" "$SB/"*.html
eq "6b NS-rename: 0× 'proto:' остаётся" "0" "$(grep -rho 'proto:' "$SB"/*.html | wc -l | tr -d ' ')"
eq "6b NS-rename: slug применён в обоих html" "2" "$(grep -rl 'banya:' "$SB"/*.html | wc -l | tr -d ' ')"

# ── iter3 (panel 3) fixes ──
# r2: ссылки hub клавиатурно-доступны — у <a class="hub-link"> есть href (tab order + Enter)
grep -q 'class="hub-link" href=' "$HFIX/hub.html" \
  && ok "hub.html: sidebar links keyboard-accessible (href)" || no "hub links missing href"
# r3: single-pass подстановка (нет порядок-зависимого chained .replace на шаблоне)
grep -q '_subs = {' "$HUBSH" && grep -q 're.sub(r"__' "$HUBSH" \
  && ok "build-hub.sh: single-pass template substitution" || no "build-hub chained-replace not replaced"
# r4: hub.html в подпапке (lab/hub.html) НЕ исключается — exclusion только по целевому out
HL="$SANDBOX/hublab/design/prototype"; mkdir -p "$HL/lab"
printf '<!doctype html><title>Главная</title>'         > "$HL/index.html"
printf '<!doctype html><title>Lab hub variant</title>' > "$HL/lab/hub.html"
bash "$HUBSH" "$SANDBOX/hublab" >/dev/null 2>&1
grep -q 'data-src="lab/hub.html"' "$HL/hub.html" \
  && ok "hub: sub-dir lab/hub.html kept (exclusion=target only)" || no "lab/hub.html wrongly excluded"
# consent-gate: 152-ФЗ submit заблокирован до согласия (kit-contracts §7)
grep -q 'id="f-consent"' "$TPL/components.html" && grep -q 'submitBtn.disabled' "$TPL/components.html" \
  && ok "components.html: submit gated by 152-ФЗ consent" || no "consent-gate missing"

# ── iter4 (panel 4) fixes ──
# r1: .c-modal info-only fallback — tabindex=-1
grep -qE 'c-modal[^>]*tabindex="-1"' "$TPL/components.html" \
  && ok "components.html: .c-modal tabindex=-1 (info-only focus fallback)" || no ".c-modal missing tabindex=-1"
# FOUC: theme-script стоит ДО stylesheet (в <head>) → нет вспышки светлой темы
SL=$(grep -n 'data-theme' "$TPL/components.html" | head -1 | cut -d: -f1)
LL=$(grep -n 'rel="stylesheet"' "$TPL/components.html" | head -1 | cut -d: -f1)
[ -n "$SL" ] && [ -n "$LL" ] && [ "$SL" -lt "$LL" ] \
  && ok "components.html: theme-restore before stylesheet (no FOUC)" || no "FOUC: theme not before stylesheet"
grep -q 'aria-pressed' "$TPL/components.html" && ok "components.html: theme-toggle aria-pressed" || no "theme aria-pressed missing"
grep -q 'data-stagger' "$TPL/components.html" && ok "components.html: [data-stagger] handler (motion-checklist parity)" || no "data-stagger not implemented"
# r4: сгенерированный hub — reduced-motion + focus-visible на интерактивах (не только .hub-search)
grep -q 'prefers-reduced-motion: reduce' "$HFIX/hub.html" && ok "hub.html: reduced-motion block" || no "hub no reduced-motion"
grep -q ':where(a.hub-link' "$HFIX/hub.html" && ok "hub.html: focus-visible on links+buttons" || no "hub focus-visible only on search"
# r2: classify точность — lab-results.html→pages (бизнес), hero-lab.html(суффикс)→lab
HC="$SANDBOX/classify/design/prototype"; mkdir -p "$HC"
printf '<!doctype html><title>Анализы лаборатории</title>' > "$HC/lab-results.html"
printf '<!doctype html><title>Hero вариант</title>'        > "$HC/hero-lab.html"
printf '<!doctype html><title>Home</title>'                > "$HC/index.html"
bash "$HUBSH" "$SANDBOX/classify" >/dev/null 2>&1
python3 - "$HC/hub.html" >/dev/null 2>&1 <<'PY' && ok "classify: lab-results→pages, hero-lab(suffix)→lab" || no "classify lab precision wrong"
import sys, re, json
DATA = json.loads(re.search(r"var DATA = (\[.*\]);", open(sys.argv[1]).read()).group(1))
g = {x["id"]: [i["src"] for i in x["items"]] for x in DATA}
sys.exit(0 if ("lab-results.html" in g.get("pages", []) and "hero-lab.html" in g.get("lab", [])
               and "lab-results.html" not in g.get("lab", [])) else 1)
PY
# r8a: оба dark-блока tokens.css в синхроне (drift guard на ключевые токены)
eq "tokens.css: dark --color-bg в ОБОИХ блоках" "2" "$(grep -cE '\-\-color-bg:.*0e0f12' "$TPL/tokens.css")"
eq "tokens.css: dark --shadow-sm в ОБОИХ блоках" "2" "$(grep -cE '\-\-shadow-sm:.*rgba\(0,0,0,\.32\)' "$TPL/tokens.css")"

echo "── orchestrator (Phase C, dry-run, no API) ──"
[ -s "$SKILL/workflow/landing-builder.js" ] && ok "workflow/landing-builder.js present" || no "orchestrator missing"
if command -v node >/dev/null 2>&1; then
  node --check "$SKILL/workflow/landing-builder.js" 2>/dev/null && ok "landing-builder.js: node --check passes" || no "landing-builder.js syntax error"
  DRY=$(node "$SKILL/tests/workflow-dryrun.mjs" 2>&1); DRC=$?
  if [ "$DRC" -eq 0 ] && printf '%s' "$DRY" | grep -q 'DRYRUN OK'; then
    ok "orchestrator dry-run green ($(printf '%s' "$DRY" | grep -c '✓') checks, hermetic/zero-cost)"
  else
    no "orchestrator dry-run failed (rc=$DRC)"; printf '%s\n' "$DRY" | grep '✗' | sed 's/^/      /'
  fi
else
  ok "node absent — skip orchestrator dry-run"
fi
# DR-1: research встроен через agent(), НЕ nested workflow() — no workflow() call in code
if grep -vE '^[[:space:]]*//' "$SKILL/workflow/landing-builder.js" | grep -qE '\bworkflow\(' ; then
  no "orchestrator calls workflow() in code (DR-1 violation)"
else
  ok "no nested workflow() call — research via agent() (DR-1)"
fi

echo "── reviewer spec + self-improve (Phase E) ──"
RF="$SKILL/stages/reviewer/prompt.md"
if [ -s "$RF" ] && grep -q 'R1' "$RF" && grep -q 'R2' "$RF" && grep -q 'R3' "$RF" && grep -q 'REVIEW_SCHEMA' "$RF"; then
  ok "stages/reviewer/prompt.md present + R1/R2/R3 + schema"
else
  no "reviewer spec missing/incomplete"
fi
grep -q 'stages/reviewer/prompt.md' "$SKILL/workflow/landing-builder.js" && ok "orchestrator gate references reviewer spec (E1)" || no "gate doesn't reference reviewer spec"
# feedback.sh (REDLOFT_FEEDBACK_DIR already → sandbox)
record_feedback planning reviewer info "повтор-замечание" 1 banya && ok "record_feedback ok" || no "record_feedback failed"
record_feedback planning reviewer info "повтор-замечание" 2 banya >/dev/null
jq -e . "$REDLOFT_FEEDBACK_DIR/planning.jsonl" >/dev/null 2>&1 && ok "feedback/<stage>.jsonl valid JSONL" || no "feedback JSONL invalid"
eq "aggregate total" "2" "$(aggregate_feedback planning | jq -r .total)"
eq "aggregate repeated → solidify_candidate" "true" "$(aggregate_feedback planning | jq -r .solidify_candidate)"
eq "aggregate detects repeated note" "1" "$(aggregate_feedback planning | jq '.repeated|length')"
record_feedback bogus user info x 2>/dev/null; rc_is 2 $? "feedback rejects invalid stage"
record_feedback planning user nosuchsev x 2>/dev/null; rc_is 2 $? "feedback rejects invalid severity"
record_feedback design user info "leak sk-abcdefgh12345678 here" 0 - >/dev/null
grep -q 'sk-abcdefgh12345678' "$REDLOFT_FEEDBACK_DIR/design.jsonl" 2>/dev/null && no "feedback secret leaked" || ok "feedback scrubs secrets"
feedback_stages | grep -qx planning && ok "feedback_stages lists stages with feedback" || no "feedback_stages wrong"

echo "── purge_project.sh (Phase F, PII-lifecycle) ──"
PP="$SKILL/lib/purge_project.sh"
PDX=$(newproj purge-me); printf 'Имя: X\n' > "$PDX/brief/contacts.md"
bash "$PP" purge-me --purge-contacts >/dev/null 2>&1
{ [ ! -f "$PDX/brief/contacts.md" ] && [ -d "$PDX" ]; } && ok "--purge-contacts removes PII, keeps project" || no "purge-contacts wrong"
bash "$PP" purge-me >/dev/null 2>&1
[ ! -d "$PDX" ] && ok "full purge removes project dir" || no "full purge failed"
bash "$PP" >/dev/null 2>&1; rc_is 64 $? "purge no-arg → usage 64"
bash "$PP" "Bad Slug!" >/dev/null 2>&1; rc_is 1 $? "purge invalid slug → 1"
bash "$PP" nope-not-here >/dev/null 2>&1; rc_is 1 $? "purge nonexistent → 1"

echo ""
echo "════════ $PASS passed, $FAIL failed ════════"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# S1 temporal-layers: unit-тесты протокола записи (DoD из DESIGN-temporal-layers-v2.md).
# Изолированная тестовая база (REDBRAIN_DB_DIR=tmp) — живые work/private не трогаются.
set -uo pipefail

LIB="$HOME/.claude/skills/redbrain/lib"
TMP=$(mktemp -d)
export REDBRAIN_DB_DIR="$TMP"
export REDBRAIN_SCOPE=work
G="python3 $LIB/graphdb.py"
DB="$TMP/work.db"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "✓ $1"; }
fail() { FAIL=$((FAIL+1)); echo "✗ $1"; }
q()    { sqlite3 "$DB" "$1"; }

$G init >/dev/null

# --- фикстуры: doc-инжест + episode-инжест
echo '{"source_id":"doc-a.md","content_hash":"h1","run_id":"r1","triples":[
  {"src":"игорь","src_type":"person","relation":"uses","dst":"plaud","dst_type":"tool"}]}' | $G insert >/dev/null

EP1='{"episode":{"ts":"2026-07-01T10:00:00+00:00","channel":"plaud","content":"смотрю билеты в Индию, телефон +7 921 123-45-67"},
 "run_id":"r2","triples":[
  {"src":"игорь","src_type":"person","relation":"traveling_to","dst":"индия","dst_type":"place",
   "valid_at":"2026-03-10","invalid_at":"2026-03-25","attribution":"model_inference"}]}'
OUT1=$(echo "$EP1" | $G insert-episode)

# T1: эпизод записан, PII вырезан
[ "$(q "SELECT COUNT(*) FROM episodes")" = "1" ] && ok "T1a episode inserted" || fail "T1a episode inserted"
q "SELECT content FROM episodes" | grep -q "921" && fail "T1b PII scrubbed" || ok "T1b PII scrubbed"
[ "$(q "SELECT redacted FROM episodes")" = "1" ] && ok "T1c redacted flag" || fail "T1c redacted flag"

# T2: candidate-ребро с интервалом + lineage
[ "$(q "SELECT COUNT(*) FROM edges WHERE status='candidate' AND relation='traveling_to'")" = "1" ] \
  && ok "T2a candidate edge" || fail "T2a candidate edge"
[ "$(q "SELECT COUNT(*) FROM edge_episodes")" = "1" ] && ok "T2b lineage row" || fail "T2b lineage row"

# T3: идемпотентность — тот же payload повторно = нулевой дифф
BEFORE=$(q "SELECT (SELECT COUNT(*) FROM edges)||'|'||(SELECT COUNT(*) FROM episodes)||'|'||(SELECT COUNT(*) FROM edge_episodes)")
echo "$EP1" | $G insert-episode >/dev/null
AFTER=$(q "SELECT (SELECT COUNT(*) FROM edges)||'|'||(SELECT COUNT(*) FROM episodes)||'|'||(SELECT COUNT(*) FROM edge_episodes)")
[ "$BEFORE" = "$AFTER" ] && ok "T3 idempotent re-send" || fail "T3 idempotent re-send ($BEFORE -> $AFTER)"

# T4: корроборация — та же тройка из ДРУГОГО эпизода = то же ребро, +1 lineage
EP2='{"episode":{"ts":"2026-07-03T18:00:00+00:00","channel":"telegram","content":"ищу жильё в Гоа на март"},
 "run_id":"r3","triples":[
  {"src":"игорь","src_type":"person","relation":"traveling_to","dst":"индия","dst_type":"place",
   "valid_at":"2026-03-10","invalid_at":"2026-03-25","attribution":"model_inference"}]}'
OUT2=$(echo "$EP2" | $G insert-episode)
[ "$(q "SELECT COUNT(*) FROM edges WHERE relation='traveling_to'")" = "1" ] && ok "T4a no duplicate edge" || fail "T4a no duplicate edge"
[ "$(q "SELECT COUNT(*) FROM edge_episodes")" = "2" ] && ok "T4b corroboration lineage=2" || fail "T4b corroboration lineage=2"
echo "$OUT2" | grep -q '"corroborated": \[{' && ok "T4c reported corroborated" || fail "T4c reported corroborated"

# T5: tombstone дока НЕ трогает episode-рёбра
echo '{"source_id":"doc-a.md","content_hash":"h2","run_id":"r4","triples":[
  {"src":"игорь","src_type":"person","relation":"uses","dst":"riffado","dst_type":"tool"}]}' | $G insert >/dev/null
[ "$(q "SELECT COUNT(*) FROM edges WHERE relation='traveling_to'")" = "1" ] && ok "T5a episode edge survives doc tombstone" || fail "T5a episode edge survives doc tombstone"
[ "$(q "SELECT COUNT(*) FROM edges WHERE relation='uses' AND dst_id=(SELECT id FROM nodes WHERE name='plaud')")" = "0" ] \
  && ok "T5b doc edges tombstoned as before" || fail "T5b doc edges tombstoned as before"

# T6: gate экстракции — мусорный relation отклонён
BAD='{"episode":{"ts":"2026-07-04T10:00:00+00:00","channel":"chat","content":"тест"},
 "run_id":"r5","triples":[
  {"src":"игорь","relation":"has_vibes_about","dst":"марс","attribution":"model_inference"}]}'
OUT=$(echo "$BAD" | $G insert-episode)
echo "$OUT" | grep -q "relation not in dictionary" && ok "T6a junk relation rejected" || fail "T6a junk relation rejected"
# T6b: мусорный valid_at → fallback на ts эпизода, не мусор в базе
BADDATE='{"episode":{"ts":"2026-07-04T11:00:00+00:00","channel":"chat","content":"тест2"},
 "run_id":"r6","triples":[
  {"src":"игорь","relation":"planning","dst":"поездка","valid_at":"когда-нибудь в марте","attribution":"model_inference"}]}'
echo "$BADDATE" | $G insert-episode >/dev/null
[ "$(q "SELECT valid_at FROM edges WHERE relation='planning'")" = "2026-07-04T11:00:00+00:00" ] \
  && ok "T6b junk valid_at falls back to episode ts" || fail "T6b junk valid_at falls back to episode ts"

# T7: интервальная валидация — invalid_at <= valid_at отклонён
INV='{"episode":{"ts":"2026-07-04T12:00:00+00:00","channel":"chat","content":"тест3"},
 "run_id":"r7","triples":[
  {"src":"игорь","relation":"located_in","dst":"питер","valid_at":"2026-03-25","invalid_at":"2026-03-10","attribution":"model_inference"}]}'
OUT=$(echo "$INV" | $G insert-episode)
echo "$OUT" | grep -q "invalid_at <= valid_at" && ok "T7 inverted interval rejected" || fail "T7 inverted interval rejected"

# T8: invalidate — episode-ребро закрывается, doc-ребро refuse
EDGE=$(q "SELECT id FROM edges WHERE relation='traveling_to'")
$G invalidate "$EDGE" "2026-03-20" >/dev/null
ROW=$(q "SELECT status||'|'||invalid_at||'|'||(expired_at IS NOT NULL) FROM edges WHERE id='$EDGE'")
[ "$ROW" = "invalidated|2026-03-20|1" ] && ok "T8a invalidate closes window, no DELETE" || fail "T8a invalidate ($ROW)"
DOC_EDGE=$(q "SELECT id FROM edges WHERE attribution='doc' LIMIT 1")
$G invalidate "$DOC_EDGE" "2026-03-20" >/dev/null 2>&1 && fail "T8b doc edge refuse" || ok "T8b doc edge refuse"

# T9: kill -9 посреди транзакции → база консистентна, никаких полурядов
KILLER=$(cat <<'PYEOF'
import sys, os, time, json, subprocess
sys.path.insert(0, os.path.expanduser("~/.claude/skills/redbrain/lib"))
import graphdb
c = graphdb.connect()
c.execute("BEGIN IMMEDIATE")
ts = graphdb.now()
c.execute("INSERT INTO episodes(id,ts,channel,content,redacted,ingested_at) VALUES('killtest','2026-07-05T00:00:00+00:00','chat','x',0,?)", (ts,))
c.execute("INSERT INTO sources(source_id,content_hash,last_ingest_at,status) VALUES('episode:killtest','k',?,'ok')", (ts,))
print("mid-tx", flush=True)
time.sleep(30)  # держим транзакцию открытой — нас убьют
PYEOF
)
python3 -c "$KILLER" &
KPID=$!
# ждём выхода в середину транзакции
for i in $(seq 1 50); do sleep 0.1; kill -0 $KPID 2>/dev/null || break; done
sleep 0.5
kill -9 $KPID 2>/dev/null; wait $KPID 2>/dev/null
[ "$(q "SELECT COUNT(*) FROM episodes WHERE id='killtest'")" = "0" ] && ok "T9a kill -9 mid-tx: no partial rows" || fail "T9a kill -9 mid-tx: no partial rows"
q "PRAGMA integrity_check" | grep -q "^ok$" && ok "T9b integrity after kill" || fail "T9b integrity after kill"
# база не залочена мёртвым писателем
echo "$EP1" | $G insert-episode >/dev/null 2>&1 && ok "T9c writable after kill" || fail "T9c writable after kill"

# T10: scope-гард — write без REDBRAIN_SCOPE = отказ
OUT=$(env -u REDBRAIN_SCOPE REDBRAIN_DB_DIR="$TMP" bash -c "echo '$EP1' | python3 $LIB/graphdb.py insert-episode" 2>&1)
echo "$OUT" | grep -q "write op" && ok "T10 scope guard on insert-episode" || fail "T10 scope guard on insert-episode"

rm -rf "$TMP"
echo "---"
echo "temporal: $PASS pass / $FAIL fail"
[ $FAIL = 0 ]

#!/usr/bin/env bash
# S2a temporal-layers: тесты promote.py (DoD: двойной прогон = идентичные карточки;
# TTL-кейс; ✅-апрув переводит пачку; события в events.log). Изолированные БД и кэш.
set -uo pipefail

LIB="$HOME/.claude/skills/redbrain/lib"
TMP=$(mktemp -d)
export REDBRAIN_DB_DIR="$TMP/db"
export REDBRAIN_PROMOTE_CACHE="$TMP/promote"
export REDBRAIN_SCOPE=work
G="python3 $LIB/graphdb.py"
P="python3 $LIB/promote.py"
DB="$TMP/db/work.db"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "✓ $1"; }
fail() { FAIL=$((FAIL+1)); echo "✗ $1"; }
q()    { sqlite3 "$DB" "$1"; }
ep()    { echo "$1" | $G insert-episode >/dev/null; }

$G init >/dev/null

# --- фикстуры
# A: корроборированный факт (2 канала, один день) → eligible
ep '{"episode":{"ts":"2026-07-01T10:00:00+00:00","channel":"plaud","content":"билеты в Индию"},"run_id":"r1","triples":[{"src":"игорь","relation":"traveling_to","dst":"индия","valid_at":"2026-03-10","invalid_at":"2026-03-25","attribution":"model_inference"}]}'
ep '{"episode":{"ts":"2026-07-01T18:00:00+00:00","channel":"telegram","content":"жильё в Гоа"},"run_id":"r2","triples":[{"src":"игорь","relation":"traveling_to","dst":"индия","valid_at":"2026-03-10","invalid_at":"2026-03-25","attribution":"model_inference"}]}'
# B: одинокий model_inference → НЕ eligible
ep '{"episode":{"ts":"2026-07-02T10:00:00+00:00","channel":"chat","content":"может баня"},"run_id":"r3","triples":[{"src":"игорь","relation":"planning","dst":"баня-проект","attribution":"model_inference"}]}'
# C: user_statement с 1 эпизода → eligible
ep '{"episode":{"ts":"2026-07-02T11:00:00+00:00","channel":"telegram","content":"я в Питере до пятницы"},"run_id":"r4","triples":[{"src":"игорь","relation":"located_in","dst":"питер","valid_at":"2026-07-01","invalid_at":"2026-07-10","attribution":"user_statement"}]}'
# D: старый одинокий кандидат → TTL
ep '{"episode":{"ts":"2026-05-01T10:00:00+00:00","channel":"chat","content":"старое"},"run_id":"r5","triples":[{"src":"игорь","relation":"planning","dst":"старый-план","attribution":"model_inference"}]}'
OLD_EDGE=$(q "SELECT e.id FROM edges e JOIN nodes n ON n.id=e.dst_id WHERE n.name='старый-план'")
q "UPDATE edges SET created_at='2026-05-01T10:00:00+00:00' WHERE id='$OLD_EDGE'"

# T1: scan — eligibility по правилам
OUT1=$($P scan)
echo "$OUT1" | grep -q "traveling_to" && ok "T1a corroborated in proposal" || fail "T1a corroborated in proposal"
echo "$OUT1" | grep -q "located_in" && ok "T1b user_statement in proposal" || fail "T1b user_statement in proposal"
echo "$OUT1" | grep -q "баня-проект" && fail "T1c lone inference NOT proposed" || ok "T1c lone inference NOT proposed"

# T2: TTL — старый одинокий кандидат погашен, строка осталась
[ "$(q "SELECT status FROM edges WHERE id='$OLD_EDGE'")" = "expired" ] && ok "T2a TTL expired" || fail "T2a TTL expired"
[ "$(q "SELECT COUNT(*) FROM edges WHERE id='$OLD_EDGE'")" = "1" ] && ok "T2b row kept (no DELETE)" || fail "T2b row kept"
grep -q '"op": "ttl-expire"' "$REDBRAIN_PROMOTE_CACHE/events.log" && ok "T2c ttl event logged" || fail "T2c ttl event logged"

# T3: идемпотентность scan — повторный прогон = тот же proposal id, байт-в-байт
PROP1=$(ls "$REDBRAIN_PROMOTE_CACHE"/proposal-*.json)
SUM1=$(md5 -q "$PROP1" 2>/dev/null || md5sum "$PROP1" | cut -d' ' -f1)
$P scan >/dev/null
PROPS=$(ls "$REDBRAIN_PROMOTE_CACHE"/proposal-*.json | wc -l | tr -d ' ')
SUM2=$(md5 -q "$PROP1" 2>/dev/null || md5sum "$PROP1" | cut -d' ' -f1)
[ "$PROPS" = "1" ] && [ "$SUM1" = "$SUM2" ] && ok "T3 double scan = identical card" || fail "T3 double scan ($PROPS files)"

# T4: apply — пачка переведена в confirmed
PID=$(python3 -c "import json;print(json.load(open('$PROP1'))['id'])")
OUT=$($P apply "$PID")
N_CONF=$(q "SELECT COUNT(*) FROM edges WHERE status='confirmed' AND attribution!='doc'")
[ "$N_CONF" = "2" ] && ok "T4a batch promoted (2 edges)" || fail "T4a batch promoted (got $N_CONF)"
grep -q '"op": "promote"' "$REDBRAIN_PROMOTE_CACHE/events.log" && ok "T4b promote events logged" || fail "T4b promote events"

# T5: apply повторно — идемпотентно, всё в skipped
OUT=$($P apply "$PID")
echo "$OUT" | grep -q '"applied": \[\]' && ok "T5 re-apply no-op" || fail "T5 re-apply no-op ($OUT)"

# T6: конфликт — новый кандидат пересекается с confirmed той же тройки
ep '{"episode":{"ts":"2026-07-03T10:00:00+00:00","channel":"plaud","content":"индия сдвиг"},"run_id":"r6","triples":[{"src":"игорь","relation":"traveling_to","dst":"индия","valid_at":"2026-03-20","invalid_at":"2026-04-05","attribution":"model_inference"}]}'
ep '{"episode":{"ts":"2026-07-04T10:00:00+00:00","channel":"telegram","content":"индия сдвиг подтверждение"},"run_id":"r7","triples":[{"src":"игорь","relation":"traveling_to","dst":"индия","valid_at":"2026-03-20","invalid_at":"2026-04-05","attribution":"model_inference"}]}'
OUT=$($P scan)
echo "$OUT" | python3 -c "import json,sys; p=json.load(sys.stdin)['proposal']; sys.exit(0 if p and len(p['conflicts'])==1 and not p['promote'] else 1)" \
  && ok "T6a overlap → conflicts, not auto-promote" || fail "T6a overlap → conflicts"
grep -q '"op": "conflict"' "$REDBRAIN_PROMOTE_CACHE/events.log" && ok "T6b conflict logged" || fail "T6b conflict logged"
# конфликтная пачка НЕ применяется apply'ем (в promote её нет)
PROP2=$(ls -t "$REDBRAIN_PROMOTE_CACHE"/proposal-*.json | head -1)
PID2=$(python3 -c "import json;print(json.load(open('$PROP2'))['id'])")
$P apply "$PID2" >/dev/null
ST=$(q "SELECT status FROM edges WHERE valid_at='2026-03-20'")
[ "$ST" = "candidate" ] && ok "T6c conflict edge stays candidate" || fail "T6c conflict edge stays candidate ($ST)"

# T7: scope-guard + cross-scope apply refuse
OUT=$(env -u REDBRAIN_SCOPE REDBRAIN_DB_DIR="$REDBRAIN_DB_DIR" REDBRAIN_PROMOTE_CACHE="$REDBRAIN_PROMOTE_CACHE" python3 $LIB/promote.py scan 2>&1)
echo "$OUT" | grep -q "явно" && ok "T7a scan scope guard" || fail "T7a scan scope guard"
OUT=$(REDBRAIN_SCOPE=private python3 $LIB/promote.py apply "$PID" 2>&1)
echo "$OUT" | grep -q "не смешиваем" && ok "T7b cross-scope apply refuse" || fail "T7b cross-scope apply refuse"

# T8: lock — занятый живым владельцем lock → skip
python3 $LIB/lock.py acquire redbrain --owner $$ >/dev/null
OUT=$($P scan 2>&1); RC=$?
[ $RC != 0 ] && echo "$OUT" | grep -q "lock" && ok "T8 busy lock → skip" || fail "T8 busy lock → skip"
python3 $LIB/lock.py release redbrain --owner $$ >/dev/null

rm -rf "$TMP"
echo "---"
echo "promote: $PASS pass / $FAIL fail"
[ $FAIL = 0 ]

#!/usr/bin/env bash
# Прогон golden query-set (DoD Phase 1). Usage: golden.sh [queries.json]
set -euo pipefail
LIB="$(cd "$(dirname "$0")" && pwd)"
Q="${1:-$LIB/../golden/queries.json}"
PASS=0; FAIL=0
COUNT=$(python3 -c "import json;print(len(json.load(open('$Q'))['queries']))")
for i in $(seq 0 $((COUNT-1))); do
  # поля построчно (readarray) — никакого IFS word-splitting: пробелы в arg
  # и expect не ломают и не ослабляют проверку
  readarray -t F < <(python3 -c "
import json; q=json.load(open('$Q'))['queries'][$i]
print(q['id']); print(q['cmd']); print(q['arg']); print(q['expect_doc_contains'])")
  ID="${F[0]}"; CMD="${F[1]}"; ARG="${F[2]}"; EXPECT="${F[3]}"
  if python3 "$LIB/query.py" "$CMD" "$ARG" 2>/dev/null | grep -qi "$EXPECT"; then
    PASS=$((PASS+1)); echo "✓ #$ID $CMD '$ARG' → $EXPECT"
  else
    FAIL=$((FAIL+1)); echo "✗ #$ID $CMD '$ARG' → expected '$EXPECT' not found"
  fi
done
echo "---"
echo "golden: $PASS/$((PASS+FAIL)) pass (порог DoD: 12/15)"
[ "$PASS" -ge 12 ]

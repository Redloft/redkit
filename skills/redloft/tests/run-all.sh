#!/usr/bin/env bash
# redloft — reproducible test gate. Один прогон всех проверок (для /finalize, CI, pre-commit).
# Закрывает «stable=unknown»: зелёный статус воспроизводим, а не ручной.
# Run: bash tests/run-all.sh   → exit 0 если всё зелёное.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(cd "$DIR/.." && pwd)"
FAIL=0
run() { echo "── $1 ──"; shift; "$@" || { echo "  ✗ FAILED"; FAIL=1; }; echo; }

# Syntax gates
run "bash -n: shell-скрипты" bash -c 'for f in "'"$SKILL"'"/lib/*.sh "'"$SKILL"'"/tests/*.sh; do bash -n "$f" || exit 1; done'
run "node --check: landing-builder.js" node --check "$SKILL/workflow/landing-builder.js"
run "json: MANIFEST.json" python3 -c "import json;json.load(open('$SKILL/lib/methodology-kit/MANIFEST.json'))"

# Test suites
run "full smoke" bash "$SKILL/tests/smoke.sh"
run "methodology smoke" bash "$SKILL/tests/methodology.smoke.sh"
run "methodology self-test (Phase 6)" bash "$SKILL/tests/methodology.selftest.sh"
run "methodology e2e connection" node "$SKILL/tests/methodology.e2e.mjs"
run "workflow dryrun" node "$SKILL/tests/workflow-dryrun.mjs"

echo "════════ run-all: $([ "$FAIL" = 0 ] && echo "ALL GREEN ✅" || echo "FAILURES ❌") ════════"
exit "$FAIL"

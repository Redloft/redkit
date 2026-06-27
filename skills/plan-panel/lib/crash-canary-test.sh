#!/usr/bin/env bash
# crash-canary-test.sh — интеграционный DoD-тест Stage 0 (DESIGN-foundation §7.1 + DoD).
# Инвариант: secrets-strip применяется ПЕРЕД любой записью, поэтому в любой момент
# (включая crash в середине фазы) на диске НЕТ сырых секретов.
#
# Тест: прогнать canary-контент через фазы draft/snapshot, сымитировать crash
# (оставить .tmp + checkpoint in-progress) → grep token-префиксов по ВСЕМ артефактам = 0.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
STRIP="$HERE/strip-secrets.sh"
CKPT="$HERE/checkpoint.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
RUN="$T/run"; mkdir -p "$RUN"

# split-literal canaries (no contiguous secret in-file; realistic at runtime)
_SK="sk-""ABCD1234efgh5678ijkl9012mnop"; _GH="ghp_""ABCDEFGHIJ1234567890abcdefXYZ"; _BR="Bearer ""abcdefghij1234567890KLMNOP"
CANARY="step: call OpenAI with $_SK and gh $_GH
ref op://AI-Tokens/OpenAI/credential header $_BR"

# helper: strip → atomic write (как в реальном пайплайне: source→strip→(только stripped)→disk)
strip_to() {
  local target="$1" tmp; tmp="$(dirname "$target")/.$(basename "$target").tmp.$$"
  # strip ОБЯЗАН пройти; иначе abort и 0 байт на диск (§7.1)
  if ! "$STRIP" < /dev/stdin > "$tmp"; then echo "✗ strip failed → abort, no write"; rm -f "$tmp"; return 1; fi
  mv -f "$tmp" "$target"
}

# Phase draft: планнер выдал план с секретами → пишем plan.v1.md через strip
bash "$CKPT" init "$RUN" "from-task" "$(bash "$CKPT" slug 'canary task')" >/dev/null
bash "$CKPT" set "$RUN" '.phase="draft" | .iteration=1'
printf '%s\n' "$CANARY" | strip_to "$RUN/plan.v1.md"

# Phase snapshot (как в /finalize): diff с секретами → diff.patch через strip
printf '%s\n' "$CANARY" | strip_to "$RUN/diff.patch"

# execution_trace: ТОЛЬКО метаданные, без payload (§5). Симулируем.
jq -n '[{phase:"draft",model:"opus",status:"ok",tokens_in:100,tokens_out:200,scope_cache_hit:false}]' > "$RUN/trace.json"

# Сымитировать CRASH в середине фазы revise: оставить .tmp + status in-progress.
# .tmp ТОЖЕ должен быть post-strip (strip идёт до записи tmp).
printf '%s\n' "$CANARY" | "$STRIP" > "$RUN/.plan.v2.md.tmp.crash"
bash "$CKPT" set "$RUN" '.phase="revise" | .status="in-progress"'

# --- АССЕРТ: ни одного token-префикса ни в одном артефакте (вкл. .tmp и checkpoint) ---
CANARY_RE='sk-[A-Za-z0-9]|ghp_|AIza|xoxb-|op://|-----BEGIN|Bearer [A-Za-z0-9]{20,}'
fail=0
while IFS= read -r f; do
  if grep -Eq "$CANARY_RE" "$f"; then
    echo "✗ LEAK in $f:"; grep -En "$CANARY_RE" "$f" || true; fail=1
  fi
done < <(find "$RUN" -type f)

# REDACTED-маркеры должны присутствовать (доказательство что strip реально отработал, а не съел всё)
grep -q '‹REDACTED:' "$RUN/plan.v1.md" || { echo "✗ plan.v1.md has no REDACTED markers — strip didn't run?"; fail=1; }

if [ "$fail" -eq 0 ]; then echo "✓ crash-canary test passed (0 token-prefixes across all artifacts, incl. .tmp & checkpoint)"; exit 0
else echo "✗ crash-canary test FAILED"; exit 1; fi

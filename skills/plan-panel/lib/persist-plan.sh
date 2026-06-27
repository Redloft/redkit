#!/usr/bin/env bash
# persist-plan.sh — записать версию плана из reviewer-loop (DESIGN-from-task: plan.vN + canonical).
# Контент идёт через strip-secrets (§7.1) ПЕРЕД записью; canonical plan.md = последняя версия.
#
# Usage:
#   persist-plan.sh <project_dir> <version_int>   < plan_content
#   persist-plan.sh --self-test
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
STRIP="$HERE/strip-secrets.sh"
CKPT="$HERE/checkpoint.sh"

write_version() {
  local dir="$1" ver="$2"
  [ -d "$dir" ] || { echo "✗ no project_dir: $dir" >&2; return 1; }
  printf '%s' "$ver" | grep -qE '^[0-9]+$' || { echo "✗ version must be int: $ver" >&2; return 1; }
  local vfile="$dir/plan.v${ver}.md" tmp="$dir/.plan.v${ver}.md.tmp.$$"
  # strip ОБЯЗАН пройти; иначе abort, 0 байт на диск (§7.1)
  if ! "$STRIP" < /dev/stdin > "$tmp"; then echo "✗ strip failed → abort, no write" >&2; rm -f "$tmp"; return 1; fi
  mv -f "$tmp" "$vfile"
  cp -f "$vfile" "$dir/plan.md"          # canonical = последняя версия
  # bump checkpoint (best-effort)
  [ -f "$dir/checkpoint.json" ] && bash "$CKPT" set "$dir" ".iteration=$ver | .phase=\"draft\"" 2>/dev/null || true
  echo "$vfile"
}

self_test() {
  local T fail=0; T="$(mktemp -d)"; trap 'rm -rf "$T"' RETURN
  local d="$T/run"; mkdir -p "$d"
  bash "$CKPT" init "$d" from-task "$(bash "$CKPT" slug 'x')" >/dev/null

  _SK="sk-""ABCD1234efgh5678ijkl9012mnop"  # split literal (push-protection safe)
  printf 'plan v1 with secret %s here\nstep 1\nstep 2\n' "$_SK" | write_version "$d" 1 >/dev/null
  printf 'plan v2 revised\nstep 1\nstep 2\nstep 3\n' | write_version "$d" 2 >/dev/null

  [ -f "$d/plan.v1.md" ] && [ -f "$d/plan.v2.md" ] || { echo "✗ version files missing"; fail=1; }
  grep -q 'plan v2 revised' "$d/plan.md" || { echo "✗ canonical != latest"; fail=1; }
  grep -Eq 'sk-[A-Za-z0-9]' "$d/plan.v1.md" && { echo "✗ secret leaked into plan.v1.md"; fail=1; }
  grep -q '‹REDACTED' "$d/plan.v1.md" || { echo "✗ strip didn't run on v1"; fail=1; }
  [ "$(jq -r .iteration "$d/checkpoint.json")" = "2" ] || { echo "✗ checkpoint iteration not bumped"; fail=1; }

  if [ "$fail" -eq 0 ]; then echo "✓ persist-plan self-test passed"; return 0; else echo "✗ persist-plan FAILED"; return 1; fi
}

case "${1:-}" in
  --self-test) self_test ;;
  "")          echo "usage: persist-plan.sh <project_dir> <version_int> | --self-test" >&2; exit 64 ;;
  *)           write_version "$@" ;;
esac

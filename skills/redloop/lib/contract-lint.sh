#!/usr/bin/env bash
# contract-lint.sh — гейт автономного старта (DESIGN v2 §S2). Fail-closed.
# Контракт годен, если ≥80% строк DoD исполнимы командой с exit code, пороги проставлены
# числами, scope задан, бюджет задан. Иначе — отказ с точным списком, что спросить у owner'а.
#
# Usage: contract-lint.sh <contract.json> | --self-test
set -euo pipefail
MIN_RATIO="${REDLOOP_DOD_MIN_RATIO:-80}"

lint() {
  local f="${1:?contract.json}"; [ -f "$f" ] || { echo '{"ok":false,"failed":["contract_missing"]}'; return 1; }
  jq -e . "$f" >/dev/null 2>&1 || { echo '{"ok":false,"failed":["contract_not_json"]}'; return 1; }
  local failed="[]"; add(){ failed="$(printf '%s' "$failed" | jq -c --arg x "$1" '. + [$x]')"; }

  local total green ratio
  total="$(jq '[.dod[]?] | length' "$f")"
  green="$(jq '[.dod[]? | select((.cmd // "") != "" and has("expect_exit"))] | length' "$f")"
  [ "${total:-0}" -eq 0 ] && { add "dod_empty"; ratio=0; } || ratio=$(( green * 100 / total ))
  [ "$ratio" -lt "$MIN_RATIO" ] && add "dod_not_machine_checkable(${ratio}%<${MIN_RATIO}%)"

  # вкусовое качество допустимо, но обязано быть явно вынесено человеку, а не молча пропасть
  jq -e '(.human_acceptance // null) != null or ([.dod[]? | select((.cmd//"")=="")] | length)==0' "$f" >/dev/null \
    || add "subjective_criteria_without_human_acceptance"

  jq -e '(.scope_globs // []) | length > 0' "$f" >/dev/null || add "scope_globs_empty"
  jq -e '(.budget.max_iters // 0) > 0' "$f" >/dev/null || add "budget_max_iters_missing"
  jq -e '(.budget.max_minutes // 0) > 0' "$f" >/dev/null || add "budget_max_minutes_missing"
  jq -e '(.thresholds.stall // 0) > 0 and (.thresholds.loop // 0) > 0' "$f" >/dev/null \
    || add "thresholds_not_numeric"   # порог, назначаемый постфактум, — не порог
  jq -e '(.escalation_channel // "") != ""' "$f" >/dev/null || add "escalation_channel_missing"
  jq -e '(.runner // "") != ""' "$f" >/dev/null || add "runner_missing"
  # штамп версий: без него снапшот приёмов не проверить на quarantine-дрейф
  jq -e '(.patterns_sha // "") != ""' "$f" >/dev/null || add "patterns_sha_missing"

  local n; n="$(printf '%s' "$failed" | jq 'length')"
  jq -nc --argjson f "$failed" --argjson ratio "${ratio:-0}" --argjson ok "$([ "$n" -eq 0 ] && echo true || echo false)" \
    '{ok:$ok, dod_machine_ratio:$ratio, failed:$f}'
  [ "$n" -eq 0 ]
}

self_test() {
  set +e; local T; T="$(mktemp -d)"; local fail=0
  ok(){ if [ "$1" -eq 0 ]; then :; else echo "  ✗ $2"; fail=1; fi; }
  cat > "$T/good.json" <<'J'
{"runner":"loop","scope_globs":["src/**"],"patterns_sha":"deadbeef",
 "budget":{"max_iters":12,"max_minutes":90},"thresholds":{"stall":3,"loop":3},
 "escalation_channel":"tg:attunedbot",
 "dod":[{"id":"t","cmd":"npm test","expect_exit":0},{"id":"b","cmd":"npm run build","expect_exit":0}]}
J
  lint "$T/good.json" >/dev/null; ok $? "валидный контракт проходит"
  jq '.dod += [{"id":"nice","desc":"красиво"}]' "$T/good.json" > "$T/mix.json"
  lint "$T/mix.json" >/dev/null 2>&1; ok $((1-$?)) "66% исполнимых DoD → отказ (ниже порога 80%)"
  jq '.dod = [{"id":"a","cmd":"x","expect_exit":0},{"id":"b","cmd":"y","expect_exit":0},{"id":"c","cmd":"z","expect_exit":0},{"id":"d","cmd":"w","expect_exit":0},{"id":"e","desc":"вкусовое"}] | .human_acceptance="Игорь смотрит глазами"' "$T/good.json" > "$T/m80.json"
  lint "$T/m80.json" >/dev/null; ok $? "80% + human_acceptance проходит"
  jq 'del(.human_acceptance)' "$T/m80.json" > "$T/m80b.json"
  lint "$T/m80b.json" >/dev/null 2>&1; ok $((1-$?)) "вкусовой критерий без human_acceptance отвергнут"
  jq 'del(.thresholds)' "$T/good.json" > "$T/nothr.json"
  lint "$T/nothr.json" >/dev/null 2>&1; ok $((1-$?)) "нет числовых порогов → отказ"
  jq 'del(.escalation_channel)' "$T/good.json" > "$T/noch.json"
  lint "$T/noch.json" >/dev/null 2>&1; ok $((1-$?)) "нет канала эскалации → отказ"
  lint "$T/missing.json" >/dev/null 2>&1; ok $((1-$?)) "нет файла → fail-closed"
  rm -rf "$T"
  [ "$fail" -eq 0 ] && { echo "✓ contract-lint self-test passed"; return 0; } || { echo "✗ contract-lint self-test FAILED"; return 1; }
}
case "${1:-}" in --self-test) self_test ;; "") echo "usage: contract-lint.sh <contract.json> | --self-test" >&2; exit 1;; *) lint "$@" ;; esac

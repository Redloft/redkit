#!/usr/bin/env bash
# compile.sh — сборка автономного промпта из контракта + библиотеки приёмов (DESIGN v2 §S3).
# Бюджет ≤6000 токенов; обязательные приёмы входят всегда; остальные — по (применимость × success_rate).
# Штампует patterns_sha в contract.json (#9): LAUNCH обязан отказать, если снапшот разъехался.
#
# Usage: compile.sh <contract.json> <out_dir> [--profile code|content|research|infra] | --self-test
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
BUDGET="${REDLOOP_PROMPT_BUDGET:-6000}"

compile() {
  local cf="${1:?contract.json}" out="${2:?out_dir}"; shift 2
  local profile="code"; while [ $# -gt 0 ]; do case "$1" in --profile) profile="$2"; shift 2;; *) shift;; esac; done
  mkdir -p "$out"
  local psha; psha="$(bash "$HERE/patterns.sh" sha)"
  local tmp; tmp="$(mktemp)"; jq --arg s "$psha" '.patterns_sha=$s' "$cf" > "$tmp" && mv "$tmp" "$cf"

  # отбор: mandatory всегда; прочие — по applies и success_rate, пока влезают в бюджет
  local sel; sel="$(bash "$HERE/patterns.sh" list | jq -s --arg pr "$profile" --argjson b "$BUDGET" '
      (map(select(.mandatory)) ) as $must
    | (map(select(.mandatory|not) | select(.applies=="always" or (.applies|test($pr))))
       | sort_by(-.success_rate)) as $opt
    | ($must + $opt)
    | reduce .[] as $p ({acc:[], used:0};
        if .used + $p.tokens <= $b or $p.mandatory
        then {acc: (.acc + [$p]), used: (.used + $p.tokens)} else . end)
    ')"
  local used; used="$(printf '%s' "$sel" | jq '.used')"

  { echo "# Автономный прогон — REDLOOP"
    echo
    echo "## Задача"; jq -r '.task // "(не задана)"' "$cf"; echo
    echo "## Контракт готовности (DoD) — единственный критерий «сделано»"
    jq -r '.dod[]? | "- [ ] `\(.id)` — " + (if (.cmd//"")!="" then "`\(.cmd)` → exit \(.expect_exit)" else "\(.desc) _(вкусовое: приёмка человеком)_" end)' "$cf"
    if jq -e '(.human_acceptance // "") != ""' "$cf" >/dev/null; then echo; echo "Приёмка человеком: $(jq -r .human_acceptance "$cf")"; fi
    echo
    echo "## Рамки"
    echo "- Scope: $(jq -r '.scope_globs | join(", ")' "$cf") — правки вне этих путей запрещены."
    echo "- Бюджет: $(jq -r '.budget.max_iters' "$cf") итераций / $(jq -r '.budget.max_minutes' "$cf") минут."
    echo "- Пороги: stall=$(jq -r '.thresholds.stall' "$cf"), loop=$(jq -r '.thresholds.loop' "$cf")."
    echo "- Эскалация: $(jq -r '.escalation_channel' "$cf")."
    echo "- Раннер: $(jq -r '.runner' "$cf")."
    echo
    echo "## Как работать"
    printf '%s' "$sel" | jq -r '.acc[].file' | while read -r f; do
      echo; sed '1{/^---$/!q;};1,/^---$/d' "$f"
    done
    echo
    echo "## Журнал"
    echo "Каждое действие — событие в \`events.jsonl\` через \`lib/events.sh append\`:"
    echo "начало и конец итерации (\`--iter N --of M\`), результат каждой проверки (\`check_result\`),"
    echo "каждое допущение (\`assumption\`), финал (\`run_done\`). Молчащий прогон считается упавшим."
  } > "$out/prompt.md"

  jq -nc --arg out "$out/prompt.md" --argjson used "$used" --argjson budget "$BUDGET" \
     --arg psha "$psha" --argjson picked "$(printf '%s' "$sel" | jq '[.acc[].id]')" \
     '{prompt:$out, tokens_est:$used, budget:$budget, patterns_sha:$psha, patterns:$picked}'
}

self_test() {
  set +e; local T; T="$(mktemp -d)"; local fail=0
  ok(){ if [ "$1" -eq 0 ]; then :; else echo "  ✗ $2"; fail=1; fi; }
  cat > "$T/c.json" <<'J'
{"task":"починить X","runner":"loop","scope_globs":["src/**"],
 "budget":{"max_iters":10,"max_minutes":60},"thresholds":{"stall":3,"loop":3},
 "escalation_channel":"tg:attunedbot",
 "dod":[{"id":"t","cmd":"npm test","expect_exit":0}]}
J
  local r; r="$(compile "$T/c.json" "$T/out")"; ok $? "compile отрабатывает"
  printf '%s' "$r" | jq -e '.tokens_est <= .budget' >/dev/null; ok $? "укладывается в бюджет"
  printf '%s' "$r" | jq -e '.patterns | index("P-UNTRUSTED")' >/dev/null; ok $? "P-UNTRUSTED в промпте всегда"
  printf '%s' "$r" | jq -e '.patterns | index("P-EXIT")' >/dev/null; ok $? "P-EXIT в промпте всегда"
  grep -q "npm test" "$T/out/prompt.md"; ok $? "DoD-команда попала в промпт"
  grep -q "REDLOOP_STATUS" "$T/out/prompt.md"; ok $? "блок статуса (двухусловный выход) в промпте"
  grep -q "^---$" "$T/out/prompt.md" && ok 1 "frontmatter приёмов вырезан" || ok 0 ""
  [ -n "$(jq -r .patterns_sha "$T/c.json")" ]; ok $? "patterns_sha проштампован в контракт"
  # тесный бюджет: обязательные всё равно внутри
  REDLOOP_PROMPT_BUDGET=100 compile "$T/c.json" "$T/out2" | jq -e '.patterns | index("P-NOASK")' >/dev/null
  ok $? "при тесном бюджете обязательные приёмы не режутся"
  rm -rf "$T"
  [ "$fail" -eq 0 ] && { echo "✓ compile self-test passed"; return 0; } || { echo "✗ compile self-test FAILED"; return 1; }
}
case "${1:-}" in --self-test) self_test ;; "") echo "usage: compile.sh <contract.json> <out_dir> [--profile P] | --self-test" >&2; exit 1;; *) compile "$@" ;; esac

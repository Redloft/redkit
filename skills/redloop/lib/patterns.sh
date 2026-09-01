#!/usr/bin/env bash
# patterns.sh — библиотека приёмов + обучающий контур (DESIGN v2 §S6).
# РАСЩЕПЛЕНИЕ (panel critical #3): ТЕКСТ приёма — в git (patterns/*.md, под review-гейтом),
# СЧЁТЧИКИ — вне git (stats/, .gitignore, local-only, append-only).
# Промоция механическая (#4): COUNT(DISTINCT independence_key) >= 2 + ревью текста человеком.
#
# Usage:
#   patterns.sh list                                  → активные приёмы + success_rate
#   patterns.sh record <pattern_id> <run_id> <ok|fail> <project> <task_type> <session_id>
#   patterns.sh candidate <slug> <run_id> <project> <task_type> <session_id> <text>
#   patterns.sh promotable                            → кандидаты с ≥2 независимыми подтверждениями
#   patterns.sh demote-scan                           → приёмы с success_rate<50% на последних 5
#   patterns.sh sha                                   → sha снапшота ТЕКСТОВ приёмов
#   patterns.sh --self-test
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
PDIR="${REDLOOP_PATTERNS_DIR:-$ROOT/patterns}"; STATS="${REDLOOP_STATS_DIR:-$ROOT/stats}"
USES="$STATS/pattern-uses.jsonl"; CAND="$STATS/candidates.jsonl"
MIN_INDEP="${REDLOOP_PROMOTE_MIN:-2}"; DEMOTE_WINDOW="${REDLOOP_DEMOTE_WINDOW:-5}"; COLD_START_RATE="0.5"

_ikey() { printf '%s|%s|%s|%s' "$1" "$2" "$(date -u +%Y-%m-%d)" "$3" | shasum | cut -c1-12; }

sha() { cat "$PDIR"/*.md 2>/dev/null | shasum | cut -c1-12; }

rate() { # success_rate приёма; нет данных → cold-start 0.5 (иначе новый приём не попадёт в промпт)
  local id="$1"; [ -f "$USES" ] || { echo "$COLD_START_RATE"; return; }
  # ⚠ grep -c при нуле совпадений ПЕЧАТАЕТ 0 и возвращает 1: `|| echo 0` дописывал второй ноль,
  # получалось "0\n0" → арифметика и --argjson ломались. Ветку берём отдельно от вывода.
  local tot ok; tot="$(grep -c "\"pattern_id\":\"$id\"" "$USES" 2>/dev/null)" || tot=0
  tot="$(printf '%s' "$tot" | head -1 | tr -dc '0-9')"; tot="${tot:-0}"
  [ "$tot" -eq 0 ] && { echo "$COLD_START_RATE"; return; }
  ok="$(jq -s --arg id "$id" '[.[] | select(.pattern_id==$id and .outcome=="ok")] | length' "$USES")"
  awk -v a="$ok" -v b="$tot" 'BEGIN{printf "%.2f", a/b}'
}

list() {
  local f id mand
  local tok
  for f in "$PDIR"/*.md; do [ -f "$f" ] || continue
    id="$(sed -n 's/^id: *//p' "$f" | head -1)"; mand="$(sed -n 's/^mandatory: *//p' "$f" | head -1)"
    # без явного дефолта пустая строка ломала --argjson, и приём МОЛЧА выпадал из библиотеки
    tok="$(sed -n 's/^tokens: *//p' "$f" | head -1)"; tok="${tok:-150}"
    jq -nc --arg id "$id" --arg file "$f" --arg mand "${mand:-false}" \
      --arg applies "$(sed -n 's/^applies: *//p' "$f" | head -1)" \
      --argjson tokens "$tok" \
      --argjson rate "$(rate "$id")" \
      '{id:$id,file:$file,mandatory:($mand=="true"),applies:$applies,tokens:$tokens,success_rate:$rate}'
  done
}

record() { # применение приёма в прогоне → счётчик ВНЕ git
  local id="${1:?pattern_id}" run="${2:?run_id}" out="${3:?ok|fail}" proj="${4:-?}" tt="${5:-?}" sess="${6:-?}"
  mkdir -p "$STATS"
  jq -nc --arg id "$id" --arg run "$run" --arg o "$out" --arg ik "$(_ikey "$proj" "$tt" "$sess")" \
     --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     '{ts:$ts, pattern_id:$id, run_id:$run, outcome:$o, independence_key:$ik}' >> "$USES"
}

candidate() { # наблюдение-кандидат: ЖИВЁТ без TTL, ждёт второго независимого подтверждения
  local slug="${1:?slug}" run="${2:?run_id}" proj="${3:-?}" tt="${4:-?}" sess="${5:-?}"; shift 5 || true
  # слаг без текста нечего ревьюить: в прогоне 20260901-0108 такой уже записан (ab-on-real-host)
  local text="$*"   # склеиваем ДО проверки: "${*//...}" не ловит пробелы, разбитые по аргументам
  [ -n "${text//[[:space:]]/}" ] || { echo "✗ кандидат без текста не принимается: $slug" >&2; return 1; }
  mkdir -p "$STATS"
  jq -nc --arg s "$slug" --arg run "$run" --arg ik "$(_ikey "$proj" "$tt" "$sess")" \
     --arg text "$text" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     '{ts:$ts, slug:$s, run_id:$run, independence_key:$ik, text:$text}' >> "$CAND"
}

promotable() {
  [ -f "$CAND" ] || { echo '[]'; return 0; }
  jq -s --argjson min "$MIN_INDEP" '
    group_by(.slug) | map({slug: .[0].slug,
      independent: ([.[].independence_key] | unique | length),
      observations: length, sample_text: .[0].text})
    | map(select(.independent >= $min))' "$CAND"
}

demote_scan() {
  [ -f "$USES" ] || { echo '[]'; return 0; }
  jq -s --argjson w "$DEMOTE_WINDOW" '
    group_by(.pattern_id) | map(.[-$w:] |
      {pattern_id: .[0].pattern_id, window: length,
       ok: ([.[] | select(.outcome=="ok")] | length)} |
      . + {rate: (if .window>0 then (.ok/.window) else 1 end)})
    | map(select(.window >= $w and .rate < 0.5))' "$USES"
}

self_test() {
  set +e; local T; T="$(mktemp -d)"; local fail=0
  ok(){ if [ "$1" -eq 0 ]; then :; else echo "  ✗ $2"; fail=1; fi; }
  export REDLOOP_STATS_DIR="$T/stats"; STATS="$REDLOOP_STATS_DIR"; USES="$STATS/pattern-uses.jsonl"; CAND="$STATS/candidates.jsonl"
  [ "$(rate P-NEW)" = "0.5" ]; ok $? "cold-start rate=0.5 (новый приём не отсекается)"
  list | jq -e -s 'length >= 9' >/dev/null; ok $? "библиотека читается (≥9 приёмов)"
  list | jq -e -s 'any(.[]; .id=="P-UNTRUSTED" and .mandatory==true)' >/dev/null; ok $? "P-UNTRUSTED обязателен"
  # одна и та же сессия/проект/день → ОДИН independence_key: синглтон не самопромотируется
  candidate cand-a r1 proj1 code sess1 "текст" ; candidate cand-a r2 proj1 code sess1 "текст"
  [ "$(promotable | jq 'length')" = "0" ]; ok $? "два наблюдения из ОДНОГО контекста ≠ промоция"
  candidate cand-a r3 proj2 code sess9 "текст"
  [ "$(promotable | jq 'length')" = "1" ]; ok $? "два НЕЗАВИСИМЫХ → кандидат промотируем"
  local i; for i in 1 2 3 4 5; do record P-BAD "r$i" fail "p$i" code "s$i"; done
  [ "$(demote_scan | jq 'length')" = "1" ]; ok $? "success_rate<50% на окне → демоция"
  for i in 1 2 3 4 5; do record P-GOOD "r$i" ok "p$i" code "s$i"; done
  [ "$(demote_scan | jq '[.[] | select(.pattern_id=="P-GOOD")] | length')" = "0" ]; ok $? "здоровый приём не демотируется"
  [ -n "$(sha)" ]; ok $? "sha снапшота считается"
  candidate cand-empty r9 proj9 code sess9 "" >/dev/null 2>&1; ok $((1-$?)) "И5: кандидат без текста отвергнут"
  candidate cand-empty r9 proj9 code sess9 "   " >/dev/null 2>&1; ok $((1-$?)) "И5: кандидат из пробелов отвергнут"
  candidate cand-empty r9 proj9 code sess9 " " " " " " >/dev/null 2>&1; ok $((1-$?)) "И5: пробелы, разбитые по аргументам, тоже отвергнуты"
  # приём без строки tokens не должен исчезать из библиотеки
  local PD="$T/pat"; mkdir -p "$PD"; printf -- '---\nid: P-NOTOK\napplies: always\n---\nтело\n' > "$PD/P-NOTOK.md"
  [ "$(REDLOOP_PATTERNS_DIR="$PD" bash "$HERE/patterns.sh" list | jq -s 'length')" = "1" ]
  ok $? "приём без tokens не выпадает (дефолт 150)"
  rm -rf "$T"
  [ "$fail" -eq 0 ] && { echo "✓ patterns self-test passed"; return 0; } || { echo "✗ patterns self-test FAILED"; return 1; }
}
case "${1:-}" in
  list) list ;; sha) sha ;; promotable) promotable ;; demote-scan) demote_scan ;;
  record) shift; record "$@" ;; candidate) shift; candidate "$@" ;;
  --self-test) self_test ;;
  *) echo "usage: patterns.sh list|sha|promotable|demote-scan|record|candidate|--self-test" >&2; exit 1 ;;
esac

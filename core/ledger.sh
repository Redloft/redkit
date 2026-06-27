#!/usr/bin/env bash
# ledger.sh — append-only learnings ledger для петли самоулучшения red*-скиллов.
# Каждый прогон panel/finalize/red* авто-пишет сюда ОДНУ строку (push, не pull):
# вердикт + gaps + methodology_findings от meta-критика. Это источник для scheduled-solidify.
# Шарится между скиллами (finalize и др. симлинкают на plan-panel/lib, как checkpoint.sh/strip-secrets.sh).
#
# Зачем: judge каждый прогон производит сигнал (gaps/conflicts/reasoning), но раньше он оседал
# в throwaway run-dir и выбрасывался. Теперь meta-критик внутри workflow классифицирует находки на
# «дефект этого плана/кода» vs «дыра в чек-листе роли», а ledger.sh копит второе для solidify.
#
# Usage:
#   ledger.sh append  <skill_root> <json_line>   # +1 запись (валидируется + strip-secrets)
#   ledger.sh cluster <skill_root>               # агрегировать methodology-gap темы (для solidify)
#   ledger.sh stat    <skill_root>               # краткая статистика ledger'а
#   ledger.sh --self-test
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
STRIP="$HERE/strip-secrets.sh"
# fallback: ledger могут звать из любого скилла (по skill_root-аргументу); strip живёт в plan-panel/lib
[ -f "$STRIP" ] || STRIP="$HOME/.claude/skills/plan-panel/lib/strip-secrets.sh"

_ledger_path() { echo "$1/feedback/learnings.jsonl"; }

append() {
  local root="${1:?skill_root}"; local line="${2:?json_line}"
  printf '%s' "$line" | jq -e . >/dev/null 2>&1 || { echo "✗ ledger: невалидный JSON" >&2; return 1; }
  # strip-secrets (defense-in-depth: observations строятся по уже-stripped diff, но не доверяем)
  local clean
  clean="$(printf '%s' "$line" | "$STRIP" 2>/dev/null)" || { echo "✗ ledger: strip failed → 0 байт на диск" >&2; return 1; }
  [ -n "$clean" ] || { echo "✗ ledger: strip дал пусто → не пишем (zero-byte guard)" >&2; return 1; }
  local compact; compact="$(printf '%s' "$clean" | jq -c .)" || { echo "✗ ledger: compact failed" >&2; return 1; }
  [ -n "$compact" ] || { echo "✗ ledger: compact пуст → не пишем" >&2; return 1; }
  local L; L="$(_ledger_path "$root")"; mkdir -p "$(dirname "$L")"
  # mkdir-lock (portable, macOS без flock): сериализация parallel-ultra append на Yandex.Disk
  local LOCK="$L.lock" i
  for i in $(seq 1 50); do mkdir "$LOCK" 2>/dev/null && break; sleep 0.05; done
  printf '%s\n' "$compact" >> "$L"
  # retention cap: ограничить рост append-only (cluster читает весь файл через jq -s)
  local CAP="${PLAN_PANEL_LEDGER_CAP:-1000}"
  if [ "$(wc -l < "$L" | tr -d ' ')" -gt "$CAP" ]; then tail -n "$CAP" "$L" > "$L.tmp" && mv -f "$L.tmp" "$L"; fi
  rmdir "$LOCK" 2>/dev/null || true
  echo "✓ ledger += 1 ($L; всего $(wc -l < "$L" | tr -d ' '))"
}

# Кластеризовать methodology_findings по (role + lens_key): что РЕГУЛЯРНО всплывает.
# lens_key — стабильный слаг линзы от meta-критика (язык/регистр не важны); fallback — нормализованный текст.
# Это вход для solidify: тема с count≥порог → кандидат на правку role-промпта.
cluster() {
  local root="${1:?skill_root}"; local L; L="$(_ledger_path "$root")"
  [ -f "$L" ] || { echo "[]"; return 0; }
  jq -s '
    [.[].methodology_findings[]?]
    | map(. + {_key: ((.role // "") + "||" + ((.lens_key // (.proposed_checklist_delta // .observation // "")) | ascii_downcase | .[0:80]))})
    | group_by(._key)
    | map({
        role: .[0].role,
        lens_key: (.[0].lens_key // null),
        theme: (.[0].proposed_checklist_delta // .[0].observation),
        count: length,
        severity: ([.[].severity] | map(. // "suggestion") | (if any(. == "critical") then "critical" elif any(. == "warning") then "warning" else "suggestion" end)),
        examples: ([.[].observation] | map(select(. != null)) | unique | .[0:3])
      })
    | sort_by(-.count)
  ' "$L"
}

stat() {
  local root="${1:?skill_root}"; local L; L="$(_ledger_path "$root")"
  [ -f "$L" ] || { echo "ledger пуст (нет $L)"; return 0; }
  local n; n="$(wc -l < "$L" | tr -d ' ')"
  local mf; mf="$(jq -s '[.[].methodology_findings[]?] | length' "$L")"
  echo "ledger: $n прогонов, $mf methodology-находок"
  echo "вердикты: $(jq -rs 'group_by(.verdict)|map("\(.[0].verdict):\(length)")|join(", ")' "$L")"
}

self_test() {
  set +e  # self-test использует паттерн «[ cond ]; ok $?» — несовместим с set -e
  local T; T="$(mktemp -d)"
  local fail=0
  ok() { if [ "$1" -eq 0 ]; then :; else echo "  ✗ $2"; fail=1; fi; }
  # 1. append валидных записей (один lens_key → должны слиться при кластеризации)
  append "$T" '{"ts":"t1","skill":"x","run_id":"r1","verdict":"NEEDS-WORK","methodology_findings":[{"role":"qa","severity":"warning","lens_key":"success-signal-integrity","observation":"нет проверки success-signal","proposed_checklist_delta":"success меряет результат, не прокси"}]}' >/dev/null
  ok $? "append #1"
  append "$T" '{"ts":"t2","skill":"x","run_id":"r2","verdict":"SHIP","methodology_findings":[{"role":"qa","severity":"warning","lens_key":"success-signal-integrity","observation":"опять прокси-success","proposed_checklist_delta":"Success меряет РЕЗУЛЬТАТ, не прокси!"}]}' >/dev/null
  ok $? "append #2"
  [ "$(wc -l < "$T/feedback/learnings.jsonl" | tr -d ' ')" = "2" ]; ok $? "2 строки в ledger"
  # 2. невалидный JSON отклоняется
  append "$T" 'not-json' >/dev/null 2>&1; [ $? -ne 0 ]; ok $? "невалидный JSON отклонён"
  # 3. cluster сливает один lens_key в один кластер с count=2 (язык/регистр не важны)
  local c; c="$(cluster "$T")"
  [ "$(printf '%s' "$c" | jq 'length')" = "1" ]; ok $? "cluster: один lens_key → 1 кластер"
  [ "$(printf '%s' "$c" | jq '.[0].count')" = "2" ]; ok $? "cluster: count=2"
  [ "$(printf '%s' "$c" | jq -r '.[0].lens_key')" = "success-signal-integrity" ]; ok $? "cluster: lens_key сохранён"
  rm -rf "$T"
  if [ "$fail" -eq 0 ]; then echo "✓ ledger self-test passed (append/reject/cluster)"; return 0; else echo "✗ ledger self-test FAILED"; return 1; fi
}

case "${1:-}" in
  append)  append "${2:-}" "${3:-}" ;;
  cluster) cluster "${2:-}" ;;
  stat)    stat "${2:-}" ;;
  --self-test) self_test ;;
  *) echo "usage: ledger.sh append|cluster|stat <skill_root> | --self-test" >&2; exit 1 ;;
esac

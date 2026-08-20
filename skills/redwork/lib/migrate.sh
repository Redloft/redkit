#!/usr/bin/env bash
# migrate.sh — forward-миграция state.json v1→v2 (panel critical #1: живые данные, второй попытки нет).
#
# v2 добавляет: updated_at (heartbeat-поле, на нём стоит sweep) и enum phase_status pending|done|blocked|abandoned.
# Инварианты: ИДЕМПОТЕНТНА (v2 пропускается), по умолчанию DRY-RUN, --apply делает бэкап каждого файла
# рядом (state.json.v1.bak) и валидирует результат перед mv. Ничего, кроме schema_version/updated_at, не трогает.
#
# Usage:
#   migrate.sh scan   [--data-root DIR]            # что будет сделано (по умолчанию — без записи)
#   migrate.sh apply  [--data-root DIR]            # выполнить
#   migrate.sh --self-test
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

_root() { echo "${REDWORK_DATA_DIR:-$HOME/Library/Application Support/redwork/runs}"; }

# updated_at выводим максимально честно: последнее событие (реальная активность) > mtime state.json > created_at.
_derive_updated() {
  local d="$1" created="$2" last=""
  if [ -f "$d/events.jsonl" ] && [ -s "$d/events.jsonl" ]; then
    last="$(tail -1 "$d/events.jsonl" | jq -r '.ts // empty' 2>/dev/null || true)"
  fi
  [ -n "$last" ] && { echo "$last"; return; }
  echo "$created"
}

run() {
  local mode="$1" root; root="$(_root)"; shift || true
  [ -d "$root" ] || { echo "нет $root"; return 0; }
  local n_mig=0 n_skip=0 d
  for d in "$root"/*/; do
    d="${d%/}"; local S="$d/state.json"
    [ -f "$S" ] || continue
    local sv; sv="$(jq -r '.schema_version // 0' "$S" 2>/dev/null || echo x)"
    if [ "$sv" = "2" ]; then n_skip=$((n_skip+1)); continue; fi          # идемпотентность
    if [ "$sv" != "1" ]; then echo "⚠ пропуск (schema_version=$sv, не 1): $d"; n_skip=$((n_skip+1)); continue; fi
    if [ -d "$d/.lock" ]; then
      local lat; lat="$(cat "$d/.lock/at" 2>/dev/null || echo 0)"
      # Порог «ран ещё жив» обязан совпадать с тем, по которому живость определяет
      # state.sh cmd_lock (REDWORK_LOCK_TTL_SEC, дефолт 43200с ≈ 12ч по эмпирике 6.9ч).
      # Своя константа 3600 означала: ран в законной ночной паузе получал миграцию
      # schema_version прямо посреди работы. Найдено панелью 2026-08-20.
      if [ $(( $(date +%s) - ${lat:-0} )) -lt "${REDWORK_LOCK_TTL_SEC:-43200}" ]; then
        echo "⚠ пропуск (активен, свежий lock): $d"; n_skip=$((n_skip+1)); continue
      fi
    fi
    local created upd
    created="$(jq -r '.created_at // ""' "$S")"
    upd="$(_derive_updated "$d" "$created")"
    if [ "$mode" = "scan" ]; then
      echo "MIGRATE $(basename "$d"): v1→v2, updated_at=$upd  (phase=$(jq -r .phase "$S"), status=$(jq -r .phase_status "$S"))"
      n_mig=$((n_mig+1)); continue
    fi
    # -n: не перезаписывать существующий бэкап. Иначе частично прошедший первый apply + второй прогон
    # затирают единственную копию v1 уже мигрированной версией.
    if [ -f "$S.v1.bak" ]; then echo "  (бэкап v1 уже есть — сохраняю оригинальный)"
    else cp -p "$S" "$S.v1.bak" || { echo "✗ бэкап не сделан → пропуск $d" >&2; continue; }; fi
    local tmp; tmp="$(mktemp "${S}.XXXXXX")"
    jq --arg u "$upd" '.schema_version = 2 | .updated_at = (.updated_at // $u)' "$S" > "$tmp" || { rm -f "$tmp"; echo "✗ jq $d" >&2; continue; }
    # валидация ДО подмены: объект, ключи на месте, ничего кроме двух полей не изменилось
    jq -e 'type=="object" and .schema_version==2 and has("slug") and has("updated_at")' "$tmp" >/dev/null 2>&1 \
      || { rm -f "$tmp"; echo "✗ результат невалиден → $d не тронут" >&2; continue; }
    local diff_keys
    diff_keys="$(jq -s '(.[0]|del(.schema_version,.updated_at)) == (.[1]|del(.schema_version,.updated_at))' "$S" "$tmp")"
    [ "$diff_keys" = "true" ] || { rm -f "$tmp"; echo "✗ миграция изменила лишнее → $d не тронут" >&2; continue; }
    mv -f "$tmp" "$S"; n_mig=$((n_mig+1)); echo "✓ $(basename "$d") → v2"
  done
  echo "migrate[$mode]: $n_mig, пропущено $n_skip"
}

self_test() {
  set +e; local T; T="$(mktemp -d)"; export REDWORK_DATA_DIR="$T"; local fail=0
  ok(){ if [ "$1" -eq 0 ]; then :; else echo "  ✗ $2"; fail=1; fi; }
  mkdir -p "$T/r1"
  jq -n '{schema_version:1,slug:"r1",task:"t",repo:"/r",mode:2,phase:"P2_implement",phase_status:"pending",
          verdicts:{plan:null},blocked_on:null,iterations:0,budget:{llm_calls:0},created_at:"2026-06-01T00:00:00Z"}' > "$T/r1/state.json"
  printf '%s\n' '{"ts":"2026-06-02T10:00:00Z","event_type":"gate_result"}' > "$T/r1/events.jsonl"

  run scan >/dev/null; ok $? "scan"
  [ "$(jq -r '.schema_version' "$T/r1/state.json")" = "1" ]; ok $? "scan НИЧЕГО не пишет (dry по умолчанию)"
  run apply >/dev/null; ok $? "apply"
  [ "$(jq -r '.schema_version' "$T/r1/state.json")" = "2" ]; ok $? "schema_version=2"
  [ "$(jq -r '.updated_at' "$T/r1/state.json")" = "2026-06-02T10:00:00Z" ]; ok $? "updated_at из последнего события (реальная активность)"
  [ -f "$T/r1/state.json.v1.bak" ]; ok $? "бэкап .v1.bak рядом"
  [ "$(jq -r '.task' "$T/r1/state.json")" = "t" ]; ok $? "остальные поля не тронуты"
  # идемпотентность
  local before; before="$(cat "$T/r1/state.json")"
  run apply >/dev/null; [ "$(cat "$T/r1/state.json")" = "$before" ]; ok $? "повторный apply идемпотентен"
  # прогон БЕЗ events → updated_at = created_at
  mkdir -p "$T/r2"; jq -n '{schema_version:1,slug:"r2",created_at:"2026-06-05T00:00:00Z",phase:"P2",phase_status:"pending"}' > "$T/r2/state.json"
  run apply >/dev/null; [ "$(jq -r '.updated_at' "$T/r2/state.json")" = "2026-06-05T00:00:00Z" ]; ok $? "без events → updated_at=created_at"
  rm -rf "$T"
  if [ "$fail" -eq 0 ]; then echo "✓ migrate self-test passed"; return 0; else echo "✗ migrate self-test FAILED"; return 1; fi
}

case "${1:-scan}" in
  scan)  shift || true; while [ $# -gt 0 ]; do case "$1" in --data-root) export REDWORK_DATA_DIR="$2"; shift 2;; *) shift;; esac; done; run scan ;;
  apply) shift || true; while [ $# -gt 0 ]; do case "$1" in --data-root) export REDWORK_DATA_DIR="$2"; shift 2;; *) shift;; esac; done; run apply ;;
  --self-test) self_test ;;
  *) echo "usage: migrate.sh scan|apply [--data-root DIR] | --self-test" >&2; exit 1 ;;
esac

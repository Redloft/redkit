#!/usr/bin/env bash
# wal.sh — Write-Ahead-Log round commit + recovery (plan D1, judge#1).
#
# THE invariant: status.last_committed_round is the single source of truth.
# A round's cards + feedback are written together to a pending file, then
# committed atomically (rename pending→committed) BEFORE the derivatives
# (captures.jsonl / feedback.jsonl / captures-index.json) are updated. The
# derivatives are LAZY-recoverable from phases/round-*.committed.jsonl, so a
# crash at any point converges on resume — no orphan cards, no dup on resume.
#
# Pending line format (one JSON object per line):
#   line 1   {"_wal":"meta","round":N,"stage":"served|answered","nonce":"..."}
#   cards    {"_wal":"card","data":{...card...}}
#   answers  {"_wal":"answer","data":{...feedback...}}
#
# Usage (source it):
#   source lib/wal.sh   # also sources atomic-append.sh + heartbeat.sh
#   wal_begin   <run_dir> <round> <nonce>
#   wal_card    <run_dir> <round> <card_json>
#   wal_answer  <run_dir> <round> <answer_json>
#   wal_commit  <run_dir> <round>          # → derivatives + set_committed_round
#   wal_rollback<run_dir> <round>          # drop orphan pending
#   wal_recover <run_dir>                  # on start: rollback orphans + rebuild if needed
#   wal_rebuild_index <run_dir>            # derivatives ← committed files

# self-dir, portable across bash (BASH_SOURCE) and zsh (sourced $0)
_WAL_HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=/dev/null
source "$_WAL_HERE/atomic-append.sh"
# shellcheck source=/dev/null
source "$_WAL_HERE/heartbeat.sh"

_wal_pending() { printf '%s/phases/round-%s.pending.jsonl' "$1" "$2"; }
_wal_committed() { printf '%s/phases/round-%s.committed.jsonl' "$1" "$2"; }

wal_begin() {
  local run_dir="$1" round="$2" nonce="$3"
  local p; p=$(_wal_pending "$run_dir" "$round")
  [ -f "$p" ] && { echo "wal_begin: pending already exists for round $round" >&2; return 1; }
  local meta; meta=$(jq -nc --argjson r "$round" --arg n "$nonce" '{_wal:"meta",round:$r,stage:"served",nonce:$n}')
  atomic_append "$p" "$meta"
}

wal_card() {
  local run_dir="$1" round="$2" card="$3"
  local p; p=$(_wal_pending "$run_dir" "$round")
  atomic_append "$p" "$(jq -nc --argjson d "$card" '{_wal:"card",data:$d}')"
}

wal_answer() {
  local run_dir="$1" round="$2" ans="$3"
  local p; p=$(_wal_pending "$run_dir" "$round")
  atomic_append "$p" "$(jq -nc --argjson d "$ans" '{_wal:"answer",data:$d}')"
}

# Commit: rename pending→committed (atomic transaction boundary), THEN derive.
wal_commit() {
  local run_dir="$1" round="$2"
  local p c; p=$(_wal_pending "$run_dir" "$round"); c=$(_wal_committed "$run_dir" "$round")
  [ -f "$p" ] || { echo "wal_commit: no pending for round $round" >&2; return 1; }
  mv -f "$p" "$c"                              # ← transaction boundary (atomic)
  _wal_apply_committed "$run_dir" "$c"         # derive captures/feedback/index
  set_committed_round "$run_dir" "$round"      # advance the anchor (under status-lock)
}

# Rollback: remove an orphan pending (uncommitted round). Derivatives untouched
# (they only ever reflect committed rounds), so nothing else to clean.
wal_rollback() {
  local run_dir="$1" round="$2"
  rm -f "$(_wal_pending "$run_dir" "$round")" 2>/dev/null || true
}

# Apply one committed round-file to the derivatives (idempotent per card via index).
_wal_apply_committed() {
  local run_dir="$1" cfile="$2"
  local cap="$run_dir/captures/captures.jsonl"
  local fb="$run_dir/captures/feedback.jsonl"
  local idx="$run_dir/captures/captures-index.json"
  [ -f "$idx" ] || echo '{}' > "$idx"
  local lock="$_WAL_HERE/with-lock.sh"
  # cards → captures.jsonl + index (dedup by source|ref_url, under lock)
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    local kind data key
    kind=$(printf '%s' "$line" | jq -r '._wal // empty' 2>/dev/null)
    case "$kind" in
      card)
        data=$(printf '%s' "$line" | jq -c '.data')
        key=$(printf '%s' "$data" | jq -r '"\(.source)|\(.ref_url)"')
        # dedup + append under index-lock
        bash "$lock" "$idx" -- bash -c '
          idx="$1"; key="$2"; data="$3"; cap="$4"
          if jq -e --arg k "$key" "has(\$k)" "$idx" >/dev/null 2>&1; then exit 0; fi
          jq --arg k "$key" ". + {(\$k): true}" "$idx" > "$idx.t.$$" && mv -f "$idx.t.$$" "$idx"
          printf "%s\n" "$data" >> "$cap"
        ' _ "$idx" "$key" "$data" "$cap" || true
        ;;
      answer)
        data=$(printf '%s' "$line" | jq -c '.data')
        printf '%s\n' "$data" >> "$fb"
        ;;
    esac
  done < "$cfile"
}

# Recovery on start (plan D1): drop orphan pendings; if committed rounds exceed
# the anchor OR derivatives are inconsistent → rebuild derivatives from committed.
wal_recover() {
  local run_dir="$1"
  local lcr; lcr=$(read_status "$run_dir" last_committed_round); lcr=${lcr:-0}
  local orphans=0 maxc=0
  shopt -s nullglob 2>/dev/null || true
  for p in "$run_dir"/phases/round-*.pending.jsonl; do
    [ -e "$p" ] || continue
    orphans=$((orphans+1)); rm -f "$p"
  done
  for c in "$run_dir"/phases/round-*.committed.jsonl; do
    [ -e "$c" ] || continue
    local n; n=$(basename "$c" | sed -E 's/round-([0-9]+)\.committed\.jsonl/\1/')
    [ "$n" -gt "$maxc" ] && maxc="$n"
  done
  [ "$orphans" -gt 0 ] && echo "WAL_ROLLBACK orphans=$orphans" >&2
  # committed beyond the recorded anchor → derivatives lag → rebuild
  if [ "$maxc" -gt "$lcr" ]; then
    echo "INDEX_REBUILT reason=committed_gt_anchor committed=$maxc anchor=$lcr" >&2
    wal_rebuild_index "$run_dir"
    set_committed_round "$run_dir" "$maxc"
    return 0
  fi
  # line-count sanity: captures.jsonl must equal Σ cards across committed
  local cap="$run_dir/captures/captures.jsonl" want have
  want=$(cat "$run_dir"/phases/round-*.committed.jsonl 2>/dev/null | jq -r 'select(._wal=="card")|1' 2>/dev/null | wc -l | tr -d ' ')
  have=$( [ -f "$cap" ] && wc -l < "$cap" | tr -d ' ' || echo 0 )
  if [ "${want:-0}" != "${have:-0}" ]; then
    echo "INDEX_REBUILT reason=linecount want=$want have=$have" >&2
    wal_rebuild_index "$run_dir"
  fi
}

# Rebuild captures.jsonl / feedback.jsonl / captures-index.json from committed files.
wal_rebuild_index() {
  local run_dir="$1"
  local cap="$run_dir/captures/captures.jsonl"
  local fb="$run_dir/captures/feedback.jsonl"
  local idx="$run_dir/captures/captures-index.json"
  : > "$cap"; : > "$fb"; echo '{}' > "$idx"
  # iterate committed rounds in numeric order
  local files; files=$(ls -1 "$run_dir"/phases/round-*.committed.jsonl 2>/dev/null \
    | sed -E 's/.*round-([0-9]+)\.committed.*/\1 &/' | sort -n | cut -d' ' -f2-)
  local c
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    _wal_apply_committed "$run_dir" "$c"
  done <<< "$files"
}

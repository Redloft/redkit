#!/usr/bin/env bash
# checkpoint.sh — единая state-machine redplan (DESIGN-foundation §2).
# checkpoint.json = SINGLE source of truth: статус run'а, фаза, iteration, scope_cache
# И lock-состояние (lock_pid/lock_at) — НЕ отдельные .lock-файлы (§2.0).
#
# Все мутации атомарны: write→tmp→(fsync)→mv -f (§2.2). Lock — mkdir-страж (атомарен на POSIX).
#
# Команды:
#   slug <text>                                  → sha1(normalize)[:12]
#   init <project_dir> <run_type> <slug>         → начальный checkpoint.json (status in-progress)
#   read <project_dir>                           → checkpoint.json в stdout (+ schema-version policy)
#   set  <project_dir> <jq_filter>               → атомарно применить jq-патч к checkpoint
#   acquire <project_dir> [ttl_sec]              → захватить project-lock (mkdir-страж + stale reclaim)
#   release <project_dir>                        → снять lock
#   gc   <root_dir>                              → удалить просроченные run-папки (expires_at < now)
#   --self-test                                  → прогон инвариантов, exit 0/1
set -euo pipefail

SCHEMA_VERSION=1      # текущая версия формата
KNOWN_MAX=1           # максимально известная (читаем что ≤ этого)
DEFAULT_TTL=1800      # 30 мин
LOCK_DIRNAME=".run.d" # mkdir-страж project-level lock

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
plus_90d_iso() { date -u -v+90d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "+90 days" +%Y-%m-%dT%H:%M:%SZ; }

# slug = sha1(normalize(text))[:12]; normalize = trim + collapse-ws + lowercase
cp_slug() {
  local raw="$1"
  printf '%s' "$raw" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -s '[:space:]' ' ' \
    | sed -E 's/^ +| +$//g' \
    | shasum -a 1 | cut -c1-12
}

# Атомарная запись stdin → файл (tmp в той же директории + mv -f)
_atomic_write() {
  local target="$1" tmp
  tmp="$(dirname "$target")/.$(basename "$target").tmp.$$"
  cat > "$tmp"
  sync "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$target"
}

cp_init() {
  local dir="$1" run_type="$2" slug="$3" ts; ts="$(now_iso)"
  mkdir -p "$dir"
  jq -n \
    --argjson sv "$SCHEMA_VERSION" \
    --arg rt "$run_type" --arg slug "$slug" \
    --arg ts "$ts" --arg exp "$(plus_90d_iso)" \
    '{schema_version:$sv, run_type:$rt, status:"in-progress", phase:null,
      iteration:0, slug:$slug, lock_pid:null, lock_at:null, lock_ttl_sec:null,
      scope_cache:null, created_at:$ts, updated_at:$ts, expires_at:$exp}' \
    | _atomic_write "$dir/checkpoint.json"
}

cp_read() {
  local dir="$1"; local f="$dir/checkpoint.json" v
  [ -f "$f" ] || { echo "✗ no checkpoint at $f" >&2; return 1; }
  v="$(jq -r '.schema_version' "$f")"
  # schema_version read-side policy (§2.2b, v3-critical#5)
  if [ "$v" -gt "$KNOWN_MAX" ]; then
    echo "✗ checkpoint schema_version $v > KNOWN_MAX $KNOWN_MAX — written by newer skill, abort" >&2; return 2
  fi
  if [ "$v" -lt "$SCHEMA_VERSION" ]; then
    # Stage 0 policy: всегда reject (миграционный фреймворк вводим только при первой реальной смене схемы)
    echo "✗ checkpoint schema_version $v < current $SCHEMA_VERSION — reject (run backfill-scan)" >&2; return 3
  fi
  cat "$f"
}

cp_set() {
  local dir="$1" filter="$2"; local f="$dir/checkpoint.json" ts; ts="$(now_iso)"
  jq --arg ts "$ts" "($filter) | .updated_at = \$ts" "$f" | _atomic_write "$f"
}

# project-level lock через mkdir-страж + stale reclaim (§2.2, §2.5)
cp_acquire() {
  local dir="$1" ttl="${2:-$DEFAULT_TTL}" lockdir="$1/$LOCK_DIRNAME"
  mkdir -p "$dir"
  if mkdir "$lockdir" 2>/dev/null; then
    _write_lock "$dir" "$ttl"; return 0
  fi
  # занято — проверить не stale ли (pid мёртв ИЛИ ttl истёк)
  local meta="$lockdir/meta.json" lpid lat lttl age dead=0 expired=0
  if [ -f "$meta" ]; then
    lpid="$(jq -r '.lock_pid // empty' "$meta" 2>/dev/null || true)"
    lat="$(jq -r '.lock_at // empty' "$meta" 2>/dev/null || true)"
    lttl="$(jq -r '.lock_ttl_sec // 0' "$meta" 2>/dev/null || echo 0)"
    [ -n "$lpid" ] && ! kill -0 "$lpid" 2>/dev/null && dead=1
    if [ -n "$lat" ]; then
      local start nows
      start="$(date -u -j -f %Y-%m-%dT%H:%M:%SZ "$lat" +%s 2>/dev/null || date -u -d "$lat" +%s 2>/dev/null || echo 0)"
      nows="$(date -u +%s)"; age=$(( nows - start ))
      [ "$lttl" -gt 0 ] && [ "$age" -gt "$lttl" ] && expired=1
    fi
  else
    dead=1  # страж без меты — оставлен крэшем
  fi
  if [ "$dead" -eq 1 ] || [ "$expired" -eq 1 ]; then
    rm -rf "$lockdir"
    if mkdir "$lockdir" 2>/dev/null; then _write_lock "$dir" "$ttl"; return 0; fi
  fi
  echo "✗ lock held by pid ${lpid:-?} (not stale)" >&2; return 1
}

_write_lock() {
  local dir="$1" ttl="$2" ts; ts="$(now_iso)"
  jq -n --argjson pid "$$" --arg at "$ts" --argjson ttl "$ttl" \
    '{lock_pid:$pid, lock_at:$at, lock_ttl_sec:$ttl}' > "$dir/$LOCK_DIRNAME/meta.json"
  # отразить lock и в checkpoint (single source of truth), если он есть
  [ -f "$dir/checkpoint.json" ] && cp_set "$dir" ".lock_pid=$$ | .lock_at=\"$ts\" | .lock_ttl_sec=$ttl"
}

cp_release() {
  local dir="$1"
  rm -rf "$dir/$LOCK_DIRNAME"
  [ -f "$dir/checkpoint.json" ] && cp_set "$dir" '.lock_pid=null | .lock_at=null | .lock_ttl_sec=null' || true
}

cp_gc() {
  local root="$1" nows; nows="$(date -u +%s)"
  [ -d "$root" ] || return 0
  local d exp exps
  for d in "$root"/*/; do
    [ -f "$d/checkpoint.json" ] || continue
    exp="$(jq -r '.expires_at // empty' "$d/checkpoint.json" 2>/dev/null || true)"
    [ -n "$exp" ] || continue
    exps="$(date -u -j -f %Y-%m-%dT%H:%M:%SZ "$exp" +%s 2>/dev/null || date -u -d "$exp" +%s 2>/dev/null || echo 0)"
    if [ "$exps" -gt 0 ] && [ "$nows" -gt "$exps" ]; then echo "gc: $d"; rm -rf "$d"; fi
  done
}

# ---------------- self-test ----------------
self_test() {
  local T fail=0; T="$(mktemp -d)"; trap 'rm -rf "$T"' RETURN
  local rdir="$T/run"

  # 1. slug стабилен + normalize
  local s1 s2 s3
  s1="$(cp_slug 'Fix the Auth bug')"; s2="$(cp_slug '  fix   the AUTH bug  ')"; s3="$(cp_slug 'other task')"
  [ "$s1" = "$s2" ] || { echo "✗ slug not stable under normalize ($s1 != $s2)"; fail=1; }
  [ "$s1" != "$s3" ] || { echo "✗ slug collision on distinct text"; fail=1; }
  [ "${#s1}" -eq 12 ] || { echo "✗ slug length != 12 (${#s1})"; fail=1; }

  # 2. init + read roundtrip
  cp_init "$rdir" "from-task" "$s1"
  cp_read "$rdir" >/dev/null || { echo "✗ read after init failed"; fail=1; }
  [ "$(jq -r .status "$rdir/checkpoint.json")" = "in-progress" ] || { echo "✗ initial status"; fail=1; }

  # 3. set атомарно меняет поле + updated_at
  cp_set "$rdir" '.phase="draft" | .iteration=1'
  [ "$(jq -r .phase "$rdir/checkpoint.json")" = "draft" ] || { echo "✗ set phase"; fail=1; }
  [ "$(jq -r .iteration "$rdir/checkpoint.json")" = "1" ] || { echo "✗ set iteration"; fail=1; }

  # 4. crash-recovery: оставить мусорный .tmp → read берёт последний хороший checkpoint
  echo '{garbage' > "$rdir/.checkpoint.json.tmp.999"
  cp_read "$rdir" >/dev/null || { echo "✗ read broke on stray tmp"; fail=1; }
  rm -f "$rdir/.checkpoint.json.tmp.999"

  # 5. resume-match: записанный state == прочитанный
  local before after
  cp_set "$rdir" '.scope_cache={output:"x",files_hash:"abc",head_sha:"def"}'
  before="$(jq -cS '{phase,iteration,scope_cache}' "$rdir/checkpoint.json")"
  after="$(cp_read "$rdir" | jq -cS '{phase,iteration,scope_cache}')"
  [ "$before" = "$after" ] || { echo "✗ resume-match mismatch"; fail=1; }

  # 6. acquire race: 2 параллельных → ровно 1 успех
  local a b
  ( cp_acquire "$rdir" 60 >/dev/null 2>&1 ) & a=$!
  ( cp_acquire "$rdir" 60 >/dev/null 2>&1 ) & b=$!
  local ra=0 rb=0; wait $a || ra=1; wait $b || rb=1
  if [ $(( (1-ra) + (1-rb) )) -ne 1 ]; then echo "✗ acquire race: expected exactly 1 winner (ra=$ra rb=$rb)"; fail=1; fi

  # 7. stale reclaim: подделать lock с мёртвым pid → acquire переотбирает
  rm -rf "$rdir/$LOCK_DIRNAME"; mkdir -p "$rdir/$LOCK_DIRNAME"
  echo '{"lock_pid":999999,"lock_at":"2000-01-01T00:00:00Z","lock_ttl_sec":1}' > "$rdir/$LOCK_DIRNAME/meta.json"
  cp_acquire "$rdir" 60 >/dev/null 2>&1 || { echo "✗ stale reclaim failed"; fail=1; }
  cp_release "$rdir"

  # 8. schema_version policy: >MAX abort(2), <current reject(3)
  local rc
  jq '.schema_version=99' "$rdir/checkpoint.json" | _atomic_write "$rdir/checkpoint.json"
  cp_read "$rdir" >/dev/null 2>&1 && rc=0 || rc=$?; [ "$rc" -eq 2 ] || { echo "✗ expected abort(2) on version>MAX, got $rc"; fail=1; }
  jq '.schema_version=0' "$rdir/checkpoint.json" | _atomic_write "$rdir/checkpoint.json"
  cp_read "$rdir" >/dev/null 2>&1 && rc=0 || rc=$?; [ "$rc" -eq 3 ] || { echo "✗ expected reject(3) on version<current, got $rc"; fail=1; }
  jq '.schema_version=1' "$rdir/checkpoint.json" | _atomic_write "$rdir/checkpoint.json"

  # 9. GC: просроченная папка удаляется, свежая остаётся
  local groot="$T/central"; mkdir -p "$groot/old" "$groot/fresh"
  jq -n '{schema_version:1,expires_at:"2000-01-01T00:00:00Z"}' > "$groot/old/checkpoint.json"
  jq -n --arg e "$(plus_90d_iso)" '{schema_version:1,expires_at:$e}' > "$groot/fresh/checkpoint.json"
  cp_gc "$groot" >/dev/null
  [ ! -d "$groot/old" ] || { echo "✗ GC did not remove expired"; fail=1; }
  [ -d "$groot/fresh" ] || { echo "✗ GC wrongly removed fresh"; fail=1; }

  if [ "$fail" -eq 0 ]; then echo "✓ checkpoint self-test passed (9 invariants)"; return 0; else echo "✗ checkpoint self-test FAILED"; return 1; fi
}

cmd="${1:-}"; shift || true
case "$cmd" in
  slug)       cp_slug "$@" ;;
  init)       cp_init "$@" ;;
  read)       cp_read "$@" ;;
  set)        cp_set "$@" ;;
  acquire)    cp_acquire "$@" ;;
  release)    cp_release "$@" ;;
  gc)         cp_gc "$@" ;;
  --self-test) self_test ;;
  *) echo "usage: checkpoint.sh {slug|init|read|set|acquire|release|gc|--self-test} ..." >&2; exit 64 ;;
esac

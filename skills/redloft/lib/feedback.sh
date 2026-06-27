#!/usr/bin/env bash
# redloft self-improvement data layer (Phase E, DR-4). Append-only feedback per
# stage → feedback/<stage>.jsonl (skill-level, cross-run learning). Aggregation
# surfaces solidify-candidates (repeated findings). Consumed by /redloft-solidify.
#
# Usage:
#   source lib/feedback.sh
#   record_feedback <stage> <source> <severity> <note> [iteration] [slug]
#   aggregate_feedback <stage>     → JSON {stage,total,by_severity,repeated[],solidify_candidate}
#   feedback_stages                → stages that have non-empty feedback
#
# feedback dir: $REDLOFT_FEEDBACK_DIR (default <skill>/feedback). Override for tests.
# sourced under bash (tests) and zsh (caller); self-locate captured at TOP LEVEL.

# Self-locate (top level — function-scope $0 = function name under zsh FUNCTION_ARGZERO).
if [ -n "${BASH_SOURCE:-}" ]; then _redloft_fb_self="${BASH_SOURCE[0]}"; else _redloft_fb_self="$0"; fi
_FB_LIB_DIR="$(cd "$(dirname "$_redloft_fb_self")" 2>/dev/null && pwd)"
_FB_SKILL_DIR="$(cd "$_FB_LIB_DIR/.." 2>/dev/null && pwd)"
: "${REDLOFT_FEEDBACK_DIR:=$_FB_SKILL_DIR/feedback}"

_FB_STAGES="briefing research planning sitemap seo content design render self-improve reviewer"
_FB_SOURCES="reviewer user self"
_FB_SEVERITY="critical warning info"

# Scrub common secret shapes — feedback never carries raw tokens (mirrors log.sh).
_fb_scrub() {
  sed -E \
    -e 's/(sk-[A-Za-z0-9_-]{8,})/sk-***REDACTED***/g' \
    -e 's/(AIza[A-Za-z0-9_-]{8,})/AIza***REDACTED***/g' \
    -e 's/(ghp_[A-Za-z0-9_-]{8,})/ghp_***REDACTED***/g' \
    -e 's#(op://[A-Za-z0-9/_.-]+)#op://***REDACTED***#g' \
    -e 's/(eyJ[A-Za-z0-9_-]{16,})/eyJ***REDACTED***/g'
}

# record_feedback <stage> <source> <severity> <note> [iteration=0] [slug=-]
record_feedback() {
  local stage="$1" source="$2" severity="$3" note="$4" iter="${5:-0}" slug="${6:--}"
  [ -n "$stage" ] && [ -n "$note" ] || { echo "record_feedback: stage + note required" >&2; return 2; }
  echo "$_FB_STAGES"    | grep -qw "$stage"    || { echo "invalid stage: $stage" >&2; return 2; }
  echo "$_FB_SOURCES"   | grep -qw "$source"   || { echo "invalid source: $source" >&2; return 2; }
  echo "$_FB_SEVERITY"  | grep -qw "$severity" || { echo "invalid severity: $severity" >&2; return 2; }
  mkdir -p "$REDLOFT_FEEDBACK_DIR" || return 1
  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local clean; clean=$(printf '%s' "$note" | _fb_scrub)
  # one compact JSON object per line; small line → append is atomic (< PIPE_BUF)
  jq -nc --arg ts "$ts" --arg stage "$stage" --arg source "$source" --arg sev "$severity" \
        --arg note "$clean" --arg iter "$iter" --arg slug "$slug" \
        '{ts:$ts, stage:$stage, source:$source, severity:$sev, note:$note, reviewer_iteration:($iter|tonumber? // 0), slug:$slug}' \
    >> "$REDLOFT_FEEDBACK_DIR/$stage.jsonl"
}

# aggregate_feedback <stage> → JSON summary + solidify_candidate flag.
# solidify_candidate = any normalized note repeated ≥2 OR ≥2 critical findings.
aggregate_feedback() {
  local stage="$1"
  local f="$REDLOFT_FEEDBACK_DIR/$stage.jsonl"
  if [ ! -s "$f" ]; then
    jq -nc --arg s "$stage" '{stage:$s, total:0, by_severity:{}, repeated:[], solidify_candidate:false}'
    return 0
  fi
  jq -s --arg s "$stage" '
    def norm: ascii_downcase | gsub("\\s+"; " ") | gsub("^ | $"; "");
    {
      stage: $s,
      total: length,
      by_severity: (group_by(.severity) | map({key: .[0].severity, value: length}) | from_entries),
      repeated: (group_by(.note | norm) | map(select(length >= 2) | {note: .[0].note, count: length}) | sort_by(-.count)),
      crit: ([.[] | select(.severity=="critical")] | length)
    }
    | .solidify_candidate = ((.repeated | length) > 0 or .crit >= 2)
    | del(.crit)
  ' "$f"
}

# feedback_stages → newline list of stages with non-empty feedback files
feedback_stages() {
  [ -d "$REDLOFT_FEEDBACK_DIR" ] || return 0
  local f
  for f in "$REDLOFT_FEEDBACK_DIR"/*.jsonl; do
    [ -s "$f" ] || continue
    basename "$f" .jsonl
  done
}

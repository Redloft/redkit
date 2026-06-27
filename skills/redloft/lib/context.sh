#!/usr/bin/env bash
# redloft Project Context state-machine (DR-6). Ported from
# redresearch/lib/heartbeat.sh (atomic status.json writer). Manages TWO files:
#   pipeline.json — stage state-machine + artifact-refs + reviews + events (common)
#   brief.json    — volatile brief fill (written on each Q&A answer, separate)
# Both written ATOMICALLY (tmp + mv rename) under a per-file mkdir-lock, so a
# crash mid-write never corrupts the file (reader sees old OR new, never partial).
#
# Usage:
#   source lib/context.sh
#   init_pipeline <project_dir> <slug> <mode> <run_id>
#   set_stage <project_dir> <stage> [status=running]
#   get_stage <project_dir> <stage>            → echo status
#   read_pipeline <project_dir> <jq-path>      → echo field (e.g. "slug", "stages.research.status")
#   set_workflow_id <project_dir> <wf_id>
#   append_event <project_dir> <stage> <event> [duration_ms] [reviewer_iteration]
#   set_review <project_dir> <R1|R2|R3> <verdict> <confidence> [iter] [escalated] [notes]
#   register_artifact <project_dir> <stage> <artifact_type> <path> <source_stage> <key_claims_json>
#   validate_artifact_header <json>            → rc 0 valid / non-zero invalid
#   artifact_header_yaml <type> <stage> <source_stage> <key_claims_json>  → prints YAML front-matter
#   init_brief <project_dir>
#   set_brief_field <project_dir> <key> <value> [source=user]
#   get_brief_field <project_dir> <key>        → echo value
#   set_site_type <project_dir> <type>         # Q13 branching driver
#   detect_state <project_dir>                 → completed|failed|in-progress|idle|missing
#
# NB: sourced under zsh by callers (and under bash by tests). Two zsh gotchas
# are honoured throughout, exactly as in heartbeat.sh:
#   1) never name a shell-local `status` — zsh has a read-only special var of
#      that name (=$?); we use `st`.
#   2) no `trap … RETURN` — zsh has no RETURN pseudo-signal; locks are cleaned
#      explicitly on every path. Also: NO `set -e` here (would abort the caller).

# ── Enums (single source of truth; _shared.md §3/§4 mirrors these) ──
REDLOFT_STAGES="briefing research planning semantic sitemap seo content design render methodology self-improve"
REDLOFT_STAGE_STATUS="pending running done failed skipped escalated"
REDLOFT_ARTIFACT_TYPES="brief visual_taste research planning semantic sitemap seo content design tz prompt review kit"
REDLOFT_SOURCE_STAGES="briefing research planning semantic sitemap seo content design render self-improve input"
REDLOFT_REVIEW_GATES="R1 R2 R3"
REDLOFT_VERDICTS="PASS NEEDS-WORK FAIL"
REDLOFT_BRIEF_SOURCES="materials user research"
REDLOFT_SITE_TYPES="landing corporate ecommerce visitka blog other"

# ── Core: atomic JSON update (mkdir-lock + tmp + rename) ──
# _atomic_update <target> <jq_filter> [jq_opts…]
# jq_opts (e.g. --arg ts X) are passed BEFORE the filter, as jq requires.
# On any jq/mv failure the original file is left untouched (atomicity).
_atomic_update() {
  local target="$1" filter="$2"; shift 2
  [ -f "$target" ] || { echo "_atomic_update: missing $target" >&2; return 1; }
  local lock_dir="${target}.lockdir"
  local attempts=0
  while ! mkdir "$lock_dir" 2>/dev/null; do
    attempts=$((attempts + 1))
    if [ "$attempts" -gt 50 ]; then
      # ~5s timeout → likely stale lock, force-clear
      rm -rf "$lock_dir" 2>/dev/null
    fi
    sleep 0.1
  done
  local tmp="${target}.tmp.$$"
  local rc=0
  jq "$@" "$filter" "$target" > "$tmp" || rc=$?
  if [ "$rc" -eq 0 ]; then
    mv -f "$tmp" "$target" || rc=$?
  fi
  rm -f "$tmp" 2>/dev/null || true
  rmdir "$lock_dir" 2>/dev/null || true
  return "$rc"
}

# ── pipeline.json ──

init_pipeline() {
  local pd="$1" slug="$2" mode="$3" run_id="$4"
  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local stages_obj
  stages_obj=$(echo "$REDLOFT_STAGES" | tr ' ' '\n' | jq -R 'select(length>0)' \
    | jq -s 'map({key:., value:{status:"pending",started_at:null,ended_at:null,reviewer_iteration:0}}) | from_entries')
  jq -n --arg slug "$slug" --arg mode "$mode" --arg run_id "$run_id" --arg ts "$ts" \
    --argjson stages "$stages_obj" '
    {
      schema_version: 1, slug: $slug, mode: $mode, run_id: $run_id,
      workflow_run_id: null, created_at: $ts, updated_at: $ts,
      stages: $stages,
      artifacts: {},
      reviews: {
        R1: {gate_after:"planning", verdict:null, confidence:null, iteration:0, escalated:false, notes:null},
        R2: {gate_after:"seo",      verdict:null, confidence:null, iteration:0, escalated:false, notes:null},
        R3: {gate_after:"design",   verdict:null, confidence:null, iteration:0, escalated:false, notes:null}
      },
      events: []
    }' > "$pd/pipeline.json"
}

set_stage() {
  local pd="$1" stage="$2" st="${3:-running}"
  echo "$REDLOFT_STAGES" | grep -qw "$stage" || { echo "invalid stage: $stage" >&2; return 2; }
  echo "$REDLOFT_STAGE_STATUS" | grep -qw "$st" || { echo "invalid stage status: $st" >&2; return 2; }
  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local filter='.updated_at = $ts
    | .stages[$stage].status = $st
    | (if $st == "running" and (.stages[$stage].started_at == null)
         then .stages[$stage].started_at = $ts else . end)
    | (if ($st == "done" or $st == "failed" or $st == "skipped" or $st == "escalated")
         then .stages[$stage].ended_at = $ts else . end)'
  _atomic_update "$pd/pipeline.json" "$filter" --arg ts "$ts" --arg stage "$stage" --arg st "$st" || return $?
  # Auto-log the transition to the events[] audit-trail (best-effort).
  append_event "$pd" "$stage" "stage_$st" || true
}

get_stage() { jq -r --arg s "$2" '.stages[$s].status // empty' "$1/pipeline.json" 2>/dev/null; }

read_pipeline() { jq -r ".$2 // empty" "$1/pipeline.json" 2>/dev/null; }

set_workflow_id() {
  local pd="$1" wf="$2"
  _atomic_update "$pd/pipeline.json" '.updated_at=$ts | .workflow_run_id=$w' \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg w "$wf"
}

# append_event <pd> <stage> <event> [duration_ms=null] [reviewer_iteration=0]
append_event() {
  local pd="$1" stage="$2" event="$3" dur="${4:-null}" rev="${5:-0}"
  [ -n "$event" ] || { echo "append_event: empty event" >&2; return 2; }
  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if [ "$dur" = "null" ]; then
    _atomic_update "$pd/pipeline.json" \
      '.events += [{ts:$ts, stage:$stage, event:$event, duration_ms:null, reviewer_iteration:($rev|tonumber)}]' \
      --arg ts "$ts" --arg stage "$stage" --arg event "$event" --arg rev "$rev"
  else
    _atomic_update "$pd/pipeline.json" \
      '.events += [{ts:$ts, stage:$stage, event:$event, duration_ms:($dur|tonumber), reviewer_iteration:($rev|tonumber)}]' \
      --arg ts "$ts" --arg stage "$stage" --arg event "$event" --arg dur "$dur" --arg rev "$rev"
  fi
}

# set_review <pd> <R1|R2|R3> <verdict> <confidence> [iter=0] [escalated=false] [notes=""]
set_review() {
  local pd="$1" gate="$2" verdict="$3" conf="$4" iter="${5:-0}" esc="${6:-false}" notes="${7:-}"
  echo "$REDLOFT_REVIEW_GATES" | grep -qw "$gate" || { echo "invalid gate: $gate" >&2; return 2; }
  echo "$REDLOFT_VERDICTS" | grep -qw "$verdict" || { echo "invalid verdict: $verdict" >&2; return 2; }
  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  _atomic_update "$pd/pipeline.json" \
    '.updated_at=$ts
     | .reviews[$g].verdict=$v
     | .reviews[$g].confidence=($c|tonumber)
     | .reviews[$g].iteration=($i|tonumber)
     | .reviews[$g].escalated=($e=="true")
     | .reviews[$g].notes=(if $n=="" then null else $n end)' \
    --arg ts "$ts" --arg g "$gate" --arg v "$verdict" --arg c "$conf" --arg i "$iter" --arg e "$esc" --arg n "$notes"
}

# ── Artifact-header contract (DR-5, _shared.md §3) ──

# validate_artifact_header <json> → rc 0 valid / non-zero invalid.
# Required: all 6 fields present + types + enums + 1..7 key_claims.
validate_artifact_header() {
  local json="$1"
  printf '%s' "$json" | jq -e \
    --arg types "$REDLOFT_ARTIFACT_TYPES" \
    --arg stages "$REDLOFT_STAGES" \
    --arg sources "$REDLOFT_SOURCE_STAGES" '
    (.artifact_type   | type == "string") and
    (.stage_id        | type == "string") and
    (.schema_version  | type == "number") and
    (.produced_at     | type == "string") and (.produced_at | length > 0) and
    (.source_stage    | type == "string") and
    (.key_claims      | type == "array")  and (.key_claims | length >= 1) and (.key_claims | length <= 7) and
    (.artifact_type as $x | (($types   | split(" ")) | index($x)) != null) and
    (.stage_id      as $x | (($stages  | split(" ")) | index($x)) != null) and
    (.source_stage  as $x | (($sources | split(" ")) | index($x)) != null)
  ' >/dev/null 2>&1
}

# register_artifact <pd> <stage> <artifact_type> <path> <source_stage> <key_claims_json>
# Builds the header (stamping schema_version + produced_at), validates it, then
# writes to pipeline.json.artifacts[stage]. Reviewer reads headers from there.
register_artifact() {
  local pd="$1" stage="$2" atype="$3" path="$4" source_stage="$5" key_claims_json="$6"
  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local header
  header=$(jq -nc --arg at "$atype" --arg sid "$stage" --arg pa "$ts" \
            --arg ss "$source_stage" --arg p "$path" --argjson kc "$key_claims_json" \
            '{artifact_type:$at, stage_id:$sid, schema_version:1, produced_at:$pa,
              source_stage:$ss, key_claims:$kc, path:$p}' 2>/dev/null) \
    || { echo "register_artifact: bad key_claims JSON" >&2; return 2; }
  validate_artifact_header "$header" || { echo "register_artifact: invalid header for stage=$stage type=$atype" >&2; return 2; }
  _atomic_update "$pd/pipeline.json" '.updated_at=$ts | .artifacts[$stage]=$h' \
    --arg ts "$ts" --arg stage "$stage" --argjson h "$header"
}

# artifact_header_yaml <type> <stage> <source_stage> <key_claims_json> → YAML front-matter
# For stage skills to prepend to their .md body so the file is self-describing.
artifact_header_yaml() {
  local atype="$1" sid="$2" source_stage="$3" key_claims_json="$4"
  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf -- '---\n'
  printf 'artifact_type: %s\n' "$atype"
  printf 'stage_id: %s\n' "$sid"
  printf 'schema_version: 1\n'
  printf 'produced_at: %s\n' "$ts"
  printf 'source_stage: %s\n' "$source_stage"
  printf 'key_claims:\n'
  # tojson keeps each claim a YAML-safe quoted scalar (JSON ⊂ YAML)
  printf '%s' "$key_claims_json" | jq -r '.[] | "  - " + (.|tojson)'
  printf -- '---\n'
}

# ── brief.json (volatile fill) ──

init_brief() {
  local pd="$1"
  jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema_version:1, updated_at:$ts, site_type:null, fields:{}, sources:{}}' > "$pd/brief.json"
}

# set_brief_field <pd> <key> <value> [source=user]
set_brief_field() {
  local pd="$1" key="$2" val="$3" src="${4:-user}"
  [ -n "$key" ] || { echo "set_brief_field: empty key" >&2; return 2; }
  echo "$REDLOFT_BRIEF_SOURCES" | grep -qw "$src" || { echo "invalid brief source: $src" >&2; return 2; }
  _atomic_update "$pd/brief.json" '.updated_at=$ts | .fields[$k]=$v | .sources[$k]=$src' \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg k "$key" --arg v "$val" --arg src "$src"
}

get_brief_field() { jq -r --arg k "$2" '.fields[$k] // empty' "$1/brief.json" 2>/dev/null; }

# set_site_type <pd> <type> — Q13 branching driver
set_site_type() {
  local pd="$1" t="$2"
  echo "$REDLOFT_SITE_TYPES" | grep -qw "$t" || { echo "invalid site_type: $t" >&2; return 2; }
  _atomic_update "$pd/brief.json" '.updated_at=$ts | .site_type=$t' \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg t "$t"
}

# ── resume / status helper ──
# detect_state <pd> → overall pipeline state for /redloft-resume + /redloft-status.
# Resume is Workflow-native (resumeFromRunId) — no detached worker pid to probe.
detect_state() {
  local pd="$1"
  [ -f "$pd/pipeline.json" ] || { echo "missing"; return; }
  jq -r '
    [.stages[].status] as $s
    | if   ($s | all(. == "done" or . == "skipped"))   then "completed"
      elif ($s | any(. == "failed"))                    then "failed"
      elif ($s | any(. == "running" or . == "escalated")) then "in-progress"
      elif ($s | all(. == "pending"))                   then "idle"
      else "in-progress" end
  ' "$pd/pipeline.json" 2>/dev/null
}

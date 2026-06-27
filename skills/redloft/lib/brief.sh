#!/usr/bin/env bash
# redloft briefing gap-engine (Phase B). Deterministic branching over
# lib/brief-schema.json so the briefing flow asks ONLY real gaps (DR — observable
# DoD). Consumes brief.json (filled by the flow via context.sh set_brief_field /
# set_site_type). Pure read/compute; does NOT write state.
#
# Usage:
#   source lib/brief.sh
#   brief_gaps <pd> [--required-only] [--no-pii]   → JSON array of gap field objs
#   brief_contact_fields                            → JSON array (Q30-34, PII → contacts.md)
#   brief_visual_fields                             → JSON array (Q11/Q12 → visual taste)
#   brief_coverage <pd>                             → "filled/relevant (non-pii)"
#
# Branching (mirrors docs/brief-schema.md):
#   • site_type unknown (null) → Q13 is the gap; site_type-dependent fields deferred.
#   • e-commerce block (Q15-21) relevant ONLY if site_type == ecommerce.
#   • structure (Q22-23) relevant for all types EXCEPT visitka.
#   • Q13 counts as filled once brief.json.site_type is set (via set_site_type).
#
# sourced under bash (tests) and zsh (caller) — schema self-locate is shell-safe.

# Locate brief-schema.json next to this lib, shell-portably (bash + zsh).
# MUST be captured at FILE TOP LEVEL: bash → BASH_SOURCE[0]; zsh (sourced) → $0 is
# the file path here (inside a function $0 would be the function name under zsh's
# FUNCTION_ARGZERO). No eval / no ${(%)…} → nothing for bash's parser to choke on.
if [ -n "${BASH_SOURCE:-}" ]; then _redloft_brief_self="${BASH_SOURCE[0]}"; else _redloft_brief_self="$0"; fi
_BRIEF_DIR="$(cd "$(dirname "$_redloft_brief_self")" 2>/dev/null && pwd)"
: "${REDLOFT_BRIEF_SCHEMA:=$_BRIEF_DIR/brief-schema.json}"

# brief_gaps <pd> [--required-only] [--no-pii] → JSON array of relevant+unfilled fields
brief_gaps() {
  local pd="$1"; shift || true
  local req_only=false pii=true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --required-only) req_only=true ;;
      --no-pii)        pii=false ;;
      *) echo "brief_gaps: unknown flag $1" >&2; return 2 ;;
    esac; shift
  done
  [ -f "$REDLOFT_BRIEF_SCHEMA" ] || { echo "brief_gaps: schema not found: $REDLOFT_BRIEF_SCHEMA" >&2; return 1; }
  [ -f "$pd/brief.json" ]        || { echo "brief_gaps: no brief.json in $pd" >&2; return 1; }
  jq -n --argjson req "$req_only" --argjson pii "$pii" \
        --slurpfile schema "$REDLOFT_BRIEF_SCHEMA" \
        --slurpfile brief "$pd/brief.json" '
    ($brief[0])         as $b
    | ($b.site_type)    as $st
    | ($b.fields // {}) as $f
    | $schema[0]
    | map(
        # relevance under branching
        ( .branch as $br
          | if   $br == null              then true
            elif $st == null              then false          # defer until Q13 answered
            elif ($br.site_type_in)       then (($br.site_type_in) | index($st)) != null
            elif ($br.site_type)          then ($st == $br.site_type)
            else true end
        ) as $relevant
        # filled? (Q13 satisfied by site_type being set)
        | ( (($f[.id] // null) != null) or (.id == "q13_site_type" and $st != null) ) as $filled
        | select($relevant and ($filled | not))
        | select(if $req then .required else true end)
        | select(if $pii then true else (.pii | not) end)
      )
  '
}

# brief_contact_fields → JSON array of PII fields (Q30-34) → collected into contacts.md
brief_contact_fields() {
  [ -f "$REDLOFT_BRIEF_SCHEMA" ] || { echo "brief_contact_fields: schema not found" >&2; return 1; }
  jq '[ .[] | select(.pii) ]' "$REDLOFT_BRIEF_SCHEMA"
}

# brief_visual_fields → JSON array of visual fields (Q11/Q12) → visual taste intake
brief_visual_fields() {
  [ -f "$REDLOFT_BRIEF_SCHEMA" ] || { echo "brief_visual_fields: schema not found" >&2; return 1; }
  jq '[ .[] | select(.visual) ]' "$REDLOFT_BRIEF_SCHEMA"
}

# brief_coverage <pd> → "filled/relevant" over non-PII fields (PII tracked in contacts.md)
brief_coverage() {
  local pd="$1"
  [ -f "$REDLOFT_BRIEF_SCHEMA" ] && [ -f "$pd/brief.json" ] || { echo "0/0"; return 1; }
  jq -rn --slurpfile schema "$REDLOFT_BRIEF_SCHEMA" --slurpfile brief "$pd/brief.json" '
    ($brief[0]) as $b | ($b.site_type) as $st | ($b.fields // {}) as $f
    | [ $schema[0][]
        | select(.pii | not)
        | ( .branch as $br
            | if $br == null then true
              elif $st == null then false
              elif ($br.site_type_in) then (($br.site_type_in)|index($st))!=null
              elif ($br.site_type) then ($st==$br.site_type)
              else true end ) as $rel
        | select($rel)
      ] as $relevant
    | ( [ $relevant[] | select( (($f[.id] // null) != null) or (.id=="q13_site_type" and $st!=null) ) ] | length ) as $filled
    | "\($filled)/\($relevant|length)"
  '
}

#!/usr/bin/env bash
# redloft project management (no agents): list / path / status.
# Reads pipeline.json (single source of truth). Ported pattern from
# redresearch/lib/manage.sh, slimmed for Phase A (cleanup/purge → Phase F).
#
# Usage:
#   manage.sh list
#   manage.sh path   <slug>     → echo project dir (rc 1 if absent)
#   manage.sh status <slug>     → human-readable pipeline status
set -uo pipefail

_data_root() {
  if [ -n "${REDLOFT_DATA_DIR:-}" ]; then printf '%s' "$REDLOFT_DATA_DIR"
  else printf '%s' "$HOME/Library/Application Support/redloft"; fi
}
PROJECTS="$(_data_root)/projects"

CMD="${1:-}"; [ "$#" -gt 0 ] && shift || true

case "$CMD" in
  path)
    SLUG="${1:-}"; [ -n "$SLUG" ] || { echo "usage: manage.sh path <slug>" >&2; exit 64; }
    PD="$PROJECTS/$SLUG"
    [ -d "$PD" ] || { echo "✗ no project: $SLUG" >&2; exit 1; }
    printf '%s\n' "$PD"
    ;;

  list)
    [ -d "$PROJECTS" ] || { echo "(no projects yet)"; exit 0; }
    found=0
    for d in "$PROJECTS"/*/; do
      [ -d "$d" ] || continue
      found=1
      slug=$(basename "$d")
      if [ -f "$d/pipeline.json" ]; then
        meta=$(jq -r '"mode=\(.mode)  updated=\(.updated_at)"' "$d/pipeline.json" 2>/dev/null)
        st=$(jq -r '[.stages[].status] as $s
          | if   ($s|all(.=="done" or .=="skipped"))     then "completed"
            elif ($s|any(.=="failed"))                    then "failed"
            elif ($s|any(.=="running" or .=="escalated")) then "in-progress"
            elif ($s|all(.=="pending"))                   then "idle"
            else "in-progress" end' "$d/pipeline.json" 2>/dev/null)
        printf '  %-28s %-34s [%s]\n' "$slug" "$meta" "$st"
      else
        printf '  %-28s (no pipeline.json)\n' "$slug"
      fi
    done
    if [ "$found" -eq 0 ]; then echo "(no projects yet)"; fi
    ;;

  status)
    SLUG="${1:-}"; [ -n "$SLUG" ] || { echo "usage: manage.sh status <slug>" >&2; exit 64; }
    PD="$PROJECTS/$SLUG"
    [ -f "$PD/pipeline.json" ] || { echo "✗ no pipeline for: $SLUG" >&2; exit 1; }
    jq -r '
      "Project: \(.slug)   mode=\(.mode)   run_id=\(.run_id)",
      "Updated: \(.updated_at)   workflow_run_id=\(.workflow_run_id // "—")",
      "Stages:",
      (.stages | to_entries[] | "  - \(.key): \(.value.status)"),
      "Reviews:",
      (.reviews | to_entries[] | "  - \(.key) (after \(.value.gate_after)): verdict=\(.value.verdict // "—") iter=\(.value.iteration) escalated=\(.value.escalated)")
    ' "$PD/pipeline.json"
    [ -f "$PD/brief.json" ] && jq -r '"Brief: site_type=\(.site_type // "—")  fields_filled=\(.fields|length)"' "$PD/brief.json"
    # methodology kit (Phase 7.5, DR-8): surface tier + version if box was assembled
    if [ -f "$PD/methodology/.methodology-version" ]; then
      _kit=$(tr '\n' ' ' < "$PD/methodology/.methodology-version")
      printf 'Methodology kit: %s(START-HERE → %s/methodology/)\n' "$_kit" "$PD"
    fi
    # surface any escalation prominently
    if jq -e '[.reviews[] | select(.escalated)] | length > 0' "$PD/pipeline.json" >/dev/null 2>&1; then
      echo "⚠️  ESCALATED to human — see reviewer notes above (cap=2 reached)."
    fi
    ;;

  *)
    echo "usage: manage.sh {list | path <slug> | status <slug>}" >&2; exit 64
    ;;
esac

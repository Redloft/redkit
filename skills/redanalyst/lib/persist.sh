#!/usr/bin/env bash
# redanalyst persistence — local-first, OUTSIDE cloud-sync dirs (client analytics data / PII).
# Usage:
#   persist.sh <slug>            → ensure project dir + empty state.json; print project_dir
#   persist.sh purge <slug>      → remove PII artifacts (>0 days; caller decides retention gate)
set -euo pipefail

DATA_DIR="${REDANALYST_DATA_DIR:-$HOME/Library/Application Support/redanalyst}"

slug_ok() { [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]]; }   # guard: no path-traversal / shell-inject

cmd="${1:-}"
if [[ "$cmd" == "purge" ]]; then
  slug="${2:-}"; slug_ok "$slug" || { echo "bad slug" >&2; exit 2; }
  pd="$DATA_DIR/$slug"
  [[ -d "$pd" ]] || { echo "no such project: $slug" >&2; exit 1; }
  # Remove PII-bearing artifacts; keep state.json skeleton + run.log (scrubbed).
  rm -f "$pd"/{audit.md,gap-list.md,goals-spec.md,setup-runbook.md,verify-report.md,ledger.db} 2>/dev/null || true
  echo "purged PII artifacts in $pd"
  exit 0
fi

slug="$cmd"; slug_ok "$slug" || { echo "usage: persist.sh <slug>  (slug: [a-z0-9_-])" >&2; exit 2; }
pd="$DATA_DIR/$slug"
mkdir -p "$pd"
state="$pd/state.json"
if [[ ! -f "$state" ]]; then
  # atomic init
  tmp="$(mktemp "$pd/.state.XXXXXX")"
  cat > "$tmp" <<JSON
{
  "schema_version": 1,
  "project": "$slug", "counter_id": 0, "domain": "",
  "last_audit_ts": "", "gap_list": [],
  "goals": [],
  "offline_scope_granted": false, "direct_linked": null,
  "consent_152fz": {"required": true, "confirmed": false, "doc_url": ""},
  "source_of_truth": {"kind": "none", "how": ""},
  "last_batch": {"batch_id": "", "uploading_id": "", "status": "", "rows": 0}
}
JSON
  mv "$tmp" "$state"
fi
echo "$pd"

#!/usr/bin/env bash
# redanalyst — Yandex.Metrika API helper. Token ONLY via 1Password op run; never printed.
#
# Wrap EVERY call so the OAuth token lives only in the child process env:
#   op run --env-file=<(echo 'YM_TOKEN=op://AI-Tokens/<Item>/credential') -- \
#     bash lib/metrika.sh <verb> ...
# where <Item> is the proj-<slug>-scoped Metrika item (see secrets skill).
#
# Read verbs (need metrika:read):   counter, goals, goal-reaches, uploadings, uploading, threshold
# Write verbs (need metrika:write / offline grant): create-goal, upload-offline
# Write verbs are DRY-RUN by default; pass --execute to actually send (write-safety contract).
set -euo pipefail

API="${YM_API:-https://api-metrika.yandex.net}"
: "${YM_TOKEN:?YM_TOKEN not in env — call via op run (never inline the token)}"

# minimal curl; NO -v / no stderr dump (token is in the Authorization header)
_get()  { curl -sS -H "Authorization: OAuth $YM_TOKEN" "$API$1"; }
_post() { curl -sS -H "Authorization: OAuth $YM_TOKEN" -H "Content-Type: application/json" -X POST -d "$2" "$API$1"; }

verb="${1:-}"; shift || true
case "$verb" in
  counter)        _get "/management/v1/counter/$1" ;;
  goals)          _get "/management/v1/counter/$1/goals" ;;
  # goal-reaches <counter> <goalId> <date1> <date2>  → did the goal actually fire?
  goal-reaches)   _get "/stat/v1/data?ids=$1&metrics=ym:s:goal$2reaches&date1=$3&date2=$4" ;;
  uploadings)     _get "/management/v1/counter/$1/offline_conversions/uploadings" ;;
  uploading)      _get "/management/v1/counter/$1/offline_conversions/uploading/$2" ;;
  # threshold <counter> → 21-day gate: how far back offline rows may be uploaded. CALL FIRST.
  threshold)      _get "/management/v1/counter/$1/offline_conversions/visit_join_threshold" ;;
  # create-goal <counter> <json-body>   (write-safety: dry-run unless --execute)
  create-goal)
      counter="$1"; body="$2"; shift 2 || true
      if [[ "${1:-}" != "--execute" ]]; then
        echo "DRY-RUN create-goal on counter $counter; payload:"; echo "$body"
        echo "(pass --execute after explicit user approval to send)"; exit 0
      fi
      _post "/management/v1/counter/$counter/goals" "$body" ;;
  # upload-offline <counter> <csv-file> <id-type>   id-type: CLIENT_ID|USER_ID|YCLID|PURCHASE_ID
  upload-offline)
      counter="$1"; csv="$2"; idtype="${3:-CLIENT_ID}"; shift 3 || true
      # validate id-type against allowed set — so a misplaced --execute can't be swallowed as idtype
      case "$idtype" in CLIENT_ID|USER_ID|YCLID|PURCHASE_ID) ;; *)
        echo "bad id-type: $idtype (CLIENT_ID|USER_ID|YCLID|PURCHASE_ID)" >&2; exit 2 ;; esac
      [[ -f "$csv" ]] || { echo "csv not found: $csv" >&2; exit 2; }
      # minimal header sanity: Target column present (NOT a full UTF-8/schema validation — caller owns that)
      head -1 "$csv" | grep -qiE '(^|[,;])Target([,;]|$)' || { echo "csv missing Target column" >&2; exit 2; }
      if [[ "${1:-}" != "--execute" ]]; then
        echo "DRY-RUN upload-offline on counter $counter ($idtype), $(($(wc -l < "$csv")-1)) rows; head:"
        head -3 "$csv"
        echo "(canary 1-2 rows first; pass --execute after approval)"; exit 0
      fi
      curl -sS -H "Authorization: OAuth $YM_TOKEN" -F "file=@$csv" \
        "$API/management/v1/counter/$counter/offline_conversions/upload?client_id_type=$idtype" ;;
  *) echo "unknown verb: $verb" >&2
     echo "verbs: counter goals goal-reaches uploadings uploading threshold create-goal upload-offline" >&2
     exit 2 ;;
esac

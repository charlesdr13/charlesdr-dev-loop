#!/usr/bin/env bash
# verify-receipt.sh — did a lane actually run, or did the agent answer from its head?
#
#   verify-receipt.sh <dir> [--lane explore|implement|review] [--since SECONDS]
#   verify-receipt.sh <dir> --run <id>
#
# exit 0  a matching successful dispatch exists
# exit 1  none — treat the report as absent and record a FAILED item
# exit 2  a dispatch exists but every one failed
# exit 3  a matched start has no end; ask lane-status before concluding
set -uo pipefail

DIR="${1:?usage: verify-receipt.sh <dir> [--lane L] [--since N] [--run ID]}"; shift || true
LANE=""; SINCE=1800; REQUESTED_RUN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --lane)  LANE="$2"; shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
    --run)   REQUESTED_RUN="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -d "$DIR" ] || { echo "verify-receipt.sh: no such directory: $DIR" >&2; exit 1; }
DIR="$(cd "$DIR" && pwd)"

log="$DIR/.charles/dispatches.jsonl"
if [ ! -s "$log" ]; then
  echo "NO RECEIPT: $log is empty or missing — no lane has ever run in this repo." >&2
  echo "The agent's report was not produced by a codex lane. Treat it as absent." >&2
  exit 1
fi
command -v jq >/dev/null || { echo "verify-receipt.sh: jq required" >&2; exit 1; }

cutoff="$(date -u -d "-${SINCE} seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || cutoff=""
declare -A start_ts start_lane start_seen end_json new_end_seen legacy_json legacy_seen
start_order=(); legacy_order=()

while IFS= read -r record; do
  [ -n "$record" ] || continue
  kind="$(jq -r 'if .event == "start" then "start" elif .event == "end" then "end" else "legacy" end' <<<"$record" 2>/dev/null)"
  run="$(jq -r '(.run // "") | tostring | split("/") | last' <<<"$record" 2>/dev/null)"
  [ -n "$run" ] || continue
  if [ "$kind" = "start" ]; then
    start_ts["$run"]="$(jq -r '.ts // ""' <<<"$record" 2>/dev/null)"
    start_lane["$run"]="$(jq -r '.lane // ""' <<<"$record" 2>/dev/null)"
    if [ -z "${start_seen[$run]+x}" ]; then start_order+=("$run"); fi
    start_seen["$run"]=1
  else
    end_json["$run"]="$record"
    if [ "$kind" = "legacy" ]; then
      if [ -z "${legacy_seen[$run]+x}" ]; then legacy_order+=("$run"); fi
      legacy_seen["$run"]=1
      legacy_json["$run"]="$record"
    else
      new_end_seen["$run"]=1
    fi
  fi
done < <(jq -c 'select(type == "object" and ((has("event") | not) or .event == "start" or .event == "end"))' "$log" 2>/dev/null)

lane_status() {
  local run_id="$1" out rc
  out="$(bash "$(dirname "$0")/lane-status.sh" --dir "$DIR" "$run_id" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "ORPHAN: $run_id — lane in flight; consult lane-status.sh before concluding." >&2
  else
    echo "ORPHAN: $run_id — lane killed mid-write; consult lane-status.sh before concluding." >&2
  fi
  echo "  $out" >&2
}

if [ -n "$REQUESTED_RUN" ]; then
  target="${REQUESTED_RUN##*/}"
  if [ -z "${start_seen[$target]+x}" ] && [ -z "${end_json[$target]+x}" ]; then
    echo "NO RECEIPT: no dispatch with run id $target." >&2
    exit 1
  fi
  if [ -n "${new_end_seen[$target]+x}" ] && [ -z "${start_seen[$target]+x}" ]; then
    echo "NO RECEIPT: start record is missing for new-format end run $target." >&2
    exit 1
  fi
  if [ -n "$LANE" ]; then
    if [ -n "${start_seen[$target]+x}" ]; then
      [ "${start_lane[$target]}" = "$LANE" ] || { echo "NO RECEIPT: run $target is not a $LANE dispatch." >&2; exit 1; }
    elif [ "$(jq -r '.lane // ""' <<<"${end_json[$target]}" 2>/dev/null)" != "$LANE" ]; then
      echo "NO RECEIPT: run $target is not a $LANE dispatch." >&2
      exit 1
    fi
  fi
  if [ -n "${start_seen[$target]+x}" ] && [ -z "${end_json[$target]+x}" ]; then
    lane_status "$target"
    exit 3
  fi
  echo "RECEIPT FOR RUN $target:"
  record="${end_json[$target]}"
  rc="$(jq -r '.rc // empty' <<<"$record" 2>/dev/null)"
  echo "$record"
  [ "$rc" = "0" ] && exit 0
  exit 2
fi

matched=(); orphan_count=0
for run in "${start_order[@]-}"; do
  [ -n "$run" ] || continue
  [ -z "$LANE" ] || [ "${start_lane[$run]}" = "$LANE" ] || continue
  if [ -n "$cutoff" ] && [[ "${start_ts[$run]}" < "$cutoff" ]]; then continue; fi
  if [ -z "${end_json[$run]+x}" ]; then
    lane_status "$run"
    orphan_count=$((orphan_count+1))
  else
    matched+=("${end_json[$run]}")
  fi
done

# Legacy records have no start to anchor a window to. Keep them parseable by
# their own timestamp, while never treating an unmatched new-format end as a
# receipt. A legacy run that is now paired to a start uses the paired last end.
for run in "${legacy_order[@]-}"; do
  [ -n "$run" ] || continue
  [ -n "${start_seen[$run]+x}" ] && continue
  record="${legacy_json[$run]}"
  [ -z "$LANE" ] || [ "$(jq -r '.lane // ""' <<<"$record" 2>/dev/null)" = "$LANE" ] || continue
  ts="$(jq -r '.ts // ""' <<<"$record" 2>/dev/null)"
  if [ -n "$cutoff" ] && [[ "$ts" < "$cutoff" ]]; then continue; fi
  matched+=("$record")
done

if [ "$orphan_count" -gt 0 ]; then
  echo "NO RECEIPT: $orphan_count matched start(s) have no end event." >&2
  echo "Consult lane-status.sh for each orphan before accepting any receipt." >&2
  exit 3
fi

if [ "${#matched[@]}" -eq 0 ]; then
  echo "NO RECEIPT: no ${LANE:-any}-lane dispatch in the last ${SINCE}s." >&2
  echo "Nothing ran. The report is the agent's own work — discard it and record FAILED." >&2
  exit 1
fi

ok=0; bad=0
for record in "${matched[@]}"; do
  rc="$(jq -r '.rc // empty' <<<"$record" 2>/dev/null)"
  [ "$rc" = "0" ] && ok=$((ok+1)) || bad=$((bad+1))
done

if [ "$ok" -eq 0 ]; then
  echo "RECEIPTS PRESENT BUT ALL FAILED ($bad failed, 0 succeeded):" >&2
  for record in "${matched[@]}"; do
    jq -r '"  rc=\(.rc)  \(.lane)/\(.model)  \(.ts)"' <<<"$record" >&2
  done
  echo >&2
  echo "The lane ran and was cut short (124 = its own timeout, 143 = killed)." >&2
  echo "This invalidates its REPORT, not necessarily its WORK: judge the tree independently." >&2
  exit 2
fi

echo "RECEIPT OK: $ok successful ${LANE:-lane} dispatch(es) in the last ${SINCE}s"
for record in "${matched[@]}"; do
  jq -c '.' <<<"$record"
done
[ "$bad" -gt 0 ] && echo "  (note: $bad failed dispatch(es) in the same window)"
exit 0

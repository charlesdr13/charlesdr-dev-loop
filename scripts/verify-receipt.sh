#!/usr/bin/env bash
# verify-receipt.sh — did a lane actually run, or did the agent answer from its head?
#
# The docs said "a report without a receipt is discarded". Nothing enforced that;
# it relied on the orchestrator noticing. This checks the mechanical record instead
# — .charles/dispatches.jsonl, written by codex-run.sh itself, which an agent
# cannot forge by pasting a plausible-looking line into its report.
#
#   verify-receipt.sh <dir> [--lane explore|implement|review] [--since SECONDS]
#
# exit 0  a matching successful dispatch exists
# exit 1  none — treat the report as absent and record a FAILED item
# exit 2  a dispatch exists but every one failed
set -uo pipefail

DIR="${1:?usage: verify-receipt.sh <dir> [--lane L] [--since N]}"; shift || true
LANE=""; SINCE=1800
while [ $# -gt 0 ]; do
  case "$1" in
    --lane)  LANE="$2"; shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
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
recent="$(jq -c --arg c "$cutoff" --arg l "$LANE" \
  'select(($c == "" or .ts >= $c) and ($l == "" or .lane == $l))' "$log" 2>/dev/null)"

if [ -z "$recent" ]; then
  echo "NO RECEIPT: no ${LANE:-any}-lane dispatch in the last ${SINCE}s." >&2
  echo "Nothing ran. The report is the agent's own work — discard it and record FAILED." >&2
  exit 1
fi

ok="$(jq -s '[.[] | select(.rc == 0)] | length' <<<"$recent" 2>/dev/null)"
bad="$(jq -s '[.[] | select(.rc != 0)] | length' <<<"$recent" 2>/dev/null)"

if [ "${ok:-0}" -eq 0 ]; then
  echo "RECEIPTS PRESENT BUT ALL FAILED ($bad failed, 0 succeeded):" >&2
  jq -s -r '.[] | select(.rc != 0) | "  rc=\(.rc)  \(.lane)/\(.model)  \(.ts)"' <<<"$recent" >&2
  echo >&2
  echo "The lane ran and was cut short (124 = its own timeout, 143 = killed)." >&2
  echo "This invalidates its REPORT, not necessarily its WORK: a lane killed at" >&2
  echo "1800s may have written correct code before the clock stopped it." >&2
  echo >&2
  echo "So do not trust a word it said, and judge the tree independently:" >&2
  echo "  1. green.sh          — does it actually pass" >&2
  echo "  2. codex-reviewer    — does the diff satisfy the plan" >&2
  echo "Both pass: keep it, and record that it came from a timed-out lane." >&2
  echo "Either fails, or you cannot be bothered to check: revert." >&2
  exit 2
fi

echo "RECEIPT OK: $ok successful ${LANE:-lane} dispatch(es) in the last ${SINCE}s"
jq -s -r '.[] | select(.rc == 0) | "  \(.ts)  \(.lane)/\(.model)"' <<<"$recent"
[ "${bad:-0}" -gt 0 ] && echo "  (note: $bad failed dispatch(es) in the same window)"
exit 0

#!/usr/bin/env bash
# flow-status.sh — did the FLOW finish, or only the dispatches?
#
# verify-receipt.sh proves a lane ran. Nothing proved the flow ran. An audit of
# 75 real dispatches found the consequence: 26 implements against 5 reviews
# (19% coverage, two repos never reviewed at all), 13 plans carrying 1 grill
# verdict, and 4 runs opened against 1 closed. Every one of those passed
# silently, because each individual dispatch succeeded.
#
#   flow-status.sh <dir>
#
# exit 0  nothing outstanding
# exit 1  work is ungraded, unplanned, or unclosed
set -uo pipefail

DIR="${1:-$PWD}"; shift || true
CLOSING=""   # the run being closed right now must not count itself as open
while [ $# -gt 0 ]; do
  case "$1" in --closing) CLOSING="${2:-}"; shift 2 ;; *) shift ;; esac
done
[ -d "$DIR" ] || { echo "flow-status.sh: no such directory: $DIR" >&2; exit 1; }
DIR="$(cd "$DIR" && pwd)"
log="$DIR/.charles/dispatches.jsonl"
issues=0

say_bad() { echo "  ISSUE  $1"; issues=$((issues+1)); }
say_ok()  { echo "  ok     $1"; }

echo "flow status: $(basename "$DIR")"

# --- 1. implements that were never graded -------------------------------------
if [ -s "$log" ] && command -v jq >/dev/null; then
  last_review="$(jq -r 'select(.lane=="review" and .rc==0) | .ts' "$log" 2>/dev/null | sort | tail -1)"
  if [ -n "$last_review" ]; then
    ungraded="$(jq -r --arg t "$last_review" \
      'select(.lane=="implement" and .rc==0 and .ts > $t) | .ts' "$log" 2>/dev/null | wc -l)"
  else
    ungraded="$(jq -r 'select(.lane=="implement" and .rc==0) | .ts' "$log" 2>/dev/null | wc -l)"
  fi
  impl="$(jq -r 'select(.lane=="implement") | .ts' "$log" 2>/dev/null | wc -l)"
  revs="$(jq -r 'select(.lane=="review") | .ts' "$log" 2>/dev/null | wc -l)"
  if [ "${ungraded:-0}" -gt 0 ]; then
    say_bad "$ungraded implement dispatch(es) never reviewed (repo total: $impl implements, $revs reviews)"
    echo "         the isolated reviewer is the point of this plugin; run codex-reviewer against the plan"
  else
    [ "${impl:-0}" -gt 0 ] && say_ok "every implement has a later review ($impl implements, $revs reviews)"
  fi
else
  say_ok "no dispatch log yet — nothing to grade"
fi

# --- 2. a plan to grade against -----------------------------------------------
specs=$(ls "$DIR"/docs/specs/*.md 2>/dev/null | wc -l)
if [ "${impl:-0}" -gt 0 ] && [ "$specs" -eq 0 ]; then
  say_bad "code was implemented but docs/specs/ is empty — the review lane has nothing to judge against"
elif [ "$specs" -gt 0 ]; then
  graded=$(grep -rl 'Grill verdict' "$DIR"/docs/specs/*.md 2>/dev/null | wc -l)
  if [ "$graded" -eq 0 ]; then
    say_bad "$specs plan(s), none carrying a grill verdict — plans went to implementation unchallenged"
  elif [ "$graded" -lt "$specs" ]; then
    say_bad "$((specs - graded)) of $specs plan(s) have no grill verdict"
  else
    say_ok "all $specs plan(s) carry a grill verdict"
  fi
fi

# --- 2b. changes no lane produced -------------------------------------------
us="$(dirname "$0")/unsourced.sh"
if [ -x "$us" ]; then
  if out="$("$us" "$DIR" 2>&1)"; then :; else
    say_bad "working-tree changes that no dispatch produced — discard them whole"
    echo "$out" | sed -n '1,2p' | sed 's/^/         /'
  fi
fi

# --- 3. runs left open --------------------------------------------------------
open=0
for d in "$DIR"/.charles/runs/*/; do
  [ -f "$d/RUN.md" ] || continue
  [ -n "$CLOSING" ] && [ "${d%/}" = "${CLOSING%/}" ] && continue
  grep -q '^## Outcome' "$d/RUN.md" 2>/dev/null || open=$((open+1))
done
if [ "$open" -gt 0 ]; then
  say_bad "$open run(s) still open — resume with /charlesdr-dev-loop:resolve, or close them"
else
  say_ok "no runs left open"
fi

echo
if [ "$issues" -eq 0 ]; then echo "flow complete: nothing outstanding"; exit 0; fi
echo "$issues outstanding — a dispatch succeeding is not a flow finishing"
exit 1

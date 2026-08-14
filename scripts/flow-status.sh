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
FLOW_FILE="$(dirname "$0")/flow.json"
issues=0

flow_graph=1
if ! command -v jq >/dev/null 2>&1 || [ ! -r "$FLOW_FILE" ] || ! jq -e '
  def strings: type == "array" and all(.[]; type == "string");
  . as $root |
  ($root | type == "object") and
  all(["feature", "debug", "polish", "ui"][];
    . as $flow |
    ($root[$flow] | type == "object") and
    ($root[$flow].phases | type == "object") and
    ($root[$flow].first | type == "string") and
    ($root[$flow].terminal | strings) and
    ([$root[$flow].phases[] | type == "object" and (.next | strings) and (.proof | type == "string")] | all)
  )
' "$FLOW_FILE" >/dev/null 2>&1; then
  echo "flow-status.sh: WARN flow.json missing or unparseable; flow guidance disabled" >&2
  flow_graph=0
fi

flow_ready() {
  local flow="$1"
  if [ "$flow_graph" -eq 0 ] || ! jq -e --arg f "$flow" '.[$f] != null' "$FLOW_FILE" >/dev/null 2>&1; then
    [ "$flow_graph" -eq 0 ] || echo "flow-status.sh: WARN flow '$flow' is not in flow.json; flow guidance disabled" >&2
    return 1
  fi
}

flow_match() {
  local flow="$1" phase="$2" lower
  lower="${phase,,}"
  jq -r --arg f "$flow" --arg p "$lower" '
    [.[$f].phases | keys[]? | . as $name | select($p | startswith($name))] |
    sort_by(length) | reverse | .[0] // ""
  ' "$FLOW_FILE" 2>/dev/null
}

flow_next() {
  jq -r --arg f "$1" --arg p "$2" '.[$f].phases[$p].next | join(" | ")' "$FLOW_FILE" 2>/dev/null
}

flow_first() {
  jq -r --arg f "$1" '.[$f].first' "$FLOW_FILE" 2>/dev/null
}

last_phase() {
  awk '
    /^## Phases$/ { inside=1; next }
    /^## Open items$/ && !proof { inside=0 }
    inside {
      if ($0 == "  ```") { proof = !proof; next }
      if (!proof && /^- \[[0-9][0-9]:[0-9][0-9]Z\] /) {
        phase=$0
        sub(/^- \[[^]]*\] /, "", phase)
        last=phase
      }
    }
    END { print last }
  ' "$1"
}

say_bad() { echo "  ISSUE  $1"; issues=$((issues+1)); }
say_ok()  { echo "  ok     $1"; }

echo "flow status: $(basename "$DIR")"

last_ends() {
  jq -c -s '
    map(select((has("event") | not) or .event == "end")) |
    reduce .[] as $r ({};
      .[(($r.run // "") | tostring | split("/") | last)] = $r) |
    .[]
  ' "$log" 2>/dev/null
}

# A start without any end is not a failed receipt; the lane may still be
# running or may have been killed between work and its end write.
if [ -s "$log" ] && command -v jq >/dev/null; then
  orphan_runs="$(jq -r -s '
    ([.[] | select(.event == "start") |
      ((.run // "") | tostring | split("/") | last)] | map(select(length > 0)) | unique) as $starts |
    ([.[] | select((has("event") | not) or .event == "end") |
      ((.run // "") | tostring | split("/") | last)] | map(select(length > 0)) | unique) as $ends |
    ($starts - $ends)[]
  ' "$log" 2>/dev/null)"
  while IFS= read -r orphan; do
    [ -n "$orphan" ] || continue
    orphan_lane="$(jq -r --arg r "$orphan" -s '
      [.[] | select(.event == "start" and ((.run // "" | tostring | split("/") | last) == $r)) | .lane] | last // ""
    ' "$log" 2>/dev/null)"
    say_bad "orphan dispatch $orphan ($orphan_lane lane)"
    status_out="$(bash "$(dirname "$0")/lane-status.sh" --dir "$DIR" "$orphan" 2>&1)"; status_rc=$?
    if [ "$status_rc" -eq 0 ]; then
      echo "         lane in flight — consult lane-status.sh before concluding"
    else
      echo "         lane killed mid-write — consult lane-status.sh before concluding"
    fi
    echo "$status_out" | sed 's/^/         /'
  done <<<"$orphan_runs"
fi

# --- 1. implements that were never graded -------------------------------------
if [ -s "$log" ] && command -v jq >/dev/null; then
  last_review="$(last_ends | jq -r 'select(.lane=="review" and .rc==0) | .ts' | sort | tail -1)"
  if [ -n "$last_review" ]; then
    ungraded="$(last_ends | jq -r --arg t "$last_review" \
      'select(.lane=="implement" and .rc==0 and .ts > $t) | .ts' | wc -l)"
  else
    ungraded="$(last_ends | jq -r 'select(.lane=="implement" and .rc==0) | .ts' | wc -l)"
  fi
  impl="$(last_ends | jq -r 'select(.lane=="implement") | .ts' | wc -l)"
  revs="$(last_ends | jq -r 'select(.lane=="review") | .ts' | wc -l)"
  if [ "${ungraded:-0}" -gt 0 ]; then
    say_bad "$ungraded implement dispatch(es) never reviewed (repo total: $impl implements, $revs reviews)"
    echo "         the isolated reviewer is the point of this plugin; run codex-reviewer against the plan"
  else
    if [ "${revs:-0}" -eq 0 ] && [ "${impl:-0}" -gt 0 ]; then
      say_ok "no successful implement awaiting review ($impl implement dispatch(es), all failed)"
    elif [ "${impl:-0}" -gt 0 ]; then
      say_ok "every implement has a later review ($impl implements, $revs reviews)"
    fi
  fi
else
  say_ok "no dispatch log yet — nothing to grade"
fi

fallback_cutoff="$(date -u -d '-7 days' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')"
if [ -s "$log" ] && command -v jq >/dev/null; then
  while IFS= read -r fallback_note; do
    [ -n "$fallback_note" ] || continue
    say_ok "$fallback_note"
  done < <(last_ends | jq -r --arg c "$fallback_cutoff" '
    select(.fallback_from != null and ($c == "" or .ts >= $c)) |
    "fallback \(.run): rescued by \(.engine) after \(.fallback_from) rc=\(.primary_rc)"
  ')
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
  out="$("$us" "$DIR" 2>&1)"; urc=$?
  case "$urc" in
    0) ;;
    2) say_bad "changes from a lane that was cut short — verify with green.sh and codex-reviewer, then keep or revert" ;;
    3) say_bad "an orphaned implement lane may own working-tree changes — census before discarding" ;;
    *) say_bad "working-tree changes that no dispatch produced — discard them whole" ;;
  esac
  [ "$urc" -ne 0 ] && echo "$out" | sed -n '1,2p' | sed 's/^/         /'
  true
fi

# --- 3. runs left open --------------------------------------------------------
open=0
for d in "$DIR"/.charles/runs/*/; do
  [ -f "$d/RUN.md" ] || continue
  grep -q '^## Outcome' "$d/RUN.md" 2>/dev/null && continue
  run_id="$(basename "${d%/}")"
  flow="$(sed -n 's/^- flow: //p' "$d/RUN.md" | head -1)"
  phase="$(last_phase "$d/RUN.md")"
  phase_label="${phase:-"(none)"}"
  if [ "$flow_graph" -eq 1 ] && flow_ready "$flow"; then
      if [ -z "$phase" ]; then
        say_ok "run $run_id: last phase: (none) | expected next: $(flow_first "$flow")"
      else
        canonical="$(flow_match "$flow" "$phase")"
        if [ -z "$canonical" ]; then
          echo "  NOTE   run $run_id: last phase: $phase | expected next: (unmapped)"
        else
          expected="$(flow_next "$flow" "$canonical")"
          if jq -e --arg f "$flow" --arg p "$canonical" '.[$f].terminal | index($p) != null' "$FLOW_FILE" >/dev/null 2>&1; then
            say_ok "run $run_id: last phase: $phase | expected next: $expected"
          else
            say_bad "run $run_id: last phase: $phase | expected next: $expected — died mid-flow at $canonical"
          fi
        fi
      fi
  else
    echo "  NOTE   run $run_id: last phase: $phase_label | expected next: (no guidance)"
  fi
  [ -n "$CLOSING" ] && [ "${d%/}" = "${CLOSING%/}" ] || open=$((open+1))
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

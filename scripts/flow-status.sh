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
if [ -n "$CLOSING" ]; then
  case "$CLOSING" in /*) ;; *) CLOSING="$DIR/$CLOSING" ;; esac
  CLOSING="${CLOSING%/}"
fi
log="$DIR/.charles/dispatches.jsonl"
FLOW_FILE="$(dirname "$0")/flow.json"
issues=0
repo_issues=0

iso_timestamp_re='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
closing_started=""
closing_spec=""
attribution_degraded=0
attribution_reason=""
if [ -n "$CLOSING" ]; then
  if [ ! -r "$CLOSING/RUN.md" ]; then
    attribution_degraded=1
    attribution_reason="closing run RUN.md is missing or unreadable"
  else
    closing_started="$(sed -n 's/^- started: //p' "$CLOSING/RUN.md" | head -1)"
    closing_spec="$(sed -n 's/^- spec: //p' "$CLOSING/RUN.md" | head -1)"
    if [ -z "$closing_started" ]; then
      attribution_degraded=1
      attribution_reason="closing run RUN.md has no '- started:' line"
    elif [[ ! "$closing_started" =~ $iso_timestamp_re ]]; then
      attribution_degraded=1
      attribution_reason="closing run '- started:' is not an ISO timestamp"
    fi
  fi
fi

paths_match() {
  local left="${1%/}" right="${2%/}" left_key right_key
  [ "$left" = "$right" ] && return 0
  if ! command -v realpath >/dev/null 2>&1; then
    attribution_degraded=1
    attribution_reason="realpath is unavailable for non-identical path attribution"
    return 0
  fi
  case "$left" in /*) ;; *) left="$DIR/$left" ;; esac
  case "$right" in /*) ;; *) right="$DIR/$right" ;; esac
  left_key="$(realpath -m "$left" 2>/dev/null)" || left_key=""
  right_key="$(realpath -m "$right" 2>/dev/null)" || right_key=""
  if [ -z "$left_key" ] || [ -z "$right_key" ]; then
    attribution_degraded=1
    attribution_reason="realpath could not canonicalize paths for attribution"
    return 0
  fi
  [ "$left_key" = "$right_key" ]
}

dispatch_is_attributable() {
  [ -z "$CLOSING" ] || [ "$attribution_degraded" -eq 1 ] || {
    [ -n "${1:-}" ] && { [ "$1" = "$closing_started" ] || [[ "$1" > "$closing_started" ]]; }
  }
}

spec_is_attributable() {
  local spec="$1"
  [ -z "$CLOSING" ] || [ "$attribution_degraded" -eq 1 ] || {
    [ "$spec" = "$closing_spec" ] && return 0
    [ -n "$closing_spec" ] || return 0
    paths_match "$spec" "$closing_spec"
  }
}

run_is_closing() {
  [ -z "$CLOSING" ] && return 0
  [ "$attribution_degraded" -eq 1 ] && return 0
  [ "${1%/}" = "${CLOSING%/}" ] && return 0
  paths_match "$1" "$CLOSING"
}

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
say_repo() { echo "  NOTE   repo backlog (not this close): $1"; repo_issues=$((repo_issues+1)); }
run_is_closed() { grep -q '^## Outcome' "$1" 2>/dev/null; }
run_is_abandoned() { grep -q '^## Abandoned$' "$1" 2>/dev/null; }

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
    orphan_ts="$(jq -r --arg r "$orphan" -s '
      [.[] | select(.event == "start" and ((.run // "" | tostring | split("/") | last) == $r)) | .ts] | last // ""
    ' "$log" 2>/dev/null)"
    status_out="$(bash "$(dirname "$0")/lane-status.sh" --dir "$DIR" "$orphan" 2>&1)"; status_rc=$?
    # Keep RUNNING visible as an ISSUE because doctor.sh only forwards ISSUE
    # lines. UNKNOWN remains an unresolved orphan candidate, never a dead lane.
    case "$status_rc" in
      0)
        finding="RUNNING dispatch $orphan ($orphan_lane lane)"
        detail="lane in flight — consult lane-status.sh before concluding"
        ;;
      1)
        finding="completed dispatch $orphan ($orphan_lane lane; terminal dispatch record missing)"
        detail="lane completed but its terminal dispatch record is missing — consult lane-status.sh before concluding"
        ;;
      2)
        finding="orphan dispatch $orphan ($orphan_lane lane)"
        detail="lane killed mid-write — consult lane-status.sh before concluding"
        ;;
      3|*)
        finding="orphan dispatch $orphan ($orphan_lane lane; liveness UNKNOWN)"
        detail="lane liveness is unknown — consult lane-status.sh before concluding"
        ;;
    esac
    if dispatch_is_attributable "$orphan_ts"; then
      say_bad "$finding"
    else
      say_repo "$finding"
    fi
    echo "         $detail"
    echo "$status_out" | sed 's/^/         /'
  done <<<"$orphan_runs"
fi

# --- 1. implements that were never graded -------------------------------------
impl=0
revs=0
ungraded=0
if [ -s "$log" ] && command -v jq >/dev/null; then
  last_review="$(last_ends | jq -r 'select(.lane=="review" and .rc==0) | .ts' | sort | tail -1)"
  impl="$(last_ends | jq -r 'select(.lane=="implement") | .ts' | wc -l)"
  revs="$(last_ends | jq -r 'select(.lane=="review") | .ts' | wc -l)"
  ungraded_close=0
  ungraded_repo=0
  # ponytail: O(implements × reviews); index the log if its size makes this slow.
  while IFS= read -r dispatch_ts; do
    if dispatch_is_attributable "$dispatch_ts"; then
      ungraded_close=$((ungraded_close+1))
    else
      ungraded_repo=$((ungraded_repo+1))
    fi
  done < <(last_ends | jq -r -s --arg t "$last_review" '
    . as $all
    | [ $all[] | select(.lane == "review" and .rc == 0) ] as $reviews
    | $all[]
    | select(.lane == "implement" and .rc == 0)
    | . as $implement
    | select(
        if (($implement.flow_run_id // "") != "" or ($implement.spec_path // "") != "") then
          ([ $reviews[]
             | select((.ts // "") > ($implement.ts // ""))
             | select(
                 ((.flow_run_id // "") != "" and ($implement.flow_run_id // "") != "" and .flow_run_id == $implement.flow_run_id)
                 or
                 ((.spec_path // "") != "" and ($implement.spec_path // "") != "" and .spec_path == $implement.spec_path)
               )
           ] | length) == 0
        else
          ($t == "" or .ts > $t)
        end
      )
    | .ts // ""
  ')
  ungraded=$((ungraded_close + ungraded_repo))
  if [ "${ungraded:-0}" -gt 0 ]; then
    [ "$ungraded_close" -eq 0 ] || say_bad "$ungraded_close implement dispatch(es) never reviewed (repo total: $impl implements, $revs reviews)"
    [ "$ungraded_repo" -eq 0 ] || say_repo "$ungraded_repo implement dispatch(es) never reviewed (repo total: $impl implements, $revs reviews)"
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
  if [ -z "$CLOSING" ]; then
    if [ "$graded" -eq 0 ]; then
      say_bad "$specs plan(s), none carrying a grill verdict — plans went to implementation unchallenged"
    elif [ "$graded" -lt "$specs" ]; then
      say_bad "$((specs - graded)) of $specs plan(s) have no grill verdict"
    else
      say_ok "all $specs plan(s) carry a grill verdict"
    fi
  else
    closing_missing=0
    repo_missing=0
    while IFS= read -r spec; do
      [ -f "$spec" ] || continue
      grep -q 'Grill verdict' "$spec" 2>/dev/null && continue
      if spec_is_attributable "$spec"; then
        closing_missing=$((closing_missing+1))
      else
        repo_missing=$((repo_missing+1))
      fi
    done < <(printf '%s\n' "$DIR"/docs/specs/*.md)
    if [ "$closing_missing" -gt 0 ]; then
      say_bad "$closing_missing plan(s) have no grill verdict — the closing run's spec is unchallenged"
    fi
    if [ "$repo_missing" -gt 0 ]; then
      say_repo "$repo_missing plan(s) have no grill verdict"
    fi
    [ "$graded" -eq "$specs" ] && say_ok "all $specs plan(s) carry a grill verdict"
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
  run_id="$(basename "${d%/}")"
  if run_is_closed "$d/RUN.md"; then
    run_is_abandoned "$d/RUN.md" && say_ok "run $run_id: ABANDONED"
    continue
  fi
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
            if run_is_closing "$d"; then
              say_bad "run $run_id: last phase: $phase | expected next: $expected — died mid-flow at $canonical"
            else
              say_repo "run $run_id: last phase: $phase | expected next: $expected — died mid-flow at $canonical"
            fi
          fi
        fi
      fi
  else
    echo "  NOTE   run $run_id: last phase: $phase_label | expected next: (no guidance)"
  fi
  if [ -n "$CLOSING" ] && run_is_closing "$d" && [ "$attribution_degraded" -eq 0 ]; then
    :
  else
    open=$((open+1))
  fi
done
if [ "$open" -gt 0 ]; then
  if [ -n "$CLOSING" ] && [ "$attribution_degraded" -eq 0 ]; then
    say_repo "$open run(s) still open — resume with /charlesdr-dev-loop:resolve, or close them"
  else
    say_bad "$open run(s) still open — resume with /charlesdr-dev-loop:resolve, or close them"
  fi
else
  say_ok "no runs left open"
fi

echo
if [ "$attribution_degraded" -eq 1 ]; then
  echo "  WARN   attribution degraded: $attribution_reason; every finding blocks this close"
fi
if [ "$repo_issues" -gt 0 ]; then
  echo "$repo_issues repo backlog finding(s) — use /charlesdr-dev-loop:resolve; audit with runs-sweep.sh"
fi
if [ "$issues" -eq 0 ]; then echo "flow complete: nothing outstanding"; exit 0; fi
echo "$issues outstanding — a dispatch succeeding is not a flow finishing"
exit 1

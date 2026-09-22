#!/usr/bin/env bash
# claude-lane-receipt.sh — PostToolUse on Agent|Task.
#
# codex-run.sh's engine=claude hand-off logs a "start" event and exits before
# any work happens (see spawn_claude_lane / run_review in codex-run.sh) — the
# work happens in a spawned plugin subagent instead. Reaching PostToolUse means
# that subagent returned, so this is the only place its "end" event can be
# written: append it, matching log_dispatch's schema, so verify-receipt.sh,
# flow-status.sh and lane-status.sh keep working unchanged.
#
# Matched by SUFFIX, not exact name: plugin agents spawn namespaced
# (charlesdr-dev-loop:claude-explorer), same reason route-subagents.sh walks
# suffixes instead of comparing names directly.
#
# rc is always 0 here: PostToolUse firing means the tool call itself completed,
# not that the lane's own work succeeded — that judgment is the review's job.
# A spawn that never completes (killed, crashed) leaves a start with no end;
# verify-receipt.sh reports that as exit 3, which is the documented outcome.
#
# Contract: JSON on stdout, exit 0. Silence = no opinion.

set -euo pipefail

payload="$(cat)"
command -v jq >/dev/null || exit 0

tool="$(jq -r '.tool_name // empty' <<<"$payload")"
case "$tool" in Agent|Task) ;; *) exit 0 ;; esac

sub="$(jq -r '.tool_input.subagent_type // empty' <<<"$payload")"
lane="" model=""
case "$sub" in
  *claude-explorer)    lane=explore;   model=haiku ;;
  *claude-implementer) lane=implement; model=sonnet ;;
  *claude-reviewer)    lane=review;    model=opus ;;
  *) exit 0 ;;
esac

prompt="$(jq -r '.tool_input.prompt // empty' <<<"$payload")"

# The reviewer's box is scratch: delete it whether or not a receipt follows.
if [ "$lane" = "review" ]; then
  # Only ever a charles-review.* dir directly under the temp root: the prompt
  # passes through the orchestrator, so its path is not trusted on its own.
  box="$(sed -n 's/^charles-box: //p' <<<"$prompt" | head -1)"
  box="$(realpath -m "$box" 2>/dev/null || true)"
  tmp="$(realpath -m "${TMPDIR:-/tmp}")"
  case "$box" in "$tmp"/charles-review.*/*|"$tmp"/charles-review.*/) box="" ;; esac
  case "$box" in "$tmp"/charles-review.*) [ -f "$box/.charles-review-box" ] && rm -rf "$box" ;; esac
fi

run_id="$(sed -n 's/^charles-run: //p' <<<"$prompt" | head -1)"
dir="$(sed -n 's/^charles-dir: //p' <<<"$prompt" | head -1)"
[ -n "$run_id" ] && [ -n "$dir" ] || exit 0

log="$dir/.charles/dispatches.jsonl"
[ -s "$log" ] || exit 0

# Already logged? PostToolUse should fire once per call, but do not double-append.
if jq -e --arg r "$run_id" \
     'select(.event == "end" and .run == $r and .engine == "claude")' \
     "$log" >/dev/null 2>&1; then
  exit 0
fi

start_record="$(jq -c --arg r "$run_id" --arg l "$lane" \
  'select(.event == "start" and .run == $r and .lane == $l)' "$log" 2>/dev/null | tail -1)"
[ -n "$start_record" ] || exit 0

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq -c --arg ts "$now" --arg model "$model" \
  '.ts = $ts | .event = "end" | .engine = "claude" | .model = $model | .rc = 0' \
  <<<"$start_record" >> "$log" 2>/dev/null || exit 0

exit 0

#!/usr/bin/env bash
# claude-review-box.sh — PreToolUse, matcher ".*" (every tool).
#
# claude-reviewer's isolation ("it cannot see anything else") is enforced
# here, not by asking nicely in its prompt: deny every tool but Read/Grep/Glob,
# and deny those too unless every path they name resolves inside a directory
# that holds a .charles-review-box marker — the marker codex-run.sh writes into
# the box before naming it in the SPAWN prompt (see run_review in codex-run.sh).
#
# Matched by SUFFIX: plugin agents spawn namespaced
# (charlesdr-dev-loop:claude-reviewer). Only fires inside that subagent —
# .agent_type is absent for the main thread and for every other agent.
#
# Contract: JSON on stdout, exit 0. Silence = allow.

set -euo pipefail

payload="$(cat)"
command -v jq >/dev/null || exit 0

agent_type="$(jq -r '.agent_type // empty' <<<"$payload")"
case "$agent_type" in *claude-reviewer) ;; *) exit 0 ;; esac

deny() {
  jq -nc --arg r "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

tool="$(jq -r '.tool_name // empty' <<<"$payload")"
case "$tool" in
  Read|Grep|Glob) ;;
  *) deny "claude-reviewer is isolated to its review box: only Read, Grep and Glob are allowed." ;;
esac

# A box is a charles-review.* dir directly under the temp root (where
# codex-run.sh's mktemp puts it) holding the marker. A marker anywhere else —
# $HOME, a worktree — unlocks nothing. A path that does not resolve or does
# not exist is a miss: "a missing path is denied".
in_box() {
  local p="$1" resolved tmp box
  [ -n "$p" ] || return 1
  resolved="$(realpath -m "$p" 2>/dev/null)" || return 1
  [ -e "$resolved" ] || return 1
  tmp="$(realpath -m "${TMPDIR:-/tmp}")"
  case "$resolved" in "$tmp"/charles-review.*) ;; *) return 1 ;; esac
  box="${resolved#"$tmp"/}"; box="$tmp/${box%%/*}"
  [ -f "$box/.charles-review-box" ]
}

# file_path (Read), path (Grep/Glob), and an absolute glob pattern (Glob) are
# the only fields that name a filesystem location; every one present must
# resolve inside the box. A relative Glob pattern is confined by its
# (checked) path, as long as it has no '..' segment.
paths=()
case "$tool" in
  Read) paths+=("$(jq -r '.tool_input.file_path // empty' <<<"$payload")") ;;
  Grep) paths+=("$(jq -r '.tool_input.path // empty' <<<"$payload")") ;;
  Glob)
    paths+=("$(jq -r '.tool_input.path // empty' <<<"$payload")")
    pattern="$(jq -r '.tool_input.pattern // empty' <<<"$payload")"
    case "$pattern" in /*) paths+=("$pattern") ;; esac
    case "/$pattern/" in */../*) deny "claude-reviewer: glob pattern '$pattern' climbs out of its review box." ;; esac
    ;;
esac

for p in "${paths[@]}"; do
  in_box "$p" || deny "claude-reviewer: '$p' is outside its review box (or missing)."
done

exit 0

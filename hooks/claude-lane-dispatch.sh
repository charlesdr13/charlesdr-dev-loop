#!/usr/bin/env bash
# claude-lane-dispatch.sh — PreToolUse on Agent|Task.
#
# 2.41.0 moved engine=claude onto plugin subagents: codex-run.sh --engine claude
# runs nothing itself, it prints a SPAWN block (agent name + rewritten prompt)
# to stdout and exits (see spawn_claude_lane / run_review in codex-run.sh).
# Before this hook, the orchestrator ran that in Bash, read the block, and
# spawned the agent by hand — two steps, and the copy-paste is where things
# drift. This hook collapses it to one Agent call: it recognises a plain
# dispatch prompt aimed at one of the three claude-lane agents, runs
# codex-run.sh itself, and rewrites the call in place via updatedInput. The
# two-step SPAWN path still works unchanged — a prompt that already carries a
# charles-run: header is that path's output (or this hook's own, met twice)
# and passes through untouched, silently.
#
# Matched by SUFFIX, not exact name, same reason route-subagents.sh and
# claude-lane-receipt.sh do: plugin agents spawn namespaced
# (charlesdr-dev-loop:claude-explorer).
#
# Contract: JSON on stdout, exit 0. Silence = no opinion.

set -euo pipefail

payload="$(cat)"
command -v jq >/dev/null || exit 0

tool="$(jq -r '.tool_name // empty' <<<"$payload")"
case "$tool" in Agent|Task) ;; *) exit 0 ;; esac

sub="$(jq -r '.tool_input.subagent_type // empty' <<<"$payload")"
lane=""
case "$sub" in
  *claude-explorer)    lane=explore ;;
  *claude-implementer) lane=implement ;;
  *claude-reviewer)    lane=review ;;
  *) exit 0 ;;
esac

prompt="$(jq -r '.tool_input.prompt // empty' <<<"$payload")"

# --- parse leading charles-*: headers; charles-run means "already dispatched" -
cl_dir="" cl_plan="" cl_req="" cl_base="" cl_unknown="" cl_legacy=0
mapfile -t cl_lines <<<"$prompt"
cl_n=${#cl_lines[@]}
cl_i=0
while [ "$cl_i" -lt "$cl_n" ]; do
  cl_line="${cl_lines[$cl_i]}"
  if [[ "$cl_line" =~ ^charles-([a-zA-Z0-9_-]+):[[:space:]]*(.*)$ ]]; then
    cl_key="${BASH_REMATCH[1]}"; cl_val="${BASH_REMATCH[2]}"
    case "$cl_key" in
      run)  cl_legacy=1 ;;
      dir)  cl_dir="$cl_val" ;;
      plan) cl_plan="$cl_val" ;;
      req)  cl_req="$cl_val" ;;
      base) cl_base="$cl_val" ;;
      *) [ -n "$cl_unknown" ] || cl_unknown="charles-$cl_key" ;;
    esac
    cl_i=$((cl_i+1))
  else
    break
  fi
done
[ "$cl_legacy" -eq 0 ] || exit 0

# --- opt-in gate: .charles.toml at or above the target dir --------------------
cwd="$(jq -r '.cwd // empty' <<<"$payload")"
[ -n "$cwd" ] || cwd="$PWD"
dir="${cl_dir:-$cwd}"
case "$dir" in /*) ;; *) dir="$cwd/$dir" ;; esac   # relative to the session, not this hook
dir="$(realpath -m "$dir" 2>/dev/null || echo "$dir")"
root=""
d="$dir"
while [ -n "$d" ] && [ "$d" != "/" ]; do
  if [ -f "$d/.charles.toml" ]; then root="$d"; break; fi
  parent="$(dirname "$d")"
  [ "$parent" = "$d" ] && break     # no progress: stop rather than spin
  d="$parent"
done
[ -n "$root" ] || exit 0

if [ -n "$cl_unknown" ]; then
  jq -nc --arg r "unknown header '$cl_unknown:' — recognised: charles-dir, charles-plan, charles-req, charles-base" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
fi

# --- task: everything after the header block, leading blank lines trimmed -----
cl_task_lines=("${cl_lines[@]:$cl_i}")
while [ "${#cl_task_lines[@]}" -gt 0 ] && [ -z "${cl_task_lines[0]}" ]; do
  cl_task_lines=("${cl_task_lines[@]:1}")
done
task="$(printf '%s\n' "${cl_task_lines[@]}")"

# a relative charles-plan resolves against the target dir, not the hook's cwd
plan="$cl_plan"
[ -z "$plan" ] || case "$plan" in /*) ;; *) plan="$dir/$plan" ;; esac

# --- resolve the plugin root from this hook's own path -------------------------
hook_dir="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd -P)"
plugin_root="$(dirname "$hook_dir")"

args=(--lane "$lane" --engine claude --dir "$dir")
[ -z "$plan" ]    || args+=(--plan "$plan")
[ -z "$cl_req" ]  || args+=(--req "$cl_req")
[ -z "$cl_base" ] || args+=(--base "$cl_base")

err_file="$(mktemp)"
rc=0
out="$("$plugin_root/scripts/codex-run.sh" "${args[@]}" -- "$task" 2>"$err_file")" || rc=$?
err="$(cat "$err_file" 2>/dev/null)"
rm -f "$err_file"

if [ "$rc" -ne 0 ]; then
  reason="$(tail -20 <<<"$err")"
  [ -n "$reason" ] || reason="codex-run.sh exited $rc with no message"
  jq -nc --arg r "$reason" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
fi

new_prompt="$(sed -n '/^PROMPT:$/,$p' <<<"$out" | sed '1d')"
if [ -z "$new_prompt" ]; then
  jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"codex-run printed no SPAWN prompt; not spawning a lane with an empty brief"}}'
  exit 0
fi

jq -c --arg p "$new_prompt" \
  '.tool_input.prompt = $p | {hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",updatedInput:.tool_input}}' \
  <<<"$payload"
exit 0

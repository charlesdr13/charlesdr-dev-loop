#!/usr/bin/env bash
# route-subagents.sh — PreToolUse gate on subagent spawning.
#
# The edit hook stops Claude typing code itself. This stops Claude handing the
# same work to one of ITS OWN subagents, which is the same bypass wearing a hat:
# a general-purpose agent exploring the repo is exactly the dispatch that was
# supposed to go to a codex lane.
#
# Denylist, not allowlist: only agents that do repo code work are challenged.
# The google-drive agent, claude-code-guide, statusline-setup and friends are
# none of this hook's business.
#
# Contract: JSON on stdout, exit 0. Silence = allow.

set -euo pipefail

payload="$(cat)"
command -v jq >/dev/null || exit 0

tool="$(jq -r '.tool_name // empty' <<<"$payload")"
case "$tool" in Agent|Task) ;; *) exit 0 ;; esac

[ "${CHARLES_INLINE_OK:-0}" = "1" ] && exit 0

# --- opt-in gate: .charles.toml at or above cwd -------------------------------
cwd="$(jq -r '.cwd // empty' <<<"$payload")"
[ -n "$cwd" ] || cwd="$PWD"
cwd="$(realpath -m "$cwd" 2>/dev/null || echo "$cwd")"
root=""
d="$cwd"
while [ -n "$d" ] && [ "$d" != "/" ]; do
  if [ -f "$d/.charles.toml" ]; then root="$d"; break; fi
  parent="$(dirname "$d")"
  [ "$parent" = "$d" ] && break     # no progress: stop rather than spin
  d="$parent"
done
[ -n "$root" ] || exit 0

sub="$(jq -r '.tool_input.subagent_type // empty' <<<"$payload")"
[ -n "$sub" ] || exit 0

# Already the right thing: these ARE the codex lanes.
case "$sub" in codex-explorer|codex-implementer|codex-reviewer) exit 0 ;; esac

# Agents that do repo code work, and therefore belong on a lane.
case "$sub" in
  Explore|general-purpose|Plan|claude|feature-dev:*|python-pro|node-specialist|\
  sql-pro|api-designer|cli-developer|test-automator|docker-expert|mcp-developer|\
  security-auditor|dashboard-modernizer) ;;
  *) exit 0 ;;
esac

case "$sub" in
  Explore|Plan|general-purpose|claude|feature-dev:code-explorer)
    alt="codex-explorer (lane: explore, gpt-5.6-luna @ max, read-only)" ;;
  feature-dev:code-reviewer)
    alt="codex-reviewer (lane: review, isolated — it cannot see the implementer)" ;;
  *)
    alt="codex-implementer (lane: implement, gpt-5.6-luna @ max)" ;;
esac

jq -nc --arg r "This repo routes code work to a codex lane, and '$sub' is not one. Spawn $alt instead. Approve only if this genuinely is not repo code work — reading docs, a non-code lookup, or a one-off question. Bypass the session with CHARLES_INLINE_OK=1." \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
exit 0

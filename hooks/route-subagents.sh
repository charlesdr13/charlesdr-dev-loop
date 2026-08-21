#!/usr/bin/env bash
# route-subagents.sh — PreToolUse gate on subagent spawning.
#
# The edit hook stops Claude typing code itself. This stops Claude handing the
# same work to one of ITS OWN subagents, which is the same bypass wearing a hat:
# a general-purpose agent exploring the repo belongs in a direct codex lane.
#
# Denylist, not allowlist: only agents that do repo code work are challenged.
# The google-drive agent, claude-code-guide, statusline-setup and friends are
# none of this hook's business.
#
# An approved inline block is honoured here too, but on a SHORTER clock than the
# edit gate: spawning the wrong agent is the expensive mistake this plugin exists
# to catch (a feature-dev explorer burns Claude quota where a codex explore lane
# costs cents), so the grant covers a burst of related spawns and then re-arms.
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

# --- honour a fresh inline-edit approval, briefly -----------------------------
cfg() { # cfg KEY DEFAULT  — read `key = value` from .charles.toml
  local v; v="$(grep -oE "^[[:space:]]*$1[[:space:]]*=[[:space:]]*[0-9]+" "$root/.charles.toml" 2>/dev/null | grep -oE '[0-9]+$' | head -1)"
  printf '%s' "${v:-$2}"
}
ok_minutes="${CHARLES_SUBAGENT_OK_MINUTES:-$(cfg subagent_ok_minutes 10)}"
ok="$root/.charles/inline-ok"
if [ -f "$ok" ] && [ -z "$(find "$ok" -mmin "+$ok_minutes" 2>/dev/null)" ]; then
  exit 0
fi

sub="$(jq -r '.tool_input.subagent_type // empty' <<<"$payload")"
[ -n "$sub" ] || exit 0

# Review keeps its isolated agent; explore and implement use direct dispatch.
case "$sub" in codex-reviewer) exit 0 ;; esac

# Agents that do repo code work, and therefore belong on a lane.
case "$sub" in
  Explore|general-purpose|Plan|claude|feature-dev:*|python-pro|node-specialist|\
  sql-pro|api-designer|cli-developer|test-automator|docker-expert|mcp-developer|\
  security-auditor|dashboard-modernizer) ;;
  *) exit 0 ;;
esac

case "$sub" in
  Explore|Plan|general-purpose|claude|feature-dev:code-explorer)
    alt='codex-run --lane explore --dir <repo> --timeout 1800 "<task>" (Bash with run_in_background: true)' ;;
  feature-dev:code-reviewer)
    alt="codex-reviewer (lane: review, isolated — it cannot see the implementer)" ;;
  *)
    alt='codex-run --lane implement --dir <repo> --timeout 1800 "<task>" (Bash with run_in_background: true)' ;;
esac

# PostToolUse turns this into inline-ok if the spawn actually happens (= approved).
mkdir -p "$root/.charles" 2>/dev/null || true
printf '%s\n' "agent:$sub" > "$root/.charles/pending-ask" 2>/dev/null || true

jq -nc --arg r "This repo routes code work to a codex lane, and '$sub' is not one. Spawn $alt instead. Approve only if this genuinely is not repo code work — reading docs, a non-code lookup, or a one-off question. Bypass the session with CHARLES_INLINE_OK=1." \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
exit 0

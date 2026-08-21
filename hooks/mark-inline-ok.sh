#!/usr/bin/env bash
# mark-inline-ok.sh — PostToolUse on Edit|Write|MultiEdit.
#
# route-to-codex.sh drops .charles/pending-ask naming the file it asked about.
# Reaching this hook means the edit LANDED, so the human said yes. Convert the
# pending marker into .charles/inline-ok and the gate goes quiet for
# inline_ok_minutes (default 60) — approval is remembered instead of re-asked
# on every subsequent edit.
#
# Cleared by a successful codex-run dispatch, same as the touched counter.
#
# Contract: JSON on stdout, exit 0. Silence (exit 0, no output) = no opinion.

set -euo pipefail

payload="$(cat)"
command -v jq >/dev/null || exit 0

tool="$(jq -r '.tool_name // empty' <<<"$payload")"
case "$tool" in Edit|Write|MultiEdit|Agent|Task) ;; *) exit 0 ;; esac

# Edits key off the file; spawns key off the agent type, and locate the repo
# through cwd. Both write the same grant — approving either says "I am doing this
# by hand for now", and the gate should stop asking for the rest of the block.
case "$tool" in
  Agent|Task)
    key="agent:$(jq -r '.tool_input.subagent_type // empty' <<<"$payload")"
    [ "$key" != "agent:" ] || exit 0
    anchor="$(jq -r '.cwd // empty' <<<"$payload")"
    [ -n "$anchor" ] || anchor="$PWD"
    ;;
  *)
    key="$(jq -r '.tool_input.file_path // empty' <<<"$payload")"
    [ -n "$key" ] || exit 0
    key="$(realpath -m "$key" 2>/dev/null || printf '%s' "$key")"
    anchor="$(dirname "$key")"
    ;;
esac
anchor="$(realpath -m "$anchor" 2>/dev/null || printf '%s' "$anchor")"

root=""
d="$anchor"
while [ -n "$d" ] && [ "$d" != "/" ]; do
  if [ -f "$d/.charles.toml" ]; then root="$d"; break; fi
  parent="$(dirname "$d")"
  [ "$parent" = "$d" ] && break
  d="$parent"
done
[ -n "$root" ] || exit 0

pending="$root/.charles/pending-ask"
[ -f "$pending" ] || exit 0

# The key must match, and the marker must be minutes old at most. A DENIED ask
# leaves the marker behind (PostToolUse never fires), so without both guards a
# later unrelated edit or spawn would cash in an approval that never happened.
[ "$(cat "$pending" 2>/dev/null)" = "$key" ] || exit 0
[ -z "$(find "$pending" -mmin +5 2>/dev/null)" ] || { rm -f "$pending"; exit 0; }

rm -f "$pending"
: > "$root/.charles/inline-ok" 2>/dev/null || true
exit 0

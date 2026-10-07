#!/usr/bin/env bash
# route-to-codex.sh — PreToolUse gate on Edit|Write|MultiEdit.
#
# Big change in an opted-in repo -> "ask", with a reason telling Claude to
# dispatch the implement lane directly. Small change -> silent allow.
#
# Opt-in is per repo: this does nothing unless a .charles.toml exists at or
# above the edited file. Known hole: writes via Bash (sed -i, heredocs) are not
# intercepted. Accepted deliberately — matching Bash would fire on every
# `bun test > out.log` and the hook would be off within a day.
#
# Approving an ask is remembered: mark-inline-ok.sh (PostToolUse) converts the
# pending marker this hook drops into .charles/inline-ok, which suppresses further
# asks for inline_ok_minutes. Without that, nfiles only ever grows and every edit
# for the next hour re-asks — the gate stops being a gate and becomes a nag.
#
# Contract: JSON on stdout, exit 0. Silence (exit 0, no output) = allow.

set -euo pipefail

payload="$(cat)"
command -v jq >/dev/null || exit 0

tool="$(jq -r '.tool_name // empty' <<<"$payload")"
case "$tool" in Edit|Write|MultiEdit) ;; *) exit 0 ;; esac

[ "${CHARLES_INLINE_OK:-0}" = "1" ] && exit 0

path="$(jq -r '.tool_input.file_path // empty' <<<"$payload")"
[ -n "$path" ] || exit 0

# --- opt-in gate: walk up for .charles.toml -----------------------------------
# realpath first: a relative path makes dirname "." return "." forever and the
# walk never terminates. Confirmed hanging at rc 124 before this line existed.
path="$(realpath -m "$path" 2>/dev/null || echo "$path")"

# Claude Code worktrees are managed copies: allow them without touching the
# root repo's inline-edit counter.
case "$path" in
  */.claude/worktrees/*) exit 0 ;;
esac

root=""
d="$(dirname "$path")"
while [ -n "$d" ] && [ "$d" != "/" ]; do
  if [ -f "$d/.charles.toml" ]; then root="$d"; break; fi
  parent="$(dirname "$d")"
  [ "$parent" = "$d" ] && break     # no progress: stop rather than spin
  d="$parent"
done
[ -n "$root" ] || exit 0

# --- code files only ----------------------------------------------------------
case "${path##*.}" in
  ts|tsx|js|jsx|mjs|cjs|py|sh|bash|go|rs|rb|java|kt|c|h|cpp|hpp|cs|php|sql|vue|svelte) ;;
  *) exit 0 ;;
esac

cfg() { # cfg KEY DEFAULT  — read `key = value` from .charles.toml
  local v; v="$(grep -oE "^[[:space:]]*$1[[:space:]]*=[[:space:]]*[0-9]+" "$root/.charles.toml" 2>/dev/null | grep -oE '[0-9]+$' | head -1)"
  echo "${v:-$2}"
}
max_lines="${CHARLES_INLINE_LINES:-$(cfg inline_lines 40)}"
max_files="${CHARLES_INLINE_FILES:-$(cfg inline_files 3)}"
ok_minutes="${CHARLES_INLINE_OK_MINUTES:-$(cfg inline_ok_minutes 60)}"

# --- new files are scaffolding: always allow ----------------------------------
[ -e "$path" ] || exit 0

# --- how many lines does this edit touch? -------------------------------------
lines="$(jq -r '
  def n: if . == null then 0 else (tostring | split("\n") | length) end;
  if .tool_name == "Write" then (.tool_input.content | n)
  elif .tool_name == "Edit" then ([(.tool_input.old_string|n), (.tool_input.new_string|n)] | max)
  else ([.tool_input.edits[]? | [(.old_string|n), (.new_string|n)] | max] | add // 0)
  end' <<<"$payload" 2>/dev/null || echo 0)"
lines="${lines:-0}"

# --- how many distinct files since the last codex dispatch? -------------------
# codex-run.sh truncates this file on a successful dispatch. Stale counters
# (>60min) are discarded so an abandoned session doesn't poison the next one.
mkdir -p "$root/.charles" 2>/dev/null || true

# --- did you already approve inline edits in this block? ----------------------
# Fresh marker -> stay quiet. Checked before the counter is even read, so an
# approved block does not keep tripping a threshold it has already answered for.
ok="$root/.charles/inline-ok"
if [ -f "$ok" ] && [ -z "$(find "$ok" -mmin "+$ok_minutes" 2>/dev/null)" ]; then
  exit 0
fi

touched="$root/.charles/touched"
if [ -f "$touched" ] && [ -n "$(find "$touched" -mmin +60 2>/dev/null)" ]; then : > "$touched"; fi
grep -qxF "$path" "$touched" 2>/dev/null || echo "$path" >> "$touched" 2>/dev/null || true
nfiles="$(sort -u "$touched" 2>/dev/null | grep -c . || echo 0)"

reason=""
if [ "$lines" -ge "$max_lines" ]; then
  reason="This edit touches ~$lines lines (inline_lines=$max_lines)."
elif [ "$nfiles" -ge "$max_files" ]; then
  reason="$nfiles distinct files edited since the last codex dispatch (inline_files=$max_files) — this is a feature, not a tweak."
fi
[ -n "$reason" ] || exit 0

# Nobody can answer an ask in an unattended session (a firstmate crewmate sets
# FM_TASK_ID), so it would hang there; deny instead and let the reason steer.
decision=ask
[ -z "${CHARLES_UNATTENDED:-}${FM_TASK_ID:-}" ] || decision=deny

# PostToolUse turns this into inline-ok if the edit actually lands (= approved).
printf '%s\n' "$path" > "$root/.charles/pending-ask" 2>/dev/null || true

jq -nc --arg r "$reason Dispatch the implement lane via a background Bash call: codex-run --lane implement --dir <repo> --timeout 2700 \"<task>\" (run_in_background: true) instead of editing inline. Approve only if this genuinely is a small local fix. Controls: inline_lines and inline_files in .charles.toml; session bypass: CHARLES_INLINE_OK=1." \
  --arg d "$decision" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
exit 0

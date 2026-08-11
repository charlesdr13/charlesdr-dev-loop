#!/usr/bin/env bash
# lane-status.sh — is a dispatch still alive, finished, or dead?
#
# Agents got stuck for 27 minutes waiting on codex processes that had already
# exited, because they were waiting on a FILE. `.last` is written only on
# success, and a killed dispatch writes nothing at all — so "no file yet" and
# "died ten minutes ago" look identical.
#
# Process liveness is the only answer that is always correct: SIGKILL cannot be
# trapped, so no marker can be guaranteed, but a dead process is unambiguous.
#
#   lane-status.sh              status of the newest dispatch
#   lane-status.sh <run-id>     status of a specific one
#
# exit 0  RUNNING   — genuinely still working, keep waiting (within your cap)
# exit 1  DONE      — finished; the result is on stdout's named file
# exit 2  DEAD      — no process and no result. It is over. Record FAILED.
set -uo pipefail

STATE="${CHARLES_STATE_DIR:-$HOME/.cache/charlesdr-dev-loop}"
run="${1:-}"
if [ -z "$run" ]; then
  newest="$(ls -t "$STATE"/*.jsonl 2>/dev/null | head -1)"
  [ -n "$newest" ] || { echo "DEAD: no dispatch has ever run"; exit 2; }
  run="$(basename "$newest" .jsonl)"
fi
base="$STATE/$run"

# pgrep -f matches this script too, since the run id is our own argument.
# Skip ourselves, our parent, and any other status check.
alive=0
for pid in $(pgrep -f "$run" 2>/dev/null); do
  [ "$pid" = "$$" ] && continue
  [ "$pid" = "${PPID:-0}" ] && continue
  # cat, not a redirect: the process can vanish mid-loop and a redirect would
  # print a shell error we cannot suppress from inside the substitution.
  cmd="$(cat "/proc/$pid/cmdline" 2>/dev/null | tr '\0' ' ')"
  case "$cmd" in *lane-status*) continue ;; esac
  [ -n "$cmd" ] || continue
  alive=1; break
done

if [ "$alive" -eq 1 ]; then
  echo "RUNNING: $run"
  [ -f "$base.jsonl" ] && echo "  transcript is $(du -h "$base.jsonl" 2>/dev/null | cut -f1) and growing"
  echo "  Keep waiting only if you are under your check cap. Never re-dispatch on top of it."
  exit 0
fi

if [ -s "$base.last" ]; then
  echo "DONE: $run"
  echo "  result: $base.last"
  [ -f "$base.done" ] && echo "  exit code: $(cat "$base.done" 2>/dev/null)"
  exit 1
fi

echo "DEAD: $run — no process, no result."
if [ -f "$base.done" ]; then
  rc="$(cat "$base.done" 2>/dev/null)"
  echo "  exit code $rc$([ "$rc" = "124" ] && echo ' (its own --timeout expired)')"
else
  echo "  no exit marker either, so it was SIGKILLed — usually the harness cap."
fi
[ -s "$base.err" ] && { echo "  stderr tail:"; tail -3 "$base.err" | sed 's/^/    /'; }
echo "  This dispatch is over. Record a FAILED item and stop. Do not wait."
exit 2

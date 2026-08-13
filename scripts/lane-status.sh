#!/usr/bin/env bash
# lane-status.sh — is a dispatch still alive, finished, or dead?
#
#   lane-status.sh              status of the newest dispatch in repo context
#   lane-status.sh <run-id>     status of a specific one
#   lane-status.sh --dir <repo> status of the newest run named by that repo
#
# exit 0  RUNNING   — genuinely still working, keep waiting (within your cap)
# exit 1  DONE      — finished; the result is on stdout's named file
# exit 2  DEAD/NONE — no process and no result, or no scoped dispatch exists
set -uo pipefail

STATE="${CHARLES_STATE_DIR:-$HOME/.cache/charlesdr-dev-loop}"
run=""
SCOPE_DIR=""
state_pending=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dir)
      if [ "$#" -lt 2 ] || [ -z "$2" ] || [[ "$2" == -* ]]; then
        echo "usage: $0 [--dir <repo>] [<run-id>]" >&2
        exit 2
      fi
      SCOPE_DIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    -*) echo "lane-status.sh: unknown flag $1" >&2; exit 2 ;;
    *) [ -n "$run" ] || run="$1"; shift ;;
  esac
done

if [ -n "$SCOPE_DIR" ]; then
  [ -d "$SCOPE_DIR" ] || { echo "NONE: no such repo: $SCOPE_DIR"; exit 2; }
  SCOPE_DIR="$(cd "$SCOPE_DIR" && pwd)"
elif [ -z "$run" ]; then
  # A repo context beats the historical global-newest fallback.
  probe="$PWD"
  while :; do
    if [ -d "$probe/.charles" ]; then SCOPE_DIR="$probe"; break; fi
    [ "$probe" = "/" ] && break
    next="$(dirname "$probe")"
    [ "$next" = "$probe" ] && break
    probe="$next"
  done
fi

if [ -n "$SCOPE_DIR" ]; then
  log="$SCOPE_DIR/.charles/dispatches.jsonl"
  if [ ! -s "$log" ]; then
    echo "NONE: $SCOPE_DIR has no dispatch runs recorded"
    exit 2
  fi
  command -v jq >/dev/null || { echo "NONE: jq is required to scope dispatch state"; exit 2; }
  declare -A named
  named_runs=()
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    if [ -z "${named[$candidate]+x}" ]; then named_runs+=("$candidate"); fi
    named["$candidate"]=1
  done < <(jq -r 'select(.run != null and ((has("event") | not) or .event == "start" or .event == "end")) | (.run | tostring | split("/") | last)' "$log" 2>/dev/null | sort -u)
  if [ "${#named_runs[@]}" -eq 0 ]; then
    echo "NONE: $SCOPE_DIR dispatch log names no runs"
    exit 2
  fi
  if [ -n "$run" ]; then
    run="${run##*/}"
    if [ -z "${named[$run]+x}" ]; then
      echo "NONE: run $run is not recorded in $log"
      exit 2
    fi
    if [ ! -f "$STATE/$run.jsonl" ]; then
      if jq -e --arg r "$run" 'select(.event == "start" and ((.run // "") | tostring | split("/") | last) == $r)' "$log" >/dev/null 2>&1; then
        state_pending=1
      else
        echo "NONE: no state file for $run in $STATE"
        exit 2
      fi
    elif [ ! -s "$STATE/$run.jsonl" ]; then
      state_pending=1
    fi
  else
    newest=""; newest_mtime=-1
    for candidate in "${named_runs[@]-}"; do
      state_file="$STATE/$candidate.jsonl"
      [ -f "$state_file" ] || continue
      mtime="$(stat -c %Y "$state_file" 2>/dev/null || echo 0)"
      if [ "$mtime" -gt "$newest_mtime" ]; then
        newest_mtime="$mtime"; newest="$candidate"
      fi
    done
    if [ -z "$newest" ]; then
      newest="$(jq -r 'select(.event == "start") | ((.run // "") | tostring | split("/") | last)' "$log" 2>/dev/null | tail -1)"
      [ -n "$newest" ] || { echo "NONE: no state file for a run recorded by $SCOPE_DIR"; exit 2; }
      state_pending=1
    fi
    run="$newest"
    [ -s "$STATE/$run.jsonl" ] || state_pending=1
  fi
elif [ -z "$run" ]; then
  newest="$(ls -t "$STATE"/*.jsonl 2>/dev/null | head -1)"
  [ -n "$newest" ] || { echo "DEAD: no dispatch has ever run"; exit 2; }
  run="$(basename "$newest" .jsonl)"
else
  run="${run##*/}"
fi

base="$STATE/$run"
[ -f "$base.jsonl" ] && [ ! -s "$base.jsonl" ] && state_pending=1

# pgrep -f matches this script too, since the run id is our own argument.
# Skip ourselves, our parent, and any other status check.
alive=0
for pid in $(pgrep -f "$run" 2>/dev/null); do
  [ "$pid" = "$$" ] && continue
  [ "$pid" = "${PPID:-0}" ] && continue
  cmd="$(cat "/proc/$pid/cmdline" 2>/dev/null | tr '\0' ' ')"
  case "$cmd" in *lane-status*) continue ;; esac
  [ -n "$cmd" ] || continue
  alive=1; break
done

if [ "$alive" -eq 1 ]; then
  echo "RUNNING: $run"
  [ "$state_pending" -eq 1 ] && echo "  state pending — start recorded, transcript not written yet"
  [ "$state_pending" -eq 0 ] && [ -f "$base.jsonl" ] && echo "  transcript is $(du -h "$base.jsonl" 2>/dev/null | cut -f1) and growing"
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

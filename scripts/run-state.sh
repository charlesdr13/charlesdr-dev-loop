#!/usr/bin/env bash
# run-state.sh — durable state for a flow run.
#
# A flow used to end in prose: open items, a rollback command and a pending
# decision, all of which died with the session. This writes the half a model has
# to narrate (goal, phase, proof, rollback). The mechanical half — which lane
# ran, on which engine, and whether it failed — is appended by codex-run.sh to
# .charles/dispatches.jsonl without any cooperation from the model.
#
#   run-state.sh init  <dir> <flow> "<goal>"          -> prints the run id
#   run-state.sh phase <dir> "<phase>" ["<proof>"]
#   run-state.sh item  <dir> <TYPE> "<text>"          TYPE: BLOCKED-HUMAN |
#                                                     PENDING-DECISION | DEFERRED | FAILED
#   run-state.sh rollback <dir> "<command>"
#   run-state.sh close <dir> "<outcome>" [--spec docs/specs/x.md]
#   run-state.sh show  <dir> [--list]
set -euo pipefail

cmd="${1:-}"; shift || true
DIR="${1:-$PWD}"; shift || true
[ -d "$DIR" ] || { echo "run-state.sh: no such directory: $DIR" >&2; exit 2; }
DIR="$(cd "$DIR" && pwd)"
RUNS="$DIR/.charles/runs"

newest_open() { # newest run with no ## Outcome section
  local d
  for d in $(ls -1d "$RUNS"/*/ 2>/dev/null | sort -r); do
    grep -q '^## Outcome' "$d/RUN.md" 2>/dev/null || { echo "${d%/}"; return 0; }
  done
  return 1
}

have_tasks() { command -v tasks-axi >/dev/null 2>&1; }

case "$cmd" in

init)
  flow="${1:?flow required}"; goal="${2:?goal required}"
  id="$(date +%Y%m%d-%H%M%S)-$flow"
  d="$RUNS/$id"; mkdir -p "$d"
  {
    # `--` first: these format strings start with '-', which printf would
    # otherwise parse as a flag and refuse.
    printf -- '# Run %s\n\n' "$id"
    printf -- '- flow: %s\n- goal: %s\n- started: %s\n- repo: %s\n\n' \
      "$flow" "$goal" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$DIR"
    printf -- '## Phases\n\n## Open items\n\n## Rollback\n\n'
  } > "$d/RUN.md"
  echo "$id"
  ;;

phase)
  d="$(newest_open)" || { echo "run-state.sh: no open run — call init first" >&2; exit 1; }
  phase="${1:?phase required}"; proof="${2:-}"
  # insert under ## Phases so phases stay in order and items stay below
  tmp="$(mktemp)"
  awk -v p="- [$(date -u +%H:%M)Z] ${phase}" -v pr="$proof" '
    /^## Open items/ && !done { if (pr != "") printf "%s\n  ```\n%s\n  ```\n", p, pr; else print p; print ""; done=1 }
    { print }' "$d/RUN.md" > "$tmp" && mv "$tmp" "$d/RUN.md"
  echo "recorded phase: $phase"
  ;;

item)
  d="$(newest_open)" || { echo "run-state.sh: no open run — call init first" >&2; exit 1; }
  type="${1:?type required}"; text="${2:?text required}"
  case "$type" in BLOCKED-HUMAN|PENDING-DECISION|DEFERRED|FAILED) ;;
    *) echo "run-state.sh: bad type '$type'" >&2; exit 2 ;; esac

  # tasks-axi is optional: it is a personal tool and absent for most installs.
  # When present it owns the item (it already resurfaces at session start);
  # otherwise the item lives in RUN.md and `resolve` reads it from there.
  ref=""
  if have_tasks && [ "$type" != "FAILED" ]; then
    tid="cdl-$(date +%s)-$RANDOM"
    # cd into the repo: tasks-axi is workspace-scoped, and inheriting cwd would
    # file the item against whatever directory the caller happened to be in.
    if ( cd "$DIR" && tasks-axi add "$tid" "$text" --kind "${type,,}" ) >/dev/null 2>&1; then
      ref=" (tasks-axi: $tid)"
    fi
  fi
  tmp="$(mktemp)"
  awk -v line="- [ ] **$type** — $text$ref" '
    /^## Rollback/ && !done { print line; print ""; done=1 } { print }' "$d/RUN.md" > "$tmp" && mv "$tmp" "$d/RUN.md"
  echo "recorded item: $type — $text$ref"
  ;;

rollback)
  d="$(newest_open)" || { echo "run-state.sh: no open run" >&2; exit 1; }
  printf '\n```bash\n%s\n```\n' "${1:?command required}" >> "$d/RUN.md"
  echo "recorded rollback"
  ;;

close)
  d="$(newest_open)" || { echo "run-state.sh: no open run" >&2; exit 1; }
  outcome="${1:?outcome required}"; shift || true
  spec=""
  [ "${1:-}" = "--spec" ] && spec="${2:-}"
  printf '\n## Outcome\n\n%s\n\nclosed: %s\n' "$outcome" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$d/RUN.md"
  # the durable half: the outcome goes next to the committed plan it resolves
  if [ -n "$spec" ] && [ -f "$DIR/$spec" ]; then
    printf '\n## Run outcome — %s\n\n%s\n' "$(date -u +%Y-%m-%d)" "$outcome" >> "$DIR/$spec"
    echo "appended outcome to $spec"
  fi
  echo "closed run: $(basename "$d")"
  ;;

show)
  if [ "${1:-}" = "--list" ]; then
    for x in $(ls -1d "$RUNS"/*/ 2>/dev/null | sort -r); do
      grep -q '^## Outcome' "$x/RUN.md" 2>/dev/null && st="closed" || st="OPEN  "
      echo "$st $(basename "${x%/}")"
    done
    exit 0
  fi
  d="$(newest_open)" || { echo "no open run in $DIR"; exit 0; }
  cat "$d/RUN.md"
  # correlate the mechanical dispatch log — this is where FAILED lanes surface
  log="$DIR/.charles/dispatches.jsonl"
  if [ -s "$log" ] && command -v jq >/dev/null; then
    echo
    echo "## Dispatches"
    jq -r 'select(.rc != 0) | "  FAILED  \(.ts)  \(.lane)/\(.model)  rc=\(.rc)  \(.task[0:60])"' "$log" 2>/dev/null
    jq -r 'select(.rc == 0) | "  ok      \(.ts)  \(.lane)/\(.model)"' "$log" 2>/dev/null | tail -5
  fi
  ;;

*) sed -n '2,18p' "$0"; exit 2 ;;
esac

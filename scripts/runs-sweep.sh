#!/usr/bin/env bash
# runs-sweep.sh — read-only cross-repo report of open flow runs.
#
# Usage: runs-sweep.sh [root...]
# Roots come from arguments, then CHARLES_SWEEP_ROOTS (colon-separated), then
# ~/MACH4 and ~/MACH4_2. Repos elsewhere need an argument or that environment
# variable; this script only reports runs and never closes or deletes them.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FLOW_FILE="$SCRIPT_DIR/flow.json"

if [ "$#" -gt 0 ]; then
  roots=("$@")
elif [ -n "${CHARLES_SWEEP_ROOTS:-}" ]; then
  IFS=: read -r -a roots <<< "$CHARLES_SWEEP_ROOTS"
else
  roots=("$HOME/MACH4" "$HOME/MACH4_2")
fi

flow_graph=1
if ! command -v jq >/dev/null 2>&1 || [ ! -r "$FLOW_FILE" ] || ! jq -e '
  def strings: type == "array" and all(.[]; type == "string");
  . as $root |
  ($root | type == "object") and
  all(["feature", "debug", "polish", "ui"][];
    . as $flow |
    ($root[$flow] | type == "object") and
    ($root[$flow].phases | type == "object") and
    ($root[$flow].first | type == "string") and
    ($root[$flow].terminal | strings) and
    ([$root[$flow].phases[] | type == "object" and (.next | strings) and (.proof | type == "string")] | all)
  )
' "$FLOW_FILE" >/dev/null 2>&1; then
  echo "runs-sweep.sh: WARN flow.json missing or unparseable; expected-next unavailable" >&2
  flow_graph=0
fi

flow_ready() {
  [ "$flow_graph" -eq 1 ] || return 1
  if ! jq -e --arg f "$1" '
    (.[$f] | type == "object") and
    (.[$f].phases | type == "object") and
    (.[$f].first | type == "string") and
    (.[$f].terminal | type == "array")
  ' "$FLOW_FILE" >/dev/null 2>&1; then
    echo "runs-sweep.sh: WARN flow '$1' is not in flow.json; expected-next unavailable" >&2
    return 1
  fi
}

flow_match() {
  local flow="$1" phase="$2"
  jq -r --arg f "$flow" --arg p "${phase,,}" '
    [.[$f].phases | keys[]? | . as $name | select($p | startswith($name))] |
    sort_by(length) | reverse | .[0] // ""
  ' "$FLOW_FILE" 2>/dev/null
}

flow_next() {
  jq -r --arg f "$1" --arg p "$2" '.[$f].phases[$p].next | join(" | ")' "$FLOW_FILE" 2>/dev/null
}

flow_first() {
  jq -r --arg f "$1" '.[$f].first' "$FLOW_FILE" 2>/dev/null
}

last_phase() {
  awk '
    /^## Phases$/ { inside=1; next }
    /^## Open items$/ && !proof { inside=0 }
    inside {
      if ($0 == "  ```") { proof = !proof; next }
      if (!proof && /^- \[[0-9][0-9]:[0-9][0-9]Z\] /) {
        phase=$0
        sub(/^- \[[^]]*\] /, "", phase)
        last=phase
      }
    }
    END { print last }
  ' "$1"
}

open_items() {
  awk '
    /^## Open items$/ { inside=1; next }
    /^## Rollback$/ { inside=0 }
    inside && /^- \[ \] / { count++ }
    END { print count + 0 }
  ' "$1"
}

age_days() {
  local run="$1" started epoch now
  started="$(sed -n 's/^- started: *//p' "$run" | head -1)"
  epoch=""
  [ -n "$started" ] && epoch="$(date -u -d "$started" +%s 2>/dev/null || true)"
  [ -n "$epoch" ] || epoch="$(stat -c %Y "$run" 2>/dev/null || true)"
  now="$(date -u +%s)"
  [ -n "$epoch" ] || { echo 0; return; }
  [ "$now" -gt "$epoch" ] && echo $(((now - epoch) / 86400)) || echo 0
}

expected_next() {
  local flow="$1" phase="$2" canonical
  if ! flow_ready "$flow"; then
    echo "(unavailable)"
  elif [ -z "$phase" ]; then
    flow_first "$flow"
  else
    canonical="$(flow_match "$flow" "$phase")"
    [ -n "$canonical" ] && flow_next "$flow" "$canonical" || echo "(unmapped)"
  fi
}

for root in "${roots[@]}"; do
  [ -n "$root" ] || continue
  if [ ! -d "$root" ] || [ ! -r "$root" ] || [ ! -x "$root" ]; then
    echo "root not found: $root"
    continue
  fi
  root="$(cd "$root" && pwd)"

  while IFS= read -r -d '' marker; do
    repo="${marker%/.charles.toml}"
    for run in "$repo"/.charles/runs/*/RUN.md; do
      [ -f "$run" ] || continue
      run_id="$(basename "$(dirname "$run")")"
      if [ ! -r "$run" ]; then
        printf '%s · %s · unreadable: %s\n' "$(basename "$repo")" "$run_id" "$run"
        continue
      fi
      grep -q '^## Outcome' "$run" 2>/dev/null && continue
      flow="$(sed -n 's/^- flow: //p' "$run" | head -1)"
      phase="$(last_phase "$run")"
      expected="$(expected_next "$flow" "$phase")"
      [ -n "$phase" ] || phase="(none)"
      printf '%s · %s · %s · %s · %s → %s\n' \
        "$(basename "$repo")" "$run_id" "$(age_days "$run")" \
        "$(open_items "$run")" "$phase" "$expected"
    done
  done < <(find "$root" -type f -name .charles.toml -print0 2>/dev/null | sort -z)
done

exit 0

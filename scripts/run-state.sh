#!/usr/bin/env bash
# run-state.sh — durable state for a flow run.
#
# A flow used to end in prose: open items, a rollback command and a pending
# decision, all of which died with the session. This writes the half a model has
# to narrate (goal, phase, proof, rollback). The mechanical half — which lane
# ran, on which engine, and whether it failed — is appended by codex-run.sh to
# .charles/dispatches.jsonl without any cooperation from the model.
#
#   run-state.sh init  <dir> <flow> "<goal>" [--spec FILE] -> prints the run id
#   run-state.sh spec  <dir> <path> [--run <id>]
#   run-state.sh phase <dir> "<phase>" ["<proof>"]
#   run-state.sh item  <dir> <TYPE> "<text>"          TYPE: BLOCKED-HUMAN |
#                                                     PENDING-DECISION | DEFERRED | FAILED
#   run-state.sh defer <dir> "<text>" [--run <id>]   -> item DEFERRED shorthand
#   run-state.sh rollback <dir> "<command>"
#   run-state.sh close <dir> "<outcome>" [--spec docs/specs/x.md]
#   run-state.sh reopen <dir> --run <id>
#   run-state.sh abandon <dir> [--run <id>] "<reason>"
#   run-state.sh show  <dir> [--list]
# R8 refusal codes: 7 unknown run id, 8 reopen of an open run, 9 abandon of a closed run.
set -euo pipefail

# readlink -f first: this script is reached through a PATH symlink, and an
# unresolved dirname points at the symlink's directory, where run-common.sh
# does not exist. Confirmed live: sourcing died with exit 1 on every wrapper
# dispatch until this line resolved the link.
SCRIPT_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd -P)"
. "$SCRIPT_DIR/run-common.sh"

cmd="${1:-}"; shift || true
DIR="${1:-$PWD}"; shift || true
[ -d "$DIR" ] || { echo "run-state.sh: no such directory: $DIR" >&2; exit 2; }
DIR="$(charles_run_root "$DIR")"
RUNS="$DIR/.charles/runs"
FLOW_FILE="$SCRIPT_DIR/flow.json"
RUN_SELECTOR="${CHARLES_RUN:-}"
RUN_SELECTOR_SET=0
[ -n "$RUN_SELECTOR" ] && RUN_SELECTOR_SET=1

flow_ready() {
  local flow="$1"
  if ! command -v jq >/dev/null 2>&1 || [ ! -r "$FLOW_FILE" ] || ! jq -e --arg f "$flow" '
    def strings: type == "array" and all(.[]; type == "string");
    (.[$f] | type == "object") and
    (.[$f].phases | type == "object") and
    (.[$f].first | type == "string") and
    (.[$f].terminal | strings) and
    ([.[$f].phases[] | type == "object" and (.next | strings) and (.proof | type == "string")] | all)
  ' "$FLOW_FILE" >/dev/null 2>&1; then
    echo "run-state.sh: WARN flow.json missing or unparseable; flow guidance disabled" >&2
    return 1
  fi
}

flow_match() {
  local flow="$1" phase="$2" lower
  lower="${phase,,}"
  jq -r --arg f "$flow" --arg p "$lower" '
    [.[$f].phases | keys[]? | . as $name | select($p | startswith($name))] |
    sort_by(length) | reverse | .[0] // ""
  ' "$FLOW_FILE" 2>/dev/null
}

flow_next() {
  jq -r --arg f "$1" --arg p "$2" '.[$f].phases[$p].next | join(" | ")' "$FLOW_FILE"
}

flow_first() {
  jq -r --arg f "$1" '.[$f].first' "$FLOW_FILE"
}

last_phase() {
  sed -n '/^## Phases$/,/^## Open items$/p' "$1" |
    sed -n 's/^- \[[^]]*\] //p' | tail -1
}

run_is_closed() { grep -q '^## Outcome' "$1" 2>/dev/null; }
run_is_abandoned() { grep -q '^## Abandoned$' "$1" 2>/dev/null; }

open_run_dirs() {
  local include_closed=0
  [ "${1:-}" = "--all" ] && include_closed=1
  local runs="$RUNS" d
  if [ ! -e "$runs" ] && [ ! -L "$runs" ]; then return 0; fi
  if [ ! -d "$runs" ] || [ ! -r "$runs" ] || [ ! -x "$runs" ]; then
    echo "run-state.sh: REFUSING — cannot read run directory: $runs" >&2
    return 2
  fi

  local had_nullglob=0
  shopt -q nullglob && had_nullglob=1
  shopt -s nullglob
  local -a dirs=("$runs"/*/)
  [ "$had_nullglob" -eq 1 ] || shopt -u nullglob
  for d in "${dirs[@]}"; do
    [ -f "$d/RUN.md" ] || continue
    [ -r "$d/RUN.md" ] || {
      echo "run-state.sh: REFUSING — cannot read run state: ${d%/}/RUN.md" >&2
      return 2
    }
    [ "$include_closed" -eq 1 ] || { run_is_closed "$d/RUN.md" && continue; }
    printf '%s\n' "${d%/}"
  done
}

newest_open() { # selected open run, or newest when called for show
  local allow_multiple=0
  [ "${1:-}" = "--show" ] && allow_multiple=1
  local listing d candidate candidate_name
  listing="$(open_run_dirs)" || return $?
  local -a open_runs=()
  if [ -n "$listing" ]; then
    mapfile -t open_runs < <(printf '%s\n' "$listing" | sort -r)
  fi

  if [ "$RUN_SELECTOR_SET" -eq 1 ]; then
    local all_listing
    all_listing="$(open_run_dirs --all)" || return $?
    local -a all_runs=()
    if [ -n "$all_listing" ]; then
      mapfile -t all_runs < <(printf '%s\n' "$all_listing" | sort -r)
    fi
    local -a substring_matches=()
    local exact_match=""
    for candidate in "${all_runs[@]}"; do
      candidate_name="${candidate##*/}"
      if [ "$candidate_name" = "$RUN_SELECTOR" ]; then
        if run_is_closed "$candidate/RUN.md"; then
          if run_is_abandoned "$candidate/RUN.md"; then
            echo "run-state.sh: REFUSING — run selector '$RUN_SELECTOR' names an ABANDONED run" >&2
          else
            echo "run-state.sh: REFUSING — run selector '$RUN_SELECTOR' names a closed run" >&2
          fi
          return 2
        fi
        exact_match="$candidate"
        break
      fi
    done
    for candidate in "${open_runs[@]}"; do
      candidate_name="${candidate##*/}"
      if [ -z "$exact_match" ] && [[ "$candidate_name" == *"$RUN_SELECTOR"* ]]; then
        substring_matches+=("$candidate")
      fi
    done
    if [ -n "$exact_match" ]; then
      printf '%s\n' "$exact_match"
    elif [ "${#substring_matches[@]}" -eq 0 ]; then
      echo "run-state.sh: REFUSING — run selector '$RUN_SELECTOR' does not name an open run (unknown or closed)" >&2
      return 2
    elif [ "${#substring_matches[@]}" -gt 1 ]; then
      echo "run-state.sh: REFUSING — run selector '$RUN_SELECTOR' is ambiguous; matches:" >&2
      printf '  %s\n' "${substring_matches[@]##*/}" >&2
      return 2
    else
      printf '%s\n' "${substring_matches[0]}"
    fi
    return 0
  fi

  if [ "${#open_runs[@]}" -gt 1 ] && [ "$allow_multiple" -eq 0 ]; then
    echo "run-state.sh: REFUSING — multiple open runs; select one:" >&2
    printf '  %s\n' "${open_runs[@]##*/}" >&2
    echo "run-state.sh: pass --run <id> or CHARLES_RUN=<id> to select one" >&2
    return 2
  fi
  [ "${#open_runs[@]}" -gt 0 ] || return 1
  printf '%s\n' "${open_runs[0]}"
}

run_dir_by_id() {
  [ "$RUN_SELECTOR_SET" -eq 1 ] || {
    echo "run-state.sh: --run <id> is required" >&2
    return 2
  }
  case "$RUN_SELECTOR" in
    */*|.|..)
      echo "run-state.sh: unknown run id '$RUN_SELECTOR'" >&2
      return 7
      ;;
  esac
  local d="$RUNS/$RUN_SELECTOR"
  if [ -f "$d/RUN.md" ]; then
    printf '%s\n' "$d"
    return 0
  fi
  echo "run-state.sh: unknown run id '$RUN_SELECTOR'" >&2
  return 7
}

PARSED_ARGS=()
parse_run_option() {
  PARSED_ARGS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --run)
        [ $# -ge 2 ] || { echo "run-state.sh: --run requires a run id" >&2; return 2; }
        [ -n "$2" ] || { echo "run-state.sh: --run requires a run id" >&2; return 2; }
        RUN_SELECTOR="$2"; RUN_SELECTOR_SET=1; shift 2
        ;;
      *) PARSED_ARGS+=("$1"); shift ;;
    esac
  done
}

spec_key() {
  local path="$1"
  case "$path" in /*) ;; *) path="$DIR/$path" ;; esac
  if command -v realpath >/dev/null 2>&1; then
    realpath -m "$path" 2>/dev/null || printf '%s\n' "$path"
  else
    printf '%s\n' "$path"
  fi
}

resolve_spec_path() {
  local spec="$1" spec_path resolved_dir resolved_spec
  case "$spec" in
    /*) spec_path="$spec" ;;
    *)  spec_path="$DIR/$spec" ;;
  esac
  [ -f "$spec_path" ] && [ -r "$spec_path" ] || {
    echo "run-state.sh: REFUSING — spec path does not exist or is unreadable: $spec" >&2
    return 2
  }
  if command -v realpath >/dev/null 2>&1; then
    resolved_dir="$(realpath "$DIR" 2>/dev/null || printf '%s\n' "$DIR")"
    resolved_spec="$(realpath "$spec_path" 2>/dev/null || printf '%s\n' "$spec_path")"
  elif [ -d "$(dirname "$spec_path")" ]; then
    resolved_dir="$(cd "$DIR" && pwd -P)"
    [ -L "$spec_path" ] && {
      echo "run-state.sh: REFUSING — cannot safely resolve symlinked spec $spec without realpath" >&2
      return 2
    }
    resolved_spec="$(cd "$(dirname "$spec_path")" && pwd -P)/$(basename "$spec_path")"
  else
    echo "run-state.sh: REFUSING — cannot resolve spec $spec" >&2
    return 2
  fi
  case "$resolved_spec" in
    "$resolved_dir"/*) printf '%s\n' "$resolved_spec" ;;
    *)
      echo "run-state.sh: REFUSING — spec resolves outside the repository: $spec" >&2
      return 2
      ;;
  esac
}

lock_run_state() {
  mkdir -p "$DIR/.charles" || {
    echo "run-state.sh: FAILED to prepare the run-state lock" >&2
    return 1
  }
  exec 9>"$DIR/.charles/run-state.lock" || {
    echo "run-state.sh: FAILED to open the run-state lock" >&2
    return 1
  }
  flock 9 || {
    echo "run-state.sh: FAILED to acquire the run-state lock" >&2
    return 1
  }
}

have_tasks() { command -v tasks-axi >/dev/null 2>&1; }

case "$cmd" in

init)
  flow="${1:?flow required}"; goal="${2:?goal required}"
  shift 2 || true
  spec=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --spec) [ $# -ge 2 ] || { echo "run-state.sh: --spec requires a path" >&2; exit 2; }; spec="$2"; shift 2 ;;
      *) echo "run-state.sh: unknown init option '$1'" >&2; exit 2 ;;
    esac
  done
  [ -z "$spec" ] || resolve_spec_path "$spec" >/dev/null || exit $?
  lock_run_state || exit $?
  id="$(date +%Y%m%d-%H%M%S)-$flow-$$"
  d="$RUNS/$id"; mkdir -p "$d"
  {
    # `--` first: these format strings start with '-', which printf would
    # otherwise parse as a flag and refuse.
    printf -- '# Run %s\n\n' "$id"
    printf -- '- flow: %s\n- goal: %s\n' "$flow" "$goal"
    [ -n "$spec" ] && printf -- '- spec: %s\n' "$spec"
    printf -- '- started: %s\n- repo: %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$DIR"
    printf -- '## Phases\n\n## Open items\n\n## Rollback\n\n'
  } > "$d/RUN.md"
  echo "$id"
  ;;

spec)
  parse_run_option "$@" || exit $?
  set -- "${PARSED_ARGS[@]}"
  spec="${1:?spec path required}"
  spec_path="$(resolve_spec_path "$spec")" || exit $?
  lock_run_state || exit $?
  d="$(newest_open)" || {
    rc=$?
    [ "$rc" -eq 1 ] && echo "run-state.sh: no open run — call init first" >&2
    exit "$rc"
  }
  tmp="$(mktemp)" || {
    echo "run-state.sh: FAILED to bind spec: $spec" >&2
    exit 1
  }
  awk -v spec="$spec" '
    /^- spec: / {
      if (!bound) { print "- spec: " spec; bound=1 }
      next
    }
    /^- started: / && !bound { print "- spec: " spec; bound=1 }
    { print }
    END { if (!bound) print "- spec: " spec }
  ' "$d/RUN.md" > "$tmp" || {
    rm -f "$tmp"
    echo "run-state.sh: FAILED to bind spec: $spec" >&2
    exit 1
  }
  mv "$tmp" "$d/RUN.md" || {
    rm -f "$tmp"
    echo "run-state.sh: FAILED to bind spec: $spec" >&2
    exit 1
  }
  echo "bound spec: $spec to run: $(basename "$d")"
  ;;

phase)
  parse_run_option "$@" || exit $?
  set -- "${PARSED_ARGS[@]}"
  lock_run_state || exit $?
  d="$(newest_open)" || { rc=$?; [ "$rc" -eq 1 ] && echo "run-state.sh: no open run — call init first" >&2; exit "$rc"; }
  phase="${1:?phase required}"; proof="${2:-}"
  flow="$(sed -n 's/^- flow: //p' "$d/RUN.md" | head -1)"
  if flow_ready "$flow"; then
    canonical="$(flow_match "$flow" "$phase")"
    [ -n "$canonical" ] || echo "run-state.sh: WARN unmapped phase '$phase' for flow '$flow' — recording anyway" >&2
  fi
  # insert under ## Phases so phases stay in order and items stay below
  tmp="$(mktemp)"
  awk -v p="- [$(date -u +%H:%M)Z] ${phase}" -v pr="$proof" '
    /^## Open items/ && !done { if (pr != "") printf "%s\n  ```\n%s\n  ```\n", p, pr; else print p; print ""; done=1 }
    { print }' "$d/RUN.md" > "$tmp" && mv "$tmp" "$d/RUN.md"
  echo "recorded phase: $phase"
  ;;

defer)
  parse_run_option "$@" || exit $?
  set -- "${PARSED_ARGS[@]}"
  text="${1:?text required}"
  defer_args=("$0" item "$DIR" DEFERRED "$text")
  [ "$RUN_SELECTOR_SET" -eq 0 ] || defer_args+=(--run "$RUN_SELECTOR")
  exec "${defer_args[@]}"
  ;;

item)
  parse_run_option "$@" || exit $?
  set -- "${PARSED_ARGS[@]}"
  lock_run_state || exit $?
  d="$(newest_open)" || { rc=$?; [ "$rc" -eq 1 ] && echo "run-state.sh: no open run — call init first" >&2; exit "$rc"; }
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
  parse_run_option "$@" || exit $?
  set -- "${PARSED_ARGS[@]}"
  lock_run_state || exit $?
  d="$(newest_open)" || { rc=$?; [ "$rc" -eq 1 ] && echo "run-state.sh: no open run" >&2; exit "$rc"; }
  printf '\n```bash\n%s\n```\n' "${1:?command required}" >> "$d/RUN.md"
  echo "recorded rollback"
  ;;

reopen)
  parse_run_option "$@" || exit $?
  set -- "${PARSED_ARGS[@]}"
  [ "$RUN_SELECTOR_SET" -eq 1 ] || { echo "run-state.sh: reopen requires --run <id>" >&2; exit 2; }
  [ "$#" -eq 0 ] || { echo "run-state.sh: reopen takes no arguments besides --run <id>" >&2; exit 2; }
  lock_run_state || exit $?
  d="$(run_dir_by_id)" || exit $?
  if ! run_is_closed "$d/RUN.md"; then
    echo "run-state.sh: REFUSING to reopen — run $(basename "$d") is already open" >&2
    exit 8
  fi

  reopened="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tmp="$(mktemp)" || { echo "run-state.sh: FAILED to reopen run" >&2; exit 1; }
  # Reopen preserves both close records: it renames the active RUN.md outcome
  # and abandoned headings to historical headings, leaves the spec's appended
  # `## Run outcome` untouched, and writes no replacement outcome. Only an
  # active `^## Outcome` heading marks a run closed.
  if ! awk -v stamp="$reopened" '
    /^## Outcome/ { print "## Previous outcome (superseded by reopen " stamp ")"; next }
    /^## Abandoned$/ { print "## Previous abandoned marker (superseded by reopen " stamp ")"; next }
    { print }
  ' "$d/RUN.md" > "$tmp"; then
    rm -f "$tmp"
    echo "run-state.sh: FAILED to reopen run" >&2
    exit 1
  fi
  if ! mv "$tmp" "$d/RUN.md"; then
    rm -f "$tmp"
    echo "run-state.sh: FAILED to reopen run" >&2
    exit 1
  fi
  echo "reopened run: $(basename "$d") (previous outcome preserved)"
  ;;

abandon)
  parse_run_option "$@" || exit $?
  set -- "${PARSED_ARGS[@]}"
  [ "$#" -eq 1 ] && [ -n "$1" ] || { echo "run-state.sh: abandon requires a non-empty reason" >&2; exit 2; }
  reason="$1"
  lock_run_state || exit $?
  if [ "$RUN_SELECTOR_SET" -eq 1 ]; then
    d="$(run_dir_by_id)" || exit $?
  else
    d="$(newest_open)" || {
      rc=$?
      [ "$rc" -eq 1 ] && echo "run-state.sh: no open run" >&2
      exit "$rc"
    }
  fi
  if run_is_closed "$d/RUN.md"; then
    echo "run-state.sh: REFUSING to abandon — run $(basename "$d") is already closed" >&2
    exit 9
  fi

  recorded_spec="$(sed -n 's/^- spec: //p' "$d/RUN.md" | head -1)"
  spec_path=""
  if [ -n "$recorded_spec" ]; then
    spec_path="$(resolve_spec_path "$recorded_spec")" || exit $?
  fi
  abandoned_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '\n## Outcome\n\nABANDONED\n\n## Abandoned\n\nreason: %s\n\nclosed: %s\n' \
    "$reason" "$abandoned_at" >> "$d/RUN.md"
  if [ -n "$spec_path" ]; then
    printf '\n## Run outcome — %s\n\nABANDONED\n\nreason: %s\n' \
      "${abandoned_at%%T*}" "$reason" >> "$spec_path"
    echo "appended abandoned outcome to $recorded_spec"
  fi
  echo "abandoned run: $(basename "$d")"
  ;;

close)
  parse_run_option "$@" || exit $?
  set -- "${PARSED_ARGS[@]}"
  lock_run_state || exit $?
  d="$(newest_open)" || { rc=$?; [ "$rc" -eq 1 ] && echo "run-state.sh: no open run" >&2; exit "$rc"; }
  outcome="${1:?outcome required}"; shift || true
  spec=""; force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --spec)
        [ $# -ge 2 ] || { echo "run-state.sh: --spec requires a path" >&2; exit 2; }
        spec="$2"; shift 2 ;;
      --force) force=1; shift ;;
      *) shift ;;
    esac
  done

  recorded_spec="$(sed -n 's/^- spec: //p' "$d/RUN.md" | head -1)"
  if [ -n "$recorded_spec" ] && [ -n "$spec" ] \
    && [ "$(spec_key "$recorded_spec")" != "$(spec_key "$spec")" ]; then
    echo "run-state.sh: REFUSING to close — selected run $(basename "$d") has a different spec." >&2
    echo "  recorded spec: $recorded_spec" >&2
    echo "  --spec given:  $spec" >&2
    exit 2
  fi

  # Closing is the moment you declare the work done, so it is where flow
  # completeness gets checked. An audit of 75 real dispatches found 19% review
  # coverage and 1 grill verdict across 13 plans — every one of those "finished"
  # because the individual dispatches succeeded. A dispatch succeeding is not a
  # flow finishing.
  # An unchecked item means the run is not finished, whatever else is clean.
  # This gate existed to stop premature "done" and did not check the one thing
  # it was built for. Found by an adversarial review, 2026-08-12.
  spec_path="$spec"
  case "$spec_path" in /*) ;; *) spec_path="$DIR/$spec_path" ;; esac
  # The boundary check is NOT under --force: --force is a bookkeeping override
  # ("close anyway"), never a licence to append this run's outcome to a file
  # outside the repo. A typo'd relative path plus --force would otherwise write
  # to someone else's file.
  if [ -n "$spec" ]; then
    if command -v realpath >/dev/null 2>&1; then
      resolved_dir="$(realpath "$DIR" 2>/dev/null || printf '%s\n' "$DIR")"
      resolved_spec="$(realpath "$spec_path" 2>/dev/null || realpath -m "$spec_path" 2>/dev/null || printf '%s\n' "$spec_path")"
    elif [ -d "$(dirname "$spec_path")" ]; then
      resolved_dir="$(cd "$DIR" && pwd -P)"
      # `cd`+`pwd -P` resolves the directory chain but not a final symlink, and
      # the outcome append below follows it. Without realpath there is nothing
      # left to resolve it with, so refuse rather than write through it.
      if [ -L "$spec_path" ]; then
        echo "run-state.sh: REFUSING to close — $spec is a symlink and realpath is unavailable to resolve it." >&2
        exit 6
      fi
      resolved_spec="$(cd "$(dirname "$spec_path")" && pwd -P)/$(basename "$spec_path")"
    else
      resolved_dir="$DIR"
      resolved_spec="$spec_path"
    fi
    case "$resolved_spec" in
      "$resolved_dir"/*) spec_path="$resolved_spec" ;;
      *)
        echo "run-state.sh: REFUSING to close — $spec resolves outside the repository." >&2
        exit 6
        ;;
    esac
  fi

  if [ "$force" -eq 0 ] && [ -n "$spec" ]; then
    if ! grep -q '^## Sign-off$' "$spec_path" 2>/dev/null; then
      echo "run-state.sh: REFUSING to close — $spec is missing the ## Sign-off section." >&2
      exit 6
    fi
    signoff="$(sed -n '/^## Sign-off$/,/^## /p' "$spec_path")"
    if ! grep -q '^- \[x\] ' <<<"$signoff"; then
      echo "run-state.sh: REFUSING to close — $spec's ## Sign-off section is empty; it has no ticked requirements." >&2
      exit 6
    fi
    if grep -q '^- \[ \] ' <<<"$signoff"; then
      echo "run-state.sh: REFUSING to close — $spec has unticked sign-off requirements:" >&2
      grep '^- \[ \] ' <<<"$signoff" | sed 's/^/  /' >&2
      echo "run-state.sh: resolve them, or close deliberately with --force." >&2
      exit 6
    fi
  fi

  if [ "$force" -eq 0 ] && grep -q '^- \[ \] ' "$d/RUN.md" 2>/dev/null; then
    echo "run-state.sh: REFUSING to close — the run still has open items:" >&2
    grep '^- \[ \] ' "$d/RUN.md" | sed 's/^/  /' >&2
    echo "run-state.sh: resolve them, or close deliberately with --force." >&2
    exit 5
  fi

  fs="$(dirname "$0")/flow-status.sh"
  if [ -x "$fs" ] && [ "$force" -eq 0 ]; then
    if ! "$fs" "$DIR" --closing "$d" > /tmp/flow-status.$$ 2>&1; then
      sed 's/^/  /' /tmp/flow-status.$$ >&2; rm -f /tmp/flow-status.$$
      echo >&2
      echo "run-state.sh: REFUSING to close — the flow is not finished." >&2
      echo "run-state.sh: grade the work, or close deliberately with --force." >&2
      exit 5
    fi
    rm -f /tmp/flow-status.$$
  fi
  shipped=0
  count_spec_path=""
  if [ -n "$spec" ]; then
    count_spec_path="$spec_path"
  else
    count_spec="$(sed -n 's/^- spec: //p' "$d/RUN.md" | head -1)"
    if [ -n "$count_spec" ]; then
      count_spec_path="$count_spec"
      case "$count_spec_path" in /*) ;; *) count_spec_path="$DIR/$count_spec_path" ;; esac
      if command -v realpath >/dev/null 2>&1; then
        count_resolved="$(realpath "$count_spec_path" 2>/dev/null || printf '%s\n' "$count_spec_path")"
      elif [ -d "$(dirname "$count_spec_path")" ] && [ ! -L "$count_spec_path" ]; then
        count_resolved="$(cd "$(dirname "$count_spec_path")" && pwd -P)/$(basename "$count_spec_path")"
      else
        count_resolved=""
      fi
      case "$count_resolved" in "$DIR"/*) count_spec_path="$count_resolved" ;; *) count_spec_path="" ;; esac
    fi
  fi
  if [ -n "$count_spec_path" ] && [ -f "$count_spec_path" ]; then
    signoff="$(sed -n '/^## Sign-off$/,/^## /p' "$count_spec_path")"
    shipped="$(grep -c '^- \[x\] ' <<<"$signoff" || true)"
  fi
  deferred="$(grep -c '^- \[[^]]*\] \*\*DEFERRED\*\*' "$d/RUN.md" 2>/dev/null || true)"
  printf '\n## Outcome\n\n%s\n\nclosed: %s\n' "$outcome" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$d/RUN.md"
  # the durable half: the outcome goes next to the committed plan it resolves
  if [ -n "$spec" ] && [ -f "$spec_path" ]; then
    printf '\n## Run outcome — %s\n\n%s\n' "$(date -u +%Y-%m-%d)" "$outcome" >> "$spec_path"
    echo "appended outcome to $spec"
  fi
  echo "$shipped requirements shipped, $deferred items deferred"
  echo "closed run: $(basename "$d")"
  ;;

show)
  parse_run_option "$@" || exit $?
  set -- "${PARSED_ARGS[@]}"
  if [ "${1:-}" = "--list" ]; then
    for x in $(ls -1d "$RUNS"/*/ 2>/dev/null | sort -r); do
      if run_is_closed "$x/RUN.md"; then
        run_is_abandoned "$x/RUN.md" && st="ABANDONED" || st="closed"
      else
        st="OPEN  "
      fi
      echo "$st $(basename "${x%/}")"
    done
    exit 0
  fi
  d="$(newest_open --show)" || {
    rc=$?
    [ "$rc" -eq 1 ] && { echo "no open run in $DIR"; exit 0; }
    exit "$rc"
  }
  echo "showing run: $(basename "$d")"
  cat "$d/RUN.md"
  flow="$(sed -n 's/^- flow: //p' "$d/RUN.md" | head -1)"
  if flow_ready "$flow"; then
    phase="$(last_phase "$d/RUN.md")"
    if [ -z "$phase" ]; then
      expected="$(flow_first "$flow")"
    else
      canonical="$(flow_match "$flow" "$phase")"
      if [ -n "$canonical" ]; then expected="$(flow_next "$flow" "$canonical")"; else expected="(unmapped)"; fi
    fi
    echo
    echo "next expected: $expected"
  fi
  # correlate the mechanical dispatch log — this is where FAILED lanes surface
  log="$DIR/.charles/dispatches.jsonl"
  if [ -s "$log" ] && command -v jq >/dev/null; then
    echo
    echo "## Dispatches"
    jq -r -s '
      map(select((has("event") | not) or .event == "end")) |
      reduce .[] as $r ({};
        .[(($r.run // "") | tostring | split("/") | last)] = $r) |
      .[] | select(.rc != 0) |
      "  FAILED  \(.ts)  \(.lane)/\(.model)  rc=\(.rc)  \(.task[0:60])"
    ' "$log" 2>/dev/null
    jq -r -s '
      map(select((has("event") | not) or .event == "end")) |
      reduce .[] as $r ({};
        .[(($r.run // "") | tostring | split("/") | last)] = $r) |
      .[] | select(.rc == 0) |
      "  ok      \(.ts)  \(.lane)/\(.model)"
    ' "$log" 2>/dev/null | tail -5
  fi
  ;;

*) sed -n '2,18p' "$0"; exit 2 ;;
esac

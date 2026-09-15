#!/usr/bin/env bash
# codex-run.sh — dispatch work to a Codex lane.
#
# Roles (--lane):
#   explore   read-only investigation
#   implement writes into the working tree
#   review    adversarial grading, ISOLATED. sol @ medium by default; luna/terra
#             @ max; --effort overrides. Review is read-only and the cheapest
#             lane, so two in parallel is cheap — and measured, two models
#             overlapped on 1 finding out of 13.
#
# Engines (--engine), for explore and implement:
#   luna      gpt-5.6-luna @ max      PRIMARY — every dispatch starts here
#   terra     gpt-5.6-terra @ max     ESCALATION — when luna's work came back wrong
#   deepseek  deepseek-v4-flash @ max FALLBACK — when luna failed to run at all
#   claude    claude-sonnet-5 @ medium; review stays on codex sol @ medium
#   grok      grok-4.6 @ high (local grok CLI, --reasoning-effort has no "max",
#             so max is translated to xhigh); ALSO runs review — unlike claude,
#             a project/global grok preference is honoured there too, since it
#             is a different model family from every codex profile. No fallback.
# Selection: --engine > CHARLES_ENGINE > <run root>/.charles/engine > global
# $CHARLES_STATE_DIR/engine. Linked worktrees share the primary checkout's preference.
#
# Availability and capability are different problems. A dispatch that DIED falls
# back to deepseek. Work that RAN and was wrong escalates to terra. Difficulty is
# never predicted from the task text — it is demonstrated by a failed check.
#
# The review lane runs in a temp dir containing ONLY plan.md + changes.diff.
# That isolation is the point: a grader that can read the implementer's
# transcript gets talked into agreeing with it. Enforced here, not by prompt.
#
# Usage:
#   codex-run.sh --lane explore   [--dir D] [--engine E] [--effort max|high|medium] [--fast] "task"
#   codex-run.sh --lane implement [--dir D] [--engine E] [--effort E] [--fast] [--run ID] [--req R1,A3] [--plan FILE] [--read-only] [--allow-main-tree] "task"
#   codex-run.sh --lane review    --dir D --plan FILE [--base REF] [--files a,b] "task"
#
# --fast is shorthand for --effort high. fast_mode is enabled explicitly on the
# luna engine and disabled on the review lane, so it applies to luna only.
# CHARLES_FAST_MODE=1 forces luna fast_mode on without the weekly quota probe; terra never calls it.

set -euo pipefail

if [ "${CHARLES_WATCHDOG:-0}" = "1" ]; then
  watchdog_parent="${CHARLES_WATCHDOG_PARENT:-}"
  watchdog_state_file="${CHARLES_WATCHDOG_STATE_FILE:-}"
  watchdog_stop_file="${CHARLES_WATCHDOG_STOP_FILE:-}"
  watchdog_run="${CHARLES_WATCHDOG_RUN:-}"
  watchdog_done="${CHARLES_WATCHDOG_DONE:-}"
  watchdog_log="${CHARLES_WATCHDOG_LOG:-}"
  watchdog_lane="${CHARLES_WATCHDOG_LANE:-}"
  watchdog_dir="${CHARLES_WATCHDOG_DIR:-}"
  watchdog_task="${CHARLES_WATCHDOG_TASK:-}"
  watchdog_req="${CHARLES_WATCHDOG_REQ:-}"
  watchdog_allow_main_tree="${CHARLES_WATCHDOG_ALLOW_MAIN_TREE:-0}"
  watchdog_flow_run_id="${CHARLES_WATCHDOG_FLOW_RUN_ID:-}"
  watchdog_spec_path="${CHARLES_WATCHDOG_SPEC_PATH:-}"
  [ -n "$watchdog_parent" ] && [ -n "$watchdog_state_file" ] && [ -n "$watchdog_stop_file" ] \
    && [ -n "$watchdog_run" ] && [ -n "$watchdog_done" ] && [ -n "$watchdog_log" ] || exit 2

  watchdog_parent_pid() {
    ps -o ppid= -p "$$" 2>/dev/null | tr -d '[:space:]'
  }

  watchdog_alive() {
    local pid="$1"
    kill -0 -- "-$pid" 2>/dev/null || kill -0 "$pid" 2>/dev/null
  }

  watchdog_kill_group() {
    local active="${1:-0}" pid_file="${2:-}" child_pid=""
    [ "$active" = "1" ] || return 0
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      [ -s "$pid_file" ] && break
      sleep 1
    done
    [ -s "$pid_file" ] || return 0
    child_pid="$(head -1 "$pid_file" 2>/dev/null || true)"
    [[ "$child_pid" =~ ^[1-9][0-9]*$ ]] && [ "$child_pid" -gt 1 ] || return 0
    kill -TERM -- "-$child_pid" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
      watchdog_alive "$child_pid" || return 0
      sleep 1
    done
    kill -KILL -- "-$child_pid" 2>/dev/null || true
  }

  watchdog_active=0
  watchdog_engine=""
  watchdog_model=""
  watchdog_fallback_from=""
  watchdog_primary_rc=""
  watchdog_pid_file=""
  while :; do
    [ -e "$watchdog_stop_file" ] && exit 0
    watchdog_current_parent="$(watchdog_parent_pid || true)"
    if [ -n "$watchdog_current_parent" ] && [ "$watchdog_current_parent" != "$watchdog_parent" ]; then
      break
    fi
    sleep 1
  done

  # Give a dying wrapper time to finish its EXIT trap and append its end event.
  sleep 2
  [ -e "$watchdog_stop_file" ] && exit 0
  if [ -s "$watchdog_state_file" ]; then
    IFS='|' read -r watchdog_active watchdog_engine watchdog_model \
      watchdog_fallback_from watchdog_primary_rc watchdog_pid_file < "$watchdog_state_file" || true
  fi
  watchdog_kill_group "$watchdog_active" "$watchdog_pid_file"

  watchdog_end_rc=""
  watchdog_end_claim="${watchdog_done%.done}.${watchdog_engine}.end"
  if [ -r "$watchdog_log" ]; then
    watchdog_end_rc="$(jq -r --arg r "$watchdog_run" --arg e "$watchdog_engine" \
      'select(.event == "end" and .run == $r and .engine == $e and .rc != null) | .rc' \
      "$watchdog_log" 2>/dev/null | tail -1 || true)"
  fi
  if [[ "$watchdog_end_rc" =~ ^[0-9]+$ ]]; then
    [ -e "$watchdog_done" ] || printf '%s\n' "$watchdog_end_rc" > "$watchdog_done" 2>/dev/null || true
  elif mkdir "$watchdog_end_claim" 2>/dev/null \
    || { rmdir "$watchdog_end_claim" 2>/dev/null && mkdir "$watchdog_end_claim" 2>/dev/null; }; then
    jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg lane "$watchdog_lane" \
      --arg engine "$watchdog_engine" --arg model "$watchdog_model" --arg run "$watchdog_run" \
      --arg dir "$watchdog_dir" --arg task "$(printf '%.200s' "$watchdog_task")" \
      --arg fallback_from "$watchdog_fallback_from" --arg primary_rc "$watchdog_primary_rc" \
      --arg req "$watchdog_req" --arg allow_main_tree "$watchdog_allow_main_tree" \
      --arg flow_run_id "$watchdog_flow_run_id" --arg spec_path "$watchdog_spec_path" \
      '{ts:$ts,event:"end",lane:$lane,engine:$engine,model:$model,rc:143,run:$run,dir:$dir,task:$task,wrapper_death:true}
       | if $flow_run_id == "" then . else . + {flow_run_id:$flow_run_id} end
       | if $spec_path == "" then . else . + {spec_path:$spec_path} end
       | if $lane == "implement" then . + {req:($req | if . == "" then [] else split(",") end),allow_main_tree:($allow_main_tree == "1")} else . end
       | if $fallback_from != "" then . + {fallback_from:$fallback_from,primary_rc:($primary_rc|tonumber)} else . end' \
      >> "$watchdog_log" 2>/dev/null || true
    [ -e "$watchdog_done" ] || printf '143\n' > "$watchdog_done" 2>/dev/null || true
  fi
  exit 0
fi

# readlink -f first: this script is reached through a PATH symlink, and an
# unresolved dirname points at the symlink's directory, where run-common.sh
# does not exist. Confirmed live: sourcing died with exit 1 on every wrapper
# dispatch until this line resolved the link.
SCRIPT_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd -P)"
. "$SCRIPT_DIR/run-common.sh"

LANE=""
ENGINE="luna"        # primary for every dispatch; deepseek is the fallback only
ENGINE_SET=0         # review defaults to sol, so it must know if you chose one
ENGINE_FROM_FLAG=0   # only --engine is explicit; env/file preferences set ENGINE_SET too
EFFORT_SET=0         # review picks effort from its resolved model unless set
PEAK_SUB=0           # 1 = deepseek was swapped to luna because DeepSeek is at peak price
EFFORT="max"         # default reasoning effort: max | high | medium. high is markedly
                     # faster and is Codex's own default; max is the quality ceiling.
DIR="$PWD"
SANDBOX="workspace-write"
RESUME=0
TIMEOUT=2700       # README's canonical timing filters durations to successful
                   # implement dispatches only (rc=0): n=233. Timeouts are
                   # counted separately: 25 of 258 ends (about 10%) hit the old
                   # 1800s cap. The successful population's max is 39.6 min;
                   # 2700s (45 min) covers it with headroom.
PLAN=""
BASE=""
FILES=""
REQ=""
REQ_SET=0
ALLOW_MAIN_TREE=0
RUN_SELECTOR="${CHARLES_RUN:-}"
RUN_SELECTOR_SET=0
if [ -n "$RUN_SELECTOR" ]; then RUN_SELECTOR_SET=1; fi
VALIDATE_ONLY=0
FALLBACK=1
STATE_DIR="${CHARLES_STATE_DIR:-$HOME/.cache/charlesdr-dev-loop}"
DS_SCRIPT="$HOME/.claude/skills/codex-deepseek/scripts/codex-ds.sh"

usage() { sed -n '2,24p' "$0"; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --lane)      LANE="$2"; shift 2 ;;
    --engine)    ENGINE="$2"; ENGINE_SET=1; ENGINE_FROM_FLAG=1; shift 2 ;;
    --effort)    EFFORT="$2"; EFFORT_SET=1; shift 2 ;;
    --fast)      EFFORT="high"; EFFORT_SET=1; shift ;;
    --dir)       DIR="$2"; shift 2 ;;
    --plan)      PLAN="$2"; shift 2 ;;
    --base)      BASE="$2"; shift 2 ;;
    --files)     FILES="$2"; shift 2 ;;
    --run)       [ $# -ge 2 ] || { echo "codex-run.sh: --run requires a run id" >&2; exit 2; }; [ -n "$2" ] || { echo "codex-run.sh: --run requires a run id" >&2; exit 2; }; RUN_SELECTOR="$2"; RUN_SELECTOR_SET=1; shift 2 ;;
    --req)       [ $# -ge 2 ] || { echo "codex-run.sh: --req requires identifiers" >&2; exit 2; }; REQ="$2"; REQ_SET=1; shift 2 ;;
    --validate-only) VALIDATE_ONLY=1; shift ;;
    --read-only) SANDBOX="read-only"; shift ;;
    --allow-main-tree) ALLOW_MAIN_TREE=1; shift ;;
    --resume)    RESUME=1; shift ;;
    --timeout)   TIMEOUT="$2"; shift 2 ;;
    --no-fallback) FALLBACK=0; shift ;;
    -h|--help)   usage ;;
    --) shift; break ;;
    -*) echo "codex-run.sh: unknown flag $1" >&2; exit 2 ;;
    *) break ;;
  esac
done

TASK="${1:-}"
[ "${CHARLES_ALLOW_MAIN_TREE:-0}" = "1" ] && ALLOW_MAIN_TREE=1
[ -n "$LANE" ] || { echo "codex-run.sh: --lane is required" >&2; usage; }
[ -n "$TASK" ] || { echo "codex-run.sh: no task given" >&2; exit 2; }
[ -d "$DIR" ]  || { echo "codex-run.sh: no such directory: $DIR" >&2; exit 2; }
[ -z "$BASE" ] || [ "$LANE" = "review" ] || { echo "codex-run.sh: --base is only valid with --lane review" >&2; exit 2; }

DIR="$(cd "$DIR" && pwd)"
RUN_DIR="$(charles_run_root "$DIR")"

# --- project/global engine switch ---------------------------------------------
# ponytail: a file, not just an env var — each harness Bash call is a fresh shell,
# so `export CHARLES_ENGINE=deepseek` cannot persist across dispatches. Written by
# the /engine command; an explicit --engine on the call still wins.
if [ "$ENGINE_FROM_FLAG" -eq 0 ]; then
  pick="${CHARLES_ENGINE:-}"
  [ -n "$pick" ] || pick="$(cat "$RUN_DIR/.charles/engine" 2>/dev/null || true)"
  [ -n "$pick" ] || pick="$(cat "$STATE_DIR/engine" 2>/dev/null || true)"
  case "$pick" in
    luna|terra|claude|grok) ENGINE="$pick"; ENGINE_SET=1 ;;     # claude review pins sol; grok review honours this preference too (R8)
    deepseek)
      ENGINE=deepseek; ENGINE_SET=1
      # DeepSeek bills peak rates 01:00-04:00 and 06:00-10:00 UTC (2x in, 2x out).
      # In those windows luna on Codex quota is the cheaper lane, so borrow it —
      # with luna's normal fast_mode selection. An explicit --engine deepseek is
      # never swapped: that is the failure fallback path.
      # ponytail: hour arithmetic, no date library. CHARLES_PEAK_HOUR pins it for tests.
      case "${CHARLES_PEAK_HOUR:-$(date -u +%H)}" in
        01|02|03|06|07|08|09) ENGINE=luna; PEAK_SUB=1
          echo "codex-run.sh: DeepSeek peak window — running this $LANE on luna instead" >&2 ;;
      esac ;;
  esac
fi

if [ "$ENGINE" = "claude" ]; then
  if [ "$LANE" = "review" ] && [ "$ENGINE_FROM_FLAG" -eq 1 ]; then
    echo "codex-run.sh: --engine claude cannot review; use sol (omit --engine)" >&2
    exit 2
  fi
  [ "$RESUME" -eq 0 ] || { echo "codex-run.sh: --resume is unavailable for claude: no session id is recorded" >&2; exit 2; }
fi

# Only the resume half applies to grok — grok IS allowed on review (R7), unlike claude.
if [ "$ENGINE" = "grok" ] && [ "$RESUME" -eq 1 ]; then
  echo "codex-run.sh: --resume is unavailable for grok: no session id is recorded" >&2
  exit 2
fi

mkdir -p "$STATE_DIR"
RUN="$STATE_DIR/$(date +%Y%m%d-%H%M%S)-$$-$LANE"
RUN_ID="${RUN##*/}"
WATCHDOG_STATE_FILE="$RUN.watchdog.state"
WATCHDOG_STOP_FILE="$RUN.watchdog.stop"
WATCHDOG_PID=""
CHILD_PID=""
CHILD_PID_FILE=""
ATTEMPT_NO=0
ATTEMPT_FALLBACK_FROM=""
ATTEMPT_PRIMARY_RC=""

open_run_dirs() {
  local include_closed=0
  [ "${1:-}" = "--all" ] && include_closed=1
  local runs="$RUN_DIR/.charles/runs" d
  if [ ! -e "$runs" ] && [ ! -L "$runs" ]; then return 0; fi
  if [ ! -d "$runs" ] || [ ! -r "$runs" ] || [ ! -x "$runs" ]; then
    echo "codex-run.sh: REFUSING — cannot read run directory: $runs" >&2
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
      echo "codex-run.sh: REFUSING — cannot read run state: ${d%/}/RUN.md" >&2
      return 2
    }
    [ "$include_closed" -eq 1 ] || { grep -q '^## Outcome' "$d/RUN.md" 2>/dev/null && continue; }
    printf '%s\n' "${d%/}"
  done
}

resolve_plan_path() {
  local path="$1"
  case "$path" in /*) ;; *) path="$RUN_DIR/$path" ;; esac
  [ -f "$path" ] && [ -r "$path" ] || return 1
  if command -v realpath >/dev/null 2>&1; then
    realpath "$path" 2>/dev/null || printf '%s\n' "$path"
  else
    printf '%s\n' "$path"
  fi
}

validate_requirement_list() {
  local id normalized
  [ -n "$REQ" ] || { echo "codex-run.sh: REFUSING — --req needs at least one requirement identifier" >&2; return 2; }
  [[ "$REQ" == *,* ]] && [[ "$REQ" =~ (^|,)[[:space:]]*(,|$) ]] && {
    echo "codex-run.sh: REFUSING — invalid requirement identifier ''" >&2
    return 2
  }
  normalized="$(printf '%s' "$REQ" | tr ',[:space:]' ' ')"
  read -r -a req_ids <<<"$normalized"
  [ "${#req_ids[@]}" -gt 0 ] && [ -n "${req_ids[0]:-}" ] || {
    echo "codex-run.sh: REFUSING — --req needs at least one requirement identifier" >&2
    return 2
  }
  for id in "${req_ids[@]}"; do
    [[ "$id" =~ $CHARLES_REQUIREMENT_REGEX ]] || {
      echo "codex-run.sh: REFUSING — invalid requirement identifier '$id'" >&2
      return 2
    }
  done
  REQ="$(IFS=,; printf '%s' "${req_ids[*]}")"
}

validate_dispatch_scope() {
  # An implement receipt without a plan mapping cannot be audited later, so fail before taking a lane.
  FLOW_RUN_ID=""
  SPEC_PATH=""
  local validate_implement=0
  [ "$LANE" = "implement" ] && validate_implement=1
  if [ "$validate_implement" -eq 1 ] && [ "$REQ_SET" -eq 1 ]; then
    validate_requirement_list || return $?
  fi

  local open_listing
  open_listing="$(open_run_dirs)" || return $?
  local -a open_runs=()
  [ -z "$open_listing" ] || mapfile -t open_runs <<<"$open_listing"
  local run_dir="" plan_path=""
  # Abandoned runs stay open for /resolve; choose one instead of blocking the repo.
  if [ "$RUN_SELECTOR_SET" -eq 1 ]; then
    local all_listing
    all_listing="$(open_run_dirs --all)" || return $?
    local -a all_runs=()
    [ -z "$all_listing" ] || mapfile -t all_runs <<<"$all_listing"
    local -a substring_matches=()
    local exact_match="" candidate candidate_name
    for candidate in "${all_runs[@]}"; do
      candidate_name="${candidate##*/}"
      if [ "$candidate_name" = "$RUN_SELECTOR" ]; then
        if grep -q '^## Outcome' "$candidate/RUN.md" 2>/dev/null; then
          echo "codex-run.sh: REFUSING — run selector '$RUN_SELECTOR' names a closed run" >&2
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
      run_dir="$exact_match"
    elif [ "${#substring_matches[@]}" -eq 0 ]; then
      echo "codex-run.sh: REFUSING — run selector '$RUN_SELECTOR' does not name an open run (unknown or closed)" >&2
      return 2
    elif [ "${#substring_matches[@]}" -gt 1 ]; then
      echo "codex-run.sh: REFUSING — run selector '$RUN_SELECTOR' is ambiguous; matches:" >&2
      printf '  %s\n' "${substring_matches[@]##*/}" >&2
      return 2
    else
      run_dir="${substring_matches[0]}"
    fi
  elif [ "${#open_runs[@]}" -gt 1 ]; then
    if [ "$validate_implement" -eq 1 ]; then
      echo "codex-run.sh: REFUSING — multiple open runs; requirement scope is ambiguous:" >&2
      printf '  %s\n' "${open_runs[@]##*/}" >&2
      echo "codex-run.sh: pass --run <id> or CHARLES_RUN=<id> to select one" >&2
      return 2
    fi
  elif [ "${#open_runs[@]}" -eq 1 ]; then
    run_dir="${open_runs[0]}"
  else
    if [ "$validate_implement" -eq 1 ]; then
      [ "$REQ_SET" -eq 1 ] || return 0
      if [ -z "$PLAN" ]; then
        echo "codex-run.sh: REFUSING — --req implement dispatch has no open run or resolvable plan" >&2
        return 2
      fi
    else
      [ -n "$PLAN" ] || return 0
    fi
    plan_path="$(resolve_plan_path "$PLAN")" || {
      [ "$validate_implement" -eq 0 ] && return 0
      echo "codex-run.sh: REFUSING — no readable plan file: $PLAN" >&2
      return 2
    }
  fi

  local run_name spec spec_path resolved_dir resolved_spec id plan_label pattern_id
  if [ -n "$run_dir" ]; then
    run_name="${run_dir##*/}"
    spec="$(sed -n 's/^- spec: //p' "$run_dir/RUN.md" | head -1)"
    if [ -z "$spec" ]; then
      echo "codex-run.sh: REFUSING — open run $run_name has no associated spec; refusing to guess a plan" >&2
      return 2
    fi
    spec_path="$spec"
    case "$spec_path" in /*) ;; *) spec_path="$RUN_DIR/$spec_path" ;; esac
    if [ ! -f "$spec_path" ]; then
      echo "codex-run.sh: REFUSING — open run $run_name names missing spec $spec" >&2
      return 2
    fi
    if command -v realpath >/dev/null 2>&1; then
      resolved_dir="$(realpath "$RUN_DIR" 2>/dev/null || printf '%s\n' "$RUN_DIR")"
      resolved_spec="$(realpath "$spec_path" 2>/dev/null || printf '%s\n' "$spec_path")"
    elif [ -d "$(dirname "$spec_path")" ]; then
      resolved_dir="$(cd "$RUN_DIR" && pwd -P)"
      [ -L "$spec_path" ] && { echo "codex-run.sh: REFUSING — cannot safely resolve symlinked spec $spec without realpath" >&2; return 2; }
      resolved_spec="$(cd "$(dirname "$spec_path")" && pwd -P)/$(basename "$spec_path")"
    else
      echo "codex-run.sh: REFUSING — cannot resolve spec $spec" >&2
      return 2
    fi
    case "$resolved_spec" in
      "$resolved_dir"/*) ;;
      *) echo "codex-run.sh: REFUSING — open run $run_name names a spec outside the repository: $spec" >&2; return 2 ;;
    esac
    plan_path="$resolved_spec"
    plan_label="$spec"
    if [ "$validate_implement" -eq 1 ] && [ "$REQ_SET" -eq 0 ]; then
      echo "codex-run.sh: REFUSING — implement dispatch must name requirements for open run $run_name ($spec)" >&2
      echo "codex-run.sh: pass --req R1,A3 (identifiers from that spec)" >&2
      return 2
    fi
    FLOW_RUN_ID="$run_name"
    SPEC_PATH="$resolved_spec"
  else
    plan_label="$PLAN"
    SPEC_PATH="$plan_path"
  fi
  [ "$validate_implement" -eq 1 ] || return 0
  local grill_section grill_basis=""
  grill_section="$(awk '
    !in_verdict && /^## Grill verdict([[:space:]]|$)/ { in_verdict=1; next }
    in_verdict && /^## / { exit }
    in_verdict { print }
  ' "$plan_path")"
  if grep -qE '^- Rounds:' <<<"$grill_section"; then
    grill_basis="rounds"
  elif grep -qE '^Grill waived:[[:space:]]*[^[:space:]].*$' <<<"$grill_section"; then
    grill_basis="waived"
  else
    echo "codex-run.sh: REFUSING — spec $plan_label is missing '- Rounds:' or 'Grill waived: <reason>' in its Grill verdict section" >&2
    return 5
  fi
  GRILL_BASIS="$grill_basis"
  # Sign-off is proof, not scope: ranged bullets there must not satisfy --req.
  for id in "${req_ids[@]}"; do
    pattern_id="${id//./[.]}"
    if ! sed '/^## Sign-off[[:space:]]*$/q' "$plan_path" |
      grep -E "^- (\[[ xX]\] )?\*\*${pattern_id}(\*\*|[[:space:]]|[.]([^0-9]|$))" >/dev/null; then
      echo "codex-run.sh: REFUSING — requirement $id is not in $plan_label" >&2
      return 2
    fi
  done
}

validate_main_tree() {
  [ "$LANE" = "implement" ] || return 0
  [ "$ALLOW_MAIN_TREE" -eq 1 ] && return 0

  command -v git >/dev/null 2>&1 || return 0

  # An inherited GIT_DIR/GIT_WORK_TREE/GIT_COMMON_DIR makes rev-parse describe a
  # repository other than the one on disk, which would let a primary checkout
  # pass as linked. The guard asks about $DIR itself, never about the ambient
  # git environment.
  local -a git_clean=(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY git)

  local probe
  probe="$(cd "$DIR" 2>/dev/null && pwd -P)" || {
    echo "codex-run.sh: REFUSING — cannot resolve --dir physically: $DIR" >&2
    return 4
  }
  [ -n "$probe" ] || {
    echo "codex-run.sh: REFUSING — cannot resolve --dir physically: $DIR" >&2
    return 4
  }
  if [ ! -e "$probe/.git" ] && [ ! -L "$probe/.git" ]; then
    local bare_state
    bare_state="$("${git_clean[@]}" -C "$DIR" rev-parse --is-bare-repository 2>/dev/null)" || bare_state=""
    case "$bare_state" in
      true)
        echo "codex-run.sh: REFUSING — implement dispatch cannot run against a bare repository: $DIR" >&2
        echo "codex-run.sh: use a non-bare worktree with --dir <that worktree>" >&2
        return 4
        ;;
      false) ;;
      *) return 0 ;;
    esac
  fi

  local has_git_entry=0
  while :; do
    if [ -e "$probe/.git" ] || [ -L "$probe/.git" ]; then
      has_git_entry=1
      break
    fi
    [ "$probe" = "/" ] && break
    probe="${probe%/*}"
    [ -n "$probe" ] || probe="/"
  done
  [ "$has_git_entry" -eq 1 ] || return 0

  local git_dir common_dir
  if ! git_dir="$("${git_clean[@]}" -C "$probe" rev-parse --git-dir 2>/dev/null)" \
    || ! common_dir="$("${git_clean[@]}" -C "$probe" rev-parse --git-common-dir 2>/dev/null)"; then
    echo "codex-run.sh: REFUSING — repository state could not be determined: $DIR" >&2
    return 4
  fi
  [ "$git_dir" != "$common_dir" ] || {
    echo "codex-run.sh: REFUSING — implement dispatch cannot run against primary working tree: $DIR" >&2
    echo "codex-run.sh: run treehouse get, then re-run with --dir <that worktree>" >&2
    return 4
  }
}

# --- always announce termination ---------------------------------------------
# .last is written only on success, so a dispatch that dies leaves nothing and
# anything waiting on it waits forever — observed as agents stuck 27 minutes on
# engines that had already exited. This marker appears on EVERY exit path,
# including SIGTERM from a harness timeout, so a waiter can always tell
# "finished" from "still running".
kill_child_group() {
  local child_pid="${CHILD_PID:-}" candidate
  if [ -n "${CHILD_PID_FILE:-}" ] && [ -s "$CHILD_PID_FILE" ]; then
    candidate="$(head -1 "$CHILD_PID_FILE" 2>/dev/null || true)"
    [[ "$candidate" =~ ^[0-9]+$ ]] && child_pid="$candidate"
  fi
  [[ "$child_pid" =~ ^[1-9][0-9]*$ ]] && [ "$child_pid" -gt 1 ] || return 0
  kill -TERM -- "-$child_pid" 2>/dev/null || true
}

terminate_dispatch() {
  local rc="$1" engine="${attempt_engine:-$ENGINE}" model="${attempt_model:-}"
  kill_child_group
  log_dispatch "$engine" "$rc" "${ATTEMPT_FALLBACK_FROM:-}" \
    "${ATTEMPT_PRIMARY_RC:-}" "$model"
  exit "$rc"
}

trap 'rc=$?; printf "%s\n" "$rc" > "$RUN.done" 2>/dev/null || true' EXIT
trap 'terminate_dispatch 143' TERM HUP
trap 'terminate_dispatch 130' INT

GUARD='Work ONLY inside the working directory. Git is READ-ONLY for you: status, diff,
log, show are fine; NEVER run any git command that mutates repository state — no reset
(any mode), checkout, switch, restore, rebase, merge, clean, stash, branch changes,
commit, push, or force-push. Never delete or move any file you did not create in this
dispatch, tracked or untracked. If the task is ambiguous or you cannot finish, STOP and
report what blocked you rather than improvising a different design or tidying unrelated
files.'

# The implement lane writes code and inherits no Claude Code skills, so the
# prompt is the only channel. ponytail ships a real Codex plugin, and a lane
# told to load it does (verified: it read skills/ponytail/SKILL.md and quoted
# rung 1 verbatim). Prefer the maintained source; the distillation below is the
# fallback for harnesses that do not have it installed.
LADDER='If a skill named `ponytail` is available in this harness, load and follow
it now — it is the canonical source of what follows, and it is maintained.
Say which file you read. If it is not available, follow this distillation.

Before writing anything, stop at the first rung that holds:
1. Does this need to exist at all? Speculative need means skip it and say so.
2. Does the standard library already do it? Use it.
3. Does a native platform feature cover it? Prefer it over a dependency.
4. Does an already-installed dependency solve it? Use it. Never add a new one
   for what a few lines can do.
5. Can it be one line? Make it one line.
6. Only then: the minimum code that works.

No unrequested abstractions: no interface with one implementation, no factory
for one product, no config for a value that never changes, no scaffolding for a
future that has not arrived. Prefer deleting over adding. Prefer boring over
clever. Fewest files, shortest working diff. Mark a deliberate shortcut with a
comment naming its ceiling and the upgrade path.

Lazy code without its check is unfinished. Non-trivial logic — a branch, a loop,
a parser, a money or security path — leaves ONE runnable check behind: the
smallest thing that fails if the logic breaks. Match whatever the repo already
uses; if it has nothing, an assert-based self-check is enough. No frameworks, no
fixtures, no per-function suites unless asked. Trivial one-liners need no test.

Do NOT simplify away: input validation at trust boundaries, error handling that
prevents data loss, security controls, accessibility basics, or anything the
brief explicitly asked for. If the brief and this instruction conflict, the
brief wins and you say which rung you skipped and why.'

# --- append dispatch events: mechanical, no model cooperation required ---------
# This is both halves of the fix: it is the receipt an agent must echo back
# (closing the inline-fallback hole) and the record `resolve` correlates on.
log_start() {
  local f="$DIR/.charles/dispatches.jsonl" event_engine="$ENGINE"
  mkdir -p "$DIR/.charles" 2>/dev/null || return 1
  touch "$RUN.jsonl" 2>/dev/null || return 1
  [ "$LANE" = "review" ] && event_engine="review"
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg lane "$LANE" \
     --arg engine "$event_engine" --arg run "$RUN_ID" --arg dir "$DIR" \
     --arg task "$(printf '%.200s' "$TASK")" --arg req "$REQ" \
     --arg allow_main_tree "$ALLOW_MAIN_TREE" \
     --arg flow_run_id "${FLOW_RUN_ID:-}" --arg spec_path "${SPEC_PATH:-}" \
     --arg grill "${GRILL_BASIS:-}" \
     '{ts:$ts,event:"start",lane:$lane,engine:$engine,run:$run,dir:$dir,task:$task}
      | if $flow_run_id == "" then . else . + {flow_run_id:$flow_run_id} end
      | if $spec_path == "" then . else . + {spec_path:$spec_path} end
      | if $lane == "implement" then . + {req:($req | if . == "" then [] else split(",") end),allow_main_tree:($allow_main_tree == "1")}
        + (if $grill == "" then {} else {grill:$grill} end) else . end' \
     >> "$f" 2>/dev/null
}

log_dispatch() { # log_dispatch ENGINE RC [FALLBACK_FROM PRIMARY_RC MODEL]
  local f="$DIR/.charles/dispatches.jsonl"
  mkdir -p "$DIR/.charles" 2>/dev/null || return 0
  local model="${5:-}" fallback_from="${3:-}" primary_rc="${4:-}"
  local end_claim="$RUN.$1.end"
  if jq -e --arg r "$RUN_ID" --arg e "$1" \
       'select(.event == "end" and .run == $r and .engine == $e)' \
       "$f" >/dev/null 2>&1; then
    return 0
  fi
  mkdir "$end_claim" 2>/dev/null || return 0
  if [ -z "$model" ]; then
    case "$1" in
      luna)     model="gpt-5.6-luna" ;;
      terra)    model="gpt-5.6-terra" ;;
      deepseek) model="deepseek-v4-flash" ;;
      claude)   model="claude-sonnet-5" ;;
      grok)     model="grok-4.6" ;;
      review)   if [ "$ENGINE_SET" -eq 1 ]; then
                  case "$ENGINE" in luna) model="gpt-5.6-luna" ;; terra) model="gpt-5.6-terra" ;; grok) model="grok-4.6" ;; *) model="gpt-5.6-sol" ;; esac
                else model="gpt-5.6-sol"; fi ;;
      *)        model="$1" ;;
    esac
  fi
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg lane "$LANE" \
     --arg engine "$1" --arg model "$model" --arg rc "$2" --arg run "$RUN_ID" \
     --arg dir "$DIR" --arg task "$(printf '%.200s' "$TASK")" \
     --arg fallback_from "$fallback_from" --arg primary_rc "$primary_rc" --arg req "$REQ" \
     --arg allow_main_tree "$ALLOW_MAIN_TREE" \
     --arg flow_run_id "${FLOW_RUN_ID:-}" --arg spec_path "${SPEC_PATH:-}" \
     --arg grill "${GRILL_BASIS:-}" \
     '{ts:$ts,event:"end",lane:$lane,engine:$engine,model:$model,rc:($rc|tonumber),run:$run,dir:$dir,task:$task}
      | if $flow_run_id == "" then . else . + {flow_run_id:$flow_run_id} end
      | if $spec_path == "" then . else . + {spec_path:$spec_path} end
      | if $lane == "implement" then . + {req:($req | if . == "" then [] else split(",") end),allow_main_tree:($allow_main_tree == "1")}
        + (if $grill == "" then {} else {grill:$grill} end) else . end
      | if $fallback_from != "" then . + {fallback_from:$fallback_from,primary_rc:($primary_rc|tonumber)} else . end' \
     >> "$f" 2>/dev/null || true
}

write_watchdog_state() { # write_watchdog_state ACTIVE ENGINE MODEL FALLBACK_FROM PRIMARY_RC PID_FILE
  printf '%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "${4:-}" "${5:-}" "$6" > "$WATCHDOG_STATE_FILE.tmp" 2>/dev/null \
    && mv -f -- "$WATCHDOG_STATE_FILE.tmp" "$WATCHDOG_STATE_FILE" 2>/dev/null || true
}

start_watchdog() {
  [ -n "$WATCHDOG_PID" ] && return 0
  CHARLES_WATCHDOG=1 \
  CHARLES_WATCHDOG_PARENT="$$" \
  CHARLES_WATCHDOG_STATE_FILE="$WATCHDOG_STATE_FILE" \
  CHARLES_WATCHDOG_STOP_FILE="$WATCHDOG_STOP_FILE" \
  CHARLES_WATCHDOG_RUN="$RUN_ID" \
  CHARLES_WATCHDOG_DONE="$RUN.done" \
  CHARLES_WATCHDOG_LOG="$DIR/.charles/dispatches.jsonl" \
  CHARLES_WATCHDOG_LANE="$LANE" \
  CHARLES_WATCHDOG_DIR="$DIR" \
  CHARLES_WATCHDOG_TASK="$TASK" \
  CHARLES_WATCHDOG_REQ="$REQ" \
  CHARLES_WATCHDOG_ALLOW_MAIN_TREE="$ALLOW_MAIN_TREE" \
  CHARLES_WATCHDOG_FLOW_RUN_ID="${FLOW_RUN_ID:-}" \
  CHARLES_WATCHDOG_SPEC_PATH="${SPEC_PATH:-}" \
  setsid bash "$SCRIPT_DIR/codex-run.sh" 9>&- &
  WATCHDOG_PID=$!
}

stop_watchdog() {
  [ -n "$WATCHDOG_PID" ] || return 0
  : > "$WATCHDOG_STOP_FILE" 2>/dev/null || true
  kill -TERM -- "-$WATCHDOG_PID" 2>/dev/null || kill "$WATCHDOG_PID" 2>/dev/null || true
  wait "$WATCHDOG_PID" 2>/dev/null || true
  WATCHDOG_PID=""
  rm -f "$WATCHDOG_STATE_FILE" "$WATCHDOG_STOP_FILE" "$CHILD_PID_FILE" 2>/dev/null || true
}

run_attempt() { # run_attempt ENGINE MODEL CWD STDOUT STDERR COMMAND...
  local attempt_engine="$1" attempt_model="$2" cwd="$3" output="$4" error="$5"
  shift 5
  ATTEMPT_NO=$((ATTEMPT_NO + 1))
  CHILD_PID_FILE="$RUN.child.$ATTEMPT_NO"
  start_watchdog || return $?
  write_watchdog_state 1 "$attempt_engine" "$attempt_model" \
    "${ATTEMPT_FALLBACK_FROM:-}" "${ATTEMPT_PRIMARY_RC:-}" "$CHILD_PID_FILE"

  # The launcher writes its own PID before exec so the watchdog always has the
  # session's process-group leader, even if the wrapper is killed immediately.
  setsid bash -c 'printf "%s\n" "$$" > "$1"; cwd="$2"; shift 2; cd -- "$cwd" && exec "$@"' \
    _ "$CHILD_PID_FILE" "$cwd" "$@" > "$output" 2> "$error" &
  CHILD_PID=$!
  local rc=0
  wait "$CHILD_PID" || rc=$?
  log_dispatch "$attempt_engine" "$rc" "${ATTEMPT_FALLBACK_FROM:-}" \
    "${ATTEMPT_PRIMARY_RC:-}" "$attempt_model"
  write_watchdog_state 0 "$attempt_engine" "$attempt_model" \
    "${ATTEMPT_FALLBACK_FROM:-}" "${ATTEMPT_PRIMARY_RC:-}" "$CHILD_PID_FILE"
  CHILD_PID=""
  return "$rc"
}

dispatch_timed_out() {
  [[ "$TIMEOUT" =~ ^[0-9]+$ ]] || return 1
  local now_us="${EPOCHREALTIME/./}" elapsed_us timeout_us
  elapsed_us=$((now_us - DISPATCH_STARTED_US))
  timeout_us=$((10#$TIMEOUT * 1000000))
  # Allow a quarter-second of scheduler/receipt slack without treating an early 124 as a timeout.
  [ "$elapsed_us" -ge "$((timeout_us - 250000))" ]
}

# --- clear the hook'"'"'s touched-files counter on a successful dispatch --------------
clear_touched() {
  local root="$1"
  [ -f "$root/.charles/touched" ] && : > "$root/.charles/touched"
  # the work moved to a lane, so the "you already approved inline" grant is spent
  rm -f "$root/.charles/inline-ok" "$root/.charles/pending-ask" 2>/dev/null || true
  return 0
}

# --- local weekly quota probe for luna fast_mode ------------------------------
weekly_quota_fast_mode() {
  if [ "${CHARLES_FAST_MODE:-}" = "1" ]; then
    printf '%s\n' "--enable"
    return 0
  fi
  # R8 operator directive: less than 20% of weekly quota remaining disables fast_mode.
  local weekly_remaining=20
  local sessions_dir="${CHARLES_CODEX_SESSIONS_DIR:-$HOME/.codex/sessions}"
  local day file record decision result="--enable" found=0 day_index file_index scanned=0
  local nullglob_was_set=0
  local -a days=() rollout_files=()
  shopt -q nullglob && nullglob_was_set=1
  shopt -s nullglob
  days=("$sessions_dir"/????/??/??)

  # Date-sharded directories and timestamped rollout names keep this newest-first
  # without recursively scanning the whole sessions tree; cap the probe at 20 files.
  for ((day_index=${#days[@]} - 1; day_index >= 0 && found == 0 && scanned < 20; day_index--)); do
    day="${days[$day_index]}"
    [ -r "$day" ] || { found=1; break; }
    rollout_files=("$day"/rollout-*.jsonl)
    for ((file_index=${#rollout_files[@]} - 1; file_index >= 0 && found == 0 && scanned < 20; file_index--)); do
      file="${rollout_files[$file_index]}"
      [ -r "$file" ] || { found=1; break; }
      scanned=$((scanned + 1))
      if ! record="$(jq -c -s '
        [ .[] | .. | objects | select(
          try (
            (.rate_limits | type) == "object"
            and ([.rate_limits.primary, .rate_limits.secondary]
              | any(.[]; type == "object" and .window_minutes == 10080))
          ) catch false
        ) ] | last // empty
      ' "$file" 2>/dev/null)"; then
        found=1
        break
      fi
      [ -n "$record" ] || continue
      found=1
      if ! decision="$(jq -r --argjson cutoff "$((100 - weekly_remaining))" '
        .rate_limits as $limits
        | if ($limits | type) != "object" then "unknown"
          else
            ([ $limits.primary ]
              | map(select(type == "object" and .window_minutes == 10080
                and ((.used_percent | type) == "number")))
              | .[0].used_percent) as $primary
            | ([ $limits.secondary ]
              | map(select(type == "object" and .window_minutes == 10080
                and ((.used_percent | type) == "number")))
              | .[0].used_percent) as $secondary
            | ($primary // $secondary) as $used
            | if ($used | type) != "number" then "unknown"
              elif $used >= $cutoff then "disable"
              else "enable"
              end
          end
      ' <<<"$record" 2>/dev/null)"; then
        result="--enable"
      else
        case "$decision" in
          disable|enable) result="--$decision" ;;
          *) result="--enable" ;;
        esac
      fi
    done
  done
  [ "$nullglob_was_set" -eq 1 ] || shopt -u nullglob
  printf '%s\n' "$result"
}

# --- engines: luna (primary) and terra (escalation), both gpt-5.6 @ max -------
run_gpt() { # run_gpt PROFILE
  local profile="$1" args fast
  if [ "$profile" = "terra" ]; then fast="--disable"; else fast="$(weekly_quota_fast_mode)"; fi
  if [ "$RESUME" -eq 1 ]; then
    args=(-p "$profile" exec resume --last --skip-git-repo-check "$fast" fast_mode --json -o "$RUN.last")
  else
    # fast_mode is globally default-on; state it here so "fast on luna only" is
    # literally true rather than inherited, and pin effort explicitly.
    args=(-p "$profile" exec --skip-git-repo-check -s "$SANDBOX" -C "$DIR"
          "$fast" fast_mode -c model_reasoning_effort="$EFFORT"
          --json -o "$RUN.last")
  fi
  # </dev/null: codex reads stdin when it is not a tty and blocks forever
  # only the write lane gets the ladder: exploration produces no code
  local extra=""
  [ "$LANE" = "implement" ] && extra="

$LADDER"
  # -k: GNU timeout sends only TERM. A child that ignores it would hang forever,
  # holding the writer lock and never falling back.
  local rc=0
  run_attempt "$profile" "gpt-5.6-$profile" "$DIR" "$RUN.jsonl" "$RUN.err" \
    timeout -k 30s "$TIMEOUT" codex "${args[@]}" "$TASK

$GUARD$extra" < /dev/null || rc=$?
  [ -s "$RUN.last" ] && cat "$RUN.last"
  echo "— codex/gpt-5.6-$profile · effort=$EFFORT · fast_mode=${fast#--}d · sandbox=$SANDBOX · raw: $RUN.jsonl" >&2
  return $rc
}

# --- engine: deepseek @ max (FALLBACK only) -----------------------------------
# Delegates to the existing proven wrapper rather than reimplementing it.
run_deepseek() {
  [ -x "$DS_SCRIPT" ] || { echo "codex-run.sh: missing $DS_SCRIPT" >&2; return 1; }
  local args=(--dir "$DIR" --timeout "$TIMEOUT")
  [ "$SANDBOX" = "read-only" ] && args+=(--read-only)
  [ "$RESUME" -eq 1 ] && args+=(--resume)
  : > "$RUN.last"
  local rc=0
  run_attempt deepseek deepseek-v4-flash "$DIR" "$RUN.last" "$RUN.err" \
    "$DS_SCRIPT" "${args[@]}" "$TASK" || rc=$?
  if [ "$rc" -eq 0 ]; then
    [ -s "$RUN.last" ] && cat "$RUN.last"
  else
    : > "$RUN.last"
  fi
  return "$rc"
}

# --- engine: claude sonnet @ medium -----------------------------------------
run_claude() {
  [ "$EFFORT_SET" -eq 0 ] && EFFORT=medium
  local args=(--model claude-sonnet-5 --effort "$EFFORT" --output-format text)
  if [ "$SANDBOX" = "workspace-write" ]; then
    args+=(--permission-mode bypassPermissions)
  else
    # ponytail: edit tools are blocked, but Bash can still write. Stronger isolation
    # needs an external sandbox; do not build one into this text adapter.
    args+=(--disallowed-tools "Edit Write MultiEdit NotebookEdit")
  fi
  local extra="" rc=0
  [ "$LANE" = "implement" ] && extra="

$LADDER"
  run_attempt claude claude-sonnet-5 "$DIR" "$RUN.jsonl" "$RUN.err" \
    timeout -k 30s "$TIMEOUT" env -u CLAUDECODE -u CLAUDE_CODE_EFFORT_LEVEL \
      CHARLES_INLINE_OK=1 claude -p "$TASK

$GUARD$extra

You ARE the worker lane. Do the work yourself. Do not dispatch another lane,
invoke codex-run, or spawn a subagent, even if repository instructions say to delegate." "${args[@]}" < /dev/null || rc=$?
  # ponytail: the prompt sits right after -p because --disallowed-tools is variadic and would swallow it.
  # Keep live stdout in the transcript: a nonempty .last makes lane-status say DONE.
  if [ "$rc" -eq 0 ]; then cp "$RUN.jsonl" "$RUN.last" || rc=$?; fi
  if [ "$rc" -eq 0 ]; then
    [ -s "$RUN.last" ] && cat "$RUN.last"
  else
    : > "$RUN.last"
  fi
  echo "— claude/claude-sonnet-5 · effort=$EFFORT · sandbox=$SANDBOX · raw: $RUN.jsonl" >&2
  return "$rc"
}

# grok has no "max" reasoning effort — passing it exits non-zero with a usage
# error, so it is translated rather than forwarded blind. Shared by run_grok
# and the review-lane grok fork so both report the same translated value.
resolve_grok_effort() {
  if [ "$EFFORT_SET" -eq 0 ]; then
    EFFORT=high
    return 0
  fi
  case "$EFFORT" in
    max) EFFORT=xhigh ;;
    xhigh|high|medium|low) ;;
    *) echo "codex-run.sh: invalid --effort '$EFFORT' for grok (xhigh|high|medium|low; max maps to xhigh)" >&2; return 2 ;;
  esac
}

# --- engine: grok-4.6 @ high (local grok CLI; ALSO runs review, see run_review) -
run_grok() {
  resolve_grok_effort || return $?
  local args=(--model grok-4.6 --reasoning-effort "$EFFORT" --output-format plain
        --cwd "$DIR" --no-subagents)
  if [ "$SANDBOX" = "workspace-write" ]; then
    args+=(--permission-mode bypassPermissions)
  else
    # ponytail: --disallowed-tools removes write/search_replace, but grok's
    # run_terminal_command can still write. Stronger isolation needs an
    # external sandbox; do not build one into this adapter.
    args+=(--disallowed-tools "write,search_replace")
  fi
  local extra="" rc=0
  [ "$LANE" = "implement" ] && extra="

$LADDER"
  run_attempt grok grok-4.6 "$DIR" "$RUN.jsonl" "$RUN.err" \
    timeout -k 30s "$TIMEOUT" grok -p "$TASK

$GUARD$extra

You ARE the worker lane. Do the work yourself. Do not dispatch another lane,
invoke codex-run, or spawn a subagent, even if repository instructions say to delegate." "${args[@]}" < /dev/null || rc=$?
  if [ "$rc" -eq 0 ]; then cp "$RUN.jsonl" "$RUN.last" || rc=$?; fi
  if [ "$rc" -eq 0 ]; then
    [ -s "$RUN.last" ] && cat "$RUN.last"
  else
    : > "$RUN.last"
  fi
  echo "— grok/grok-4.6 · effort=$EFFORT · sandbox=$SANDBOX · raw: $RUN.jsonl" >&2
  return "$rc"
}

# --- lane: review (sol @ medium; luna/terra @ max; isolated temp dir) ---------
run_review() {
  [ -n "$PLAN" ] || { echo "codex-run.sh: --lane review requires --plan FILE" >&2; return 2; }
  [ -f "$PLAN" ] || { echo "codex-run.sh: no such plan file: $PLAN" >&2; return 2; }
  if [ -n "$BASE" ] && ! git -C "$DIR" rev-parse --verify "$BASE" >/dev/null 2>&1; then
    echo "codex-run.sh: invalid --base ref '$BASE'" >&2
    return 2
  fi

  # No RETURN trap here: it fires after the function's locals are gone, which
  # under `set -u` turns a successful review into exit 1. Clean up explicitly.
  local box rc; box="$(mktemp -d "${TMPDIR:-/tmp}/charles-review.XXXXXX")"
  cp "$PLAN" "$box/plan.md"

  # the plan lives in the repo, so exclude it (and our own scratch) from the
  # diff — otherwise the reviewer reports its own input as scope creep. An
  # outside plan has no pathspec in this repository.
  local plan_rel="" resolved_plan untracked_file
  local -a excludes=(':(exclude).charles' ':(exclude).charles.toml')
  if resolved_plan="$(realpath --relative-to="$DIR" "$PLAN" 2>/dev/null)"; then
    case "$resolved_plan" in
      ..|../*) ;;
      *) plan_rel="$resolved_plan"; excludes+=(":(exclude)$plan_rel") ;;
    esac
  fi

  if git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
    if [ -n "$BASE" ]; then
      if ! git -C "$DIR" diff "$BASE" -- . "${excludes[@]}" > "$box/changes.diff"; then
        echo "codex-run.sh: refusing review — git error while assembling review diff (git diff $BASE)" >&2
        rm -rf "$box"
        return 4
      fi
      NOTE="Input is a git diff from $BASE to the working tree, plus untracked files as additions."
    else
      # HEAD covers staged and unstaged both. A second --cached pass appended
      # every staged hunk a second time, so the reviewer saw duplicates of
      # exactly the changes most likely to be mid-commit.
      if ! git -C "$DIR" diff HEAD -- . "${excludes[@]}" > "$box/changes.diff"; then
        echo "codex-run.sh: refusing review — git error while assembling review diff (git diff HEAD)" >&2
        rm -rf "$box"
        return 4
      fi
      NOTE="Input is a git diff of the working tree against HEAD, plus untracked files as additions."
    fi
    # untracked files are invisible to git diff — append Git's metadata-aware adds
    untracked_file="$box/untracked"
    if ! git -C "$DIR" ls-files --others --exclude-standard -z -- . "${excludes[@]}" > "$untracked_file"; then
      echo "codex-run.sh: refusing review — git error while assembling review diff (git ls-files)" >&2
      rm -rf "$box"
      return 4
    fi
    while IFS= read -r -d '' f; do
      case "$f" in .charles/*|.charles.toml|"$plan_rel") continue ;; esac
      if git -C "$DIR" diff --no-index -- /dev/null "$f" >> "$box/changes.diff"; then
        :
      else
        untracked_diff_rc=$?
        if [ "$untracked_diff_rc" -ne 1 ]; then
          echo "codex-run.sh: refusing review — could not assemble untracked file '$f'" >&2
          rm -rf "$box"
          return 4
        fi
      fi
      if [ ! -s "$box/changes.diff" ]; then
        echo "codex-run.sh: refusing review — could not assemble untracked file '$f'" >&2
        rm -rf "$box"
        return 4
      fi
    done < "$untracked_file"
    # the reviewer prompt claims the box holds exactly two files — so drop the
    # scratch list of untracked paths that assembling the diff needed.
    rm -f "$untracked_file"
  elif [ -n "$FILES" ]; then
    : > "$box/changes.diff"
    IFS=',' read -ra parts <<< "$FILES"
    for f in "${parts[@]}"; do
      printf '\n===== FILE: %s =====\n' "$f" >> "$box/changes.diff"
      cat "$DIR/$f" >> "$box/changes.diff" 2>/dev/null || echo "(unreadable)" >> "$box/changes.diff"
    done
    NOTE="NOT a git repo — input is the FULL TEXT of the changed files, not a diff. You cannot see what was there before. Say so in your verdict."
  else
    rm -rf "$box"
    echo "codex-run.sh: $DIR is not a git repo; pass --files a,b,c for the review lane" >&2
    return 2
  fi

  if [ ! -s "$box/changes.diff" ]; then
    rm -rf "$box"
    echo "codex-run.sh: nothing to review (empty diff)" >&2
    return 3
  fi

  # review defaults to sol; --engine picks another model for a second opinion
  local rmodel rprofile
  if [ "$ENGINE_SET" -eq 1 ]; then
    case "$ENGINE" in
      luna)  rmodel="gpt-5.6-luna";  rprofile=(-p luna) ;;
      terra) rmodel="gpt-5.6-terra"; rprofile=(-p terra) ;;
      deepseek)
        rmodel="deepseek-v4-flash"; rprofile=(-p deepseek)
        # the deepseek profile resolves its key from the environment
        ds_env="${LG_CC_DEEPSEEK_HOME:-$HOME/.config/lg-cc-deepseek}/key.env"
        [ -f "$ds_env" ] && { set -a; . "$ds_env"; set +a; } ;;
      grok)  rmodel="grok-4.6";      rprofile=() ;;
      *)     rmodel="gpt-5.6-sol";   rprofile=() ;;
    esac
  else
    rmodel="gpt-5.6-sol"; rprofile=()
  fi

  if [ "$rmodel" = "grok-4.6" ]; then
    resolve_grok_effort || {
      local effort_rc=$?
      : > "$RUN.last"
      cp "$box/changes.diff" "$RUN.diff" 2>/dev/null || true
      rm -rf "$box"
      return "$effort_rc"
    }
  elif [ "$EFFORT_SET" -eq 0 ]; then
    case "$rmodel" in
      gpt-5.6-sol)        EFFORT=medium ;;
      gpt-5.6-luna|gpt-5.6-terra) EFFORT=max ;;
    esac
  fi

  local review_fast="--disable"
  [ "$rmodel" = "gpt-5.6-luna" ] && review_fast="$(weekly_quota_fast_mode)"

  local prompt="You are an adversarial reviewer. You can see exactly two files: plan.md
(what was supposed to be built) and changes.diff (what was actually built). You cannot
see the repository, the implementer's reasoning, or any test output — by design.

$NOTE

$TASK

Report, in this order:
1. Requirements in plan.md that the changes do NOT satisfy. Quote the plan line.
2. Defects in the changes: bugs, unhandled cases, security or data-loss risks. Cite the diff hunk.
3. Anything in the changes that plan.md never asked for: scope creep, and also
   unrequested complexity — an abstraction with one caller, a config value that
   never varies, a new dependency doing what a few lines would, scaffolding for
   a future the plan never mentions. Quote the hunk and say what it should have
   been instead.
4. Whether non-trivial logic in the diff — a branch, a loop, a parser, a money
   or security path — shipped a runnable check alongside it. A missing check on
   non-trivial logic is Required, not a nit. Trivial one-liners need none.
5. A one-line verdict: SATISFIES PLAN | GAPS FOUND | CANNOT TELL (and why).

Prefix every finding with Critical: (blocks — security, data loss, broken
behaviour), Required: (must fix before this counts as done), or Nit: (optional,
the author may ignore it). Order by leverage: correctness and security first.
If you have one structural problem and ten nits, the structural problem is the
review.

Do not praise. Do not summarise the diff back. If you find nothing, say so plainly."

  # grok builds its own command instead of bending codex's exec argv: none of
  # -p <profile>, -m, -c model_reasoning_effort=, fast_mode, or --json -o apply,
  # and lane-status.sh reads $RUN.last, so it is published the same way R4 does.
  if [ "$rmodel" = "grok-4.6" ]; then
    # ponytail: --disallowed-tools removes write/search_replace, but grok's
    # run_terminal_command can still write. Stronger isolation needs an
    # external sandbox; do not build one into this adapter.
    local grok_args=(--model grok-4.6 --reasoning-effort "$EFFORT" --output-format plain
          --cwd "$box" --no-subagents --disallowed-tools "write,search_replace")
    local rc=0
    run_attempt review grok-4.6 "$box" "$RUN.jsonl" "$RUN.err" \
      timeout -k 30s "$TIMEOUT" grok -p "$prompt" "${grok_args[@]}" < /dev/null || rc=$?
    if [ "$rc" -eq 0 ]; then cp "$RUN.jsonl" "$RUN.last" || rc=$?; fi
    if [ "$rc" -ne 0 ]; then : > "$RUN.last"; fi
    cp "$box/changes.diff" "$RUN.diff" 2>/dev/null || true
    rm -rf "$box"
    [ -s "$RUN.last" ] && cat "$RUN.last"
    echo "" >&2
    echo "— grok/grok-4.6 · effort=$EFFORT · isolated · raw: $RUN.jsonl" >&2
    return "$rc"
  fi

  local rc=0
  run_attempt review "$rmodel" "$box" "$RUN.jsonl" "$RUN.err" \
    timeout -k 30s "$TIMEOUT" codex "${rprofile[@]}" exec --skip-git-repo-check \
      -s read-only -C "$box" -m "$rmodel" -c model_reasoning_effort="$EFFORT" \
      "$review_fast" fast_mode \
      --json -o "$RUN.last" "$prompt" < /dev/null || rc=$?
  cp "$box/changes.diff" "$RUN.diff" 2>/dev/null || true
  rm -rf "$box"
  [ -s "$RUN.last" ] && cat "$RUN.last"
  echo "" >&2
  echo "— codex/$rmodel · effort=$EFFORT · fast_mode=${review_fast#--}d · isolated · raw: $RUN.jsonl" >&2
  return $rc
}

# The role and its required inputs are validated before the start event. A
# refused or malformed dispatch therefore has no start to orphan.
case "$LANE" in
  explore)   SANDBOX="read-only" ;;
  implement) ;;
  review)
    [ -n "$PLAN" ] || { echo "codex-run.sh: --lane review requires --plan FILE" >&2; exit 2; }
    [ -f "$PLAN" ] || { echo "codex-run.sh: no such plan file: $PLAN" >&2; exit 2; }
    ;;
  *) echo "codex-run.sh: unknown lane '$LANE' (explore|implement|review)" >&2; exit 2 ;;
esac
if [ "$LANE" != "review" ]; then
  case "$ENGINE" in luna|terra|deepseek|claude|grok) ;; *) echo "codex-run.sh: unknown engine '$ENGINE' (luna|terra|deepseek|claude|grok)" >&2; exit 2 ;; esac
fi
[ "$REQ_SET" -eq 0 ] || [ "$LANE" = "implement" ] || { echo "codex-run.sh: --req is only valid with --lane implement" >&2; exit 2; }
[ "$VALIDATE_ONLY" -eq 0 ] || [ "$LANE" = "implement" ] || { echo "codex-run.sh: --validate-only is only valid with --lane implement" >&2; exit 2; }
validate_dispatch_scope || exit $?
[ "$VALIDATE_ONLY" -eq 0 ] || exit 0
validate_main_tree || exit $?

# codex and grok are separate dependencies; require only the one the resolved
# lane/engine will actually spawn (R16). A grok-only dispatch on a machine
# without codex must not die on a check it never needed.
if [ "$LANE" = "review" ]; then
  if [ "$ENGINE_SET" -eq 1 ] && [ "$ENGINE" = "grok" ]; then
    command -v grok >/dev/null || { echo "codex-run.sh: grok CLI not on PATH" >&2; exit 127; }
  else
    command -v codex >/dev/null || { echo "codex-run.sh: codex CLI not on PATH" >&2; exit 127; }
  fi
elif [ "$ENGINE" = "grok" ]; then
  command -v grok >/dev/null || { echo "codex-run.sh: grok CLI not on PATH" >&2; exit 127; }
else
  command -v codex >/dev/null || { echo "codex-run.sh: codex CLI not on PATH" >&2; exit 127; }
fi

# --- refuse a second writer on the same tree ---------------------------------
# Two workspace-write dispatches on one directory interleave their edits and the
# loser is silently overwritten. Observed live: a dispatch killed by the harness
# 10-minute cap was re-dispatched while the original codex was still writing.
# Worktree isolation was documented but never enforced by anything; this is.
if [ "$LANE" = "implement" ] && [ "$SANDBOX" = "workspace-write" ]; then
  # flock, not pgrep: the probe was racy (two simultaneous starts could both
  # pass it) and blind to `--resume`, which omits -C and so never matched.
  # The lock is held on this process until it exits, by the kernel.
  mkdir -p "$DIR/.charles" 2>/dev/null || true
  exec 9>"$DIR/.charles/implement.lock"
  if ! flock -n 9; then
    others=1
  else
    others=0
  fi
  if [ "${others:-0}" -gt 0 ]; then
    echo "codex-run.sh: REFUSING — $others implement dispatch(es) already writing to $DIR" >&2
    echo "codex-run.sh: two writers on one tree interleave edits and silently lose work." >&2
    echo "codex-run.sh: wait for it to finish, or give this one its own worktree:" >&2
    echo "codex-run.sh:   treehouse get   # then re-run with --dir <that worktree>" >&2
    echo "codex-run.sh: override deliberately with CHARLES_ALLOW_CONCURRENT_WRITES=1" >&2
    [ "${CHARLES_ALLOW_CONCURRENT_WRITES:-0}" = "1" ] || exit 4
    echo "codex-run.sh: override set — proceeding anyway" >&2
  fi
fi

if ! log_start; then
  if [ "$LANE" = "implement" ]; then
    echo "codex-run.sh: failed to write implement start event; aborting dispatch (exit 6)" >&2
    exit 6
  fi
  echo "codex-run.sh: WARNING — failed to write $LANE start event; continuing without receipt" >&2
fi
DISPATCH_STARTED_US="${EPOCHREALTIME/./}"

dispatch() { # dispatch ENGINE
  case "$1" in
    luna)     run_gpt luna ;;
    terra)    run_gpt terra ;;
    deepseek) run_deepseek ;;
    claude)   run_claude ;;
    grok)     run_grok ;;
    *) echo "codex-run.sh: unknown engine '$1' (luna|terra|deepseek|claude|grok)" >&2; exit 2 ;;
  esac
}

if [ "$LANE" = "review" ]; then
  set +e; run_review; RC=$?; set -e
else
  set +e; dispatch "$ENGINE"; RC=$?; set -e

  # Engine fallback: luna is primary, deepseek catches a broken luna profile or
  # a transient failure. Same role, same sandbox — only the model changes.
  # There is deliberately NO fallback to inline editing: that would defeat the
  # entire point of routing this work out in the first place.
  if [ $RC -ne 0 ] && [ "$FALLBACK" -eq 1 ] && { [ "$ENGINE" = "luna" ] || [ "$ENGINE" = "terra" ]; }; then
    primary_rc="$RC"
    if [ "$primary_rc" -eq 124 ] && dispatch_timed_out; then
      echo "codex-run.sh: fallback was skipped because the task timed out" >&2
    else
      ATTEMPT_FALLBACK_FROM="$ENGINE"
      ATTEMPT_PRIMARY_RC="$primary_rc"
      echo "codex-run.sh: $ENGINE failed (exit $primary_rc) — falling back to deepseek for this $LANE" >&2
      set +e; dispatch deepseek; RC=$?; set -e
      if [ "$RC" -eq 0 ]; then
        if [ -s "$RUN.last" ]; then
          printf '\nfallback_from:%s primary_rc:%s\n' "$ENGINE" "$primary_rc" >> "$RUN.last"
        else
          printf 'fallback_from:%s primary_rc:%s\n' "$ENGINE" "$primary_rc" > "$RUN.last"
        fi
      fi
      echo "codex-run.sh: fallback receipt fallback_from:$ENGINE primary_rc:$primary_rc" >&2
    fi
  fi
fi

printf '%s\n' "$RC" > "$RUN.done" 2>/dev/null || true
stop_watchdog

if [ $RC -ne 0 ]; then
  echo "codex-run.sh: dispatch failed (exit $RC)" >&2
  [ $RC -eq 124 ] && echo "codex-run.sh: timed out after ${TIMEOUT}s" >&2
  [ -f "$RUN.err" ] && tail -5 "$RUN.err" >&2
  echo "codex-run.sh: STOPPING. Do not do this work inline — fix the lane and re-dispatch." >&2
  exit $RC
fi

clear_touched "$DIR"
exit 0

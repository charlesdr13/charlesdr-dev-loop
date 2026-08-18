
#!/usr/bin/env bash
# codex-run.sh — dispatch work to a Codex lane.
#
# Roles (--lane):
#   explore   read-only investigation
#   implement writes into the working tree
#   review    adversarial grading, ISOLATED. sol @ medium by default; --engine
#             luna|terra runs the same isolated review on another model. Review
#             is read-only and the cheapest lane, so two in parallel is cheap —
#             and measured, two models overlapped on 1 finding out of 13.
#
# Engines (--engine), for explore and implement:
#   luna      gpt-5.6-luna @ max      PRIMARY — every dispatch starts here
#   terra     gpt-5.6-terra @ max     ESCALATION — when luna's work came back wrong
#   deepseek  deepseek-v4-flash @ max FALLBACK — when luna failed to run at all
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
#   codex-run.sh --lane implement [--dir D] [--engine E] [--effort E] [--fast] [--read-only] "task"
#   codex-run.sh --lane review    --dir D --plan FILE [--files a,b] "task"
#
# --fast is shorthand for --effort high. fast_mode is enabled explicitly on the
# luna engine and disabled on the review lane, so it applies to luna only.

set -euo pipefail

LANE=""
ENGINE="luna"        # primary for every dispatch; deepseek is the fallback only
ENGINE_SET=0         # review defaults to sol, so it must know if you chose one
EFFORT="max"         # luna reasoning effort: max | high | medium. high is markedly
                     # faster and is Codex's own default; max is the quality ceiling.
DIR="$PWD"
SANDBOX="workspace-write"
RESUME=0
TIMEOUT=1800       # measured: median successful run 8.8 min, p90 22.8 min. A 540s
                   # cap (chosen to fit the Bash tool) would have truncated 57% of
                   # successful explores. Long runs are normal; see the agent docs
                   # for the background + lane-status pattern that survives them.
PLAN=""
FILES=""
FALLBACK=1
STATE_DIR="${CHARLES_STATE_DIR:-$HOME/.cache/charlesdr-dev-loop}"
DS_SCRIPT="$HOME/.claude/skills/codex-deepseek/scripts/codex-ds.sh"

usage() { sed -n '2,24p' "$0"; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --lane)      LANE="$2"; shift 2 ;;
    --engine)    ENGINE="$2"; ENGINE_SET=1; shift 2 ;;
    --effort)    EFFORT="$2"; shift 2 ;;
    --fast)      EFFORT="high"; shift ;;
    --dir)       DIR="$2"; shift 2 ;;
    --plan)      PLAN="$2"; shift 2 ;;
    --files)     FILES="$2"; shift 2 ;;
    --read-only) SANDBOX="read-only"; shift ;;
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
[ -n "$LANE" ] || { echo "codex-run.sh: --lane is required" >&2; usage; }
[ -n "$TASK" ] || { echo "codex-run.sh: no task given" >&2; exit 2; }
[ -d "$DIR" ]  || { echo "codex-run.sh: no such directory: $DIR" >&2; exit 2; }
command -v codex >/dev/null || { echo "codex-run.sh: codex CLI not on PATH" >&2; exit 127; }

# --- global engine switch ------------------------------------------------------
# ponytail: a file, not just an env var — each harness Bash call is a fresh shell,
# so `export CHARLES_ENGINE=deepseek` cannot persist across dispatches. Written by
# the /engine command; an explicit --engine on the call still wins.
if [ "$ENGINE_SET" -eq 0 ]; then
  pick="${CHARLES_ENGINE:-}"
  [ -n "$pick" ] || pick="$(cat "$STATE_DIR/engine" 2>/dev/null || true)"
  case "$pick" in
    luna|terra|deepseek) ENGINE="$pick"; ENGINE_SET=1 ;;   # review honours it too
  esac
fi

DIR="$(cd "$DIR" && pwd)"
mkdir -p "$STATE_DIR"
RUN="$STATE_DIR/$(date +%Y%m%d-%H%M%S)-$$-$LANE"
RUN_ID="${RUN##*/}"

# --- always announce termination ---------------------------------------------
# .last is written only on success, so a dispatch that dies leaves nothing and
# anything waiting on it waits forever — observed as agents stuck 27 minutes on
# engines that had already exited. This marker appears on EVERY exit path,
# including SIGTERM from a harness timeout, so a waiter can always tell
# "finished" from "still running".
trap 'rc=$?; printf "%s\n" "$rc" > "$RUN.done" 2>/dev/null || true' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

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
     --arg task "$(printf '%.200s' "$TASK")" \
     '{ts:$ts,event:"start",lane:$lane,engine:$engine,run:$run,dir:$dir,task:$task}' \
     >> "$f" 2>/dev/null
}

log_dispatch() { # log_dispatch ENGINE RC [FALLBACK_FROM PRIMARY_RC]
  local f="$DIR/.charles/dispatches.jsonl"
  mkdir -p "$DIR/.charles" 2>/dev/null || return 0
  local model fallback_from="${3:-}" primary_rc="${4:-}"
  case "$1" in
    luna)     model="gpt-5.6-luna" ;;
    terra)    model="gpt-5.6-terra" ;;
    deepseek) model="deepseek-v4-flash" ;;
    review)   if [ "$ENGINE_SET" -eq 1 ]; then
                case "$ENGINE" in luna) model="gpt-5.6-luna" ;; terra) model="gpt-5.6-terra" ;; *) model="gpt-5.6-sol" ;; esac
              else model="gpt-5.6-sol"; fi ;;
    *)        model="$1" ;;
  esac
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg lane "$LANE" \
     --arg engine "$1" --arg model "$model" --arg rc "$2" --arg run "$RUN_ID" \
     --arg dir "$DIR" --arg task "$(printf '%.200s' "$TASK")" \
     --arg fallback_from "$fallback_from" --arg primary_rc "$primary_rc" \
     '{ts:$ts,event:"end",lane:$lane,engine:$engine,model:$model,rc:($rc|tonumber),run:$run,dir:$dir,task:$task}
      | if $fallback_from != "" then . + {fallback_from:$fallback_from,primary_rc:($primary_rc|tonumber)} else . end' \
     >> "$f" 2>/dev/null || true
}

# --- clear the hook'"'"'s touched-files counter on a successful dispatch --------------
clear_touched() {
  local root="$1"
  [ -f "$root/.charles/touched" ] && : > "$root/.charles/touched"
  return 0
}

# --- engines: luna (primary) and terra (escalation), both gpt-5.6 @ max -------
run_gpt() { # run_gpt PROFILE
  local profile="$1" args fast
  # fast_mode on luna only. terra is the escalation engine — it is reached after
  # two failures, which is exactly when you want its full deliberation, not a
  # faster answer.
  if [ "$profile" = "terra" ]; then fast="--disable"; else fast="--enable"; fi
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
  ( cd "$DIR" && timeout -k 30s "$TIMEOUT" codex "${args[@]}" "$TASK

$GUARD$extra" < /dev/null ) > "$RUN.jsonl" 2> "$RUN.err"
  local rc=$?
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
  "$DS_SCRIPT" "${args[@]}" "$TASK" > "$RUN.last" || rc=$?
  if [ "$rc" -eq 0 ]; then
    [ -s "$RUN.last" ] && cat "$RUN.last"
  else
    : > "$RUN.last"
  fi
  return "$rc"
}

# --- lane: review (sol @ medium, isolated temp dir) ---------------------------
run_review() {
  [ -n "$PLAN" ] || { echo "codex-run.sh: --lane review requires --plan FILE" >&2; return 2; }
  [ -f "$PLAN" ] || { echo "codex-run.sh: no such plan file: $PLAN" >&2; return 2; }

  # No RETURN trap here: it fires after the function's locals are gone, which
  # under `set -u` turns a successful review into exit 1. Clean up explicitly.
  local box rc; box="$(mktemp -d "${TMPDIR:-/tmp}/charles-review.XXXXXX")"
  cp "$PLAN" "$box/plan.md"

  # the plan lives in the repo, so exclude it (and our own scratch) from the
  # diff — otherwise the reviewer reports its own input as scope creep.
  local plan_rel; plan_rel="$(realpath --relative-to="$DIR" "$PLAN" 2>/dev/null || echo "")"

  if git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
    { git -C "$DIR" diff HEAD -- . ':(exclude).charles' ':(exclude).charles.toml' ${plan_rel:+":(exclude)$plan_rel"}
      git -C "$DIR" diff --cached -- . ':(exclude).charles' ':(exclude).charles.toml' ${plan_rel:+":(exclude)$plan_rel"}
    } > "$box/changes.diff" 2>/dev/null || true
    # untracked files are invisible to git diff — append them as adds
    git -C "$DIR" ls-files --others --exclude-standard -z 2>/dev/null |
      while IFS= read -r -d '' f; do
        case "$f" in .charles/*|.charles.toml|"$plan_rel") continue ;; esac
        printf '\n--- /dev/null\n+++ b/%s\n' "$f" >> "$box/changes.diff"
        sed 's/^/+/' "$DIR/$f" >> "$box/changes.diff" 2>/dev/null || true
      done
    NOTE="Input is a git diff of the working tree against HEAD, plus untracked files as additions."
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
      *)     rmodel="gpt-5.6-sol";   rprofile=() ;;
    esac
  else
    rmodel="gpt-5.6-sol"; rprofile=()
  fi

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
4. A one-line verdict: SATISFIES PLAN | GAPS FOUND | CANNOT TELL (and why).
Do not praise. Do not summarise the diff back. If you find nothing, say so plainly."

  set +e
  ( cd "$box" && timeout -k 30s "$TIMEOUT" codex "${rprofile[@]}" exec --skip-git-repo-check \
      -s read-only -C "$box" -m "$rmodel" -c model_reasoning_effort=medium \
      --disable fast_mode \
      --json -o "$RUN.last" "$prompt" < /dev/null ) > "$RUN.jsonl" 2> "$RUN.err"
  rc=$?
  set -e
  cp "$box/changes.diff" "$RUN.diff" 2>/dev/null || true
  rm -rf "$box"
  [ -s "$RUN.last" ] && cat "$RUN.last"
  echo "" >&2
  echo "— codex/$rmodel · effort=medium · isolated · raw: $RUN.jsonl" >&2
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
  case "$ENGINE" in luna|terra|deepseek) ;; *) echo "codex-run.sh: unknown engine '$ENGINE' (luna|terra|deepseek)" >&2; exit 2 ;; esac
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

dispatch() { # dispatch ENGINE
  case "$1" in
    luna)     run_gpt luna ;;
    terra)    run_gpt terra ;;
    deepseek) run_deepseek ;;
    *) echo "codex-run.sh: unknown engine '$1' (luna|terra|deepseek)" >&2; exit 2 ;;
  esac
}

if [ "$LANE" = "review" ]; then
  set +e; run_review; RC=$?; set -e
  log_dispatch review "$RC"
else
  set +e; dispatch "$ENGINE"; RC=$?; set -e
  log_dispatch "$ENGINE" "$RC"

  # Engine fallback: luna is primary, deepseek catches a broken luna profile or
  # a transient failure. Same role, same sandbox — only the model changes.
  # There is deliberately NO fallback to inline editing: that would defeat the
  # entire point of routing this work out in the first place.
  if [ $RC -ne 0 ] && [ "$FALLBACK" -eq 1 ] && { [ "$ENGINE" = "luna" ] || [ "$ENGINE" = "terra" ]; }; then
    primary_rc="$RC"
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
    log_dispatch deepseek "$RC" "$ENGINE" "$primary_rc"
  fi
fi

if [ $RC -ne 0 ]; then
  echo "codex-run.sh: dispatch failed (exit $RC)" >&2
  [ $RC -eq 124 ] && echo "codex-run.sh: timed out after ${TIMEOUT}s" >&2
  [ -f "$RUN.err" ] && tail -5 "$RUN.err" >&2
  echo "codex-run.sh: STOPPING. Do not do this work inline — fix the lane and re-dispatch." >&2
  exit $RC
fi

clear_touched "$DIR"
exit 0

#!/usr/bin/env bash
# codex-run.sh — dispatch work to a Codex lane.
#
# Roles (--lane):
#   explore   read-only investigation
#   implement writes into the working tree
#   review    adversarial grading, ISOLATED (always gpt-5.6-sol @ medium)
#
# Engines (--engine), for explore and implement:
#   luna      gpt-5.6-luna @ max      PRIMARY — every dispatch starts here
#   deepseek  deepseek-v4-flash @ max FALLBACK — only when luna fails
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
EFFORT="max"         # luna reasoning effort: max | high | medium. high is markedly
                     # faster and is Codex's own default; max is the quality ceiling.
DIR="$PWD"
SANDBOX="workspace-write"
RESUME=0
TIMEOUT=540        # the Bash tool caps one call at 600s; stay under it
PLAN=""
FILES=""
FALLBACK=1
STATE_DIR="${CHARLES_STATE_DIR:-$HOME/.cache/charlesdr-dev-loop}"
DS_SCRIPT="$HOME/.claude/skills/codex-deepseek/scripts/codex-ds.sh"

usage() { sed -n '2,24p' "$0"; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --lane)      LANE="$2"; shift 2 ;;
    --engine)    ENGINE="$2"; shift 2 ;;
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

DIR="$(cd "$DIR" && pwd)"
mkdir -p "$STATE_DIR"
RUN="$STATE_DIR/$(date +%Y%m%d-%H%M%S)-$$-$LANE"

GUARD='Work ONLY inside the working directory. Never run git clean, git reset --hard,
git checkout -- ., or anything that discards uncommitted work. Never commit, push, or
force-push. If the task is ambiguous or you cannot finish, STOP and report what blocked
you rather than improvising a different design or tidying unrelated files.'

# --- append a dispatch receipt: mechanical, no model cooperation required -----
# This is both halves of the fix: it is the receipt an agent must echo back
# (closing the inline-fallback hole) and the record `resolve` correlates on.
log_dispatch() { # log_dispatch ENGINE RC
  local f="$DIR/.charles/dispatches.jsonl"
  mkdir -p "$DIR/.charles" 2>/dev/null || return 0
  local model
  case "$1" in
    luna)     model="gpt-5.6-luna" ;;
    deepseek) model="deepseek-v4-flash" ;;
    review)   model="gpt-5.6-sol" ;;
    *)        model="$1" ;;
  esac
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg lane "$LANE" \
     --arg engine "$1" --arg model "$model" --arg rc "$2" --arg run "$RUN" \
     --arg task "$(printf '%.200s' "$TASK")" \
     '{ts:$ts,lane:$lane,engine:$engine,model:$model,rc:($rc|tonumber),run:$run,task:$task}' \
     >> "$f" 2>/dev/null || true
}

# --- clear the hook'"'"'s touched-files counter on a successful dispatch --------------
clear_touched() {
  local root="$1"
  [ -f "$root/.charles/touched" ] && : > "$root/.charles/touched"
  return 0
}

# --- engine: luna @ max (PRIMARY for both explore and implement) --------------
run_luna() {
  local args
  if [ "$RESUME" -eq 1 ]; then
    args=(-p luna exec resume --last --skip-git-repo-check --enable fast_mode --json -o "$RUN.last")
  else
    # fast_mode is globally default-on; state it here so "fast on luna only" is
    # literally true rather than inherited, and pin effort explicitly.
    args=(-p luna exec --skip-git-repo-check -s "$SANDBOX" -C "$DIR"
          --enable fast_mode -c model_reasoning_effort="$EFFORT"
          --json -o "$RUN.last")
  fi
  # </dev/null: codex reads stdin when it is not a tty and blocks forever
  ( cd "$DIR" && timeout "$TIMEOUT" codex "${args[@]}" "$TASK

$GUARD" < /dev/null ) > "$RUN.jsonl" 2> "$RUN.err"
  local rc=$?
  [ -s "$RUN.last" ] && cat "$RUN.last"
  echo "— codex/gpt-5.6-luna · effort=$EFFORT · fast_mode=on · sandbox=$SANDBOX · raw: $RUN.jsonl" >&2
  return $rc
}

# --- engine: deepseek @ max (FALLBACK only) -----------------------------------
# Delegates to the existing proven wrapper rather than reimplementing it.
run_deepseek() {
  [ -x "$DS_SCRIPT" ] || { echo "codex-run.sh: missing $DS_SCRIPT" >&2; return 1; }
  local args=(--dir "$DIR" --timeout "$TIMEOUT")
  [ "$SANDBOX" = "read-only" ] && args+=(--read-only)
  [ "$RESUME" -eq 1 ] && args+=(--resume)
  "$DS_SCRIPT" "${args[@]}" "$TASK"
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

  local prompt="You are an adversarial reviewer. You can see exactly two files: plan.md
(what was supposed to be built) and changes.diff (what was actually built). You cannot
see the repository, the implementer's reasoning, or any test output — by design.

$NOTE

$TASK

Report, in this order:
1. Requirements in plan.md that the changes do NOT satisfy. Quote the plan line.
2. Defects in the changes: bugs, unhandled cases, security or data-loss risks. Cite the diff hunk.
3. Anything in the changes that plan.md never asked for (scope creep).
4. A one-line verdict: SATISFIES PLAN | GAPS FOUND | CANNOT TELL (and why).
Do not praise. Do not summarise the diff back. If you find nothing, say so plainly."

  set +e
  ( cd "$box" && timeout "$TIMEOUT" codex exec --skip-git-repo-check \
      -s read-only -C "$box" -m gpt-5.6-sol -c model_reasoning_effort=medium \
      --disable fast_mode \
      --json -o "$RUN.last" "$prompt" < /dev/null ) > "$RUN.jsonl" 2> "$RUN.err"
  rc=$?
  set -e
  cp "$box/changes.diff" "$RUN.diff" 2>/dev/null || true
  rm -rf "$box"
  [ -s "$RUN.last" ] && cat "$RUN.last"
  echo "" >&2
  echo "— codex/gpt-5.6-sol · effort=medium · isolated · raw: $RUN.jsonl" >&2
  return $rc
}

# The role fixes the sandbox; the engine is what actually runs.
case "$LANE" in
  explore)   SANDBOX="read-only" ;;
  implement) ;;                       # keeps workspace-write unless --read-only
  review)    ;;
  *) echo "codex-run.sh: unknown lane '$LANE' (explore|implement|review)" >&2; exit 2 ;;
esac

dispatch() { # dispatch ENGINE
  case "$1" in
    luna)     run_luna ;;
    deepseek) run_deepseek ;;
    *) echo "codex-run.sh: unknown engine '$1' (luna|deepseek)" >&2; exit 2 ;;
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
  if [ $RC -ne 0 ] && [ "$FALLBACK" -eq 1 ] && [ "$ENGINE" = "luna" ]; then
    echo "codex-run.sh: luna failed (exit $RC) — falling back to deepseek for this $LANE" >&2
    set +e; dispatch deepseek; RC=$?; set -e
    log_dispatch deepseek "$RC"
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

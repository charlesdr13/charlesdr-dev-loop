#!/usr/bin/env bash
# codex-run.sh — dispatch work to a Codex lane.
#
# Lanes:
#   explore   deepseek-v4-flash @ max, read-only      (wide fan-out, cents/task)
#   implement gpt-5.6-luna      @ max, workspace-write (lands in your repo)
#   review    gpt-5.6-sol       @ medium, read-only    (adversarial, ISOLATED)
#
# The review lane runs in a temp dir containing ONLY plan.md + changes.diff.
# That isolation is the point: a grader that can read the implementer's
# transcript gets talked into agreeing with it. Enforced here, not by prompt.
#
# Usage:
#   codex-run.sh --lane explore   [--dir D] [--timeout N] "task"
#   codex-run.sh --lane implement [--dir D] [--read-only] [--resume] "task"
#   codex-run.sh --lane review    --dir D --plan FILE [--files a,b] "task"

set -euo pipefail

LANE=""
DIR="$PWD"
SANDBOX="workspace-write"
RESUME=0
TIMEOUT=1800
PLAN=""
FILES=""
FALLBACK=1
STATE_DIR="${CHARLES_STATE_DIR:-$HOME/.cache/charlesdr13}"
DS_SCRIPT="$HOME/.claude/skills/codex-deepseek/scripts/codex-ds.sh"

usage() { sed -n '2,20p' "$0"; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --lane)      LANE="$2"; shift 2 ;;
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

# --- clear the hook'"'"'s touched-files counter on a successful dispatch --------------
clear_touched() {
  local root="$1"
  [ -f "$root/.charles/touched" ] && : > "$root/.charles/touched"
  return 0
}

# --- lane: explore (deepseek, delegates to the existing proven wrapper) --------
run_explore() {
  [ -x "$DS_SCRIPT" ] || { echo "codex-run.sh: missing $DS_SCRIPT" >&2; return 1; }
  local args=(--dir "$DIR" --timeout "$TIMEOUT")
  [ "$SANDBOX" = "read-only" ] && args+=(--read-only)
  [ "$RESUME" -eq 1 ] && args+=(--resume)
  "$DS_SCRIPT" "${args[@]}" "$TASK"
}

# --- lane: implement (luna @ max) ---------------------------------------------
run_implement() {
  local args
  if [ "$RESUME" -eq 1 ]; then
    args=(-p luna exec resume --last --skip-git-repo-check --json -o "$RUN.last")
  else
    args=(-p luna exec --skip-git-repo-check -s "$SANDBOX" -C "$DIR" --json -o "$RUN.last")
  fi
  # </dev/null: codex reads stdin when it is not a tty and blocks forever
  ( cd "$DIR" && timeout "$TIMEOUT" codex "${args[@]}" "$TASK

$GUARD" < /dev/null ) > "$RUN.jsonl" 2> "$RUN.err"
  [ -s "$RUN.last" ] && cat "$RUN.last"
  echo "— codex/gpt-5.6-luna · effort=max · raw: $RUN.jsonl" >&2
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
      -s read-only -C "$box" -c model_reasoning_effort=medium \
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

dispatch() {
  case "$1" in
    explore)   run_explore ;;
    implement) run_implement ;;
    review)    run_review ;;
    *) echo "codex-run.sh: unknown lane '$1' (explore|implement|review)" >&2; exit 2 ;;
  esac
}

set +e
dispatch "$LANE"
RC=$?
set -e

# Cross-lane retry (explore <-> implement only). A failure here is usually one
# broken profile or key, not a broken task. Review has no counterpart: hard stop.
# There is deliberately NO fallback to inline editing — that would defeat the
# entire point of routing this work out in the first place.
if [ $RC -ne 0 ] && [ "$FALLBACK" -eq 1 ]; then
  case "$LANE" in
    explore)   ALT=implement ;;
    implement) ALT=explore ;;
    *)         ALT="" ;;
  esac
  if [ -n "$ALT" ]; then
    echo "codex-run.sh: lane '$LANE' failed (exit $RC) — retrying once on '$ALT'" >&2
    set +e; dispatch "$ALT"; RC=$?; set -e
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

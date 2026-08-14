#!/usr/bin/env bash
# parallel-chunks.sh — run disjoint implement chunks concurrently, safely.
#
# Serial chunking localises failure but pays for it in wall clock: implement is
# 1.9 min at the median and 19.5 at p90, so three long disjoint chunks cost ~30
# minutes serially and ~10 in parallel. That is worth having.
#
# What makes it safe is not the worktrees, it is the check afterwards. Each
# chunk DECLARES the files it may touch; a chunk that wrote outside its
# declaration is rejected and never merged. Disjoint declarations plus enforced
# declarations means the merge cannot clobber.
#
#   parallel-chunks.sh <repo> <spec.json> [--timeout N]
#
#   spec.json: [ {"name":"api","files":["src/a.ts","src/b.ts"],"task":"..."}, ... ]
#
# exit 0  every chunk landed
# exit 1  refused before dispatching (overlapping declarations, no treehouse)
# exit 3  some chunk failed or wrote out of bounds; those are NOT merged
set -uo pipefail

REPO="${1:?usage: parallel-chunks.sh <repo> <spec.json>}"; shift
SPEC="${1:?spec.json required}"; shift || true
TIMEOUT=1800
while [ $# -gt 0 ]; do case "$1" in --timeout) TIMEOUT="$2"; shift 2 ;; *) shift ;; esac; done

[ -d "$REPO" ] || { echo "no such repo: $REPO" >&2; exit 1; }
[ -f "$SPEC" ] || { echo "no such spec: $SPEC" >&2; exit 1; }
REPO="$(cd "$REPO" && pwd)"
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }
command -v treehouse >/dev/null || { echo "treehouse required for parallel chunks — run them serially instead" >&2; exit 1; }
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repo: $REPO" >&2; exit 1; }

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
n="$(jq 'length' "$SPEC")"
[ "$n" -ge 2 ] || { echo "fewer than two chunks — run it serially, the setup is not worth it" >&2; exit 1; }

# --- refuse overlapping declarations BEFORE spending anything -----------------
dupes="$(jq -r '[.[].files[]] | group_by(.) | map(select(length>1)) | .[][0]' "$SPEC" 2>/dev/null | sort -u)"
if [ -n "$dupes" ]; then
  echo "REFUSING: chunks declare overlapping files. Parallel writers on the same" >&2
  echo "file interleave and the loser is lost silently. Overlaps:" >&2
  printf '  %s\n' $dupes >&2
  echo "Merge those chunks, or run serially." >&2
  exit 1
fi

echo "dispatching $n chunks in parallel"
rc=0
declare -a CH_WT CH_NAME CH_PID CH_RC   # prefixed: bare NAME collides with the environment
for i in $(seq 0 $((n-1))); do
  name="$(jq -r ".[$i].name" "$SPEC")"
  task="$(jq -r ".[$i].task" "$SPEC")"
  files="$(jq -r ".[$i].files | join(\", \")" "$SPEC")"
  # treehouse operates on the cwd's repo and has no --repo flag
  wt="$( cd "$REPO" && treehouse get --lease --lease-holder "chunk-$name" 2>/dev/null )" || wt=""
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    echo "  $name: FAILED — could not lease a worktree (run this chunk serially)" >&2
    rc=3
    continue
  fi
  CH_WT+=("$wt"); CH_NAME+=("$name")
  ( "$SCRIPTS/codex-run.sh" --lane implement --dir "$wt" --timeout "$TIMEOUT" \
      "$task

You may modify ONLY these files: $files
Touching anything else means this chunk is discarded, so if the task cannot be
done within them, stop and say so instead of widening the scope." \
    > "$wt/.chunk.out" 2>"$wt/.chunk.err" ) &
  CH_PID+=("$!")
  echo "  $name -> $wt"
done

for i in "${!CH_PID[@]}"; do
  if wait "${CH_PID[$i]}" 2>/dev/null; then
    CH_RC[$i]=0
  else
    CH_RC[$i]=$?
    echo "  ${CH_NAME[$i]}: REJECTED — child exited ${CH_RC[$i]}" >&2
    rc=3
  fi
done

# --- merge only what stayed inside its declaration ----------------------------
for i in "${!CH_WT[@]}"; do
  wt="${CH_WT[$i]}"; name="${CH_NAME[$i]}"
  if [ "${CH_RC[$i]}" -ne 0 ]; then
    echo "  $name: not merged — child exited ${CH_RC[$i]}" >&2
    continue
  fi
  declared="$(jq -r ".[] | select(.name==\"$name\") | .files[]" "$SPEC" | sort)"
  # .charles/ is the wrapper's own record and .chunk.* is our capture; neither
  # is the chunk's work, and counting them rejects every chunk.
  changed="$(git -C "$wt" status --porcelain -uall 2>/dev/null | awk '{print $2}' \
             | grep -vE '^(\.charles/|\.chunk\.)' | sort)"
  if [ -z "$changed" ]; then
    echo "  $name: no changes — nothing to merge"; rc=3; continue
  fi
  outside="$(comm -23 <(echo "$changed") <(echo "$declared"))"
  if [ -n "$outside" ]; then
    echo "  $name: REJECTED — wrote outside its declared files:" >&2
    printf '    %s\n' $outside >&2
    rc=3; continue
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    mkdir -p "$REPO/$(dirname "$f")" 2>/dev/null
    if cp "$wt/$f" "$REPO/$f"; then
      echo "  $name: merged $f"
    else
      echo "  $name: FAILED — could not merge $f" >&2
      rc=3
    fi
  done <<< "$changed"
done

for wt in "${CH_WT[@]:-}"; do ( cd "$REPO" && treehouse return "$wt" ) >/dev/null 2>&1 || true; done

echo
echo "Merged what stayed in bounds. Now run green ONCE on the combined result —"
echo "chunks that pass alone can still fail together."
exit $rc

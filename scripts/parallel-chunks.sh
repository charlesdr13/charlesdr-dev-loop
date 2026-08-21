#!/usr/bin/env bash
# parallel-chunks.sh — run disjoint implement chunks concurrently, safely.
#
# Serial chunking localises failure but pays for it in wall clock: across 229
# implement runs the median is 9.9 min, p75 is 15.1, p90 is 25.7, and the max
# is 39.6, so three p90 chunks cost about 77 min serially versus 26 in parallel.
#
# What makes it safe is not the worktrees, it is the check afterwards. Each
# chunk DECLARES the files it may touch; a chunk that wrote outside its
# declaration is rejected and never merged. Disjoint declarations plus enforced
# declarations means the merge cannot clobber.
#
#   parallel-chunks.sh <repo> <spec.json> [--timeout N] [--no-green]
#
#   spec.json: [ {"name":"api","files":["src/a.ts","src/b.ts"],"task":"..."}, ... ]
#
# exit 0  every chunk landed and the combined tree is green (or green was skipped)
# exit 1  refused before dispatching (invalid manifest, overlap, dirty declaration)
# exit 3  a lease, chunk, merge, or combined-green check failed
set -uo pipefail

REPO="${1:?usage: parallel-chunks.sh <repo> <spec.json>}"; shift
SPEC="${1:?spec.json required}"; shift || true
TIMEOUT=2700
NO_GREEN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) [ $# -ge 2 ] || { echo "--timeout requires seconds" >&2; exit 2; }; TIMEOUT="$2"; shift 2 ;;
    --no-green) NO_GREEN=1; shift ;;
    *) shift ;;
  esac
done

[ -d "$REPO" ] || { echo "no such repo: $REPO" >&2; exit 1; }
[ -f "$SPEC" ] || { echo "no such spec: $SPEC" >&2; exit 1; }
REPO="$(cd -- "$REPO" && pwd)"
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repo: $REPO" >&2; exit 1; }

if ! jq -e '
  if type != "array" then false
  else all(.[];
    type == "object" and has("name") and has("files") and has("task")
    and (.name | if type == "string" then length > 0 else false end)
    and (.task | if type == "string" then length > 0 else false end)
    and (.files | if type == "array" then
      length > 0 and all(.[]; if type == "string" then
        length > 0 and (startswith("/") | not)
        and (contains("..") | not)
        and (test("^[A-Za-z]:") | not)
      else false end)
    else false end)
  )
  end
' "$SPEC" >/dev/null 2>&1; then
  echo "invalid manifest: expected an array of named chunks with files and task" >&2
  exit 1
fi

n="$(jq -r 'length' "$SPEC")"
[ "$n" -ge 2 ] || { echo "fewer than two chunks — run it serially, the setup is not worth it" >&2; exit 1; }

duplicate_names="$(jq -r 'map(.name) | sort | group_by(.) | map(select(length > 1) | .[0]) | .[]' "$SPEC")"
if [ -n "$duplicate_names" ]; then
  echo "invalid manifest: duplicate chunk names:" >&2
  printf '  %s\n' "$duplicate_names" >&2
  exit 1
fi

# --- refuse overlapping declarations BEFORE spending anything -----------------
dupes="$(jq -r '[.[].files[]] | sort | group_by(.) | map(select(length > 1) | .[0]) | .[]' "$SPEC")"
if [ -n "$dupes" ]; then
  echo "REFUSING: chunks declare overlapping files. Parallel writers on the same" >&2
  echo "file interleave and the loser is lost silently. Overlaps:" >&2
  printf '  %s\n' "$dupes" >&2
  echo "Merge those chunks, or run serially." >&2
  exit 1
fi

# A root edit to a declared path is an overwrite hazard; unrelated dirty files
# belong to the caller and must not block this batch.
dirty=""
while IFS= read -r declared_file; do
  if [ -n "$(git -C "$REPO" status --porcelain -z -uall -- "$declared_file" 2>/dev/null)" ]; then
    dirty+="$declared_file"$'\n'
  fi
done < <(jq -r '.[].files[]' "$SPEC")
if [ -n "$dirty" ]; then
  echo "REFUSING: root has uncommitted changes to declared files:" >&2
  printf '  %s\n' "$dirty" >&2
  exit 1
fi

command -v treehouse >/dev/null || { echo "treehouse required for parallel chunks — run them serially instead" >&2; exit 1; }

SCRIPTS="$(cd -- "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/parallel-chunks.XXXXXX")" || { echo "could not create temporary directory" >&2; exit 1; }
declare -a CH_WT=() CH_NAME=() CH_PID=() CH_RC=() CH_KEEP=() CH_STATUS=()

return_worktree() {
  local wt="$1"
  ( cd -- "$REPO" && treehouse return "$wt" ) >/dev/null 2>&1
}

cleanup() {
  local cleanup_rc="$1" pid i wt receipt run
  trap - EXIT INT TERM

  # A signal can arrive while codex is still writing; wait before releasing its
  # worktree or the lease can be reused while the child is mutating it.
  for pid in "${CH_PID[@]}"; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
  done
  for pid in "${CH_PID[@]}"; do
    [ -n "$pid" ] || continue
    wait "$pid" 2>/dev/null || true
  done

  for i in "${!CH_WT[@]}"; do
    wt="${CH_WT[$i]}"
    receipt="$wt/.charles/dispatches.jsonl"
    if [ -f "$receipt" ]; then
      if ! mkdir -p -- "$REPO/.charles" || ! cat "$receipt" >> "$REPO/.charles/dispatches.jsonl"; then
        echo "  ${CH_NAME[$i]}: FAILED — could not aggregate $receipt" >&2
        CH_KEEP[$i]=1
        cleanup_rc=3
      else
        while IFS= read -r run; do
          [ -n "$run" ] || continue
          echo "  ${CH_NAME[$i]}: run $run"
        done < <(jq -r 'select(.run != null) | .run' "$receipt" 2>/dev/null | sort -u)
      fi
    fi

    if [ "${CH_KEEP[$i]:-0}" -eq 1 ]; then
      echo "  ${CH_NAME[$i]}: keeping worktree $wt for inspection" >&2
    elif ! return_worktree "$wt"; then
      echo "  ${CH_NAME[$i]}: FAILED — could not return worktree $wt" >&2
      cleanup_rc=3
    fi
  done

  rm -rf -- "$TMP"
  exit "$cleanup_rc"
}
trap 'cleanup "$?"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "leasing $n chunks"
for i in $(seq 0 $((n - 1))); do
  name="$(jq -r ".[$i].name" "$SPEC")"
  wt="$(cd -- "$REPO" && treehouse get --lease --lease-holder "chunk-$name" 2>/dev/null)" || wt=""
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    echo "  $name: FAILED — could not lease a worktree; refusing the whole batch" >&2
    exit 3
  fi
  CH_WT+=("$wt"); CH_NAME+=("$name"); CH_KEEP+=(0)
  echo "  $name -> $wt"
done

echo "dispatching $n chunks in parallel"
for i in "${!CH_WT[@]}"; do
  task="$(jq -r ".[$i].task" "$SPEC")"
  files="$(jq -r ".[$i].files | join(\", \")" "$SPEC")"
  ( "$SCRIPTS/codex-run.sh" --lane implement --dir "${CH_WT[$i]}" --timeout "$TIMEOUT" \
      "$task

You may modify ONLY these files: $files
Touching anything else means this chunk is discarded, so if the task cannot be
done within them, stop and say so instead of widening the scope." \
    > "${CH_WT[$i]}/.chunk.out" 2>"${CH_WT[$i]}/.chunk.err" ) &
  CH_PID+=("$!")
done

rc=0
for i in "${!CH_PID[@]}"; do
  if wait "${CH_PID[$i]}" 2>/dev/null; then
    child_rc=0
  else
    child_rc=$?
  fi
  CH_PID[$i]=""
  CH_RC[$i]="$child_rc"
  if [ "$child_rc" -ne 0 ]; then
    CH_KEEP[$i]=1
    echo "  ${CH_NAME[$i]}: REJECTED — child exited $child_rc" >&2
    rc=3
  fi
done

internal_path() {
  case "$1" in
    .charles|.charles/*|.chunk.*) return 0 ;;
  esac
  return 1
}

# Acceptance is a separate pass: a failed sibling must not leave earlier
# accepted chunks copied into the root.
for i in "${!CH_WT[@]}"; do
  wt="${CH_WT[$i]}"
  if [ "${CH_RC[$i]}" -ne 0 ]; then
    continue
  fi

  status_file="$TMP/$i.status"
  if ! git -C "$wt" status --porcelain -z -uall > "$status_file" 2>/dev/null; then
    echo "  ${CH_NAME[$i]}: REJECTED — could not read worktree status" >&2
    CH_KEEP[$i]=1; rc=3
    continue
  fi
  CH_STATUS[$i]="$status_file"

  changed=()
  status_error=0
  while IFS= read -r -d '' record; do
    if [ "${#record}" -lt 3 ]; then
      status_error=1
      break
    fi
    xy="${record:0:2}"; path="${record:3}"
    if [[ "$xy" == *R* ]]; then
      if ! IFS= read -r -d '' old_path; then
        status_error=1
        break
      fi
      if internal_path "$path" || internal_path "$old_path"; then
        continue
      fi
      changed+=("$path" "$old_path")
    elif [[ "$xy" == *C* ]]; then
      internal_path "$path" || changed+=("$path")
      IFS= read -r -d '' old_path || status_error=1
    elif internal_path "$path"; then
      continue
    else
      changed+=("$path")
    fi
  done < "$status_file"

  if [ "$status_error" -ne 0 ]; then
    echo "  ${CH_NAME[$i]}: REJECTED — malformed git status" >&2
    CH_KEEP[$i]=1; rc=3
    continue
  fi
  changed_list="$(printf '%s\n' "${changed[@]}" | sort -u)"
  if [ -z "$changed_list" ]; then
    echo "  ${CH_NAME[$i]}: REJECTED — no declared work was written" >&2
    CH_KEEP[$i]=1; rc=3
    continue
  fi
  declared="$(jq -r ".[$i].files[]" "$SPEC")"
  outside="$(comm -23 <(printf '%s\n' "$changed_list" | sort -u) <(printf '%s\n' "$declared" | sort -u))"
  if [ -n "$outside" ]; then
    echo "  ${CH_NAME[$i]}: REJECTED — wrote outside its declared files:" >&2
    printf '    %s\n' "$outside" >&2
    CH_KEEP[$i]=1; rc=3
    continue
  fi
done

if [ "$rc" -ne 0 ]; then
  echo "No chunks merged; every chunk must pass before any file is copied." >&2
  exit 3
fi

for i in "${!CH_WT[@]}"; do
  wt="${CH_WT[$i]}"
  while IFS= read -r -d '' record; do
    xy="${record:0:2}"; path="${record:3}"
    if [[ "$xy" == *R* ]]; then
      IFS= read -r -d '' old_path || { echo "  ${CH_NAME[$i]}: FAILED — malformed rename" >&2; CH_KEEP[$i]=1; rc=3; continue; }
      if internal_path "$path" || internal_path "$old_path"; then
        continue
      fi
      target_dir="$(dirname -- "$path")"
      if mkdir -p -- "$REPO/$target_dir" \
        && cp -a -- "$wt/$path" "$REPO/$path" \
        && rm -f -- "$REPO/$old_path"; then
        echo "  ${CH_NAME[$i]}: merged rename $old_path -> $path"
      else
        echo "  ${CH_NAME[$i]}: FAILED — could not merge rename $old_path -> $path" >&2
        CH_KEEP[$i]=1; rc=3
      fi
    elif [[ "$xy" == *C* ]]; then
      IFS= read -r -d '' old_path || { echo "  ${CH_NAME[$i]}: FAILED — malformed copy" >&2; CH_KEEP[$i]=1; rc=3; continue; }
      internal_path "$path" && continue
      target_dir="$(dirname -- "$path")"
      if mkdir -p -- "$REPO/$target_dir" && cp -a -- "$wt/$path" "$REPO/$path"; then
        echo "  ${CH_NAME[$i]}: merged $path"
      else
        echo "  ${CH_NAME[$i]}: FAILED — could not merge $path" >&2
        CH_KEEP[$i]=1; rc=3
      fi
    elif internal_path "$path"; then
      continue
    elif [[ "$xy" == *D* ]]; then
      if rm -f -- "$REPO/$path"; then
        echo "  ${CH_NAME[$i]}: merged deletion $path"
      else
        echo "  ${CH_NAME[$i]}: FAILED — could not delete $path" >&2
        CH_KEEP[$i]=1; rc=3
      fi
    else
      target_dir="$(dirname -- "$path")"
      if mkdir -p -- "$REPO/$target_dir" && cp -a -- "$wt/$path" "$REPO/$path"; then
        echo "  ${CH_NAME[$i]}: merged $path"
      else
        echo "  ${CH_NAME[$i]}: FAILED — could not merge $path" >&2
        CH_KEEP[$i]=1; rc=3
      fi
    fi
  done < "${CH_STATUS[$i]}"
done

if [ "$rc" -eq 0 ] && [ "$NO_GREEN" -eq 0 ]; then
  echo "running combined green check"
  "$SCRIPTS/green.sh" "$REPO"
  green_rc=$?
  if [ "$green_rc" -eq 2 ]; then
    echo "WARN: no green command configured; accepting without a combined check" >&2
  elif [ "$green_rc" -ne 0 ]; then
    rc="$green_rc"
  fi
elif [ "$rc" -eq 0 ]; then
  echo "combined green check skipped (--no-green)"
fi

exit "$rc"

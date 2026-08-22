#!/usr/bin/env bash
# parallel-chunks.sh — run disjoint implement chunks concurrently, safely.
#
# Serial chunking localises failure but pays for it in wall clock. README's
# canonical measurement uses successful implement dispatches only (rc=0):
# n=233 across all opted-in repos; timeouts are counted separately (25 of 258
# ends, about 10%, at the old 1800s cap). Its p90 is 19.1 min, so three p90
# chunks cost about 57 min serially versus 19.1 in parallel.
#
# What makes it safe is not the worktrees, it is the check afterwards. Each
# chunk DECLARES the files it may touch; a chunk that wrote outside its
# declaration is rejected and never merged. Disjoint declarations plus enforced
# declarations means the merge cannot clobber.
#
#   parallel-chunks.sh <repo> <spec.json> [--timeout N] [--no-green] [--run ID]
#
#   spec.json: [ {"name":"api","files":["src/a.ts","src/b.ts"],"task":"..."}, ... ]
#
# exit 0  every chunk landed and the combined tree is green (or green was skipped)
# exit 1  refused before dispatching (invalid manifest, overlap, dirty declaration)
# exit 3  a lease, chunk, merge, or combined-green check failed
set -uo pipefail

# readlink -f first: this script is reached through a PATH symlink, and an
# unresolved dirname points at the symlink's directory, where run-common.sh
# does not exist. Confirmed live: sourcing died with exit 1 on every wrapper
# dispatch until this line resolved the link.
SCRIPT_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd -P)"
. "$SCRIPT_DIR/run-common.sh"

REPO="${1:?usage: parallel-chunks.sh <repo> <spec.json>}"; shift
SPEC="${1:?spec.json required}"; shift || true
TIMEOUT=2700
NO_GREEN=0
RUN_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) [ $# -ge 2 ] || { echo "--timeout requires seconds" >&2; exit 2; }; TIMEOUT="$2"; shift 2 ;;
    --no-green) NO_GREEN=1; shift ;;
    --run) [ $# -ge 2 ] || { echo "--run requires a run id" >&2; exit 2; }; [ -n "$2" ] || { echo "--run requires a run id" >&2; exit 2; }; RUN_ARGS+=(--run "$2"); shift 2 ;;
    *) shift ;;
  esac
done

[ -d "$REPO" ] || { echo "no such repo: $REPO" >&2; exit 1; }
[ -f "$SPEC" ] || { echo "no such spec: $SPEC" >&2; exit 1; }
REPO="$(cd -- "$REPO" && pwd)"
SPEC="$(cd -- "$(dirname -- "$SPEC")" && pwd)/$(basename -- "$SPEC")"
PLAN=""
case "$SPEC" in
  *.chunks.json) PLAN="${SPEC%.chunks.json}.md" ;;
esac
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repo: $REPO" >&2; exit 1; }

repo_root="$(realpath -m "$REPO" 2>/dev/null || echo "$REPO")"
root="$repo_root"
while [ "$root" != "/" ] && [ ! -f "$root/.charles.toml" ]; do
  parent="$(dirname "$root")"; [ "$parent" = "$root" ] && break; root="$parent"
done
cfg() { # cfg KEY DEFAULT — read `key = value` from .charles.toml
  local v; v="$(sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*([0-9]+)[[:space:]]*(#.*)?[[:space:]]*$/\1/p" "$root/.charles.toml" 2>/dev/null | head -1)"
  if [ -z "$v" ] && grep -qE "^[[:space:]]*$1[[:space:]]*=" "$root/.charles.toml" 2>/dev/null; then
    echo "parallel-chunks.sh: WARN: invalid $1; using default $2" >&2
  fi
  echo "${v:-$2}"
}
parallel_min_chunks="${CHARLES_PARALLEL_MIN_CHUNKS:-$(cfg parallel_min_chunks 2)}"
case "$parallel_min_chunks" in
  ''|*[!0-9]*|0|1) echo "parallel-chunks.sh: WARN: invalid parallel_min_chunks; using default 2" >&2; parallel_min_chunks=2 ;;
esac

if ! jq -e --arg requirement_regex "$CHARLES_REQUIREMENT_REGEX" '
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
    and (if has("req") then
      (.req | type == "array" and all(.[]; type == "string" and test($requirement_regex)))
    else true end)
  )
  end
' "$SPEC" >/dev/null 2>&1; then
  echo "invalid manifest: expected an array of named chunks with files and task" >&2
  exit 1
fi

n="$(jq -r 'length' "$SPEC")"
[ "$n" -ge "$parallel_min_chunks" ] || { echo "fewer than two chunks — run it serially, the setup is not worth it" >&2; exit 1; }

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

SCRIPTS="$SCRIPT_DIR"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/parallel-chunks.XXXXXX")" || { echo "could not create temporary directory" >&2; exit 1; }

# Validate through the dispatcher before leasing; it owns the open-run semantics.
for i in $(seq 0 $((n - 1))); do
  name="$(jq -r ".[$i].name" "$SPEC")"
  reqs="$(jq -r ".[$i].req // [] | join(\",\")" "$SPEC")"
  scope_args=(--lane implement --dir "$REPO" --timeout "$TIMEOUT" --validate-only)
  scope_args+=("${RUN_ARGS[@]}")
  [ -z "$PLAN" ] || scope_args+=(--plan "$PLAN")
  [ -n "$reqs" ] && scope_args+=(--req "$reqs")
  scope_out="$(CHARLES_STATE_DIR="$TMP/state-$i" "$SCRIPTS/codex-run.sh" "${scope_args[@]}" \
    "validate requirement scope for chunk $name" 2>&1)"
  scope_rc=$?
  if [ "$scope_rc" -ne 0 ]; then
    echo "invalid manifest: chunk $name requirement scope was refused" >&2
    printf '%s\n' "$scope_out" >&2
    rm -rf -- "$TMP"
    exit 1
  fi
done

declare -a CH_WT=() CH_NAME=() CH_PID=() CH_RC=() CH_KEEP=() CH_STATUS=()

return_worktree() {
  local wt="$1"
  ( cd -- "$REPO" && treehouse return "$wt" ) >/dev/null 2>&1
}

cleanup() {
  local cleanup_rc="$1" pid i wt receipt run
  trap '' INT TERM
  trap - EXIT

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

  # All children have been waited on above, so receipts have no concurrent
  # writer here and aggregation does not need a lock.
  for i in "${!CH_WT[@]}"; do
    wt="${CH_WT[$i]}"
    receipt="$wt/.charles/dispatches.jsonl"
    if [ "${CH_RC[$i]+set}" = set ] || [ -n "${CH_PID[$i]:-}" ]; then
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
      else
        echo "  ${CH_NAME[$i]}: FAILED — missing receipt $receipt" >&2
        CH_KEEP[$i]=1
        cleanup_rc=3
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
  child_args=(--lane implement --dir "${CH_WT[$i]}" --timeout "$TIMEOUT")
  child_args+=("${RUN_ARGS[@]}")
  [ -z "$PLAN" ] || child_args+=(--plan "$PLAN")
  reqs="$(jq -r ".[$i].req // [] | join(\",\")" "$SPEC")"
  [ -n "$reqs" ] && child_args+=(--req "$reqs")
  ( "$SCRIPTS/codex-run.sh" "${child_args[@]}" \
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

safe_copy() {
  local wt="$1" path="$2" parent
  parent="$(dirname -- "$path")"
  mkdir -p -- "$REPO/$parent" || return 1
  parent="$(realpath -- "$REPO/$parent" 2>/dev/null)" || return 1
  case "$parent/" in
    "$repo_root/"*) cp -a -- "$wt/$path" "$REPO/$path" ;;
    *) return 1 ;;
  esac
}

# Acceptance is a separate pass: a failed sibling must not leave earlier
# accepted chunks copied into the root.
for i in "${!CH_WT[@]}"; do
  wt="${CH_WT[$i]}"
  if [ "${CH_RC[$i]}" -ne 0 ]; then
    continue
  fi

  receipt="$wt/.charles/dispatches.jsonl"
  if [ ! -f "$receipt" ] || [ ! -r "$receipt" ]; then
    echo "  ${CH_NAME[$i]}: REJECTED — missing receipt $receipt" >&2
    CH_KEEP[$i]=1; rc=3
    continue
  fi
  if ! jq -e -s \
    'any(.[]; type == "object" and (.run? | if type == "string" then length > 0 else false end))' \
    "$receipt" >/dev/null; then
    echo "  ${CH_NAME[$i]}: REJECTED — invalid receipt $receipt (expected a non-empty .run)" >&2
    CH_KEEP[$i]=1; rc=3
    continue
  fi

  status_file="$TMP/$i.status"
  if ! git -C "$wt" status --porcelain -z -uall --ignored > "$status_file" 2>/dev/null; then
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
  rename_destinations=()
  rename_sources=()
  deletions=()
  while IFS= read -r -d '' record; do
    xy="${record:0:2}"; path="${record:3}"
    if [[ "$xy" == *R* ]]; then
      IFS= read -r -d '' old_path || { echo "  ${CH_NAME[$i]}: FAILED — malformed rename" >&2; CH_KEEP[$i]=1; rc=3; continue; }
      if internal_path "$path" || internal_path "$old_path"; then
        continue
      fi
      if safe_copy "$wt" "$path"; then
        rename_destinations+=("$path")
        rename_sources+=("$old_path")
        echo "  ${CH_NAME[$i]}: merged rename $old_path -> $path"
      else
        echo "  ${CH_NAME[$i]}: FAILED — could not merge rename $old_path -> $path" >&2
        CH_KEEP[$i]=1; rc=3
      fi
    elif [[ "$xy" == *C* ]]; then
      IFS= read -r -d '' old_path || { echo "  ${CH_NAME[$i]}: FAILED — malformed copy" >&2; CH_KEEP[$i]=1; rc=3; continue; }
      internal_path "$path" && continue
      if safe_copy "$wt" "$path"; then
        echo "  ${CH_NAME[$i]}: merged $path"
      else
        echo "  ${CH_NAME[$i]}: FAILED — could not merge $path" >&2
        CH_KEEP[$i]=1; rc=3
      fi
    elif internal_path "$path"; then
      continue
    elif [[ "$xy" == *D* ]]; then
      deletions+=("$path")
    else
      if safe_copy "$wt" "$path"; then
        echo "  ${CH_NAME[$i]}: merged $path"
      else
        echo "  ${CH_NAME[$i]}: FAILED — could not merge $path" >&2
        CH_KEEP[$i]=1; rc=3
      fi
    fi
  done < "${CH_STATUS[$i]}"

  for path in "${deletions[@]}"; do
    if rm -f -- "$REPO/$path"; then
      echo "  ${CH_NAME[$i]}: merged deletion $path"
    else
      echo "  ${CH_NAME[$i]}: FAILED — could not delete $path" >&2
      CH_KEEP[$i]=1; rc=3
    fi
  done

  for old_path in "${rename_sources[@]}"; do
    for path in "${rename_destinations[@]}"; do
      [ "$old_path" = "$path" ] && continue 2
    done
    if ! rm -f -- "$REPO/$old_path"; then
      echo "  ${CH_NAME[$i]}: FAILED — could not remove rename source $old_path" >&2
      CH_KEEP[$i]=1; rc=3
    fi
  done
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

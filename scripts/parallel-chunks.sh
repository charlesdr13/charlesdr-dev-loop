#!/usr/bin/env bash
# parallel-chunks.sh — run compatible implement chunks concurrently, safely.
#
# Serial chunking localises failure but pays for it in wall clock. README's
# canonical measurement uses successful implement dispatches only (rc=0):
# n=233 across all opted-in repos; timeouts are counted separately (25 of 258
# ends, about 10%, at the old 1800s cap). Its p90 is 19.1 min, so three p90
# chunks cost about 57 min serially versus 19.1 in parallel.
#
# What makes it safe is not the worktrees, it is the check afterwards. Each
# chunk DECLARES the files it may touch; a chunk that wrote outside its
# declaration is rejected and never merged. Disjoint declarations or validated
# shared merges mean the merge cannot clobber.
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
git_clean=(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY git)
"${git_clean[@]}" -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repo: $REPO" >&2; exit 1; }

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
    and (if has("shared") then
      (.shared | if type == "array" then
        all(.[]; if type == "string" then
          length > 0 and (startswith("/") | not)
          and (contains("..") | not)
          and (test("^[A-Za-z]:") | not)
        else false end)
      else false end)
    else true end)
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

# --- validate shared declarations BEFORE spending anything --------------------
shared_paths="$(jq -r '[.[].shared[]?] | unique[]' "$SPEC")"
shared_outside="$(jq -r 'to_entries[] | .value as $chunk | (($chunk.shared // []) - $chunk.files)[] | "\($chunk.name)\t\(.)"' "$SPEC")"
if [ -n "$shared_outside" ]; then
  while IFS=$'\t' read -r shared_chunk shared_path; do
    [ -n "$shared_path" ] || continue
    echo "REFUSING: shared path '$shared_path' is not in files for chunk $shared_chunk" >&2
  done < <(printf '%s\n' "$shared_outside")
  exit 1
fi
if [ -n "$shared_paths" ]; then
  while IFS= read -r shared_path; do
    [ -n "$shared_path" ] || continue
    file_count="$(jq -r --arg p "$shared_path" '[.[] | select((.files | index($p)) != null)] | length' "$SPEC")"
    shared_count="$(jq -r --arg p "$shared_path" '[.[] | select(((.shared // []) | index($p)) != null)] | length' "$SPEC")"
    file_names="$(jq -r --arg p "$shared_path" '[.[] | select((.files | index($p)) != null) | .name] | join(", ")' "$SPEC")"
    shared_names="$(jq -r --arg p "$shared_path" '[.[] | select(((.shared // []) | index($p)) != null) | .name] | join(", ")' "$SPEC")"
    if [ "$file_count" -gt 2 ]; then
      echo "REFUSING: shared path '$shared_path' is declared by $file_count chunks; at most 2 chunks may share a path ($file_names)" >&2
      exit 1
    fi
    if [ "$file_count" -lt 2 ]; then
      echo "REFUSING: shared path '$shared_path' is not declared by two chunks (shared by: $shared_names)" >&2
      exit 1
    fi
    if [ "$shared_count" -ne "$file_count" ]; then
      echo "REFUSING: shared path '$shared_path' is not declared shared by every overlapping chunk (files: $file_names; shared: $shared_names)" >&2
      exit 1
    fi
  done < <(printf '%s\n' "$shared_paths")
fi

# Unshared overlap keeps the original refusal and message.
dupes="$(jq -r '[.[].files[]] | sort | group_by(.) | map(select(length > 1) | .[0]) | .[]' "$SPEC")"
if [ -n "$dupes" ]; then
  unshared_dupes=""
  while IFS= read -r duplicate_path; do
    [ -n "$duplicate_path" ] || continue
    duplicate_file_count="$(jq -r --arg p "$duplicate_path" '[.[] | select((.files | index($p)) != null)] | length' "$SPEC")"
    duplicate_shared_count="$(jq -r --arg p "$duplicate_path" '[.[] | select(((.shared // []) | index($p)) != null)] | length' "$SPEC")"
    [ "$duplicate_shared_count" -eq "$duplicate_file_count" ] || unshared_dupes+="$duplicate_path"$'\n'
  done < <(printf '%s\n' "$dupes")
  if [ -n "$unshared_dupes" ]; then
    echo "REFUSING: chunks declare overlapping files. Parallel writers on the same" >&2
    echo "file interleave and the loser is lost silently. Overlaps:" >&2
    printf '  %s\n' "$dupes" >&2
    while IFS= read -r duplicate_path; do
      [ -n "$duplicate_path" ] || continue
      echo "  reason: overlap '$duplicate_path' is not declared shared by every overlapping chunk" >&2
    done < <(printf '%s\n' "$unshared_dupes")
    echo "Merge those chunks, or run serially." >&2
    exit 1
  fi
fi

batch_head="$("${git_clean[@]}" -C "$REPO" rev-parse --verify HEAD 2>/dev/null)" || {
  echo "REFUSING: could not snapshot target HEAD; refusing the whole batch" >&2
  exit 3
}

declare -a SHARED_PATHS=()
mapfile -t SHARED_PATHS < <(printf '%s\n' "$shared_paths" | sed '/^$/d')
for shared_path in "${SHARED_PATHS[@]}"; do
  base_entry="$("${git_clean[@]}" -C "$REPO" ls-tree "$batch_head" -- "$shared_path" 2>/dev/null)"
  base_mode="${base_entry%% *}"
  base_tail="${base_entry#* }"
  base_type="${base_tail%% *}"
  if [ -z "$base_entry" ] || [ "$base_type" != blob ] || { [ "$base_mode" != 100644 ] && [ "$base_mode" != 100755 ]; }; then
    echo "REFUSING: shared path '$shared_path' must be an existing ordinary file at batch HEAD $batch_head" >&2
    exit 1
  fi
done

if [ "${#SHARED_PATHS[@]}" -gt 0 ] && [ "$NO_GREEN" -eq 1 ]; then
  echo "REFUSING: shared files require the combined green check; --no-green is not allowed" >&2
  exit 1
fi

# A root edit to a declared path is an overwrite hazard; unrelated dirty files
# belong to the caller and must not block this batch.
dirty=""
while IFS= read -r declared_file; do
  if [ -n "$("${git_clean[@]}" -C "$REPO" status --porcelain -z -uall -- "$declared_file" 2>/dev/null)" ]; then
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
  local cleanup_rc="$1" pid i wt receipt run terminal wait_tick
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

  # A surviving watchdog can still append the terminal record after its child
  # exits, so poll each receipt before copying it. The 5s bound is the
  # watchdog's sleep 2 plus 3s margin; SIGKILL can still leave no record.
  for i in "${!CH_WT[@]}"; do
    wt="${CH_WT[$i]}"
    receipt="$wt/.charles/dispatches.jsonl"
    if [ "${CH_RC[$i]+set}" = set ] || [ -n "${CH_PID[$i]:-}" ]; then
      if [ -f "$receipt" ]; then
        terminal=0
        for ((wait_tick=0; wait_tick<50; wait_tick++)); do
          if jq -e -s \
              '([.[] | select(.event == "start") |
                ((.run // "") | tostring | split("/") | last)] | map(select(length > 0)) | unique) as $starts |
               ([.[] | select((has("event") | not) or .event == "end") |
                ((.run // "") | tostring | split("/") | last)] | map(select(length > 0)) | unique) as $ends |
               (($starts - $ends) | length) == 0' \
              "$receipt" >/dev/null 2>&1; then
            terminal=1
            break
          fi
          sleep 0.1
        done
        if [ "$terminal" -ne 1 ]; then
          echo "  ${CH_NAME[$i]}: FAILED — no terminal record after bounded wait; retaining worktree $wt with unaggregated receipt $receipt" >&2
          CH_KEEP[$i]=1
          cleanup_rc=3
        elif ! mkdir -p -- "$REPO/.charles" || ! cat "$receipt" >> "$REPO/.charles/dispatches.jsonl"; then
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
  lease_head="$("${git_clean[@]}" -C "$wt" rev-parse --verify HEAD 2>/dev/null)" || {
    echo "  $name: REFUSING — could not read lease HEAD; refusing the whole batch" >&2
    CH_WT+=("$wt"); CH_NAME+=("$name"); CH_KEEP+=(0)
    exit 3
  }
  CH_WT+=("$wt"); CH_NAME+=("$name"); CH_KEEP+=(0)
  if [ "$lease_head" != "$batch_head" ]; then
    echo "  $name: REFUSING — lease HEAD $lease_head differs from batch HEAD $batch_head" >&2
    exit 3
  fi
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

ignored_path_inside_worktree() {
  local wt="$1" path="${2%/}" worktree_root target
  [ -L "$wt/$path" ] || return 0
  worktree_root="$(realpath -- "$wt" 2>/dev/null)" || return 1
  target="$(realpath -- "$wt/$path" 2>/dev/null)" || return 1
  case "$target" in
    "$worktree_root"|"$worktree_root"/*) return 0 ;;
    *) return 1 ;;
  esac
}

sanitize_ignored_path() {
  local clean
  clean="$(printf '%s' "$1" | LC_ALL=C tr -d '[:cntrl:]' | LC_ALL=C cut -c1-200)"
  [ -n "$clean" ] || clean='<control-only>'
  printf '%s' "$clean"
}

is_shared_path() {
  local candidate
  for candidate in "${SHARED_PATHS[@]}"; do
    [ "$candidate" = "$1" ] && return 0
  done
  return 1
}

shared_status_for_path() { # shared_status_for_path STATUS_FILE PATH
  local status_file="$1" wanted="$2" record xy path old_path
  SHARED_STATUS_FOUND=0
  SHARED_STATUS_XY=""
  SHARED_STATUS_KIND=""
  while IFS= read -r -d '' record; do
    [ "${#record}" -ge 3 ] || { SHARED_STATUS_KIND=malformed; return 0; }
    xy="${record:0:2}"; path="${record:3}"
    if [[ "$xy" == *R* || "$xy" == *C* ]]; then
      old_path=""
      IFS= read -r -d '' old_path || { SHARED_STATUS_KIND=malformed; return 0; }
      if [ "$path" = "$wanted" ] || [ "$old_path" = "$wanted" ]; then
        SHARED_STATUS_FOUND=1
        SHARED_STATUS_XY="$xy"
        SHARED_STATUS_KIND=rename
        return 0
      fi
    elif [ "$xy" != "!!" ] && [ "$path" = "$wanted" ]; then
      SHARED_STATUS_FOUND=1
      SHARED_STATUS_XY="$xy"
      SHARED_STATUS_KIND=ordinary
      return 0
    fi
  done < "$status_file"
}

shared_text_pair() { # shared_text_pair BASE FILE; 0=text, 1=binary, 2=inspection failure
  local numstat diff_rc
  numstat="$("${git_clean[@]}" -C "$REPO" diff --no-index --numstat -- "$1" "$2" 2>/dev/null)"
  diff_rc=$?
  [ "$diff_rc" -le 1 ] || return 2
  case "$numstat" in
    $'-\t-'*) return 1 ;;
  esac
  return 0
}

declare -a SHARED_RESULT=()

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
  # Keep --ignored so setup output such as node_modules is reported, never
  # rejected: ignored files are setup noise, while -uall still catches untracked
  # non-ignored files and ordinary status still catches tracked undeclared writes.
  if ! "${git_clean[@]}" -C "$wt" status --porcelain -z -uall --ignored > "$status_file" 2>/dev/null; then
    echo "  ${CH_NAME[$i]}: REJECTED — could not read worktree status" >&2
    CH_KEEP[$i]=1; rc=3
    continue
  fi
  CH_STATUS[$i]="$status_file"

  changed=()
  ignored=()
  ignored_escape=()
  status_error=0
  while IFS= read -r -d '' record; do
    if [ "${#record}" -lt 3 ]; then
      status_error=1
      break
    fi
    xy="${record:0:2}"; path="${record:3}"
    if [[ "$xy" == "!!" ]]; then
      ignored+=("$path")
      ignored_path_inside_worktree "$wt" "$path" || ignored_escape+=("$path")
    elif [[ "$xy" == *R* ]]; then
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
  if [ "${#ignored[@]}" -gt 0 ]; then
    ignored_preview=""
    for ignored_path in "${ignored[@]:0:3}"; do
      [ -z "$ignored_preview" ] || ignored_preview+=", "
      ignored_preview+="$(sanitize_ignored_path "$ignored_path")"
    done
    [ "${#ignored[@]}" -le 3 ] || ignored_preview+=" ..."
    echo "  ${CH_NAME[$i]}: ignored ${#ignored[@]} path(s): $ignored_preview" >&2
  fi
  if [ "${#ignored_escape[@]}" -gt 0 ]; then
    echo "  ${CH_NAME[$i]}: REJECTED — wrote outside its declared files:" >&2
    for ignored_path in "${ignored_escape[@]}"; do
      printf '    %s\n' "$(sanitize_ignored_path "$ignored_path")" >&2
    done
    CH_KEEP[$i]=1; rc=3
    continue
  fi
  changed_list="$(printf '%s\n' "${changed[@]}" | sort -u)"
  if [ -z "$changed_list" ]; then
    echo "  ${CH_NAME[$i]}: REJECTED — no declared work was written" >&2
    CH_KEEP[$i]=1; rc=3
    continue
  fi
  declared="$(jq -r ".[$i].files[] , ((.[$i].shared // [])[])" "$SPEC")"
  outside="$(comm -23 <(printf '%s\n' "$changed_list" | sort -u) <(printf '%s\n' "$declared" | sort -u))"
  if [ -n "$outside" ]; then
    echo "  ${CH_NAME[$i]}: REJECTED — wrote outside its declared files:" >&2
    printf '    %s\n' "$outside" >&2
    CH_KEEP[$i]=1; rc=3
    continue
  fi
done

if [ "$rc" -eq 0 ]; then
  shared_index=0
  for shared_path in "${SHARED_PATHS[@]}"; do
    SHARED_RESULT[$shared_index]=""
    mapfile -t shared_chunks < <(jq -r --arg p "$shared_path" \
      'to_entries[] | select((.value.files | index($p)) != null) | .key' "$SPEC")
    base_file="$TMP/shared-base-$shared_index"
    base_entry="$("${git_clean[@]}" -C "$REPO" ls-tree "$batch_head" -- "$shared_path" 2>/dev/null)"
    base_mode="${base_entry%% *}"
    if ! "${git_clean[@]}" -C "$REPO" show "$batch_head:$shared_path" > "$base_file" 2>/dev/null; then
      echo "  shared path '$shared_path': REJECTED — could not read base content at $batch_head" >&2
      for shared_chunk in "${shared_chunks[@]}"; do CH_KEEP[$shared_chunk]=1; done
      rc=3
      shared_index=$((shared_index + 1))
      continue
    fi

    shared_bad=0
    for shared_chunk in "${shared_chunks[@]}"; do
      wt="${CH_WT[$shared_chunk]}"
      shared_status_for_path "${CH_STATUS[$shared_chunk]}" "$shared_path"
      if [ "$SHARED_STATUS_KIND" = malformed ]; then
        echo "  ${CH_NAME[$shared_chunk]}: REJECTED — malformed status for shared path '$shared_path'" >&2
        CH_KEEP[$shared_chunk]=1; rc=3; shared_bad=1
        continue
      fi
      if [ "$SHARED_STATUS_FOUND" -ne 1 ]; then
        echo "  ${CH_NAME[$shared_chunk]}: REJECTED — shared path '$shared_path' was not modified in place" >&2
        CH_KEEP[$shared_chunk]=1; rc=3; shared_bad=1
        continue
      fi
      if [ "$SHARED_STATUS_KIND" != ordinary ]; then
        echo "  ${CH_NAME[$shared_chunk]}: REJECTED — shared path '$shared_path' has a rename or copy change" >&2
        CH_KEEP[$shared_chunk]=1; rc=3; shared_bad=1
        continue
      fi
      case "$SHARED_STATUS_XY" in
        ' M'|'M '|'MM') ;;
        *)
          echo "  ${CH_NAME[$shared_chunk]}: REJECTED — shared path '$shared_path' has unsupported change '$SHARED_STATUS_XY'" >&2
          CH_KEEP[$shared_chunk]=1; rc=3; shared_bad=1
          continue
          ;;
      esac
      if [ ! -f "$wt/$shared_path" ] || [ -L "$wt/$shared_path" ]; then
        echo "  ${CH_NAME[$shared_chunk]}: REJECTED — shared path '$shared_path' is not an ordinary file" >&2
        CH_KEEP[$shared_chunk]=1; rc=3; shared_bad=1
        continue
      fi
      actual_mode="$(stat -c '%a' -- "$wt/$shared_path" 2>/dev/null)" || actual_mode=""
      if [ "$actual_mode" != "${base_mode:3}" ]; then
        echo "  ${CH_NAME[$shared_chunk]}: REJECTED — shared path '$shared_path' changed mode" >&2
        CH_KEEP[$shared_chunk]=1; rc=3; shared_bad=1
        continue
      fi
      shared_text_pair "$base_file" "$wt/$shared_path"
      text_rc=$?
      if [ "$text_rc" -eq 1 ]; then
        echo "  ${CH_NAME[$shared_chunk]}: REJECTED — shared path '$shared_path' has binary content" >&2
        CH_KEEP[$shared_chunk]=1; rc=3; shared_bad=1
      elif [ "$text_rc" -ne 0 ]; then
        echo "  ${CH_NAME[$shared_chunk]}: REJECTED — could not inspect shared path '$shared_path'" >&2
        CH_KEEP[$shared_chunk]=1; rc=3; shared_bad=1
      fi
    done
    if [ "$shared_bad" -ne 0 ]; then
      shared_index=$((shared_index + 1))
      continue
    fi

    result_file="$TMP/shared-result-$shared_index"
    left="${CH_WT[${shared_chunks[0]}]}/$shared_path"
    right="${CH_WT[${shared_chunks[1]}]}/$shared_path"
    if ! cp -a -- "$left" "$result_file"; then
      echo "  shared path '$shared_path': REJECTED — could not prepare merge result" >&2
      for shared_chunk in "${shared_chunks[@]}"; do CH_KEEP[$shared_chunk]=1; done
      rc=3
      shared_index=$((shared_index + 1))
      continue
    fi
    "${git_clean[@]}" merge-file -p "$left" "$base_file" "$right" > "$result_file" 2>/dev/null
    merge_rc=$?
    if [ "$merge_rc" -ne 0 ]; then
      if [ "$merge_rc" -eq 1 ]; then
        echo "  shared path '$shared_path' has a conflicting merge" >&2
      else
        echo "  shared path '$shared_path': REJECTED — three-way merge failed (rc $merge_rc)" >&2
      fi
      for shared_chunk in "${shared_chunks[@]}"; do CH_KEEP[$shared_chunk]=1; done
      rc=3
      shared_index=$((shared_index + 1))
      continue
    fi
    SHARED_RESULT[$shared_index]="$result_file"
    shared_index=$((shared_index + 1))
  done
fi

if [ "$rc" -ne 0 ]; then
  echo "No chunks merged; every chunk must pass before any file is copied." >&2
  exit 3
fi

target_head="$("${git_clean[@]}" -C "$REPO" rev-parse --verify HEAD 2>/dev/null)" || {
  echo "REFUSING: could not re-check target HEAD before merge" >&2
  for i in "${!CH_WT[@]}"; do CH_KEEP[$i]=1; done
  exit 3
}
if [ "$target_head" != "$batch_head" ]; then
  echo "REFUSING: target HEAD changed during batch: batch HEAD $batch_head, current HEAD $target_head" >&2
  for i in "${!CH_WT[@]}"; do CH_KEEP[$i]=1; done
  exit 3
fi

for i in "${!CH_WT[@]}"; do
  wt="${CH_WT[$i]}"
  rename_destinations=()
  rename_sources=()
  deletions=()
  while IFS= read -r -d '' record; do
    xy="${record:0:2}"; path="${record:3}"
    if [[ "$xy" == "!!" ]]; then
      if ! ignored_path_inside_worktree "$wt" "$path"; then
        echo "  ${CH_NAME[$i]}: REJECTED — wrote outside its declared files:" >&2
        printf '    %s\n' "$(sanitize_ignored_path "$path")" >&2
        CH_KEEP[$i]=1; rc=3
      fi
      continue
    elif [[ "$xy" == *R* ]]; then
      IFS= read -r -d '' old_path || { echo "  ${CH_NAME[$i]}: FAILED — malformed rename" >&2; CH_KEEP[$i]=1; rc=3; continue; }
      if is_shared_path "$path" || is_shared_path "$old_path"; then
        continue
      fi
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
      if is_shared_path "$path" || is_shared_path "$old_path"; then
        continue
      fi
      internal_path "$path" && continue
      if safe_copy "$wt" "$path"; then
        echo "  ${CH_NAME[$i]}: merged $path"
      else
        echo "  ${CH_NAME[$i]}: FAILED — could not merge $path" >&2
        CH_KEEP[$i]=1; rc=3
      fi
    elif internal_path "$path"; then
      continue
    elif is_shared_path "$path"; then
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

if [ "$rc" -eq 0 ]; then
  for shared_index in "${!SHARED_PATHS[@]}"; do
    shared_path="${SHARED_PATHS[$shared_index]}"
    shared_parent="$(dirname -- "$shared_path")"
    if mkdir -p -- "$REPO/$shared_parent" \
      && shared_parent="$(realpath -- "$REPO/$shared_parent" 2>/dev/null)" \
      && case "$shared_parent/" in
        "$repo_root/"*) cp -a -- "${SHARED_RESULT[$shared_index]}" "$REPO/$shared_path" ;;
        *) false ;;
      esac
    then
      echo "merged shared ${SHARED_PATHS[$shared_index]}"
    else
      echo "FAILED — could not merge shared ${SHARED_PATHS[$shared_index]}" >&2
      rc=3
    fi
  done
fi

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

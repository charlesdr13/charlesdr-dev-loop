#!/usr/bin/env bash
# Shared run-root and requirement grammar for the flow scripts.

CHARLES_REQUIREMENT_REGEX='^[A-Z]+[0-9]+(\.[0-9]+)?[a-z]?$'

charles_run_root() {
  local dir="$1" git_common_dir
  dir="$(cd -- "$dir" && pwd)" || return 1
  if git_common_dir="$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null)"; then
    case "$git_common_dir" in
      /*) ;;
      *) git_common_dir="$dir/$git_common_dir" ;;
    esac
    if git_common_dir="$(cd -- "$git_common_dir" 2>/dev/null && pwd -P)"; then
      dir="$(dirname -- "$git_common_dir")"
    fi
  fi
  printf '%s\n' "$dir"
}

# True when $2 (a resolved path) is inside $1 (a run root) or any linked
# worktree of it. The run root is the main checkout, but a flow writes its plan
# in the worktree it runs in.
charles_in_repo() {
  local root
  while IFS= read -r root; do
    root="$(cd -- "$root" 2>/dev/null && pwd -P)" || continue
    case "$2" in "$root"/*) return 0 ;; esac
  done < <(printf '%s\n' "$1"; git -C "$1" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
  return 1
}

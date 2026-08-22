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

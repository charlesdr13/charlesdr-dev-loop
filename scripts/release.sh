#!/usr/bin/env bash
# release.sh — validate, install, relink, and diagnose one plugin release.
set -euo pipefail

VERSION="${1:-}"
SEMVER='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'
if [ "$#" -ne 1 ] || [[ ! "$VERSION" =~ $SEMVER ]]; then
  echo "usage: $0 <semver>" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

dirty="$(git status --porcelain --untracked-files=all -- .claude-plugin/)"
if [ -n "$dirty" ]; then
  echo "release.sh: refusing — .claude-plugin/ has uncommitted changes" >&2
  printf '%s\n' "$dirty" >&2
  exit 1
fi

if ! bash scripts/green.sh "$REPO_ROOT"; then
  echo "release.sh: refusing — green command failed" >&2
  exit 1
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/charles-release.XXXXXX")"
restore_needed=0

cleanup() {
  local rc="${1:-$?}" restore_rc=0 signaled=0
  [ "$#" -gt 0 ] && signaled=1
  trap - EXIT HUP INT TERM
  if [ "$restore_needed" -eq 1 ]; then
    echo "release.sh: restoring .claude-plugin/ from byte-for-byte backups" >&2
    if ! mv "$tmp_dir/plugin.json.orig" "$REPO_ROOT/.claude-plugin/plugin.json"; then
      echo "release.sh: RESTORE FAILED: plugin.json" >&2
      restore_rc=1
    fi
    if ! mv "$tmp_dir/marketplace.json.orig" "$REPO_ROOT/.claude-plugin/marketplace.json"; then
      echo "release.sh: RESTORE FAILED: marketplace.json" >&2
      restore_rc=1
    fi
    [ "$restore_rc" -eq 0 ] || [ "$signaled" -eq 1 ] || rc=1
  fi
  if ! rm -rf "$tmp_dir"; then
    echo "release.sh: cleanup failed: $tmp_dir" >&2
    [ "$signaled" -eq 1 ] || rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'cleanup 129' HUP
trap 'cleanup 130' INT
trap 'cleanup 143' TERM

if ! cp -- .claude-plugin/plugin.json "$tmp_dir/plugin.json.orig" \
  || ! cp -- .claude-plugin/marketplace.json "$tmp_dir/marketplace.json.orig"; then
  echo "release.sh: could not save .claude-plugin backups" >&2
  exit 1
fi
restore_needed=1

if ! jq --arg version "$VERSION" '.version = $version' \
    .claude-plugin/plugin.json > "$tmp_dir/plugin.json" \
  || ! jq --arg version "$VERSION" \
    '.metadata.version = $version | .plugins[0].version = $version' \
    .claude-plugin/marketplace.json > "$tmp_dir/marketplace.json"; then
  echo "release.sh: could not write version fields" >&2
  exit 1
fi
mv "$tmp_dir/plugin.json" .claude-plugin/plugin.json
mv "$tmp_dir/marketplace.json" .claude-plugin/marketplace.json

if ! claude plugin marketplace update charlesdr-dev-loop \
  || ! claude plugin install charlesdr-dev-loop@charlesdr-dev-loop; then
  exit 1
fi
# `install` is a no-op when the plugin is already installed; `update` is what
# actually copies the new version into the cache.
CACHE_ROOT="$HOME/.claude/plugins/cache/charlesdr-dev-loop/charlesdr-dev-loop"
if [ ! -d "$CACHE_ROOT/$VERSION" ]; then
  claude plugin update charlesdr-dev-loop@charlesdr-dev-loop || exit 1
fi

CACHE="$HOME/.claude/plugins/cache/charlesdr-dev-loop/charlesdr-dev-loop/$VERSION"
TARGET="$CACHE/scripts/codex-run.sh"
LINK="$HOME/.local/bin/codex-run"
if [ ! -d "$CACHE" ]; then
  echo "release.sh: installed cache directory is missing: $CACHE" >&2
  exit 1
fi

if [ ! -f "$TARGET" ] \
  || ! mkdir -p "$(dirname "$LINK")" \
  || ! ln -sfn "$TARGET" "$LINK" \
  || [ "$(readlink "$LINK" 2>/dev/null)" != "$TARGET" ]; then
  echo "release.sh: could not relink codex-run to $TARGET" >&2
  exit 1
fi
restore_needed=0

set +e
bash scripts/doctor.sh
doctor_rc=$?
set -e
exit "$doctor_rc"

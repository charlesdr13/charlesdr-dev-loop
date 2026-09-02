#!/usr/bin/env bash
# link-dispatcher.sh — SessionStart. Put a stable `codex-run` on PATH.
#
# Why this exists: agents were told to run ${CLAUDE_PLUGIN_ROOT}/scripts/codex-run.sh,
# but that variable does not expand in an agent's shell. They got "not found: --",
# went hunting, and found the author's working checkout — which was being edited at
# the time, so one of them executed a half-written file and died on a syntax error.
#
# A symlink into the plugin's own cache copy fixes both halves: the path is stable,
# and it points at an installed snapshot rather than someone's live working tree.
set -euo pipefail

root="${CLAUDE_PLUGIN_ROOT:-}"
[ -n "$root" ] || exit 0
src="$root/scripts/codex-run.sh"

command -v git >/dev/null 2>&1 || exit 0
git_clean=(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY git)

target_ok() {
  local candidate="$1" resolved
  [ -f "$candidate" ] && [ -x "$candidate" ] || return 1
  resolved="$(readlink -f "$candidate" 2>/dev/null)" || return 1
  [ -n "$resolved" ] || return 1
  if "${git_clean[@]}" -C "$(dirname "$resolved")" rev-parse --show-toplevel >/dev/null 2>&1; then
    echo "charlesdr-dev-loop: refusing to link codex-run into a git working tree: $resolved" >&2
    return 1
  fi
}

target=""
ver="$(jq -r '.version' "$root/.claude-plugin/plugin.json" 2>/dev/null)" || ver=""
if [ -n "$ver" ]; then
  cache="$HOME/.claude/plugins/cache/charlesdr-dev-loop/charlesdr-dev-loop/$ver/scripts/codex-run.sh"
  target_ok "$cache" && target="$cache"
fi
if [ -z "$target" ] && target_ok "$src"; then
  target="$src"
fi
[ -n "$target" ] || exit 0

bin="$HOME/.local/bin"
mkdir -p "$bin" 2>/dev/null || exit 0
link="$bin/codex-run"

# Only rewrite when it actually changed, so a reinstall is silent and idempotent.
if [ "$(readlink "$link" 2>/dev/null)" != "$target" ]; then
  ln -sfn "$target" "$link" 2>/dev/null || exit 0
  echo "charlesdr-dev-loop: codex-run -> $target"
fi

# --- where you left off -------------------------------------------------------
# 12 runs sat open across 5 repos, invisible unless you ran /status in each. The
# Stop hook only warns about FAILED items; this answers the resume question at
# the moment you enter the repo, and stays silent when nothing is open.
repo="$PWD"
repo="$(realpath -m "$repo" 2>/dev/null || echo "$repo")"
while [ "$repo" != "/" ] && [ ! -f "$repo/.charles.toml" ]; do
  parent="$(dirname "$repo")"; [ "$parent" = "$repo" ] && break; repo="$parent"
done
[ -f "$repo/.charles.toml" ] || exit 0

open_n=0; items=0; newest=""; abandoned_n=0; abandoned_ids=""
for d in "$repo"/.charles/runs/*/; do
  [ -f "$d/RUN.md" ] || continue
  if grep -q '^## Outcome' "$d/RUN.md" 2>/dev/null; then
    if grep -q '^## Abandoned$' "$d/RUN.md" 2>/dev/null; then
      abandoned_n=$((abandoned_n + 1))
      abandoned_ids="${abandoned_ids:+$abandoned_ids }$(basename "${d%/}")"
    fi
    continue
  fi
  open_n=$((open_n + 1))
  n="$(grep -c '^- \[ \] ' "$d/RUN.md" 2>/dev/null)" || n=0
  items=$((items + ${n:-0}))
  newest="$(basename "${d%/}")"
done

if [ "$open_n" -gt 0 ]; then
  echo "charlesdr-dev-loop: $open_n open run(s) here, $items unresolved item(s). Newest: $newest"
  echo "  /charlesdr-dev-loop:resolve to pick up where you stopped"
fi
if [ "$abandoned_n" -gt 0 ]; then
  echo "charlesdr-dev-loop: $abandoned_n ABANDONED run(s) here (not open): $abandoned_ids"
fi
exit 0

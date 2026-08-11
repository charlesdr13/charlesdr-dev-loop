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
[ -x "$src" ] || exit 0

bin="$HOME/.local/bin"
mkdir -p "$bin" 2>/dev/null || exit 0
link="$bin/codex-run"

# Only rewrite when it actually changed, so a reinstall is silent and idempotent.
if [ "$(readlink "$link" 2>/dev/null)" != "$src" ]; then
  ln -sfn "$src" "$link" 2>/dev/null || exit 0
  echo "charlesdr-dev-loop: codex-run -> $src"
fi
exit 0

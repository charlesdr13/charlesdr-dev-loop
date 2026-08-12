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

open_n=0; items=0; newest=""
for d in "$repo"/.charles/runs/*/; do
  [ -f "$d/RUN.md" ] || continue
  grep -q '^## Outcome' "$d/RUN.md" 2>/dev/null && continue
  open_n=$((open_n + 1))
  n="$(grep -c '^- \[ \] ' "$d/RUN.md" 2>/dev/null)" || n=0
  items=$((items + ${n:-0}))
  newest="$(basename "${d%/}")"
done

if [ "$open_n" -gt 0 ]; then
  echo "charlesdr-dev-loop: $open_n open run(s) here, $items unresolved item(s). Newest: $newest"
  echo "  /charlesdr-dev-loop:resolve to pick up where you stopped"
fi
exit 0

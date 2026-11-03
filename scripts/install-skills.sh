#!/usr/bin/env bash
# install-skills.sh — install as plain skills, for contexts without plugin support.
#
# The plugin install (/plugin install) is the normal path and gives you the
# agents, the commands, and the hook. This path gives you the two skills and the
# lane dispatcher only — no agents, no hook. Use it on a machine or harness
# where plugins are not available.
#
#   bash scripts/install-skills.sh            # symlink (edits track the repo)
#   bash scripts/install-skills.sh --copy     # copy (independent of the repo)
#   bash scripts/install-skills.sh --codex    # symlink into ~/.codex/skills for Codex
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SKILLS="$HOME/.claude/skills"
BIN="$HOME/.local/bin"
MODE="symlink"
[ "${1:-}" = "--copy" ] && MODE="copy"
[ "${1:-}" = "--codex" ] && SKILLS="$HOME/.codex/skills"

mkdir -p "$SKILLS" "$BIN"

for s in charles-flow grill-rounds; do
  dest="$SKILLS/$s"
  [ -e "$dest" ] || [ -L "$dest" ] && rm -rf "$dest"
  if [ "$MODE" = "copy" ]; then cp -r "$REPO/skills/$s" "$dest"
  else ln -s "$REPO/skills/$s" "$dest"; fi
  echo "installed skill: $dest ($MODE)"
done

# Put the dispatcher on PATH so the skills work without ${CLAUDE_PLUGIN_ROOT}.
ln -sf "$REPO/scripts/codex-run.sh" "$BIN/codex-run"
echo "installed dispatcher: $BIN/codex-run -> $REPO/scripts/codex-run.sh"

case ":$PATH:" in
  *":$BIN:"*) ;;
  *) echo "WARNING: $BIN is not on PATH — add it, or the skills cannot dispatch" ;;
esac

echo
echo "Skill-only install. You do NOT have: the codex-* agents, the /cstack:*"
echo "commands, or the edit-routing hook. For those, install as a plugin:"
echo "  /plugin marketplace add $REPO"
echo "  /plugin install cstack@cstack"

---
description: Switch the project engine (luna | terra | deepseek | claude), set a global default, or show the current one
---

```bash
SCRIPTS="$(dirname "$(readlink -f "$(command -v codex-run)")")"
. "$SCRIPTS/run-common.sh"
ROOT="$(charles_run_root "$PWD")"
D="${CHARLES_STATE_DIR:-$HOME/.cache/charlesdr-dev-loop}"
VALUE="${ARGUMENTS:-}"; GLOBAL=0
case "$VALUE" in global\ *) GLOBAL=1; VALUE="${VALUE#global }" ;; esac
TARGET="$D/engine"
if [ "$GLOBAL" -eq 0 ] && [ -f "$ROOT/.charles.toml" ] \
  && [ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ]; then
  TARGET="$ROOT/.charles/engine"
fi
case "$VALUE" in
  luna|terra|deepseek|claude) mkdir -p "$(dirname "$TARGET")" && printf '%s\n' "$VALUE" > "$TARGET" || exit $? ;;
  default|clear|reset)
    rm -f "$TARGET" || exit $? ;;
  "") ;;
  *) echo "unknown engine '$ARGUMENTS' (luna|terra|deepseek|claude|default; optional global prefix)" >&2; exit 2 ;;
esac
PICK="${CHARLES_ENGINE:-}"; SCOPE=environment
if [ -z "$PICK" ]; then PICK="$(cat "$ROOT/.charles/engine" 2>/dev/null || true)"; SCOPE=project; fi
if [ -z "$PICK" ]; then PICK="$(cat "$D/engine" 2>/dev/null || true)"; SCOPE=global; fi
case "$PICK" in luna|terra|deepseek|claude) ;; *) PICK='default (luna; review on sol)'; SCOPE=default ;; esac
echo "engine ($SCOPE): $PICK"
```

Report the engine line back. Takes effect on the next dispatch — no restart, no
reinstall. `/engine <value>` writes `<run root>/.charles/engine` in a repo with
`.charles.toml`, otherwise the global `$CHARLES_STATE_DIR/engine` (default:
`~/.cache/charlesdr-dev-loop/engine`). Linked worktrees share the primary
checkout's preference. `/engine global <value>` always writes global.
`/engine default` clears the project preference; `/engine global default` clears
the global preference. The echoed scope is the effective one, even after a
global change that a project preference overrides.

Precedence: `--engine` flag, `CHARLES_ENGINE`, project file, global file.
`claude` runs explore and implement on `claude-sonnet-5` at medium effort;
review stays on codex sol at medium. Explicit `--engine claude --lane review`
and `--engine claude --resume` are refused. `--effort` still overrides the
default. A failed claude dispatch has no fallback.

`deepseek` is the free-of-codex-quota lane (deepseek-v4-flash @ max, via
`~/.codex/deepseek.config.toml`). With no preference, explore and implement use
luna with deepseek as fallback, and review uses sol.

`deepseek` is peak-aware. DeepSeek bills roughly double between 01:00-04:00 and
06:00-10:00 UTC, so dispatches inside those windows run on luna instead — at max
reasoning with luna's normal fast_mode selection. Outside them the lane stays
on deepseek. An explicit `--engine deepseek` is never swapped: that is the
failure fallback path.

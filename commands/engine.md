---
description: Switch the project engine (luna | terra | deepseek | claude | grok), set a global default, or show the current one
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
  luna|terra|deepseek|claude|grok) mkdir -p "$(dirname "$TARGET")" && printf '%s\n' "$VALUE" > "$TARGET" || exit $? ;;
  default|clear|reset)
    rm -f "$TARGET" || exit $? ;;
  "") ;;
  *) echo "unknown engine '$ARGUMENTS' (luna|terra|deepseek|claude|grok|default; optional global prefix)" >&2; exit 2 ;;
esac
PICK="${CHARLES_ENGINE:-}"; SCOPE=environment
if [ -z "$PICK" ]; then PICK="$(cat "$ROOT/.charles/engine" 2>/dev/null || true)"; SCOPE=project; fi
if [ -z "$PICK" ]; then PICK="$(cat "$D/engine" 2>/dev/null || true)"; SCOPE=global; fi
case "$PICK" in luna|terra|deepseek|claude|grok) ;; *) PICK='default (luna; review on sol)'; SCOPE=default ;; esac
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
`claude` runs explore, implement AND review as native Claude Code subagents:
`claude-explorer` (haiku), `claude-implementer` (sonnet), or `claude-reviewer`
(opus, isolated to a review box the same way `codex-reviewer` is). One Agent
call is the dispatch. Its prompt opens with header lines: `charles-dir:`, then
`charles-plan:` (implement and review), `charles-req:` (implement) and
`charles-base:` (review of committed work), then a blank line and the task. A hook runs
`codex-run`'s validation and receipts behind it, and a refusal comes back as a
denied tool call. Like `grok`, a `claude`
preference is honoured on review too — it no longer silently pins sol.
`--resume` is refused: no session id is recorded for a subagent. A failed
claude dispatch has no fallback.

`deepseek` is the free-of-codex-quota lane (deepseek-v4-flash @ max, via
`~/.codex/deepseek.config.toml`). With no preference, explore and implement use
luna with deepseek as fallback, and review uses sol.

`deepseek` is peak-aware. DeepSeek bills roughly double between 01:00-04:00 and
06:00-10:00 UTC, so dispatches inside those windows run on luna instead — at max
reasoning with luna's normal fast_mode selection. Outside them the lane stays
on deepseek. An explicit `--engine deepseek` is never swapped: that is the
failure fallback path.

`grok` runs all three lanes — explore, implement, AND review — on `grok-4.6` at
high effort by default via the local `grok` CLI; `--effort max` means `xhigh`
(grok has no `max`). Unlike `claude`, a `grok` preference is honoured on review
too: it is a different model family from every codex profile, which is exactly
what the isolated review wants. `--resume` is refused: no session id is
recorded. A failed grok dispatch has no fallback.

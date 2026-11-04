---
description: Switch the project engine (luna | terra | deepseek | claude | grok | omp | omp:<provider>/<model>), set a global default, or show the current one
---

```bash
SCRIPTS="$(dirname "$(readlink -f "$(command -v codex-run)")")"
. "$SCRIPTS/run-common.sh"
ROOT="$(charles_run_root "$PWD")"
D="${CHARLES_STATE_DIR:-$HOME/.cache/cstack}"
VALUE="${ARGUMENTS:-}"; GLOBAL=0
case "$VALUE" in global\ *) GLOBAL=1; VALUE="${VALUE#global }" ;; esac
TARGET="$D/engine"
if [ "$GLOBAL" -eq 0 ] && [ -f "$ROOT/.charles.toml" ] \
  && [ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ]; then
  TARGET="$ROOT/.charles/engine"
fi
case "$VALUE" in
  luna|terra|deepseek|claude|grok|omp) mkdir -p "$(dirname "$TARGET")" && printf '%s\n' "$VALUE" > "$TARGET" || exit $? ;;
  omp:?*)
    mkdir -p "$(dirname "$TARGET")" && printf '%s\n' "$VALUE" > "$TARGET" || exit $? ;;
  default|clear|reset)
    rm -f "$TARGET" || exit $? ;;
  "") ;;
  *) echo "unknown engine '$ARGUMENTS' (luna|terra|deepseek|claude|grok|omp|omp:<provider>/<model>|default; optional global prefix)" >&2; exit 2 ;;
esac
PICK="${CHARLES_ENGINE:-}"; SCOPE=environment
if [ -z "$PICK" ]; then PICK="$(cat "$ROOT/.charles/engine" 2>/dev/null || true)"; SCOPE=project; fi
if [ -z "$PICK" ]; then PICK="$(cat "$D/engine" 2>/dev/null || true)"; SCOPE=global; fi
case "$PICK" in luna|terra|deepseek|claude|grok|omp|omp:?*) ;; *) PICK="${CHARLES_DEFAULT_ENGINE-claude}"; PICK="default (${PICK:-luna; review on sol})"; SCOPE=default ;; esac
echo "engine ($SCOPE): $PICK"
```

Report the engine line back. Takes effect on the next dispatch; no restart or
reinstall. `/engine <value>` writes `<run root>/.charles/engine` in a repo with
`.charles.toml`, otherwise the global `$CHARLES_STATE_DIR/engine` (default
`~/.cache/cstack/engine`). Linked worktrees share the primary checkout's
preference. `/engine global <value>` always writes global; `/engine default`
clears the project preference, `/engine global default` the global one. The echoed
scope is the effective one, even after a global change a project preference
overrides.

Precedence: `--engine` flag, `CHARLES_ENGINE`, project file, global file, then the
built-in default `claude`. Codex (luna/terra/sol) and grok run only when asked for.

`claude` runs explore, implement and review as native subagents: `claude-explorer`
(haiku), `claude-implementer` (sonnet), `claude-reviewer` (opus, isolated to a
review box like `codex-reviewer`). One Agent call is the dispatch; its prompt opens
with header lines `charles-dir:`, then `charles-plan:` (implement and review),
`charles-req:` (implement) and `charles-base:` (review of committed work), a blank
line, then the task. A hook runs `codex-run`'s validation and receipts behind it; a
refusal comes back as a denied tool call. A `claude` preference is honoured on
review too, like `grok`. `--resume` is refused (no session id is recorded for a
subagent); a failed claude dispatch has no fallback.

`deepseek` is the free-of-codex-quota lane (deepseek-v4-flash @ max, via
`~/.codex/deepseek.config.toml`). It is peak-aware: DeepSeek bills roughly double
between 01:00-04:00 and 06:00-10:00 UTC, so dispatches in those windows run on luna
(max reasoning, luna's normal fast_mode selection) instead. An explicit
`--engine deepseek` is never swapped. It is not an automatic fallback: luna and
terra fall back to grok, and grok to luna.

`grok` runs all three lanes on `grok-4.6` at high effort via the local `grok` CLI;
`--effort max` means `xhigh` (grok has no `max`). Honoured on review too: a
different model family from every codex profile, which is what the isolated review
wants. `--resume` is refused; a failed grok dispatch has no fallback.

`omp` runs all three lanes on a headless `omp` process, one model per lane: explore
`cursor/composer-2.5-fast`, implement `cursor/composer-2.5`, review
`openai-codex/gpt-6.1-sol`. `omp:<provider>/<model>` overrides the model for every
lane (an unknown model exits 1 at dispatch); a bare `omp:` is rejected. Honoured on
review too, in the same isolated box. `--resume` is refused; a failed omp dispatch
has no fallback. Under an omp orchestrator, its bash `async: true` is
`run_in_background: true` and its `task` tool is the Agent tool: spawning the
`claude-<lane>` agents with it dispatches them on their omp lane models whatever the
engine preference says.

# omp-native lanes: the task tool is the dispatch

Goal: an omp orchestrator spawns the `claude-<lane>` agents with omp's own
`task` tool and gets the same dispatch, receipts and review isolation the Agent
tool gets in Claude Code, with each lane on its own provider. The omp engine's
headless lanes get faster defaults.

## Facts (sourced)

- omp re-runs extension factories inside subagents; `ctx.agent` is
  `{kind:"main"|"sub", name, id, depth}`. Live probe 2026-09-28 (omp 18.4.2):
  a `claude-explorer` spawn reported `kind:"sub", name:"claude-explorer"`.
- The `task` tool input is `{context, tasks:[{name, agent, task, ...}]}` (batch,
  default) or a flat item. Agent names arrive plain. `tool_call` handlers may
  return `{input}` to revise it or `{block, reason}` (binary: `emitToolCall`).
- `before_subagent_spawn` carries `agent`, `patterns`; returning `{model, note}`
  replaces the spawn's model patterns ([extensions.md](https://raw.githubusercontent.com/can1357/oh-my-pi/main/docs/extensions.md)).
- The agents' frontmatter `model: haiku` does not resolve under omp; the probe
  child ran on the parent's model (`patterns: ["openai-codex/gpt-5.6-luna"]`).
- The child's first prompt is `Complete assignment thoroughly:\n\n<task>`, so
  `charles-run:`/`charles-box:` lines survive at line starts.
- `agent_end` fires before a subagent finishes (a reminder turn follows); the
  hidden `yield` tool is the finish. A section yield carries `type`.
- omp paths: `read {path:"a.txt:1"}` carries line selectors; `glob {path}` is
  the pattern; `grep {pattern, path}`.
- A plugin can read settings via `@oh-my-pi/pi-coding-agent/config/registry`
  `lookup("task.agentModelOverrides")` (probe 2026-09-28).
- `BUN_BE_BUN=1 omp file.ts` runs a file on omp's embedded Bun.

## Requirements

- [ ] **R1** — `task` tool calls in an opted-in repo pass each item through
  `route-subagents.sh` then `claude-lane-dispatch.sh`; a lane item's `task` is
  replaced by the rewritten brief (batch and flat shapes); a deny blocks the call.
- [ ] **R2** — `before_subagent_spawn` routes `claude-explorer` to
  `cursor/composer-2.5-fast`, `claude-implementer` to `cursor/composer-2.5`,
  `claude-reviewer` to `openai-codex/gpt-5.6-sol:medium`, in opted-in repos only,
  unless `task.agentModelOverrides` names the agent. Models match `omp_default_model`.
- [ ] **R3** — Inside a `claude-reviewer` subagent, `read`/`grep`/`glob` are
  mapped to Claude shapes and checked by `claude-review-box.sh`; `yield` passes;
  every other tool is blocked.
- [ ] **R4** — Inside a lane subagent, the first non-section `yield` (or session
  shutdown) feeds `claude-lane-receipt.sh` the brief once; the end record names
  the model that ran (`CHARLES_LANE_MODEL`). The reviewer's box is removed.
- [ ] **R5** — The `claude-implementer` subagent's edits skip the edit gate.
- [ ] **R6** — `route-subagents.sh` gates omp's `task|scout|sonic|designer|reviewer`
  toward the lane agents.
- [ ] **R7** — omp engine speed: explore defaults to `--thinking high` (explicit
  `--effort` wins) and adds `--no-lsp`; explore and review add `--no-title`,
  review adds `--no-lsp`; implement keeps LSP and max.
- [ ] **R8** — Docs (README, charles-flow SKILL.md, engine.md) and version 2.45.0.
- [ ] **R9** — selftest drives charles.ts under omp's Bun for R1-R6 and asserts R7.

User decision (2026-09-28): Cursor Composer is the subagent and implementer.
Explore runs `cursor/composer-2.5-fast`, implement `cursor/composer-2.5`, in
both the bridge and `omp_default_model`. Review stays `openai-codex/gpt-5.6-sol`,
a different family from the implementer. Composer has no thinking levels; omp
accepts and ignores `--thinking` for it (probe: rc 0 on both models at `max`).

## Live proof — 2026-09-28

- Bridge, real omp 18.4.2, throwaway opted-in repo: the main agent spawned
  `claude-explorer` via `task`; the dispatch hook logged `start`, the child ran on
  `cursor/composer-2.5-fast`, answered `entry.ts:1`, and its final yield logged
  `end` with `model:"cursor/composer-2.5-fast"`. `verify-receipt.sh --lane explore`: RECEIPT OK.
- Engine: `codex-run --lane implement --engine omp` ran `omp/cursor/composer-2.5`,
  made exactly the asked 4-line edit in ~15 s, `end` rc 0 with that model.

## Sign-off

Green: `bash scripts/selftest.sh && bash scripts/doctor.sh` → `492 passed, 0 failed` · `21 ok, 0 failing`.
Not yet run: grill and isolated review.

- [x] **R1** — selftest: omp task batch dispatch, flat shape rewrite, unknown header blocked (PASS); live proof above
- [x] **R2** — selftest: bridge lane models, parity with omp_default_model, opted-in-only spawn routing (PASS)
- [x] **R3** — selftest: reviewer confined to read/grep/glob in its box plus yield (PASS)
- [x] **R4** — selftest: one end receipt with the real model, none on a section yield, box removed (PASS); live proof above
- [x] **R5** — selftest: claude-implementer subagent writes past the edit gate, main agent still gated (PASS)
- [x] **R6** — selftest: omp scout/default spawns gated; an approved ask is remembered (PASS)
- [x] **R7** — selftest: omp explore high effort + --no-lsp/--no-title, explicit --effort max passes, review --no-lsp, implement keeps LSP (PASS)
- [x] **R8** — README, SKILL.md, engine.md updated; 2.45.0 in all three version fields
- [x] **R9** — selftest drives charles.ts under `BUN_BE_BUN=1 omp` (16 new checks)

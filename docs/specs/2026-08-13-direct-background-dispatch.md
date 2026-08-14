# Direct background dispatch replaces the explorer/implementer wrapper agents

Measured over one day of runs: every supervision failure (immortal wait loops,
80k-token pollers, re-dispatch storms, misreported results) happened in the
dispatcher-agent layer; none happened in codex. The orchestrator's Bash tool
already provides detached background execution with a completion callback, which
is the exact mechanism the wrapper agents were hand-rolling badly.

## Requirements (checkable)

1. `agents/codex-explorer.md` and `agents/codex-implementer.md` are deleted.
   `agents/codex-reviewer.md` remains and is unchanged in behaviour.
2. `skills/charles-flow/SKILL.md` documents ONE primary dispatch mechanism for
   explore and implement lanes: the orchestrator itself runs
   `codex-run --lane <lane> --dir <repo> --timeout 1800 "<task>"` as a
   **background Bash call** (`run_in_background: true`). The harness re-invokes
   the orchestrator when the process exits — no `sleep` loops, no periodic
   `lane-status.sh` polling as the primary wait. `lane-status.sh` remains
   documented only as the recovery probe for a dispatch whose completion signal
   was lost (session restart, harness death). All instructions to spawn
   `codex-explorer` / `codex-implementer` agents are removed, including the
   "three or more in parallel → agents" row; parallel fan-out is N background
   Bash calls, each logging to its own file under `.charles/`. Review-lane
   guidance (foreground, isolated, `codex-reviewer` agent allowed) is unchanged.
3. `hooks/route-to-codex.sh` ask-message tells Claude to dispatch the implement
   lane via a background `codex-run` call, not to spawn the codex-implementer
   agent. `hooks/route-subagents.sh` drops `codex-explorer|codex-implementer`
   from its allowlist (keeping `codex-reviewer`) and its `alt=` suggestions
   name the direct `codex-run --lane ...` command instead of agents.
4. `scripts/selftest.sh` passes: the two subagent-allow checks for the deleted
   agents are replaced with checks that (a) `codex-reviewer` is still allowed,
   (b) the blocked-agent messages point at direct dispatch. No other assertions
   weakened. `scripts/doctor.sh` drift list drops the two deleted agent files.
5. `commands/feature.md`, `commands/ui.md`, and `README.md` no longer reference
   the deleted agents; their wording matches the direct-dispatch mechanism.
6. Version is `2.13.0` in `.claude-plugin/plugin.json` and in BOTH `version`
   fields of `.claude-plugin/marketplace.json`.

## Out of scope

`scripts/codex-run.sh`, `scripts/lane-status.sh`, `scripts/parallel-chunks.sh`,
`agents/codex-reviewer.md` behaviour, and all run-state/receipt machinery.

## Must keep working

`bash scripts/selftest.sh && bash scripts/doctor.sh` (the green command).
Conventions: copy the existing voice of `skills/charles-flow/SKILL.md` —
measured numbers stay, scar-tissue anecdotes stay where still true.

## Background context the implementer needs

`run_in_background: true` is a parameter of Claude Code's Bash tool: the command
runs detached, survives across turns, and the harness re-invokes the agent when
it exits. That callback is the completion signal the old wrapper agents lacked,
and it is why polling guidance is being deleted rather than tuned.

## Run outcome — 2026-08-13

Explorer/implementer wrapper agents deleted; explore and implement lanes now dispatch via background Bash directly from the orchestrator, with the harness completion callback replacing all polling. Reviewer agent and review lane unchanged. Hooks, selftest, doctor, commands, README updated to match. Version 2.13.0. Grill skipped deliberately: plan was the user-approved design from conversation; sol review graded diff against plan (GAPS FOUND -> fixed). Rollback: git checkout -- . && git checkout agents/

## Grill verdict

Waived: the plan was the user-approved design from conversation; the isolated
sol review graded the diff against it (GAPS FOUND → fixed) in place of a
pre-implementation grill. Recorded at close on 2026-08-13.

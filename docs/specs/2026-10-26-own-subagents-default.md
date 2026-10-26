# Own subagents by default, anchoring questions (2.49.1)

Charles, 2026-10-26: "by default use own subagents unless asked to used grok or codex". Also "do recom" on the research rec:
replace the grill with up to 3 anchoring questions in one message, then proceed on the recommended defaults without blocking (Pocock: misalignment is the top failure; Kun Chen: rigor matched to stakes).

## Requirements

- [ ] **R1** — `scripts/codex-run.sh`: when no `--engine`, `CHARLES_ENGINE`, project file or global file picks an engine, the engine is `claude` (explore, implement and review all print the claude SPAWN block). `CHARLES_DEFAULT_ENGINE` overrides the built-in default; set to empty it restores the old luna lanes with sol review (the selftest uses that so its codex stubs keep running). Selftest proves an unconfigured explore and review print the claude SPAWN block.
- [ ] **R2** — `skills/charles-flow/SKILL.md`, `commands/engine.md`, `README.md` and `CLAUDE.md` say lanes default to Claude's own subagents (claude-explorer / claude-implementer / claude-reviewer) and that codex (luna/terra/sol) and grok run only when the user asks or a repo/global `/engine` preference names them.
- [ ] **R3** — `skills/charles-flow/SKILL.md` step 2: before planning, when the ask leaves a real fork (scope, user-visible behaviour, an irreversible choice), ask at most 3 questions in one message, each with a recommended default, then proceed on the defaults without waiting; fold late answers into the plan. The grill stays on-demand only.
- [ ] **R4** — version 2.49.1 in all three places.

Green: `bash scripts/selftest.sh && bash scripts/doctor.sh`.

## Grill verdict

Grill waived: two small, reversible changes the user asked for directly; the review grades the diff.

## Sign-off

- [x] **R1** — built-in default is claude; preferences still win (mutation-tested); empty CHARLES_DEFAULT_ENGINE restores luna/sol — selftest 465 passed, 0 failed
- [x] **R2** — SKILL.md, engine.md, README lane table, CLAUDE.md, plugin and marketplace descriptions — review round 2 SATISFIES PLAN
- [x] **R3** — step 2 "Anchor, then plan": at most 3 questions with defaults, proceed without waiting — SKILL.md diff
- [x] **R4** — 2.49.1 in plugin.json and both marketplace.json fields

## Run outcome — 2026-10-26

shipped 2.49.1 (PR #5, installed)

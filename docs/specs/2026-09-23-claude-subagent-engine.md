# claude engine = built-in subagents

engine=claude stops shelling out to headless `claude -p`. The orchestrating
Claude Code session does the work with three plugin subagents; `codex-run`
keeps everything it is good at (scope/--req/grill validation, receipts, the
isolated review box) and hands the orchestrator a ready-to-spawn brief.

| Lane | Agent (`agents/*.md`) | model | tools |
|---|---|---|---|
| explore | `claude-explorer` | haiku | Read, Grep, Glob, Bash |
| implement | `claude-implementer` | sonnet | Read, Edit, Write, MultiEdit, Grep, Glob, Bash |
| review | `claude-reviewer` | opus | Read, Grep, Glob |

Spawned plugin agents are namespaced (`charlesdr-dev-loop:claude-reviewer`), so
every hook matches agent names by suffix (`*claude-reviewer`), never exactly.

## Requirements

- [ ] **R1 Agents.** Add the three agent files above. Explorer: read-only
  research, cause/evidence with file:line, never patches. Implementer: works
  only in the directory named in its brief, implements the named requirements,
  runs the verification it is told to, reports the diff; never commits.
  Reviewer: adversarial grader of `plan.md` + `changes.diff` in the box dir it
  is given, same verdict format as the codex review lane (`GAPS FOUND` /
  pass), and it knows it cannot see anything else.
- [ ] **R2 Dispatcher hand-off.** With engine=claude (flag, env, project or
  global file), `codex-run` explore/implement/review no longer runs `claude -p`
  (`run_claude` and its model mapping are deleted). It runs the same
  validation as today (dir, main-tree refusal, open-run `--req`, grill
  verdict), logs the normal `start` event (engine `claude`), and prints a
  SPAWN block to stdout: the agent to spawn (`charlesdr-dev-loop:claude-<lane>`)
  and the exact prompt to pass, whose first line is `charles-run: <RUN_ID>`
  and `charles-dir: <DIR>`, followed by the task (plus plan path / req IDs for
  implement). Exit 0 immediately. Review with engine=claude is now allowed
  (drop the refusal); it builds the box exactly as today (same exit 3 on empty
  diff), writes a `.charles-review-box` marker file into it, does not delete
  it, and the SPAWN prompt names the box dir. `--resume` with claude stays
  refused. No fallback for claude.
- [ ] **R3 Receipts via hooks.** New `hooks/claude-lane-receipt.sh` on
  PostToolUse `Agent|Task`: for `*claude-explorer|*claude-implementer|
  *claude-reviewer` whose prompt carries `charles-run:` / `charles-dir:`,
  append the matching `end` event (same schema as `log_dispatch`: lane, engine
  `claude`, model `haiku|sonnet|opus`, rc 0, same run id, plus any
  flow_run_id/spec_path/req carried on the start record) to
  `<dir>/.charles/dispatches.jsonl`; for the reviewer also delete its box. So
  `verify-receipt.sh`, `flow-status.sh` ungraded counting and
  `lane-status.sh` work unchanged. A spawn that never completes leaves a start
  without an end (verify-receipt exit 3) — acceptable, documented.
- [ ] **R4 Review isolation enforced.** New `hooks/claude-review-box.sh` on
  PreToolUse (matcher `.*`): when payload `agent_type` ends in
  `claude-reviewer`, deny (`permissionDecision: deny`) any tool other than
  Read/Grep/Glob, and deny Read/Grep/Glob unless every path it names
  (`file_path`, `path`, absolute `pattern`) realpath-resolves inside a
  directory containing `.charles-review-box`; a missing path is denied.
  Other agents and the main thread: silent allow. Keep the jq guard.
- [ ] **R5 Gates.** `route-subagents.sh` allows the three claude agents and
  `*codex-reviewer` (fixing today's exact-name match). hooks.json wires R3/R4.
- [ ] **R6 Docs + proof.** Rewrite the claude sections of `commands/engine.md`,
  README, and the charles-flow SKILL lanes section ("engine=claude: run the
  codex-run call in the foreground, then spawn the SPAWN block's agent with its
  prompt verbatim; implement subagents get the worktree dir"). doctor: claude
  engine no longer needs the `claude` CLI; it checks the three agent files
  exist. selftest: replace the headless-claude cases with: SPAWN block + start
  event per lane; review box has marker and survives; receipt hook writes a
  matching end event and verify-receipt passes; review-box hook denies a
  reviewer Read outside the box, a reviewer Bash, and a missing path, allows a
  Read inside, ignores non-reviewer agents; route-subagents allows namespaced
  claude agents. Version bump in all three places.

Files: agents/claude-{explorer,implementer,reviewer}.md, scripts/codex-run.sh,
hooks/{claude-lane-receipt.sh,claude-review-box.sh,route-subagents.sh,hooks.json},
scripts/{doctor.sh,selftest.sh}, commands/engine.md, README.md,
skills/charles-flow/SKILL.md, .claude-plugin/{plugin,marketplace}.json.
Other engines untouched.

## Green

`bash scripts/selftest.sh && bash scripts/doctor.sh`

## Grill verdict

Grill waived: user fixed the design decisions directly (replace headless lane; built-in Opus review with hook-enforced isolation).

## Sign-off

- [x] **R1** `agents/claude-{explorer,implementer,reviewer}.md` (haiku / sonnet / opus).
- [x] **R2** SPAWN hand-off; `run_claude` deleted; the review box is kept and holds the marker. Selftest pins the exact agent names.
- [x] **R3** `hooks/claude-lane-receipt.sh` end events; verify-receipt accepts them.
- [x] **R4** `hooks/claude-review-box.sh`: a box counts only if it is a `charles-review.*` dir directly under the temp root. Denials covered: planted marker, missing path, Grep with no path, Glob `..`, Bash.
- [x] **R5** `route-subagents.sh` matches by suffix.
- [x] **R6** docs, doctor, selftest, and version 2.41.0.

Opus review GAPS FOUND: (1) SPAWN named nonexistent agents (`claude-explore` etc.), (3) any ancestor marker unlocked a subtree, (4) relative Glob `..`, (5) `rm -rf` of a prompt-supplied path. All fixed and tested. (2) Review start keeps engine `review`, the repo-wide convention; (6) fail-open without jq follows the hook contract; (7) lane-status reads start/end only. Accepted as is.
Green: `bash scripts/selftest.sh && bash scripts/doctor.sh` → `434 passed, 0 failed` / `25 ok, 0 failing`.

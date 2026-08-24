# Scope the close check to the run being closed

## Why

`run-state.sh close` runs `flow-status.sh --closing <rundir>` and refuses when it
exits non-zero. `flow-status.sh` audits the whole repository, so in a repo with a
backlog its exit is dominated by findings that have nothing to do with the run
being closed. Measured in `infra-orchestrator` on 2026-08-25: closing a run whose
own work was complete and signed off was blocked by seven unrelated open runs, two
orphan dispatch starts from 2026-08-21 and 2026-08-24, and five older plans with
no grill verdict.

The result is that every close in a busy repo needs `--force`. That trains the
operator to force by reflex, and a reflexive `--force` also silently bypasses the
findings that ARE about this run — an ungraded implement, a plan that never got a
grill verdict, a run dying mid-flow. The check stops being read.

Repo-wide auditing is still wanted; it just is not a close-time gate.

## Requirements

- **F1** `flow-status.sh <dir>` with no `--closing` is unchanged: repo-wide audit, exit 1 if anything is outstanding. `doctor.sh` and `runs-sweep.sh` keep today's behaviour exactly.

- **F2** `flow-status.sh <dir> --closing <rundir>` still REPORTS every finding, but only findings attributable to `<rundir>` affect the exit code. Non-attributable findings print with a marker showing they belong to the repo, not this close.

- **F3** Attribution is mechanical, never a guess: an ungraded implement or an orphan dispatch is attributable from the closing run's `- started:` onward, open-ended; this deliberately over-blocks because demoting a real closing-run finding is worse than over-blocking a close, and the proper fix is tracked as tasks-axi `cdl-dispatch-runid` (log the flow-run id, then attribute by exact match). A plan missing a grill verdict is attributable only when it is that run's own `- spec:`; a mid-flow death is attributable only for the closing run itself; other runs left open are never attributable.

- **F4** Working-tree changes that no dispatch produced (`unsourced.sh`) remain BLOCKING at close time regardless of attribution. That finding is about possible data loss, and the whole point of this session's work is that a lane can destroy uncommitted work — it must not become a NOTE.

- **F5** The non-attributable summary names counts and the command that addresses them (`/charlesdr-dev-loop:resolve`, `runs-sweep.sh`), so the backlog stays visible rather than silently dropped.

- **F6** Exit codes are otherwise unchanged: 0 clean, 1 outstanding. `run-state.sh close`'s existing exit 5 on a failed check is untouched.

- **F7** `scripts/selftest.sh` proves it against real run fixtures: a run whose own work is complete closes cleanly while stale open runs and a pre-dating orphan exist; a closing run with its OWN ungraded implement still refuses; a closing run whose OWN spec has no grill verdict still refuses; a closing run that died mid-flow still refuses; unsourced working-tree changes still refuse even when nothing else is attributable; and `flow-status.sh` with no `--closing` still reports every finding and exits 1.

- **F8** Version is 2.33.0 in `.claude-plugin/plugin.json` and both `version` fields of `.claude-plugin/marketplace.json`.

- **F9** `bash scripts/selftest.sh && bash scripts/doctor.sh` stays green: the 249 existing tests keep passing and doctor gains no new FAIL.

## Files in scope

- `scripts/flow-status.sh` — attribution and the exit-code split
- `scripts/selftest.sh` — the tests
- `skills/charles-flow/SKILL.md` — one line on what close actually gates on
- `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` — version

## Files out of scope — do not touch

- `scripts/run-state.sh`, `scripts/codex-run.sh`, `scripts/unsourced.sh`,
  `scripts/doctor.sh`, `scripts/runs-sweep.sh`, `hooks/`, `commands/`
- `docs/specs/` other than this file

## What must keep working

`bash scripts/selftest.sh && bash scripts/doctor.sh`

## Convention to copy

`flow-status.sh`'s existing `say_bad` / `say_ok` pair and its `--closing`
argument handling are the shape to follow: add a third reporter for
non-attributable findings rather than threading a flag through every check.

## Grill verdict

Grill skipped deliberately: the design is a scoping change to an existing check,
the attribution rules are stated mechanically above, and the one case that could
cause harm if scoped wrongly (unsourced working-tree changes) is explicitly held
blocking in F4. The isolated review lane still grades the diff.

## Sign-off

- [x] **F1** no `--closing` is unchanged — the attribution helpers short-circuit and the original repo-wide branches run; `doctor.sh` and `runs-sweep.sh` untouched
- [x] **F2** `--closing` still reports every finding; non-attributable ones print as `NOTE repo backlog (not this close): …` and do not count toward the exit
- [x] **F3** attribution is mechanical and open-ended by design — dispatch timestamp at or after the run's `- started:`, the run's own `- spec:`, the closing run itself for a mid-flow death, other open runs never. The bounded window tried in cycle 1 was reverted: it could demote a real closing-run finding when a later run started mid-implement. Proper fix tracked as tasks-axi cdl-dispatch-runid
- [x] **F4** unsourced working-tree changes still block on every path, including while attribution is degraded — 0 `say_repo` calls in that branch, confirmed by review
- [x] **F5** the summary names counts and the commands: `4 repo backlog finding(s) — use /charlesdr-dev-loop:resolve; audit with runs-sweep.sh`
- [x] **F6** exit codes unchanged: 0 clean, 1 outstanding; `run-state.sh` untouched
- [x] **F7** selftests cover stale backlog, the run's own ungraded implement, its own ungrilled spec, its own mid-flow death, unsourced changes, repo-wide reporting, and all three degraded paths (missing, malformed, and unreadable `RUN.md`)
- [x] **F8** version is 2.33.0 in plugin.json and both marketplace.json fields
- [x] **F9** green holds — `264 passed, 0 failed` (was 249); doctor `21 ok, 0 failing`

Hardening added across three review cycles, beyond the nine requirements:

- [x] Attribution fails CLOSED: a missing, unreadable, or malformed `- started:` line, or an absent/failing `realpath`, degrades attribution so every finding blocks, with a `WARN` naming the reason
- [x] Proven live on `infra-orchestrator`: the same close went from 7 blockers to 3 real ones plus 4 visible backlog notes, and a `RUN.md` without `- started:` blocks everything with the degraded warning
- [x] Reviewed specifically for the dangerous direction — every `say_repo` call site enumerated, no closing-run finding can reach one

Known and accepted: backlog NOTEs printed before degradation is discovered keep their NOTE label even though the run then blocks. The exit code is correct and no finding is demoted; tracked as tasks-axi cdl-degrade-eager.

# A clean tree has nothing for an orphan to own

## Why

`unsourced.sh` computes `changed` (working-tree paths outside the orchestrator's
own artifacts) near the top, but its clean-tree early return sits BELOW the orphan
block. Any unresolved implement `start` in `dispatches.jsonl` therefore exits 3
even when `git status --porcelain -uall` is completely empty.

`flow-status.sh` maps that exit to a blocking ISSUE — "an orphaned implement lane
may own working-tree changes" — which is the one finding `2026-08-25-close-scoping`
deliberately kept blocking at close time, because it is the data-loss signal.

The consequence undoes that work. In a repo carrying a historical orphan start,
the blocker can never be satisfied, so every close needs `--force` again. Measured
on this repo at 60a3a51: clean tree, `unsourced_rc=3`.

An orphan owns changes only if there are changes. With nothing on disk to
attribute, there is nothing to census and nothing to discard.

## Requirements

- **U1** When the working tree has no changes outside the ignored orchestrator
  artifacts, and no orphaned implement lane is IN FLIGHT, `unsourced.sh` exits 0.
  Orphan starts that are dead are reported on stderr for visibility, but they do
  not set a non-zero exit when there is nothing to own.

- **U2** An orphan lane that is IN FLIGHT still exits 3 even on a clean tree.
  A running lane may write at any moment, so a point-in-time clean census proves
  nothing about it. `lane-status.sh` already distinguishes the two cases; exit 0
  from it means in flight.

- **U3** Every existing non-zero outcome is unchanged when the tree is NOT clean:
  a dead orphan with changes still exits 3, an unreadable or unparseable dispatch
  log still exits 3, missing `jq` still exits 3, and the existing exits for
  changes a cut-short lane produced are untouched.

- **U4** A dispatch log that EXISTS but cannot be read or parsed still exits 3
  even on a clean tree: the census itself is impossible, which is not the same as
  having nothing to census. A log that is simply ABSENT is not a failed census —
  a repo that has never dispatched anything has nothing recorded, and on a clean
  tree it exits 0 as it always has. Conflating the two would make every fresh
  repo fail this check, which is worse than the defect being fixed.

- **U5** `scripts/selftest.sh` proves each case with real repos and real logs: a
  clean tree with a dead orphan exits 0; a clean tree with an in-flight orphan
  exits 3; a dirty tree with a dead orphan still exits 3; a clean tree with an
  unparseable log still exits 3; and `flow-status.sh --closing` on a clean repo
  carrying a dead orphan reports no blocking ISSUE from this check.

- **U6** Version is 2.33.1 in `.claude-plugin/plugin.json` and both `version`
  fields of `.claude-plugin/marketplace.json`. This is a defect fix, not new
  behaviour.

- **U7** `bash scripts/selftest.sh && bash scripts/doctor.sh` stays green: the 264
  existing tests keep passing and doctor gains no new FAIL.

## Files in scope

- `scripts/unsourced.sh` — the ordering fix and the in-flight distinction
- `scripts/selftest.sh` — the tests
- `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` — version

## Files out of scope — do not touch

- `scripts/flow-status.sh`, `scripts/run-state.sh`, `scripts/codex-run.sh`,
  `scripts/lane-status.sh`, `hooks/`, `commands/`, `skills/`
- `docs/specs/` other than this file

## What must keep working

`bash scripts/selftest.sh && bash scripts/doctor.sh`

## Convention to copy

The existing `[ "${changed:-0}" -eq 0 ] && { echo "clean tree — nothing to account
for"; exit 0; }` line is the behaviour to preserve; this change is about WHERE it
runs relative to the orphan block, plus the in-flight carve-out U2 requires.

## Grill verdict

Grill skipped deliberately: the defect, its cause, its measured symptom and the
one carve-out that must survive (U2, an in-flight lane) are all stated above, and
the change is a reordering plus one condition. The isolated review lane still
grades the diff.

## Sign-off

- [x] **U1** clean tree + dead orphan exits 0, orphan still reported on stderr — probed live on this repo: `unsourced rc=0`, was 3
- [x] **U2** an IN-FLIGHT orphan still exits 3 on a clean tree — selftest `clean tree with in-flight orphan exits 3`, which asserts the `lane in flight` message, not just the code; `lane-status.sh:116-122` detects liveness by process cmdline
- [x] **U3** every prior non-zero outcome survives on a dirty tree — selftest `dirty tree with dead orphan still exits 3`
- [x] **U4** an existing but unparseable log still exits 3; an ABSENT log is not a failed census and exits 0 on a clean tree — this requirement was wrong as first written and the first cycle implemented it faithfully, breaking every fresh repo; caught by direct probe, corrected here and in code
- [x] **U5** selftests use real repos, real logs and a real live process, and assert exit codes: `clean tree with dead orphan exits 0 and reports the orphan`, `clean tree with in-flight orphan exits 3`, `dirty tree with dead orphan still exits 3`, `fresh clean repo with no dispatch log exits 0`, `clean tree with unparseable dispatch log exits 3`, `changes made during orphan probing are recounted`
- [x] **U6** version is 2.33.1 in plugin.json and both marketplace.json fields
- [x] **U7** green holds — `271 passed, 0 failed` (was 264); doctor `21 ok, 0 failing`

Hardening beyond the seven requirements:

- [x] The change count is recounted AFTER the per-orphan liveness probes, closing a fail-open race where a lane writing during the probes would be missed by a stale count. Test proven non-vacuous: disabling the recount flips it to `FAIL … rc=0`
- [x] End-to-end proof that the defect this run targeted is gone: `flow-status.sh --closing` on this repo now reports `flow complete: nothing outstanding`, where before it blocked and forced `--force`

Filed, not fixed here: `cdl-lane-status-scope` — lane-status.sh exit 2 means both "dead" and "undeterminable", and its cache is keyed by run id globally rather than per repo.

## Run outcome — 2026-08-25

unsourced.sh no longer exits 3 on a clean tree, shipped as 2.33.1. A dead orphan with nothing on disk to own is reported and exits 0; an in-flight orphan still exits 3 because a running lane can write at any moment; a dirty tree with a dead orphan is unchanged; an existing but unparseable log still exits 3 while an absent log is not a failed census. The change count is recounted after the liveness probes, closing a fail-open race. This restores the F4 blocker that 2.33.0 deliberately kept blocking - before this fix any repo with a historical orphan start could never satisfy it, so every close needed --force, which is exactly what 2.33.0 set out to stop. Two cycles: cycle 1 implemented a requirement (U4) that was wrong as written and broke every fresh repository with no dispatch log, caught by direct probe rather than by tests and corrected in both the plan and the code; cycle 2 fixed a TOCTOU on the change count and reverted a fixture change. Selftest 264 -> 271. End-to-end proof: flow-status --closing on this repo now reports 'flow complete: nothing outstanding'. Built in a worktree at f6a944c, never the main tree, committed as 9bd0e1e. Rollback: git revert 9bd0e1e

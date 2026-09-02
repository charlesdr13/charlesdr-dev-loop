# Flow selector, dispatch supervision, and the release/ops flows

Polish run. Three explore lanes (luna @ max, read-only) established the evidence;
one adversary lane attacked the first draft. Every `file:line` below was
re-verified against source after that attack, which corrected three of them.

**Scope note, recorded deliberately:** this plan carries 12 requirements. The
skill's own guidance (`skills/charles-flow/SKILL.md:269-278`) says 11+ usually
means two features that have not been separated. The operator was shown that and
chose the full bundle. It is one plan because the twelve requirements share one
subject — the gap between what the flow *says* and what it *enforces* — and it
ships as five serially-dispatched slices, defined below.

**Parallelism is refused, not unavailable.** Slice S3 edits
`scripts/codex-run.sh` and S4 edits `scripts/parallel-chunks.sh`. The skill
mandates serial execution for any batch touching the dispatcher
(`SKILL.md:317-326`): children execute the dispatcher from the runner's script
directory, and Bash reads a script lazily by byte offset, so rewriting it mid-run
kills it at a stale offset. No `.chunks.json` accompanies this plan.

## Background — and where the numbers come from

Measured during this run, not checked in. Reproduce with:

```bash
for f in ~/MACH4_2/*/.charles/dispatches.jsonl; do jq -c '{ts,lane,engine,rc,event}' "$f"; done
```

- 47 opted-in repos, 2094 dispatch records.
- 40 orphan dispatches (start with no end) between 2026-08-15 and 2026-09-02,
  still accruing daily.
- 73 genuine `rc=124` timeouts, 66 of them before 2026-08-22 — largely addressed
  by the timeout-aware fallback in 2.34.0.
- Orphan lifetimes cluster at ~540-645s, ~123s and ~34-94s.
- Sibling lanes die in the same second (`20260826-194619/194632/194638`;
  `20260901-162012-203842/-203851`), so each cluster is one kill event per fleet,
  not per-lane failure.

The repo's own published baseline (`README.md:222-238`, restated at
`scripts/codex-run.sh:141-145`) is a different, older population — 179 runs,
233 successful implements, 25 of 258 ends timing out. Both are true; they count
different things. This plan does not replace the published baseline.

**Harness facts used below are properties of Claude Code, not of this repo**, and
are cited as such: the Bash tool caps one foreground call at 600s and defaults to
120s when no timeout is passed. `README.md:240-249` and
`agents/codex-reviewer.md:77-86` establish the 600s cap; nothing in the repo
states the 120s default, which is why R2 requires it to be written down.

## Requirements

- **R1** — the skill selects a flow

  `skills/charles-flow/SKILL.md:3` names three work-kinds and maps none of them to
  a flow, and does not mention UI work at all. The Flow headings at `:392`, `:436`,
  `:465`, `:488` are section labels, not a selector. `README.md:319-329` already
  holds a work-kind → command table, so this is a hoist, not an invention.

  UI keeps its established meaning: `SKILL.md:488-491` calls it *a router, not a
  flow*, and R1 must not silently promote it. The selector routes UI work to
  `/charlesdr-dev-loop:ui` and says it is a router.

  Done when: `SKILL.md` contains one work-kind → destination table covering every
  flow plus the two added by R11 and R12; the frontmatter description names the
  selection axis and includes UI; and a reader given only the skill routes "the
  login button is misaligned" and "cut a release" correctly without guessing.

- **R2** — the background rule has one shape, and it is the correct one

  `agents/codex-reviewer.md:102-105` backgrounds with `nohup … &` then sleeps in
  the same Bash call; `skills/charles-flow/SKILL.md:251-254` uses shell `&`.
  Neither is the Bash tool's `run_in_background`, and both are the shape the
  harness SIGKILLs at its cap. `commands/debug.md:31-32` and
  `commands/polish.md:31-32` give a serial implement command without saying
  background at all.

  **Scope: instructional text only.** Executable mechanics legitimately use `&`
  (`scripts/codex-run.sh:590`, `:615`, `scripts/parallel-chunks.sh:330`) and must
  not be touched. A grep-based check that does not exclude executable code would
  be wrong.

  Done when: no *instructional* passage tells a reader to background a lane with
  `&` or `nohup`; every explore/implement example states `run_in_background: true`;
  the foreground review exception at `agents/codex-reviewer.md:25-29` states the
  required outer Bash timeout, the 600s ceiling, and the 120s default that makes an
  unset timeout silently fatal; and `selftest.sh` asserts this over documentation
  paths only.

- **R3** — a killed dispatch always leaves a terminal record

  **Amended 2026-09-02 mid-run, after measurement.** The original R3 named the
  `parallel-chunks.sh` cleanup race as the cause. That race is real but rare.
  The dominant cause is one layer down and needs no worktrees or chunks at all:

  `scripts/codex-run.sh:481-489` traps TERM/HUP to `terminate_dispatch`, which
  kills the child group and calls `exit`. The EXIT trap then writes `.done`.
  **Neither path ever calls `log_dispatch`**, so a SIGTERMed wrapper records a
  `.done` file and *no terminal record at all*. The watchdog is supposed to
  cover this (`:101-119`), but when the harness stops a task it takes the
  setsid'd watchdog with it, so nothing survives to write the record.

  Reproduced three times in this run's own session — dispatches
  `20260902-165706-3830875`, `20260902-171815-4036860` and
  `20260902-173656-89546`. All three have `.done=143`, exactly one line in
  `dispatches.jsonl` (the start), and no `wrapper_death:true` record. Two were
  plain serial dispatches with no worktree involved. This is why 40 orphans
  accumulated across 47 repos and why none of them can ever be cleared.

  The fix belongs in the process guaranteed to still be alive: the wrapper's own
  TERM handler, before it exits. The parallel-chunks race below remains the
  second half of the requirement.

  `scripts/parallel-chunks.sh:246-249` kills its direct child PIDs, `:250-252`
  waits only for those, `:259-262` aggregates each worktree receipt into the
  parent, and `:281` returns (destroys) the worktree. The child's watchdog needs
  `sleep 2` plus a state read plus a kill loop (`scripts/codex-run.sh:92-119`)
  before it appends the END record. So aggregation copies the START, the worktree
  is destroyed, and the END dies with it. `scripts/flow-status.sh:173-177` then
  sees a start with no matching end — note it counts a record *lacking* an `event`
  key as an end too, so "requires an END record" means "requires a terminal
  record", legacy shapes included.

  Evidence: dev2phone chunks `20260901-162012-203842` and `-203851` both wrote
  `.done=143` at 16:21:46 inside worktrees `/5/dev2phone` and `/6/dev2phone`; the
  parent log holds their starts only; both worktrees are gone.

  **The guarantee must be honest.** If the wrapper *and* its watchdog are both
  SIGKILLed, no END can ever be written, so "every START has an END" is
  unachievable. And if `parallel-chunks.sh` itself is SIGKILLed its `EXIT` trap
  (`:290`) never runs, so no cleanup happens at all.

  Done when, first half: `terminate_dispatch` writes the terminal record before
  exiting, on every signal path it traps, and does so idempotently — the
  watchdog must not append a second record when it also survives. A dispatch
  SIGTERMed at any point leaves exactly one terminal record. `selftest.sh` sends
  a real SIGTERM to a live wrapper and asserts exactly one terminal record with
  a non-zero rc results.

  Done when, second half: cleanup waits a **bounded** interval (stated in the code, at least the
  watchdog's own `sleep 2` plus margin) for each child's terminal record before
  aggregating; on expiry it **retains the worktree** rather than destroying it,
  marks the chunk failed, and says which worktree holds the unaggregated receipt;
  no worktree is returned before its receipt has been aggregated; and
  `scripts/selftest.sh` covers both the wait-then-aggregate path and the
  expiry-then-retain path. The unreachable case (both processes SIGKILLed) is named
  as an accepted risk, not claimed as fixed.

- **R4** — RUNNING is distinguishable from ORPHANED

  `scripts/flow-status.sh:173-177` computes orphan status as "start with no
  terminal record". A running lane satisfies that. Observed live: `doctor.sh`
  reported this run's own three in-flight explore lanes as `WARN orphan dispatch`.
  Every orphan count in this repo is inflated by whatever is running.

  **Liveness must not come from `pgrep -f`.** `scripts/lane-status.sh:109-118`
  matches the run id against command lines, which is unreliable in both directions:
  the watchdog receives its run id through the environment specifically so it does
  *not* appear in its command line (`scripts/codex-run.sh:578-588`, asserted by
  `scripts/selftest.sh:2594-2605`), and an unrelated process mentioning the id
  matches falsely. The run's own artifacts are authoritative: `.watchdog.state`
  holds `active|engine|model|fallback_from|primary_rc|pid_file`
  (`scripts/codex-run.sh:571-574`) and the named `.child.N` file holds the setsid
  group leader written before `exec` (`:612-615`).

  Done when: a start with no terminal record whose recorded child PID is alive is
  reported as RUNNING, not as an orphan; liveness is decided from
  `.watchdog.state` plus the recorded PID rather than a command-line scan; a state
  that cannot be determined is reported as UNKNOWN and never silently as DEAD; the
  RUNNING line still contains `ISSUE` or is otherwise visible to `doctor.sh`, which
  parses only lines matching `*ISSUE*` (`scripts/doctor.sh:127`); and `selftest.sh`
  asserts a live dispatch is not counted as an orphan.

- **R5** — no implement lane runs against an ungrilled plan

  Enforcement today is reporting, not refusal. `scripts/flow-status.sh:250-284`
  scans for missing grill verdicts and is invoked by `run-state.sh:457-465`
  (close), `commands/status.md:5-8` and `scripts/doctor.sh:119-140` — so drift is
  *visible* in three places and *blocked* in none. The insertion point for refusal
  is exact: after plan resolution at `scripts/codex-run.sh:384-393` and before the
  requirement loop at `:394-402`, inside `validate_dispatch_scope()` (`:290`),
  which both the serial path (`:920`) and the parallel path
  (`scripts/parallel-chunks.sh:213-229`) already call.

  **Operator decision: the gate applies to every flow, with a written waiver.**
  The waiver is load-bearing, not a softener: five of ten specs in `docs/specs/`
  explicitly skipped the grill (`2026-08-13-direct-background-dispatch.md:57-65`,
  `2026-08-20-signoff-gate.md:67-71`, `2026-08-24-main-tree-guard.md:71-75`,
  `2026-08-25-close-scoping.md:63-68`,
  `2026-08-25-unsourced-clean-tree.md:80-85`), and Flow 2 and UI have no grill step
  at all (`SKILL.md:436-463`, `:488-506`). A gate with no waiver would block them.

  **A heading is not a verdict.** Every waived spec above still contains a literal
  `## Grill verdict` heading, and this very plan contained `## Grill verdict` with
  `_(pending)_` while ungrilled. A `grep 'Grill verdict'` gate would have passed
  all of them, which is exactly the failure mode being fixed.

  Done when: the gate accepts a spec only if its `## Grill verdict` section
  contains a `- Rounds:` line (the shape `skills/grill-rounds/SKILL.md` already
  mandates) **or** an explicit `Grill waived: <reason>` line with a non-empty
  reason; an ungrilled spec is refused with a distinct non-zero exit naming the
  spec and the missing marker; the dispatch record gains a field recording which of
  the two applied; `commands/debug.md` and `commands/ui.md` document the waiver
  line as their normal path; and `selftest.sh` covers refuse, verdict-accept,
  waiver-accept, the `_(pending)_` case, and the parallel path.

- **R6** — review coverage is correlated per run, not globally

  `scripts/flow-status.sh:161-168` reduces to the latest end per dispatch and
  `:208-222` compares implements against the latest successful review across the
  whole log, so a review in one run marks earlier implements from a different run
  as reviewed. Reported unreviewed-implement counts are understated.

  **The data to do this correctly does not exist yet.** The dispatch record
  (`scripts/codex-run.sh:536-567`) carries lane, engine, run *dispatch* id, dir,
  task, req and main-tree permission — but no flow-run id and no spec path. `.run`
  is the dispatch id generated at `:217-222`, not the `RUN.md` directory. This is
  backlog item `cdl-dispatch-runid`. R6 therefore includes adding that identity,
  which `validate_dispatch_scope()` already resolves and can log.

  Engine fallback writes more than one END for a single dispatch
  (`scripts/codex-run.sh:979-997`); correlation must use the last terminal record
  for a dispatch id, consistent with the existing reducer at `:161-168`.

  Done when: `log_start`/`log_dispatch` record the open flow-run id and resolved
  spec path when a run is open; `flow-status.sh` counts an implement as reviewed
  only via a later review attributable to the same flow run or spec; records
  predating the new field degrade to today's behaviour rather than erroring; and
  `selftest.sh` asserts a review in run B does not clear an unreviewed implement in
  run A.

- **R7** — release is a step the flow can reach

  `scripts/release.sh` already refuses on a dirty `.claude-plugin/` (`:15-20`) and
  on a red green check (`:22-25`), then installs, verifies the cache, relinks
  `codex-run` and runs doctor (`:64-107`). It takes exactly one semver argument and
  exits 2 otherwise (`:5-10`). Nothing in `scripts/flow.json:2-49`, the four flows
  or `README.md:319-329` exposes it, so releasing is an undocumented manual act.

  Done when: `/charlesdr-dev-loop:release <semver>` exists, passes the version
  through to `release.sh` without reimplementing any of its checks, records its
  output as a phase on the open run, and on failure records a `FAILED` item rather
  than closing; and the command documents that `release.sh` computes the plugin
  root from its own location (`:12-13`), so it always releases *this* plugin
  regardless of the caller's cwd.

- **R8** — a run can be reopened and abandoned

  `backlog.md` records that there is no reopen verb, so recovering a mistakenly
  closed run means hand-stripping state. `scripts/run-state.sh:356-363` shows
  `rollback` only *records* a command; it performs nothing.

  **Operator decision: abandoned is a distinct terminal state.** It writes
  `## Outcome` so the run leaves the open count, plus an explicit abandoned marker
  so reporting can tell it from a finished run. That means every closure consumer
  must learn the distinction: `run-state.sh:75-99` and `:506-509`,
  `flow-status.sh:300-337`, `runs-sweep.sh:124-142`,
  `hooks/link-dispatcher.sh:39-52`, `hooks/warn-open-runs.sh:20-31`. This
  deliberately supersedes `README.md:361-364` ("abandoned, not finished — leave it
  open"), which must be updated in the same change rather than left contradicting
  the code.

  Argument shape follows the existing convention `<command> <dir> [--run <id>]`
  (`scripts/run-state.sh:10`, `:28-32`); a bare id would be parsed as a directory.

  Done when: `run-state.sh reopen "$(pwd)" --run <id>` returns a closed run to open
  state and states what happened to the outcome text it removed;
  `run-state.sh abandon "$(pwd)" [--run <id>] "<reason>"` writes a distinct
  abandoned outcome with a reason; both refuse on an unknown id or an already-
  correct state; all six closure consumers report abandoned distinctly from
  finished; `README.md:361-364` is corrected; and `selftest.sh` covers both verbs,
  their refusals, and the reporting distinction.

- **R9** — commands/ui.md agrees with the skill

  `commands/ui.md:23-24` opens the run before baseline green, inverting
  `SKILL.md:493` and `scripts/flow.json:41-42`, and opens it with no `--spec`,
  which `SKILL.md:343-347,360-365` requires and without which every later implement
  dispatch cannot validate requirements. `commands/ui.md:93-108` goes from
  verification to close with no sign-off, which `run-state.sh:432-447` then
  refuses. `commands/ui.md:67-75` omits the `FAILED` item that `SKILL.md:380-383`
  requires on receipt exit 1.

  **The ordering problem is already solved in the code.** `run-state.sh:265-298`
  provides a `spec` verb that binds a spec to the newest open run after the fact.
  UI can therefore keep its real sequence: baseline green → `init` → audit → write
  plan → `run-state.sh spec` → implement. No new mechanism is needed.

  Done when: all four disagreements resolve in favour of the skill using the
  existing `spec` verb; `commands/status.md:11-15` also mentions unsourced
  working-tree changes per `SKILL.md:180-185`; and UI's status as a router rather
  than a flow is preserved.

- **R10** — the dispatcher symlink never points at a checkout

  `hooks/link-dispatcher.sh:13-26` links `codex-run` to
  `$CLAUDE_PLUGIN_ROOT/scripts/codex-run.sh`. Observed on this machine: that
  resolved to the working checkout, and `doctor.sh` failed with `codex-run points
  at …/charlesdr-dev-loop/scripts/codex-run.sh, not v2.34.0`. The hook's own header
  states the opposite intent — an agent once executed a half-written working-tree
  file and died on a syntax error. Tracked as `cdl-1787324684-30198`.

  Done when: the hook refuses to link to a path inside a git working tree, falls
  back to the installed cache copy, and says so on stderr; if no installed copy
  exists it leaves any existing link alone rather than pointing at a checkout;
  `doctor.sh` stays OK across a session restart in this repo; and `selftest.sh`
  asserts the refusal and the fallback.

- **R11** — Flow 5, release

  A flow for work whose deliverable is a published version rather than a diff.

  `flow.json` is data-driven for *consumption* — `run-state.sh:38-68`, `:301-317`,
  `flow-status.sh:114-137`, `:300-331` and `runs-sweep.sh:39-50`, `:104-114` all
  look flows up dynamically. It is **not** data-driven for *validation*:
  `flow-status.sh:100` and `runs-sweep.sh:25` both hard-code
  `["feature","debug","polish","ui"]` in their structural check. Those two literals
  must gain the new flows or the graph check silently stops covering them.

  Done when: `scripts/flow.json` carries a `release` entry with named phases,
  `first` and `terminal`, each phase with `next` and `proof`; both hard-coded
  validator lists include it; `SKILL.md` documents it and the R1 selector routes to
  it; `commands/release.md` (R7) drives it; a release run opens, phases and closes
  through the normal `run-state.sh` path; and `selftest.sh` fixtures around
  `:2092-2194` are extended rather than left asserting a four-flow world.

- **R12** — Flow 6, ops

  A flow for work with no code deliverable: cross-repo run triage and run recovery.
  `scripts/runs-sweep.sh:1-7` is read-only by design and `commands/resolve.md:5-17`
  is single-repo, so multi-repo remediation has nowhere to live.

  Two scoping facts constrain it. `runs-sweep.sh:4-19` sweeps supplied or default
  roots, not the whole filesystem — the command must say which roots it covers.
  And `run-common.sh:6-18` normalises worktree paths to the git common root while
  `flow-status.sh:16-28` uses the supplied directory as given, so an ops run must
  record which root it acted on.

  Done when: `flow.json` carries an `ops` entry and both hard-coded validator lists
  include it; `SKILL.md` documents it and the R1 selector routes to it;
  `commands/ops.md` composes `runs-sweep.sh` with the R8 verbs; it never closes,
  abandons or deletes another repo's run without explicit human confirmation,
  preserving the sweep's read-only default; the ops run itself is opened in the
  repo the command was invoked from and records the roots it swept; and
  `selftest.sh` asserts the read-only default and the confirmation requirement.

## Serial slices

Dispatched in order, each with `green.sh` and a `run-state.sh phase` between.
Each slice declares its files; a lane may touch no other path.

| Slice | Requirements | Files |
|---|---|---|
| S1 | R1, R2, R9 | `skills/charles-flow/SKILL.md`, `README.md`, `agents/codex-reviewer.md`, `commands/{debug,polish,ui,status}.md` |
| S2 | R4 | `scripts/flow-status.sh`, `scripts/doctor.sh`, `scripts/lane-status.sh` |
| S3 | R5, R6 | `scripts/codex-run.sh`, `scripts/flow-status.sh` |
| S4 | R3 | `scripts/parallel-chunks.sh` |
| S5 | R7, R8, R10, R11, R12 | `scripts/{run-state.sh,flow.json,runs-sweep.sh,release.sh}`, `hooks/{link-dispatcher.sh,warn-open-runs.sh}`, `commands/{release,ops}.md`, `README.md` |

`scripts/selftest.sh` is written by every slice; serial execution is what makes
that safe. S2 and S3 both touch `flow-status.sh` and must not be reordered.

## Out of scope

- Recovering completed work from already-orphaned lanes.
  `scripts/verify-receipt.sh:101-130` treats a start with no END as an orphan and
  never promotes `.jsonl`/`.last`; building an adoption path is a separate plan.
- Back-filling grill verdicts for the ~350 existing ungrilled plans. R5 stops new
  drift only.
- Any change to the four existing flows' phase sequences.
- `scripts/unsourced.sh` and `scripts/verify-receipt.sh` orphan terminology,
  which R12 touches conceptually but does not edit.

## Files in scope

As listed in the slice table, plus `.claude-plugin/plugin.json` and both
`version` fields in `.claude-plugin/marketplace.json`. Out of scope for edits:
every other file in the repo.

## Green

`bash scripts/selftest.sh && bash scripts/doctor.sh`

Baseline at plan time: `selftest 293 passed, 0 failed`; `doctor 22 ok, 0 failing`.
Any behaviour change bumps the version in `.claude-plugin/plugin.json` and both
`version` fields in `.claude-plugin/marketplace.json` to the same value.

## Grill verdict — 2026-09-02

- Rounds: 2
- Attacks raised: 16 — resolved from source: 13, changed the plan: 11, escalated: 2
- Plan changes:
  - Corrected `parallel-chunks.sh:277` → `:281` (`:277` is `fi`; return is `:281`).
  - Corrected "requires an END record": `flow-status.sh:175` also treats records
    with no `event` key as ends.
  - Withdrew "drift is detected only at close" — `commands/status.md:5-8` and
    `scripts/doctor.sh:119-140` run the same scan outside close.
  - Withdrew "the skill omits UI entirely"; `SKILL.md:488-491` documents UI as a
    router, and R1 now preserves that status instead of promoting it.
  - R2 scoped to instructional text; executable `&` at `codex-run.sh:590`, `:615`
    and `parallel-chunks.sh:330` is explicitly excluded.
  - R2 now states the 120s Bash default as a harness fact, not a repo citation.
  - R3 gained a bounded wait with a defined expiry behaviour (retain the
    worktree, fail the chunk) instead of an unbounded and unachievable guarantee.
  - R4 replaced `pgrep -f` liveness with `.watchdog.state` plus the recorded child
    PID, added an UNKNOWN state, and requires the RUNNING line to stay visible to
    `doctor.sh:127`, which parses only `*ISSUE*` lines.
  - R5 gained a real acceptance predicate — a `- Rounds:` line or an explicit
    `Grill waived: <reason>` — because every waived spec, and this plan while
    ungrilled, contains a bare `## Grill verdict` heading that a grep gate passes.
  - R6 absorbed backlog item `cdl-dispatch-runid`: correlation is impossible until
    the dispatch record carries a flow-run id and spec path.
  - R8 now enumerates all six `^## Outcome` consumers and supersedes
    `README.md:361-364` explicitly rather than contradicting it silently.
  - R9 adopted the existing `run-state.sh:265-298` `spec` verb instead of
    inventing an ordering fix.
  - R11/R12 name the hard-coded `["feature","debug","polish","ui"]` literals at
    `flow-status.sh:100` and `runs-sweep.sh:25` that make `flow.json` data-driven
    for consumption but not for validation.
  - Added the serial slice table the adversary correctly said was missing.
  - Added measurement provenance and a reproduction command.
- Escalated to the operator and answered: R5 gate scope → every flow with a
  written waiver. R8 abandon semantics → distinct terminal state.
- **Mid-run amendment, 2026-09-02, operator-approved:** R3 was rewritten after
  three of this run's own dispatches were SIGTERMed and reproduced the defect
  live. The original R3 blamed the `parallel-chunks.sh` cleanup race; the
  dominant cause is `terminate_dispatch` exiting without a terminal record,
  which needs no worktrees and explains the serial cases too. The chunks race is
  retained as the second half. Recorded here rather than silently edited,
  because a requirement that changes after sign-off is exactly the thing a
  reviewer must be able to see.
- Accepted risks:
  - **R3 cannot guarantee every START gets an END.** If the wrapper and its
    watchdog are both SIGKILLed, no process survives to write one. If
    `parallel-chunks.sh` itself is SIGKILLed its EXIT trap never runs and no
    cleanup happens at all. R3 narrows the window and stops destroying evidence;
    it does not close the hole. Accepted because the residual case is
    unobservable from inside the process being killed.
  - **R4 can still be wrong under PID reuse.** A recorded child PID may be
    reassigned to an unrelated process, reporting a dead lane as RUNNING.
    Accepted: the failure is a stale warning, not lost work, and the alternative
    (`pgrep -f`) is wrong more often and in both directions.
  - **R5's waiver is honour-system.** Nothing stops a lane writing
    `Grill waived: because` and proceeding. Accepted: the gate exists to stop
    accidental drift, not a determined bypass, and the waiver is recorded in the
    dispatch record where a reviewer can see it.
  - **The 12-requirement span still risks the 60%-attention effect**
    (`SKILL.md:264-267`). Mitigated by five slices with green between them, not
    eliminated. If S1 or S5 comes back thin, the correct response is to split it,
    not to accept the diff.
  - **~350 historical ungrilled plans stay ungrilled**, and historical orphans
    stay visible until R4 reclassifies the live ones. Accepted as out of scope.
- Unresolved: none blocking. Settling the residual R3 case would need a
  supervisor outside the killed process group (a systemd unit or a cgroup
  watcher), which is a larger change than this plan.

## Sign-off

_(pending)_

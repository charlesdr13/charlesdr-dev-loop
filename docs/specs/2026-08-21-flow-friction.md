# Cutting flow friction

## Why

Measured on the 2026-08-21 session: 411 minutes of wall clock, 205 minutes of
lane time across 21 dispatches. Only 6 of those 21 served the task that opened
the session. The other 15 were scope growth, rework, or operator error.

Cause, by cost:

1. Scope tripled mid-flight (~90 min). Everything the flow discovered got
   dispatched immediately instead of recorded. Nothing made that visible until
   the session was over.
2. Version-drift ceremony (~20 min). `doctor` FAILs when the tree differs from
   the installed build, so a session with eight bumps reinstalled eight times.
   The guard is right at close time and pure friction mid-flow.
3. Review effort was flat-max (~40 min). Five reviews at max effort, one of them
   47 minutes; only the final pass needed that depth.
4. Committing before review (~30 min). An implement was committed, the review
   lane then saw an empty diff, and recovering cost a feature build.
5. Parallel chunks stayed documented rather than used (~25 min per multi-chunk
   run). Two disjoint chunks ran back to back for no reason.

## Out of scope

- Any session-metrics dashboard. Lane time is one `jq` away from
  `.charles/dispatches.jsonl` when someone asks; a dashboard for it gets read
  twice.
- Retroactively closing the orphan review dispatch from that session. Receipts
  are never forged, and an accurate record of a dead lane is worth more than a
  tidy status line.
- Changing what `--req` means for explore or review lanes. Only implement
  dispatches carry requirement identity.

## Files in scope

Chunk A (runtime): `scripts/codex-run.sh`, `scripts/run-state.sh`,
`scripts/doctor.sh`, `scripts/flow-status.sh`, `scripts/selftest.sh`,
`scripts/parallel-chunks.sh` (R10 only)

Chunk B (contract): `skills/charles-flow/SKILL.md`, `commands/feature.md`,
`commands/polish.md`, `commands/debug.md`, `README.md`

Version files are bumped by the orchestrator during the flow when an install requires it, including mid-flow; close does not defer every bump.

Must not touch: `hooks/`, `agents/codex-reviewer.md` beyond the one `--base`
sentence R6 requires.

## Green

`bash scripts/selftest.sh && bash scripts/doctor.sh`

## Conventions

Match the surrounding style: comment why a guard exists, not what the line does.
New selftest cases follow the existing `check`-helper shape and the
`echo "  PASS  <name>"; pass=$((pass+1))` idiom the runner counts.

## Requirements

- [ ] **R1. An implement dispatch names the requirements it serves.**
  `codex-run --lane implement` accepts `--req A3,A5`. When a run is open in the
  target repo, a dispatch with no `--req` is refused (exit 2) with a message
  naming the open run's spec. The identifiers are recorded on the dispatch event
  so the mapping survives the session.
- [ ] **R2. A `--req` that the spec does not contain is refused.** The
  identifiers are checked against the open run's `--spec` plan file. A typo, or a
  requirement invented mid-flight, fails before a lane is spent. This is the
  mechanism that makes scope growth an exit code rather than a judgment call.
  Requirement IDs use `[A-Z]+[0-9]+(\.[0-9]+)?[a-z]?`; body bullets may use
  either `- [ ] **R1. ...**`/`- [x] **R1. ...**` or `- **A1** ...`. The
  `## Sign-off` section is evidence, not a requirement source.
- [ ] **R3. Deferring is one command.** `run-state.sh defer <dir> "<text>"` is a
  shorthand for the existing `item ... DEFERRED` path, and `close` reports the
  count: "N requirements shipped, M items deferred". The friction of recording a
  discovery must be lower than the friction of dispatching it.
- [ ] **R4. Version drift is a WARN while a run is open — but only the file-content
  check.** `doctor.sh` has two distinct checks and they must not be conflated. The
  CONTENT check ("N files differ from installed vX") downgrades to WARN while a run
  is open, so a session reinstalls once rather than once per iteration. The
  DISPATCHER TARGET check ("codex-run points at <path>, not vX") stays FAIL
  always, in every state.
  This was learned the hard way during this plan's own chunk A: the dispatcher was
  symlinked to the working tree, the lane rewrote `scripts/codex-run.sh` while bash
  was executing that exact file, and because bash reads a script lazily by byte
  offset the running shell resumed at a stale offset and died with
  `syntax error near unexpected token )` at line 458. The receipt was written and
  the work was sound; the wrapper crashed on itself afterwards. Downgrading that
  check would remove the only guard against a dispatcher editing itself mid-run.
- [ ] **R5. Review effort is tiered by position, without a new flag.**
  Intermediate reviews are dispatched with `--effort medium`; the final
  pre-close review uses the model-aware default. This is a documented rule in
  `SKILL.md`, not code: the grill pointed out that `--final` would change the
  meaning of the existing default and has no caller that knows its own position
  (`agents/codex-reviewer.md:23-36` passes only `--base` and `--timeout`). The
  simpler mechanism already exists.
- [ ] **R6. Committing ungraded work fails loudly, and stays reviewable.**
  `doctor.sh` already counts implements with no later review; while a run is open
  that count becomes a FAIL, so `green` goes red until the diff is graded. Detection
  alone is not enough: `SKILL.md` and `agents/codex-reviewer.md` must also state
  that a review after `HEAD` moved requires `--base <ref>`, or the reviewer sees an
  empty diff — the exact failure that cost a feature build this session.
- [ ] **R7. The flow dispatches chunks in parallel when a manifest exists.**
  Flow 1 step 6, and the equivalent step in the polish and debug flows, read
  `docs/specs/<plan>.chunks.json` and invoke `parallel-chunks.sh` when it holds
  `parallel_min_chunks` or more entries; serial dispatch is the documented
  fallback for one chunk, overlapping declarations, an invalid manifest, or a
  missing `treehouse`.
- [ ] **R9. Multiple open runs require an explicit selector.** An implement
  dispatch with more than one open run selects one with `--run <run-id>` or
  `CHARLES_RUN`; the flag wins, and either accepts an exact full id or a unique
  substring. An ambiguous substring names its candidates, while an unknown or
  closed selector names what was asked for and exits 2. An exact id wins even
  when it is also a substring of another id. `--req` is then validated against
  the selected run's `--spec`; with no selector, multiple open runs still exit 2
  listing every id and the selector hint. One open run and no open runs retain
  their existing behavior. This avoids `newest_open` selecting the wrong plan
  (`cdl-1786688980-3638`) without making stale abandoned runs block every
  implement dispatch.
- [ ] **R10. Parallel children carry requirement identity too.** A chunk child is
  dispatched with `--dir <worktree>`, where no run state exists, so R1's gate
  would silently pass and every parallel dispatch would bypass scope control. The
  manifest gains an optional `req` array per chunk, validated against the plan
  like `--req` is, and `parallel-chunks.sh` passes it to each child. The gate then
  holds on both paths.
- [ ] **R8. The contract documents scope discipline.** `SKILL.md` states that a
  discovery made mid-flow is deferred rather than dispatched, and that `--req`
  enforces it. The three flow commands reference `--req` in their implement
  steps.

- [ ] **R11. Run selection and spec selection cannot disagree silently.** Every
  `run-state.sh` verb that mutates a run — `phase`, `item`, `close`, `rollback`,
  and `spec` — takes the same selector semantics as the dispatch gate: an exact
  id wins, a unique substring selects, and an ambiguous or unknown substring
  refuses. `run-state.sh spec <dir> <path> [--run <id>]` attaches a readable plan
  to an already-open run, replacing any existing `- spec:` field and refusing a
  missing path or multiple open runs without a selector. `close` additionally
  requires that its `--spec` path match the spec recorded on the SELECTED run,
  refusing and naming both when they disagree.
  Found in production, after the grill and two reviews had passed the design:
  with two runs open, `close --spec <a third run's plan>` closed the newest run
  while the outcome paragraph went to an unrelated spec. Two independent pieces of
  state pointed at different runs and nothing checked they agreed. The selector
  alone would not have caught it — the cross-check is the part that would.
  This also retires `cdl-1786688980-3638`, deferred as theoretical until two
  verify-phase records were written into the wrong run.

## Sequencing

Chunk A owns every script; chunk B owns every document. They share no file.

**They run SERIALLY anyway, and the reason is the point.** R10 requires chunk A to
modify `parallel-chunks.sh`, which would be the runner executing the batch. Worse,
the grill established that children execute the dispatcher from the runner's own
script directory while the post-merge green check runs the merged root scripts —
so a batch that modifies the dispatcher is split-brain by construction: the
children ran the old one, the verification runs the new one.

Dogfooding the parallel runner is therefore deferred to the first plan whose
chunks do not touch the flow's own machinery. That is a real limitation of the
parallel path and belongs in the record rather than being discovered later by
someone whose batch silently used a stale dispatcher.

## Grill verdict — 2026-08-21

- Rounds: 1 (adversary at high effort; nothing survived that needed a human)
- Attacks raised: 17 — resolved from source: 13, changed the plan: 4, escalated: 0
- Plan changes:
  - R1 and R7 were incompatible. A chunk child runs with `--dir <worktree>`, where
    no run state exists, so R1's gate would have passed silently on every parallel
    dispatch — scope control would have held on the serial path and quietly not on
    the parallel one. R10 added: requirement identity travels in the manifest.
  - R5 dropped its `--final` flag. It would have changed the meaning of the
    existing model-aware default, and no caller knows its own position anyway
    (`agents/codex-reviewer.md:23-36` passes only `--base` and `--timeout`).
    Dispatching intermediate reviews with `--effort medium` achieves the same
    thing with no code.
  - R6 gained the `--base` requirement. Detecting a pre-review commit does not
    make the review possible; without `--base` the reviewer still sees an empty
    diff.
  - R9 added: `newest_open` picks the wrong run when two are open
    (`cdl-1786688980-3638`), so `--req` fails closed rather than validating
    against the wrong plan.
  - R9 gained `--run <run-id>` and `CHARLES_RUN` because fail-closed on multiple open runs made every repo with a stale run undispatchable; found by a repo with several stale runs being unable to dispatch at all.
  - The `codex-run.sh` and `run-state.sh` selector implementations drifted because they were built in separate dispatches; a single canonical git-common-dir resolution is now shared by both.
  - A live selector run against a repo with three open runs found both gaps — no spec-binding verb for legacy runs and leading-prefix-only matching — rather than by review.
  - The requirement matcher was written around one repo's house style and rejected other valid conventions (`- **A1** text`, dotted and suffixed ids); it now accepts both shapes, and excludes `## Sign-off` as a requirement source.
  - The run-root resolver and requirement grammar were duplicated across scripts, which allowed them to drift, and are now shared.
  - Sequencing changed from parallel to serial, and the reason recorded: R10
    modifies the runner that would execute the batch, and children execute the
    dispatcher from the runner's script directory while the green check runs the
    merged root scripts.
- Accepted risks:
  - **The parallel path stays unexercised against a real repo for another round.**
    Deferring it is the right call for a batch that edits the runner, but it means
    177 tests and zero production runs remains true.
  - **`--req` validation parses requirement ids out of Markdown.** A plan that
    renames a requirement mid-flow will refuse a dispatch that was correct
    yesterday. Failing closed is deliberate; the cost is occasional friction after
    a plan edit.
  - **R4 and R6 make `green` mean something different mid-flow than after close.**
    A run can be green while open and red the moment it closes with ungraded work.
    That asymmetry is the intent — close is where the standard tightens — but it
    will surprise someone who reads only the exit code.

## Sign-off

Green at close: `bash scripts/selftest.sh && bash scripts/doctor.sh` -> `236 passed,
0 failed`, at v2.31.0. Suite grew 150 -> 236 over this plan.

- [x] **R1** — `codex-run --lane implement` takes `--req`; with a run open a
  dispatch without it is refused, naming the run's spec. Test: `open-run implement
  without --req is refused with its spec`. Identifiers are recorded on both
  dispatch events.
- [x] **R2** — identifiers are validated against the open run's spec; an unknown
  one is refused before a lane is spent (`requirement R99 is not in <spec>`,
  observed live). Empty elements between separators are refused too.
- [x] **R3** — `run-state.sh defer` writes the same structure `close` reads, and
  close reports both counts. Tests: `defer --run targets the selected open run`,
  `close reports shipped requirements and deferred items`.
- [x] **R4** — content drift is WARN while a run is open; the dispatcher-target
  check stays FAIL in every state. Tests: `open-run doctor warns on drift but
  fails on unreviewed implement`, `open-run doctor keeps dispatcher-target drift
  as FAIL`. The second exists because a dispatcher running from the working tree
  is what let a lane rewrite `codex-run.sh` mid-execution, twice.
- [x] **R5** — documented rule, no flag: intermediate reviews dispatch with
  `--effort medium`, the final review uses the model-aware default. A `--final`
  flag was designed and dropped — it would have redefined the existing default
  and no caller knows its own position.
- [x] **R6** — an unreviewed implement is a FAIL while a run is open, so `green`
  goes red until the diff is graded; `agents/codex-reviewer.md` documents that a
  review after `HEAD` moved needs `--base`. This gate held this run open through
  six review rounds, which is the behaviour it was built for.
- [x] **R7** — the flow reads `<plan>.chunks.json` and invokes
  `parallel-chunks.sh` at `parallel_min_chunks` or more, with serial documented
  for one chunk, overlap, an invalid manifest or no `treehouse` — plus the rule
  learned here: a batch whose chunks modify the flow's own machinery MUST run
  serially, because children execute the dispatcher from the runner's script
  directory while the green check runs the merged root scripts.
- [x] **R8** — `SKILL.md` states that a mid-flow discovery is deferred rather
  than dispatched, and documents `--req` as the mechanism.
- [x] **R9** — multiple open runs require `--run` or `CHARLES_RUN`; full id,
  unique substring, or exact match, with an exact CLOSED id refused rather than
  silently resolving to an open run that contains it. Tests: `two open runs
  without a selector name both runs and the selector`, `exact closed id is
  refused before an open substring match in both selectors`.
- [x] **R10** — manifests carry `req` per chunk, validated with the same grammar
  and passed through to children. Test: `parallel chunks pass --run to preflight
  and children with generalized req`.
- [x] **R11** — every mutating `run-state.sh` verb takes the selector, and
  `close` refuses when `--spec` disagrees with the spec recorded on the selected
  run. Test: `close refuses a spec that disagrees with the selected run`. This is
  the requirement that would have prevented the production incident: two pieces
  of state pointed at different runs and nothing checked they agreed.

Corrections carried on the record rather than quietly fixed:

- **B2-class error, twice.** R2's requirement matcher was written around this
  repo's own bullet style and would have rejected valid alternatives
  (`- **A1** text`, dotted and suffixed ids). Generalised only after a different
  convention was supplied from outside. Test: `alternate requirement bullet
  convention validates`, `Sign-off-only and ranged requirements are refused`.
- **The selector shipped in two dialects.** Built in separate dispatches,
  `codex-run.sh` and `run-state.sh` resolved run roots differently, so the same
  `--run` could mean different runs from a worktree. Now one shared
  `scripts/run-common.sh`. Test: `worktree run-state and codex-run select the
  main repo run`, `scripts source run-common.sh through a symlink`.
- **The review lane could grade input that was not the diff.** A plan outside
  `--dir` produced a `..` exclude pathspec, git fataled, the error was swallowed
  twice, and untracked files were still appended — so the reviewer received a
  PARTIAL diff and reported real tracked work as absent. Empty input announces
  itself; partial input persuades. Now refused with exit 4 before untracked
  enumeration. Test: `a failing tracked diff refuses instead of grading
  untracked-only`.
- **Six defects reached production despite 236 tests, a grill and six
  max-effort reviews.** All six were found by the code being run in a different
  repo, under different assumptions, rather than by reading it. Two of them
  silently corrupted state.

## Run outcome — 2026-08-22

Flow friction cut at v2.31.1. Implement dispatches carry validated requirement identity, deferring is one command, doctor severity is conditional on an open run, review effort is tiered by position, and the flow dispatches chunks in parallel when a manifest exists. Six defects surfaced only when the machinery ran in another repo under different assumptions: a fail-closed multi-run refusal that made every repo with a stale run undispatchable, run and spec selection disagreeing silently, a requirement matcher written around one repo's bullet style, two selector dialects reading different run stores, a shared helper unreachable through the PATH symlink, and a review lane grading a partial diff while reporting real work as absent. Suite 150 -> 236. Closed with --force for one reason: an orphan start event from an operator gate-probe that was killed at 20s. Censused before closing — its result file records 'no repository files changed' and the tree carries no unattributed work. The start event stays in the log because a killed lane never writes an end and receipts are not forged.

# Parallel-first implement

## Why

Measured across 229 completed implement dispatches in opted-in repos: median
9.9 min, p75 15.1, p90 25.7, max 39.6. 49% run over 10 minutes; only 16% finish
under 3. The flow's stated basis for "serial by default" is a 1.9-minute median
that no longer holds — implement is now 5x slower than the docs claim, so
wall-clock savings from parallel chunks are real rather than theoretical.

In those same 229 dispatches, `parallel-chunks.sh` ran **zero** times. Overlapping
implements in one repo: 0. The script has never executed against a real repo.

Three causes, each verified against source:

1. Nothing invokes it. No command, hook or flow calls it; every flow dispatches
   one direct implement lane (`SKILL.md:333`, `:355`, `:372`; `commands/feature.md:5`).
2. The one documented invocation cannot run: `SKILL.md:244` uses `$SCRIPTS`,
   which `charles-flow/SKILL.md` never assigns (only `commands/status.md:6` and
   `commands/ui.md:22` do). It expands to `/parallel-chunks.sh`.
3. The happy path is untested. `selftest.sh:249` installs a `treehouse` stub that
   exits 1, so the only parallel test asserts lease failure. Merge, in-bounds
   check, cleanup and receipt propagation are never exercised.

Flipping the default onto untested machinery is the failure mode this plan
exists to avoid. So: harden first, flip second, and the flip is gated on the
hardening being green.

## Out of scope

- Dependency edges between chunks (blocking order). Deferred in `backlog.md:6`; a
  chunk graph is a different feature and disjoint slices do not need one.
- `run-state.sh newest_open` picking the wrong run with two open runs
  (`run-state.sh:63-67`). Pre-existing, tracked as `cdl-1786688980-3638`.
- Re-measuring review and explore statistics. Only implement numbers are
  remeasured here; other stale figures get labelled, not recomputed.
- Cost budgets or a concurrency limiter beyond the chunk count itself.

## Files in scope

- `scripts/parallel-chunks.sh`
- `scripts/selftest.sh`
- `skills/charles-flow/SKILL.md`
- `commands/feature.md`, `commands/polish.md`, `commands/debug.md`
- `README.md`
- `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`

Must not touch: `scripts/codex-run.sh` (the writer lock and receipt format are
correct as they stand — chunks already get distinct worktree lock paths, verified
at `codex-run.sh:373`), `scripts/run-state.sh`, `scripts/flow.json`,
`hooks/`.

## Green

`bash scripts/selftest.sh && bash scripts/doctor.sh`

## Conventions

Copy the style of `scripts/parallel-chunks.sh` itself: comment the *reason* a
guard exists, not what the line does. New selftest cases follow the existing
`check`/`scheck_tool` helper shape in `scripts/selftest.sh`.

## Requirements

Chunk A — make the machinery trustworthy (`scripts/parallel-chunks.sh`,
`scripts/selftest.sh`):

- [ ] **A1. Exit 0 means the combined tree is green.** After merging,
  `parallel-chunks.sh` calls `green.sh "$REPO"` once and exits non-zero if the
  green command fails. Today it only prints an instruction
  (`parallel-chunks.sh:119-122`), so a caller that trusts exit 0 can close a run
  on a red tree. `green.sh` exit 2 means no green command is configured
  (`green.sh:26-46`) — that is a WARN and does not fail the batch, because a repo
  without a green command was never verifiable in the first place. A `--no-green`
  flag skips the call for callers that will run it themselves.
- [ ] **A2. Merge is all-or-nothing.** Acceptance is evaluated for every chunk
  first; no file is copied unless every chunk passed. Today a failed sibling still
  leaves accepted chunks copied into the root (`:87-89` `continue`s and later
  chunks merge), producing a partial tree alongside a failure exit code.
- [ ] **A2b. Work in a failed or rejected chunk is recoverable.** Worktrees for
  chunks that failed or wrote out of bounds are NOT returned to the pool; their
  paths are printed so the work can be judged independently. This matches the
  existing contract that a failed lane's work "may be" correct
  (`unsourced.sh:96-113`). Accepted chunks' worktrees are returned normally.
- [ ] **A3. All leases are acquired before any chunk is dispatched.** A lease
  failure returns every lease already taken and refuses the whole batch with
  **exit 3**, dispatching nothing. Today a failed lease is recorded and the
  remaining chunks run anyway (`:56-61`), so a short worktree pool yields partial
  parallel execution. Exit 3 rather than 1 keeps the code meaning it already has
  (`docs/specs/2026-08-14-flow-graph-and-janitor.md:73-80`).
- [ ] **A4. Child receipts reach the root.** Each chunk's
  `<worktree>/.charles/dispatches.jsonl` lines are appended to the root
  `.charles/dispatches.jsonl` before the worktree is returned, and each chunk's
  run ID is printed. Today receipts die with the worktree
  (`codex-run.sh:162` writes to `$DIR`), so `verify-receipt.sh:26` and
  `flow-status.sh` cannot see that the work was dispatched at all.
- [ ] **A5. Changed-file detection survives real filenames.** Parsing uses
  `git status --porcelain -z -uall`, and each case has a defined result:
  a **deletion** removes the file from the root rather than reaching `cp` with a
  missing source (`:108`); a **rename** requires BOTH the old and new path to be
  declared, otherwise the chunk is rejected; **spaces** and quoted paths resolve
  to the real path; **mode bits and symlinks** survive, so the copy uses `cp -a`.
  Today `awk '{print $2}'` (`:94-95`) returns the old path for a rename and the
  first word for a spaced path.
- [ ] **A6. Worktrees are always returned.** An `EXIT` trap returns every leased
  worktree, so a failure or interrupt after leasing does not strand leases.
  Today cleanup is a best-effort line at `:117` reached only on the success path.
- [ ] **A7. No declared file is overwritten blind.** If the root has uncommitted
  changes to any *declared* file, the merge refuses rather than overwriting it
  with `cp` (`:105-108`). Scope is the declared set, not the whole tree — an
  unrelated dirty file is none of this batch's business.
- [ ] **A8. The happy path is tested.** `selftest.sh` exercises a *successful*
  two-chunk run with a working `treehouse` stub and a stub implementer: merge
  lands, receipts aggregate, an out-of-bounds write is rejected, a failed sibling
  blocks all merges, and combined-green failure fails the run. Today
  `selftest.sh:246-257` only proves lease failure returns 3.
  This needs a test seam that does not exist yet: a fake `treehouse` whose `get`
  prints a real git worktree and whose `return` is a no-op, plus a fake `codex`
  on PATH that writes a declared file and exits 0 — `codex-run.sh:81` exits 127
  without a real binary. The fixture repo carries its own `.charles.toml` with
  `green = "true"`, because this repo's own green command is `selftest.sh`
  (`.charles.toml:6`) and pointing A1 at it would recurse.

Chunk B — make parallel the default (docs and flow contract):

- [ ] **B1. The plan phase emits a chunk manifest.** Flows write
  `docs/specs/YYYY-MM-DD-<topic>.chunks.json` alongside the plan whenever the
  plan yields 2+ disjoint file slices. Committed next to the plan, since
  `.charles/` is gitignored and `unsourced.sh:28-31` treats `docs/specs/` as
  orchestrator-authored.
- [ ] **B1b. The manifest is validated before anything is leased.**
  `parallel-chunks.sh` rejects a manifest that is not an array of objects, is
  missing `name`/`files`/`task`, has duplicate names, or declares an absolute
  path or one containing `..` — those strings are concatenated straight into
  `cp "$wt/$f" "$REPO/$f"` (`:105-108`). Today only `length` and duplicate file
  strings are checked (`:35-45`); the schema at `:13-15` is a comment, not a
  validator.
- [ ] **B2. Parallel is the default at 2+ chunks.** `SKILL.md` states parallel
  when the manifest has 2+ disjoint chunks; serial only when there is one chunk,
  declarations overlap, the manifest is invalid, or `treehouse` is absent. The
  current "3+ chunks and each non-trivial" rule (`SKILL.md:239-241`) is replaced.
  The threshold is readable from `.charles.toml` as `parallel_min_chunks`
  (default 2) so a repo that measures otherwise can raise it without a code change.
- [ ] **B3. The documented invocation runs as written.** Every
  `parallel-chunks.sh` call site resolves the script the way `commands/ui.md:22`
  does, so no snippet depends on an unassigned `$SCRIPTS`.
- [ ] **B4. Stale implement statistics are corrected.** Every occurrence of the
  1.9-minute median / 19.5-minute p90 pair is replaced with the measured
  n=229 median 9.9 / p75 15.1 / p90 25.7 / max 39.6, and the derived "30 min
  serial vs 10 parallel" arithmetic is recomputed from those. Known sites:
  `SKILL.md:194-202`, `:235-237`, `README.md:216-227`, `parallel-chunks.sh:4-6`.
  The older 179-run population (`SKILL.md:23-25`, `README.md:216-222`) stays, but
  is labelled as covering all lanes and predating this measurement — only the
  implement figures are remeasured here. The measurement is start/end pairing on
  `.charles/dispatches.jsonl` across all opted-in repos; that method is recorded
  in this spec so the number can be reproduced rather than trusted.
- [ ] **B5. Version bumped in all three places** to the same value:
  `.claude-plugin/plugin.json` and both `version` fields in
  `.claude-plugin/marketplace.json`.

## Sequencing

Chunk A and chunk B touch disjoint files and can run in parallel. B4 edits the
comment block at `parallel-chunks.sh:4-6` — that file belongs to A, so A carries
B4's edit to it and B covers only the Markdown sites.

Chunk B's default flip must not be released while chunk A is red: if A fails,
B's documentation change is reverted rather than shipped, because pointing every
flow at unhardened machinery is worse than the status quo.

## Grill verdict — 2026-08-21

- Rounds: 2
- Attacks raised: 22 — resolved from source: 18, changed the plan: 11, escalated: 1
- Plan changes:
  - A1 names the exact call (`green.sh "$REPO"`), treats exit 2 (no green
    configured) as WARN, and gains `--no-green`.
  - A1's fixture problem named: this repo's green command is `selftest.sh`, so a
    test pointing at it would recurse. The fixture carries `green = "true"`.
  - A2 split: acceptance for all chunks is evaluated before any file is copied.
  - A2b added: failed/rejected worktrees are kept and their paths printed, rather
    than returned with the work inside them.
  - A3 exit code corrected 1 → 3, keeping the meaning the code already has.
  - A5 given per-case semantics (delete, rename, spaces, mode, symlink) instead
    of the undefined word "handled"; parsing moves to `-z`.
  - A6 must kill and wait for live children before releasing their worktrees.
  - A7 retitled: the check is over declared files, not the whole tree.
  - A8 names the two missing test seams (fake `treehouse`, fake `codex`) —
    `codex-run.sh:81` exits 127 without a real binary, so "a stub implementer"
    was not a thing that existed.
  - B1 dropped the false claim that `parallel-chunks.sh:13-15` enforces a schema;
    it is a comment. B1b added to actually validate the manifest.
  - B2 threshold made configurable via `parallel_min_chunks`.
  - B4 keeps the older 179-run population, labelled, rather than silently
    implying it was remeasured; records the measurement method.
- Accepted risks:
  - **Merge is still not atomic across files.** A2 removes the failed-sibling
    partial merge, but a `cp` failing midway through an accepted batch still
    leaves the root half-updated. A real fix means staging and rollback; the
    likelihood (disk/permission error mid-copy) does not justify it yet.
  - **Combined-green failure leaves the merge in place.** A1 reports red; it does
    not revert. Reverting would discard work the operator may want to debug, and
    the tree is a git repo — `git diff` is the rollback.
  - **"Disjoint files" is not "independent changes".** Two chunks can declare
    non-overlapping files and still break each other through a shared type,
    lockfile, generated artifact or test fixture. Combined green is the only
    defence, and it is a real one; a dependency graph is explicitly out of scope.
  - **Paths containing newlines are not supported.** `-z` parsing handles them,
    but nothing else in the pipeline does, and no such path exists in these repos.
  - **`parallel_min_chunks = 2` is a judgment, not a measurement.** The 9.9-minute
    median is per whole dispatch, not per chunk, and worktree/merge/green overhead
    is unmeasured. The knob exists so this can be corrected by evidence later.
  - **Aggregated child receipts widen what `unsourced.sh` counts as sourced**
    (`unsourced.sh:84-93` treats any rc=0 implement as accounting for root
    changes). That is intended here — the root changes did come from those
    chunks — but it means a mixed batch needs `verify-receipt.sh --run` per chunk
    rather than the default lane-wide check.
- Unresolved: one escalated question, below.

## Sign-off

Green at close: `bash scripts/selftest.sh && bash scripts/doctor.sh` -> `155 passed,
0 failed` / `20 ok, 0 failing` / `GREEN` at v2.20.1.

- [x] **A1** — `parallel-chunks.sh:317-325` calls `green.sh "$REPO"`; exit 2 prints
  `WARN: no green command configured; accepting without a combined check` and does
  not fail the batch; `--no-green` skips it. Test: `combined-green failure fails
  the batch after merge`.
- [x] **A2** — acceptance is a separate pass over every chunk before any copy
  (`:198-267`). Test: `failed sibling blocks every merge`.
- [x] **A2b** — `CH_KEEP` marks failed/rejected chunks; `cleanup` prints
  `keeping worktree <path> for inspection` instead of returning it (`:135-142`).
  Test: `out-of-bounds chunk is rejected and kept`.
- [x] **A3** — all leases acquired in a dedicated loop before any dispatch
  (`:150-159`); a failure exits 3 and the EXIT trap returns what was taken.
  Test: `partial lease failure returns the first worktree without dispatching`.
- [x] **A4** — each worktree's `.charles/dispatches.jsonl` is appended to the root
  log and every run ID printed (`:119-134`). Test: `successful two-chunk merge
  aggregates and prints receipts`.
- [x] **A5** — `git status --porcelain -z -uall` throughout (`:206`, `:218-241`);
  deletions remove from the root, renames require both paths declared, copies use
  `cp -a` (`:277`, `:288`, `:305`) so mode bits and symlinks survive.
- [x] **A6** — `trap 'cleanup "$?"' EXIT` plus INT/TERM (`:145-147`); cleanup kills
  then waits for live children only, since the dispatch loop clears each PID as it
  is reaped (`:184`), so a reused PID cannot be signalled.
- [x] **A7** — refuses only when a *declared* path is dirty in the root
  (`:80-92`); unrelated dirty files do not block the batch.
- [x] **A8** — six parallel cases now run, five of which the old suite never
  reached: successful two-chunk merge, out-of-bounds rejection, failed-sibling
  block, combined-green failure, partial lease recovery. Suite went 150 -> 155.
- [x] **B1** — the chunk manifest is documented as a plan-phase artifact at
  `docs/specs/YYYY-MM-DD-<topic>.chunks.json`, alongside the plan.
- [x] **B1b** — manifest validation before any lease (`:40-68`): array of objects,
  required fields, unique names, no absolute or `..` paths.
- [x] **B2** — `SKILL.md` states parallel at 2+ disjoint chunks with serial as the
  fallback; threshold configurable as `parallel_min_chunks`.
- [x] **B3** — `SKILL.md:264` assigns `SCRIPTS` with the
  `readlink -f "$(command -v codex-run)"` idiom, so the documented invocation runs
  as written. Verified: `grep -n 'SCRIPTS=' skills/charles-flow/SKILL.md` -> hit.
- [x] **B4** — `grep -rn '1\.9|19\.5'` over `SKILL.md`, `README.md` and
  `parallel-chunks.sh` returns nothing; replaced with n=229 median 9.9 / p75 15.1
  / p90 25.7 / max 39.6 and the measurement method recorded.
- [x] **B5** — 2.20.1 in `.claude-plugin/plugin.json:3` and both
  `.claude-plugin/marketplace.json:8,15`; installed build matches
  (`doctor: OK installed v2.20.1 matches this repo`).

Review: two rounds by an isolated `sol` reviewer that saw only the plan and the
diff. Round 1 found two real defects (unconditional kill of reaped PIDs; A3's
lease-recovery path untested). Both were verified against source by the
orchestrator before acting, fixed by a dispatched lane, and confirmed fixed by
round 2, which found no new defects.

## Run outcome — 2026-08-21

Parallel-first implement shipped at v2.20.1. parallel-chunks.sh went from never-executed, never-merge-tested code to a hardened runner: combined green gates exit 0, acceptance is all-or-nothing, leases are taken before any dispatch and released on refusal, failed chunks keep their worktree for recovery, receipts aggregate to the root, and -z parsing handles deletes, renames and spaces. The flow now defaults to parallel at 2+ disjoint chunks with serial as the fallback, and the stale 1.9-minute implement median was replaced with the measured 9.9 across n=229 dispatches.

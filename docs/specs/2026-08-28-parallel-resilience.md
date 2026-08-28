# Parallel resilience — stop the failure modes that force serial dispatch

2026-08-28 · polish flow · run 20260828-200748-polish-528568.

## Why

An audit of `.charles/` receipts (2026-08-21 → 2026-08-28) across the opted-in
repos (evidence lives in each repo's `.charles/dispatches.jsonl` and
`.charles/runs/*/RUN.md`: infra-orchestrator, leadgrow-olympus, this repo)
found five mechanisms that turn "parallel is available" into serial practice:

1. **Timeout rescue futility.** `scripts/codex-run.sh:733` falls back to
   deepseek on ANY nonzero rc, including 124. On 2026-08-21 infra-orchestrator
   logged 8 implement rc=124; every deepseek rescue of a timeout also hit
   rc=124 (3/3), doubling each loss to ~60 min. A timeout means the task
   outgrew the clock, not that the engine broke.
2. **Wrapper kills leave a rogue writer.** `scripts/codex-run.sh:374-376`
   traps EXIT/TERM/INT, but the codex child runs as a foreground subshell
   (`codex-run.sh:490`, `:642`; deepseek path `:499-514`). A SIGKILLed
   wrapper (observed: infra dispatch `20260827-184101-159540-implement` —
   start event, no end event, codex still writing; olympus logged the same
   class 3×) bypasses every trap: the child is reparented and keeps writing,
   lane-status reports RUNNING, and the orchestrator must sit serial because
   re-dispatch on a live writer is forbidden. SIGTERM is little better: bash
   defers the trap until the foreground child exits.
3. **Hub-file overlap makes manifests impossible.** `parallel-chunks.sh`
   refuses any overlapping declaration (`scripts/parallel-chunks.sh:106-114`).
   In infra-orchestrator every recent 2-chunk plan overlapped on `store.py`
   or `cli/main.py` (runs 20260824-214426, 20260827-161647 both record
   "overlap → serial"), so parallel-chunks has fired exactly once there, ever.
4. **Merges from a diverged lease contaminate the tree.** Olympus run
   20260825-022124: a merge copied whole files from worktrees leased at
   `04bc0382`, not an ancestor of the target `main` at `e1d8eee1` — 8 tracked
   files silently replaced. Nothing records or verifies a lease's fork point
   (`parallel-chunks.sh:216-225`; retained arrays at `:154`/`:224` hold no
   commit).
5. **Foreground reviews die at the Bash cap.** Olympus run 20260827-224343
   logged a sol review killed twice at the foreground 600s cap; the "review
   never exceeded 540s" claim was measured on small repos.

Out of scope: cross-session contention (ruled out — on 08-28 an olympus
parallel batch ran to rc=0 alongside a live infra session; no OOM in dmesg),
and semantic-independence checking beyond the combined green run.

## Terms

- **wrapper** — the `codex-run.sh` process for one dispatch.
- **attempt** — one engine execution inside a dispatch; a fallback dispatch
  has two attempts and legitimately two end events (one per attempt,
  `selftest.sh:2411-2419` asserts this).
- **end marker** — the pair `$RUN.done` (exit code file) + `event:"end"`
  JSONL record; `lane-status.sh:109-145` additionally treats nonempty
  `$RUN.last` as DONE.
- **fork commit** — the commit a leased worktree's HEAD points at when the
  lease is acquired, recorded by this plan (nothing records it today).

## Requirements

- **R1** — When a luna/terra primary attempt exits 124 AND the dispatch's
  elapsed time has reached `--timeout` (within a small slack), the deepseek
  fallback is skipped: the dispatch ends rc=124 and stderr says the fallback
  was skipped because the task timed out. An rc=124 that arrives well before
  the deadline is treated as an engine failure and still falls back (closes
  the `green.sh:60-65`-class ambiguity of "timed out or the command itself
  returned 124"). All other nonzero rcs keep today's fallback behaviour and
  receipts. Deepseek-as-primary continues to never fall back
  (`codex-run.sh:732`).
- **R2** — When the wrapper dies by any wrapper-killing signal mid-dispatch,
  the live child attempt is killed within 15s and the end marker is completed
  so the dispatch cannot remain a RUNNING orphan with a live writer.
  Mechanism, per the explore audit (receipt 20260828-200703):
  - Each attempt's child (gpt subshell `:490`, review `:642`, and the
    deepseek script `:499-514` alike) launches session-detached
    (`setsid … &`) and the wrapper `wait`s, so TERM/INT/HUP traps fire
    immediately and kill the child's process group before exiting 143/130.
  - A watchdog, spawned as a direct child of the wrapper and ALSO
    session-detached (so a harness group-kill cannot take it down with the
    wrapper), detects wrapper death by its own reparenting (PPID change —
    immune to PID reuse), then TERM→KILLs the child group, escalating after
    5s, polling every ≤3s.
  - End-marker dedup: after killing the child, the watchdog writes an
    `event:"end"` (rc 143, marked wrapper-death) ONLY if no end event exists
    for the current attempt, and writes `$RUN.done` ONLY if absent — if the
    wrapper already logged the attempt's end, the watchdog completes the
    missing `.done` with that logged rc and adds nothing else. On a clean
    dispatch the wrapper reaps the watchdog before exiting; each attempt
    yields exactly one end event on every path.
  - The watchdog's command line must not contain the run id (so
    `lane-status.sh`'s `pgrep -f` cannot mistake it for the lane); pass
    state via environment. After wrapper death is handled, `lane-status.sh`
    must classify the dispatch from the completed marker (DEAD/DONE with the
    recorded rc), never RUNNING; adjust `lane-status.sh` only if that
    classification needs it.
- **R3** — `parallel-chunks.sh` accepts a manifest where chunks overlap ONLY
  on files that every overlapping chunk lists in a per-chunk `"shared"`
  array. Rules:
  - Schema: `shared` is optional, per chunk; every `shared` path MUST also
    appear in that chunk's `files`; a path appearing in ≥2 chunks' `files`
    is valid only if EVERY such chunk lists it in `shared`; at most 2 chunks
    may share any one path (a third refuses — sequential-merge order effects
    stay out of scope); asymmetric or out-of-declaration `shared` entries
    refuse with a named reason. Overlap not declared shared refuses exactly
    as today.
  - Shared paths count as in-declaration for the scope check
    (`parallel-chunks.sh:386-399`).
  - Shared handling covers only ordinary text files that exist at the fork
    commit and are modified in place by both chunks; an add, delete, rename,
    mode change, symlink, or binary content on a shared path refuses the
    manifest.
  - The 3-way merge (`git merge-file`-class, base = fork commit content via
    `git show <fork>:<path>`) is computed into temp results during the
    pre-copy acceptance pass (`parallel-chunks.sh:299-405`), BEFORE any root
    mutation; a conflict rejects that chunk there, so the existing
    all-or-nothing acceptance property is preserved rather than weakened by
    the in-order copy loop (`:407-475`).
  - A shared-files manifest refuses `--no-green`: the combined green run is
    the only semantic-compatibility net and is mandatory there.
- **R7** — `parallel-chunks.sh` captures ONE batch HEAD snapshot of the
  target repo at batch start; every lease's HEAD (recorded at lease
  acquisition, before dispatch) must equal it, and the target HEAD is
  re-checked unchanged before merging; any mismatch refuses, naming both
  commits. All R7/R3 git inspection runs with the inherited-git-env
  sanitization codex-run.sh already uses (`codex-run.sh:314-318`). R3's merge
  base is this verified snapshot.
- **R4** — Docs stop contradicting the above: `skills/charles-flow/SKILL.md`
  (`:49-50`, `:102`, and BOTH overlap rules `:268-287` and `:282-300`),
  `README.md:531-549`, `commands/feature.md:8-15`, `commands/debug.md:12-19`,
  `commands/polish.md:12-19`, and `agents/codex-reviewer.md` are updated to
  (a) direct a review expected to exceed ~9 minutes (heavy diff, big repo,
  terra at max) to background dispatch — including fixing codex-reviewer's
  `--timeout 540` command (`agents/codex-reviewer.md:25-28`) to give the
  background path a real timeout and completion protocol consistent with its
  existing background-fallback section (`:72-100`) — and (b) describe the R3
  shared-files rule, keeping serial as the rule for overlap not declared
  shared.
- **R5** — All three version fields become `2.34.0`:
  `.claude-plugin/plugin.json`, both `version` fields in
  `.claude-plugin/marketplace.json`.
- **R6** — `scripts/selftest.sh` proves, beyond the existing synthetic
  receipts, with real processes where stated:
  - R1: rc=124 at deadline skips fallback; rc=1 still falls back; early
    rc=124 still falls back.
  - R2 (real process test): spawn the wrapper with a fake long-running
    codex, SIGKILL the wrapper, assert the child process group is gone
    within 15s and the end marker is complete; assert a clean dispatch
    leaves exactly one end event per attempt and no watchdog survivor.
  - R3: clean shared merge accepted; conflicting shared merge rejects the
    chunk BEFORE any root file changes; undeclared overlap still refused;
    one-sided `shared` refused; shared path absent from `files` refused;
    3-sharer refused; shared+`--no-green` refused.
  - R7: a lease at a stale commit refuses before dispatch; a target HEAD
    moved mid-batch refuses before merge.
  Reuse `parallel_fixture`/`parallel_swap_fixture` (`selftest.sh:287-343`),
  fake `treehouse` (`:392-434`), fake `codex` (`:455-498`); live-process
  precedent at `:1722-1746`. Suite stays green:
  `bash scripts/selftest.sh && bash scripts/doctor.sh` exits 0.

## Scope

May touch: `scripts/codex-run.sh`, `scripts/parallel-chunks.sh`,
`scripts/lane-status.sh` (R2 classification only), `scripts/selftest.sh`,
`skills/charles-flow/SKILL.md`, `README.md` (overlap/review sections only),
`agents/codex-reviewer.md`, `commands/feature.md`, `commands/debug.md`,
`commands/polish.md`, `.claude-plugin/plugin.json`,
`.claude-plugin/marketplace.json`, this file.

Must not touch: hooks/, run-state.sh, flow-status.sh, green.sh, unsourced.sh,
any consumer repo.

Machinery batch → serial dispatch only, in a treehouse worktree (never the
main tree; live sessions execute the main-tree dispatcher through the PATH
symlink). Two serial implement chunks with green between: chunk A =
R1+R2+their R6 tests (codex-run.sh, lane-status.sh, selftest.sh); chunk B =
R3+R7+their R6 tests+R4+R5 (parallel-chunks.sh, selftest.sh, docs, versions).

## Green

`bash scripts/selftest.sh && bash scripts/doctor.sh` — baseline 2026-08-28,
recorded in RUN.md phase `plan`: 271 passed, 0 failed; doctor 19 ok,
0 failing (2 WARN orphans, known, cdl-stale-orphans).

## Conventions

Refusal/receipt style: `scripts/codex-run.sh:677-700` (flock guard).
Preserve all-or-nothing acceptance (`parallel-chunks.sh:299-405`) and the
`.charles/*`/`.chunk.*` exclusions (`:263-268`). Append-only receipts via
`>>` single-line writes.

## Grill verdict — 2026-08-28

- Rounds: 1 (adversary lane 20260828-202146-572045, luna@max; round 2 skipped
  — zero items required the user; all attacks resolved from source or by
  recorded design defaults)
- Attacks raised: 29 — resolved from source: 8, changed the plan: 18,
  escalated: 0, accepted as risk: 3
- Plan changes: rc=124 disambiguated by elapsed-vs-deadline (attack 2);
  fallback matrix stated (3); R2 covers all three dispatch paths incl.
  deepseek script (4); watchdog normal-stop + end-marker dedup protocol (5,
  6, 28); watchdog itself setsid so group-kills can't orphan the child (7);
  watchdog cmdline free of run id + lane-status classification (9); 15s bound
  given poll/escalation mechanics (10); `shared` schema fully specified,
  2-sharer cap (11, 12, 16); shared merges computed pre-copy so acceptance
  stays all-or-nothing (13); non-ordinary shared files refused (15);
  shared+`--no-green` refused (17); batch HEAD snapshot replaces per-lease
  reasoning, re-checked pre-merge (18, 20, 26); sanitized git env for R7
  checks (19); README + earlier SKILL overlap rule + codex-reviewer command
  added to R4 (21, 22); version target fixed at 2.34.0 (23); R6 upgraded to
  real process kills + fork-divergence fixtures (24); Terms section (27);
  receipt locations named in Why (1); baseline provenance stated (25).
- Accepted risks: (a) textually-clean-but-semantically-wrong shared merges —
  the mandatory combined green run is the only net (attacks 14, 29), same
  exposure the serial path already has; (b) sub-second append race between a
  dying wrapper's end write and the watchdog's dedup check — watchdog waits
  2s after reparent before acting, residual window accepted on a single
  machine (8); (c) a human editing the target tree mid-batch can still be
  overwritten, unchanged from `2026-08-21-parallel-first-implement.md:208-211`
  (20).
- Unresolved: none.

## Sign-off

- [ ] R1 —
- [ ] R2 —
- [ ] R3 —
- [ ] R4 —
- [ ] R5 —
- [ ] R6 —
- [ ] R7 —

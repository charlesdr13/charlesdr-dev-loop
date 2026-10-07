
## Archived 2026-09-03
- [x] cdl-1786425693-24582 - Make charlesdr13/charlesdr-dev-loop public (audit clean) (kind: pending-decision) (done 2026-08-11)

## Archived 2026-09-03
- [x] cdl-1786425693-15926 - Agent|Task hook matcher unverified against a real harness payload (kind: deferred) (done 2026-08-14)

## Archived 2026-09-03
- [x] cdl-1787298851-1915 - Failed/rejected chunk worktrees: keep them leased so the work is recoverable (A2b), or return them to the pool and accept losing it? (kind: blocked-human) (done 2026-08-21)

## Archived 2026-09-03
- [x] cdl-shebang - codex-run.sh has a blank line 1, so its shebang is on line 2 and the kernel ignores it: exec'ing it directly (timeout codex-run, cron, any non-bash caller) falls back to sh and dies on 'set -o pipefail'. One-line fix; only script in the repo missing a valid shebang. (done 2026-08-21)

## Archived 2026-09-03
- [x] cdl-signoff-infra - codex-run review lane silently grades an EMPTY diff when --plan lives outside the repo (pathspec ':(exclude)../..' is fatal, swallowed by 2>/dev/null||true at codex-run.sh:271-274); codex-reviewer agent can return a verdict with no dispatch receipt; a refused dispatch ('--lane review requires --plan FILE') still reports exit 0 (done 2026-08-23)

## Archived 2026-09-03
- [x] cdl-1787324684-30198 - SessionStart link-dispatcher.sh points codex-run at the working tree when the plugin's marketplace source is a local directory; the installed-copy guard then has to be re-applied by hand every session (kind: deferred) (done 2026-09-03)
  Resolved by R10 (2373fe7, v2.35.0): link-dispatcher now refuses any target inside a git working tree, prefers the installed cache copy, and leaves an existing link alone when no viable target exists. Verified live twice.

## Archived 2026-09-03
- [x] cdl-1787328403-11410 - run-state has no reopen verb; recovering a mistakenly closed run means hand-stripping its Outcome section, and close may already have appended an outcome paragraph to the committed spec (kind: deferred) (done 2026-09-03)
  Resolved by R8 (5af61a7, v2.35.0): run-state.sh reopen <dir> --run <id> restores a closed run and preserves the prior outcome as a superseded heading. Exit 8 refuses an already-open run, 7 an unknown id. The spec's appended outcome paragraph is deliberately left in place as history.

## Archived 2026-09-03
- [x] cdl-lane-status-scope - lane-status.sh exit 2 means BOTH 'dead' and 'could not determine' (no such repo, jq missing, malformed state), and it identifies a live lane by scanning process cmdlines for the run id against a global ~/.cache/charlesdr-dev-loop keyed only by run id, not by repo. Two repos sharing a run id therefore interfere - observed live 2026-08-25 while probing unsourced.sh with a hand-made id. Callers that treat non-zero as 'dead' (unsourced.sh) can fail open on an error. Fix: give lane-status a distinct exit for 'undeterminable', and scope its cache lookups by repo. (done 2026-09-03)
  Resolved by R4 (5f79ace, v2.35.0): lane-status.sh gained exit 3 UNKNOWN, distinct from exit 2 DEAD, and never reports an indeterminate lane as dead. Propagated to flow-status.sh, unsourced.sh and verify-receipt.sh. Repo scoping via --dir was already present.

## Archived 2026-09-03
- [x] cdl-1788336261-29694 - R5 grill gate scope: refuse implement for every flow, or only feature/polish (debug+ui have no grill step by design)? (kind: blocked-human) (done 2026-09-03)
  Answered by the operator 2026-09-02: gate every flow, with a written 'Grill waived: <reason>'. Shipped as R5 (8499de0).

## Archived 2026-09-03
- [x] cdl-1788336261-2170 - R8 abandon semantics: does an abandoned run stop counting as open (writes ## Outcome) or stay open with an abandoned marker, per README.md:361-364? (kind: blocked-human) (done 2026-09-03)
  Answered by the operator 2026-09-02: abandoned is a distinct terminal state that writes ## Outcome and leaves the open count. Shipped as R8 (5af61a7).

## Archived 2026-09-03
- [x] cdl-fastmode-live-probe - Confirm R8 live: after next real luna review dispatch, check receipt shows fast_mode=enabled (was --disable pre-2.34.0); and next timeout shows 'fallback was skipped' (done 2026-09-03)
  Both conditions confirmed live 2026-09-02: luna dispatch receipts show fast_mode=enabled (e.g. 20260902-174013-99174-implement), and the S4a rc=124 timeout printed 'codex-run.sh: fallback was skipped because the task timed out'.

## Archived 2026-09-03
- [x] cdl-unsourced-clean-tree - unsourced.sh exits 3 whenever the dispatch log holds an unresolved implement start, even when git status is completely empty. With a clean tree there are no changes for an orphan to own, so exit 3 is wrong. Effect: flow-status's F4 blocker can never be satisfied in a repo with a historical orphan start, which reintroduces reflexive --force through the one check close-scoping deliberately kept blocking (see docs/specs/2026-08-25-close-scoping.md F4). Fix: census the tree first and exit 0 when there is nothing to attribute; keep exit 3 only when unattributable changes actually exist. Verified 2026-08-25 on charlesdr-dev-loop at 60a3a51: clean tree, unsourced_rc=3. (done 2026-09-03)
  No longer reproduces on charlesdr-dev-loop at a926487: clean tree, dispatch log still holds the unresolved implement start 20260821-230555-3404680, unsourced.sh exits 0 (was 3 at 60a3a51 on 2026-08-25). Closed on evidence, not on a targeted fix.

## Archived 2026-09-03
- [x] cdl-1787588353-32395 - flow-status ISSUEs are two 2026-08-21 orphan dispatches predating HEAD 6fdfcfa, not this run's work; working tree censused, every change accounted for (6 merged files + this run's spec). Carried to tasks-axi cdl-stale-orphans; closing with --force for that reason only. (kind: deferred) (done 2026-09-03)
  Superseded. This recorded a one-off --force close rationale for the two 2026-08-21 orphans; the underlying item is cdl-stale-orphans, which remains open. R4 (5f79ace) also stopped flow-status asserting those orphans are dead — they now report liveness UNKNOWN.

## Archived 2026-10-08
- [x] cdl-1790530671-24095 - Pre-existing selftest GIT_DIR leak causes inherited Git environment to affect temporary repositories (done 2026-10-08)

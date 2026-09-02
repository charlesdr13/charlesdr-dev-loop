# Backlog drain: attribution, orphan retirement, and dispatch resilience

Polish run. Scope is the `tasks-axi` backlog for this repo, drained rather than
extended. The 2026-09-02 selector/supervision run closed eight items outright;
this plan takes the remainder that is tractable here.

**Baseline:** `selftest 338 passed, 0 failed` · `doctor 20 ok, 0 failing`, at
`a926487`, plugin v2.35.0 installed.

**Not in this plan, with reasons.** These stay open deliberately:

- `cdl-1788339398-22741` — the detached-child hazard. A SIGKILLed wrapper leaves
  its setsid'd codex child running unsupervised; observed live on 2026-09-02
  (pid 3676741, 6+ minutes). Closing it needs a supervisor outside the killed
  process group — a systemd unit, a cgroup watcher, or `PR_SET_PDEATHSIG`, which
  bash cannot set. That is a different kind of change from anything here.
- `cdl-1788341971-13254` — splitting the 198KB `scripts/selftest.sh`. A large
  mechanical refactor of the one file every requirement in this repo depends on
  for proof. It deserves its own run with its own review, not a slice of this one.
- `cdl-1787918943-6895` — a cross-repo sweep naming four urgent production items
  in infra-orchestrator and leadgrow-olympus. Not this repo's work; surfaced to
  the operator directly.

## Requirements

- **A1** — close attribution uses the flow-run id, not a timestamp window

  `scripts/flow-status.sh:74-77` decides whether a dispatch belongs to the
  closing run by comparing timestamps against `closing_started`. That is the
  open-ended window `cdl-dispatch-runid` was raised to remove: a later run's
  dispatches over-block an earlier close, and two runs open at once cannot be
  told apart at all.

  The blocker is gone. R6 (`6cbff8b`) added `flow_run_id` and `spec_path` to
  every dispatch record, which is exactly the identity the item asked for.

  Done when: a dispatch carrying `flow_run_id` is attributed to the closing run
  by exact match and never by timestamp; records without the field keep the
  existing window behaviour, because 2000+ historical records across 47 repos
  have no identity and must not change meaning; and `selftest.sh` asserts that a
  later run's identified dispatch does not block an earlier run's close.

- **A2** — an old orphan dispatch can be retired

  `cdl-stale-orphans`: two dispatches from 2026-08-21 have starts with no
  terminal record, so `flow-status` reports them on every run in this repo and
  `close` needs `--force`. Their work predates HEAD and a census found no
  unaccounted changes. R3 stops new ones accruing; it does nothing for these.

  R4 already softened the claim — they now report `liveness UNKNOWN` rather than
  an asserted death. What is missing is a way to retire one deliberately.

  Done when: an operator can record a terminal `abandoned` outcome for a named
  orphan dispatch, with a reason, through an explicit command that names the
  dispatch — never a blanket sweep and never automatic on age; a retired
  dispatch stops being reported as an orphan and stops blocking close; the
  record is distinguishable from a real terminal record, so retiring one cannot
  be mistaken for the lane having finished; and `selftest.sh` covers retire,
  refusal on an unknown id, and refusal on a dispatch that already has a
  terminal record.

- **A3** — a run item can be resolved without hand-editing

  `run-state.sh` has `item` and `defer` but no verb to resolve one. Closing a
  run therefore means editing `- [ ]` to `- [x]` in `RUN.md` by hand, which is
  what this repo's own 2026-09-02 run had to do for eight items.

  Done when: `run-state.sh resolve <dir> [--run <id>] <selector> "<note>"` ticks
  a single open item and appends the note; the selector identifies one item
  unambiguously and refuses when it matches none or several, naming the
  candidates; and `selftest.sh` covers resolve, ambiguous selector, and no match.

- **A4** — an ambiguous open run is refused, not guessed

  `run-state.sh:25-29` `newest_open` picks the most recent open run when several
  are open, so a `phase` or `item` can land on the wrong one.
  `codex-run.sh:344-350` already refuses this ambiguity for implement dispatches
  and prints the candidates; run-state guesses instead.

  Done when: verbs that mutate a run refuse when several runs are open and no
  `--run` is given, printing the candidates the way `codex-run.sh` does; read-only
  paths (`show`) keep their current behaviour; and `selftest.sh` asserts the
  refusal names every candidate.

- **A5** — close without `--spec` still checks the run's recorded plan

  `run-state.sh:382-388,470-496`: the sign-off and spec cross-checks run only
  when `--spec` is passed. A close with no `--spec` silently skips the run's own
  recorded plan and its outcome promotion, so the sign-off gate — the thing that
  makes a close mean something — is opt-in.

  Done when: a close with no `--spec` uses the spec recorded in `RUN.md` and
  applies the same gates; a run opened without any spec behaves as today; and
  `selftest.sh` asserts a close with no `--spec` is refused when the recorded
  spec has an unticked sign-off line.

- **A6** — `--req` validation does not depend on a filename convention

  `cdl-req-noplan`: `parallel-chunks.sh:46-52` derives the plan path only when
  the manifest name ends `.chunks.json`, so a manifest named anything else skips
  requirement validation entirely while still dispatching.

  Done when: the plan is resolved from the manifest or the open run regardless of
  the manifest's filename, and a manifest that cannot be tied to a plan is
  refused rather than dispatched unvalidated; and `selftest.sh` covers a
  manifest whose name does not end `.chunks.json`.

- **A7** — the review diff shows the real change

  `codex-run.sh:506-509`: untracked files are synthesised into the review diff as
  plain content, dropping the executable bit and inlining a symlink's target as
  though it were file text. The reviewer then grades something other than what
  was written — and this repo ships executable hooks and scripts, so a new hook
  landing non-executable is exactly the defect a reviewer should catch.

  Done when: a new executable file appears in the review diff as a mode change,
  and a new symlink appears as a symlink rather than as its target's text; and
  `selftest.sh` asserts both.

- **A8** — attribution degradation is decided once, before any check runs

  `cdl-degrade-eager`: `flow-status.sh` discovers degradation lazily inside
  `paths_match`, so lines printed before the first path comparison keep a
  classification the final verdict contradicts. Reviewed as cosmetic — the exit
  code is unaffected and no closing-run finding is demoted — but a report that
  disagrees with itself costs a reader time.

  Done when: canonicalisation capability is resolved once at startup, before any
  check emits a line, and every line reflects the same decision; and
  `selftest.sh` asserts consistency when canonicalisation is unavailable.

- **A9** — the plan requirement format is documented where plans are written

  `cdl-1788337312-10399`: `codex-run.sh:396-398` requires requirement identifiers
  as `- **R1** —` bullets and refuses the dispatch otherwise. Nothing documents
  that. This repo's own 2026-09-02 plan was written with `### R1` headings, read
  perfectly, and was refused at dispatch after the plan was complete.

  Done when: `skills/charles-flow/SKILL.md` states the bullet contract where it
  tells the reader to write checkable requirements, with an example; and
  `selftest.sh` asserts the skill documents it, so the contract and its
  documentation cannot drift apart.

- **A10** — a lane that cannot reach its provider fails fast

  Measured 2026-09-02 19:20: a dispatch spent its entire 540s budget retrying
  `wss://chatgpt.com` while DNS returned `EAGAIN`, then reported `rc=124` as a
  timeout. WSL2 routes all DNS through a single proxy at `10.255.255.254`, which
  saturates when several sessions run codex fleets at once. The wrapper correctly
  refused to fall back — the failure was real — but it burned nine minutes to
  learn nothing, and `rc=124` misdescribes it as slow work rather than no network.

  Done when: a dispatch whose provider is unreachable is detected and reported
  distinctly from a genuine timeout, well before the budget expires; the check
  cannot itself become a new failure mode when the probe is unavailable; and
  `selftest.sh` covers the unreachable case and the ordinary case.

## Green

`bash scripts/selftest.sh && bash scripts/doctor.sh`

Baseline: `338 passed, 0 failed`; `20 ok, 0 failing`. Any behaviour change bumps
`.claude-plugin/plugin.json` and both `version` fields in
`.claude-plugin/marketplace.json` to the same value.

## Files in scope

`scripts/{flow-status.sh,run-state.sh,codex-run.sh,parallel-chunks.sh,selftest.sh}`,
`skills/charles-flow/SKILL.md`, `.claude-plugin/*`, and one new command file if
A2 warrants one. Out of scope for edits: every other file in the repo.

## Grill verdict

_(pending — grill-rounds)_

## Sign-off

_(pending)_

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

  R6 (`6cbff8b`) added the identity the item asked for, but **not to every
  record**, and the plan's first draft said otherwise. `codex-run.sh:573-579`
  and `:610-617` write `flow_run_id`/`spec_path` only when the variables are
  non-empty, and the watchdog's terminal record at `codex-run.sh:112-120` never
  writes either. So a wrapper-death end record is unidentifiable even for a run
  whose start was identified.

  Attribution is also still timestamp-only in three places, not one:
  orphan detection (`flow-status.sh:175-180`), orphan attribution (`:187-215`)
  and ungraded-implement attribution (`:232-237`) all pass a bare timestamp to
  `dispatch_is_attributable`.

  Done when: the watchdog record carries the same identity fields as the wrapper
  record; a dispatch carrying `flow_run_id` is attributed by exact match and
  never by timestamp; a record without the field keeps the window, because 2000+
  historical records across 47 repos have no identity and must not change
  meaning; **the precedence when both kinds appear in one run is stated in a
  comment** — identity decides whenever present, the window only fills gaps, and
  an identified foreign record is excluded even if it falls inside the window;
  and `selftest.sh` asserts, at close time, all four cases in one fixture: an
  identified foreign orphan, an identified closing-run orphan, a legacy orphan,
  and a watchdog-generated end.

- **A3** — a run item can be resolved without hand-editing

  `run-state.sh` has `item` and `defer` but no verb to resolve one. Closing a
  run therefore means editing `- [ ]` to `- [x]` in `RUN.md` by hand, which is
  what this repo's own 2026-09-02 run had to do for eight items.

  Done when: `run-state.sh resolve <dir> [--run <id>] <selector> "<note>"` ticks
  a single open item and appends the note; the selector identifies one item
  unambiguously and refuses when it matches none or several, naming the
  candidates; and `selftest.sh` covers resolve, ambiguous selector, and no match.

- **A4** — an ambiguous open run is refused, not guessed

  `run-state.sh:107-170` `newest_open` picks the most recent open run when several
  are open, so a `phase` or `item` can land on the wrong one.
  `codex-run.sh:344-350` already refuses this ambiguity for implement dispatches
  and prints the candidates; `run-state.sh:162-166` refuses only in its own
  selector path, while the mutating verbs still take the newest.

  Done when: verbs that mutate a run refuse when several runs are open and no
  `--run` is given, printing the candidates the way `codex-run.sh` does; read-only
  paths (`show`) keep their current behaviour; and `selftest.sh` asserts the
  refusal names every candidate.

- **A5** — close without `--spec` still checks the run's recorded plan

  `run-state.sh:533` guards the sign-off gate behind `[ -n "$spec" ]`, so the
  gate at `:533-549` never runs on a bare close; recorded-spec counting at
  `:569-591` still happens, and outcome promotion at `:595-598` is skipped. A close with no `--spec` silently skips the run's own
  recorded plan and its outcome promotion, so the sign-off gate — the thing that
  makes a close mean something — is opt-in.

  **Migration risk, measured.** `run-state.sh:539-542` refuses a sign-off
  section containing no ticked line at all, not merely one with an unticked box.
  This repo has 13 `RUN.md` files, 12 closed and 1 open — and the open one is
  *this run*, whose plan currently has `## Sign-off` holding only `_(pending)_`.
  Under A5 a bare close of it would be refused. That is correct behaviour, but
  it must be a deliberate outcome rather than a surprise.

  Done when: a close with no `--spec` uses the spec recorded in `RUN.md` and
  applies the same gates; a run opened without any spec behaves as today; an
  unreadable or missing recorded spec is refused with a message naming it rather
  than silently skipping the gate; `--force` still overrides, as it does today;
  and `selftest.sh` covers three fixtures — an unticked `- [ ]` line, a sign-off
  section with no ticked line at all, and a run with no recorded spec.

- **A6** — `--req` validation does not depend on a filename convention

  `cdl-req-noplan`: `parallel-chunks.sh:45-52` derives the plan path only when
  the manifest name ends `.chunks.json`, and `:217-220` then omits `--plan`.

  **The bypass is narrower than the item claims.** With exactly one open run, or
  with `--run`, `codex-run.sh:351-404` still resolves and validates the run's
  recorded spec whatever the manifest is called. The real hole is the remaining
  case: no open run *and* no derived plan, where `codex-run.sh:354-364` returns
  success before any validation. The manifest schema (`parallel-chunks.sh:74-104`)
  has no plan field, so "resolve the plan from the manifest" is not currently a
  defined input and this requirement does not invent one.

  Done when: a `--req` dispatch with no open run and no resolvable plan is
  refused rather than dispatched unvalidated; the single-open-run and `--run`
  paths keep working unchanged; and `selftest.sh` covers the refusal and both
  still-valid paths.

- **A7** — the review diff shows the real change

  `codex-run.sh:858-873`: untracked files are appended to the review diff as
  `--- /dev/null`, `+++ b/path`, then content piped through `sed 's/^/+/'`, dropping the executable bit and inlining a symlink's target as
  though it were file text. The reviewer then grades something other than what
  was written — and this repo ships executable hooks and scripts, so a new hook
  landing non-executable is exactly the defect a reviewer should catch.

  **This needs a different diff construction, not an extra assertion.** The
  append format emits no `new file mode`, cannot express mode `100755` or
  symlink mode `120000`, and `sed` follows a symlink and inlines the target's
  text. Tracked mode changes already survive via `git diff HEAD`
  (`codex-run.sh:848-856`); only the untracked synthesis is blind.

  Done when: a new executable file carries `new file mode 100755` in the review
  diff and a new symlink is represented as a link rather than its target's
  contents; a binary untracked file is reported as binary rather than emitted as
  mangled text; the reviewer's inputs stay limited to `plan.md` and
  `changes.diff` (`codex-run.sh:921-925`); and `selftest.sh` asserts the
  executable, symlink and binary cases.

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

  `cdl-1788337312-10399`: `codex-run.sh:429` requires requirement identifiers as a `- **ID**` bullet,
  optionally checkboxed, terminated by `**`, whitespace, or a non-numeric dot
  suffix. Nothing documents that grammar, and the accepted form is broader than any prose
  in the repo suggests — `scripts/selftest.sh:1417-1444` already accepts
  `- **A1** alternate convention` and dotted suffixes.

  The cost is observed, not hypothetical: this run's predecessor wrote its plan
  with `### R1` headings, read perfectly, and was refused at dispatch once the
  plan was finished. That evidence is not reproducible from the committed tree —
  the file was converted to bullets before it was committed — so it is recorded
  here as an observation rather than offered as a citation.

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

  **An independent probe is the wrong mechanism.** DNS resolving proves nothing
  about the websocket; a probe can pass while the real request fails, and it
  disagrees with codex whenever a proxy, TLS setting or model route is involved.
  The causal signal is already captured: codex's own stderr goes to `$RUN.err`
  (`codex-run.sh:653-670`, `:785-790`) and is tailed on failure at `:1053-1057`.
  The observed run wrote `failed to lookup address information: Try again`
  there, repeatedly, minutes before the budget expired.

  Done when: the wrapper recognises a repeated provider-unreachable signal in the
  lane's own error stream and terminates the dispatch early with an exit code
  distinct from `124`, naming the cause; a lane that is merely slow is never
  terminated early; the detection degrades to today's behaviour if the error
  stream is unreadable; the threshold (how many occurrences, over what window)
  is stated in a comment rather than tuned invisibly; and `selftest.sh` covers a
  stub lane emitting the unreachable signal, and one that is simply slow.

## Green

`bash scripts/selftest.sh && bash scripts/doctor.sh`

Baseline: `338 passed, 0 failed`; `20 ok, 0 failing`. Any behaviour change bumps
`.claude-plugin/plugin.json` and both `version` fields in
`.claude-plugin/marketplace.json` to the same value.

## Files in scope

`scripts/{flow-status.sh,run-state.sh,codex-run.sh,parallel-chunks.sh,selftest.sh}`,
`skills/charles-flow/SKILL.md`, `.claude-plugin/*`, and one new command file if
A2 warrants one. Out of scope for edits: every other file in the repo.

## Grill verdict — 2026-09-03

- Rounds: 1 (unattended adversary; nothing survived needing the operator)
- Attacks raised: 10 — resolved from source: 3, changed the plan: 7, escalated: 0
- Plan changes:
  - **A2 deleted outright.** It proposed retiring old orphan dispatches because
    they "block close without --force". The premise is false: `flow-status.sh:157`
    routes them through `say_repo`, which increments `repo_issues`, and only
    `issues` drives the non-zero exit (`:398-400`). Proof: the 2026-09-02 run
    closed cleanly without `--force` while both orphans were present. The
    adversary also argued the mechanism was dangerous — a way to make evidence of
    an unresolved failure disappear, invisible to every consumer, since
    `flow-status.sh:175-180`, `verify-receipt.sh:40-58`, `lane-status.sh:60` and
    `unsourced.sh:52-56` recognise only start/end. Building it would have been
    worse than the problem it was solving, and there was no problem.
  - Seven of the plan's `file:line` citations were wrong — written from the
    previous run's line numbers, which moved across thirteen commits. All
    corrected against source.
  - A1's premise corrected: R6 did **not** add identity to every record. The
    fields are written only when non-empty and the watchdog's terminal record
    never writes them, so the requirement now includes fixing that, names all
    three timestamp-only attribution sites, and states the mixed-record
    precedence instead of leaving it to the implementer.
  - A5 gained the measured migration risk: `run-state.sh:539-542` refuses a
    sign-off section with no ticked line, and this run's own plan is in exactly
    that state, so A5 would refuse a bare close of it.
  - A6 narrowed to the actual bypass. Validation does not skip whenever the
    manifest is misnamed — only when there is no open run *and* no derived plan.
  - A7 rescoped: a mode change is not representable in the current append-based
    synthesis, so this needs a different diff construction, not a new assertion.
  - A9's supporting anecdote demoted to an observation: the `### R1` refusal did
    happen, but the file was converted before it was committed, so the evidence
    is not in the tree and must not be cited as though it were.
  - A10's mechanism replaced. An independent reachability probe is weaker than
    the signal already captured in the lane's own stderr, and can pass while the
    real request fails.
- Accepted risks:
  - **A1 leaves a genuinely incoherent evidence model for mixed logs.** Two
    records describing the same kind of work are judged by different rules purely
    by when they were written. The alternative — migrating 2000+ historical
    records across 47 repos — is worse. Identity wins where present; the window
    is the fallback, and it decays as history ages out.
  - **A10 is a heuristic on someone else's error text.** codex publishes no
    stable error schema, so a wording change upstream silently disables early
    termination. Chosen anyway because the failure mode is a silent nine-minute
    stall, and degrading to today's behaviour is safe.
  - **A7 cannot make an untracked binary reviewable**, only correctly labelled.
  - The three items excluded at the top of this plan stay excluded.
- Unresolved: none blocking.
- **Post-grill reversal, 2026-09-03: A10 implemented, measured, and reverted.**
  The requirement was built on a single observed incident. Before shipping, the
  heuristic was measured against all eight occurrences in this machine's dispatch
  history and failed both ways. Cadence is one provider error every 5-8 seconds,
  at most two in any ten-second window, so the implemented 3-in-10s threshold
  would never have fired — including on the stall it was written for. And the
  signal does not discriminate: five of the eight signalling lanes recovered and
  completed, one of them with seven occurrences, the same count as two that died.
  Any threshold loose enough to fire would kill working dispatches. Reverted in
  `58b3151`; the measurement is recorded on the backlog item so the next attempt
  starts from evidence rather than repeating the assumption.

## Sign-off

Green at close: `selftest 362 passed, 0 failed` · `doctor 22 ok, 0 failing`.
Baseline at open was `338 passed, 0 failed`. Version 2.36.0.

- [x] **A1** — close attribution uses the flow-run id, not a timestamp window — `f11d86b`, `2d0d52a`, `ebc5117`. The watchdog record now carries identity; attribution matches on `flow_run_id` when present and falls back to the window otherwise; identity outranks degradation. A parsing hole found in final review is fixed: `IFS=$'\t'` collapsed an empty middle field, so a record with `spec_path` and no `flow_run_id` had its spec parsed as the run id and was excluded as foreign — letting a close pass that should have blocked. Verified identical output on seven real repos.
- [x] **A3** — a run item can be resolved without hand-editing — `9fce6dc`. `run-state.sh resolve` ticks one item and appends a note; proved live: ambiguous selector names both candidates, unique selector resolves, no match refuses.
- [x] **A4** — an ambiguous open run is refused, not guessed — `9fce6dc`. Proved live with two open runs: `phase`, `resolve` and `close` all refuse with rc=2 and no `--run`. The final review called this unimplemented from the diff alone; running the code disproved that.
- [x] **A5** — close without `--spec` still checks the run's recorded plan — `9fce6dc`. Proved live: a bare close of a run whose recorded spec has a pending sign-off is refused with rc=6. Missing or unreadable recorded spec is refused by name; `--force` still overrides.
- [x] **A6** — `--req` validation does not depend on a filename convention — `d5e1daa`. The narrowed hole (no open run and no resolvable plan) is refused with exit 2; the single-open-run and `--run` paths are asserted unchanged.
- [x] **A7** — the review diff shows the real change — `5c04342`. Replaced hand-rolled synthesis with `git diff --no-index`. Proved on real files: `100755` for an executable, `120000` for a symlink with its target untraversed, binary reported as binary, plain text unchanged.
- [x] **A8** — attribution degradation is decided once, before any check runs — `a66033c`. Also caught and reverted a safety regression in the first implementation, where per-path canonicalisation failure would have turned a blocking ISSUE into a NOTE and let a close through.
- [x] **A9** — the plan requirement format is documented where plans are written — `23344b3`. The skill states the bullet grammar, including that identifiers below `## Sign-off` do not count, and a selftest keeps contract and documentation together.
- [x] **A10** — **implemented, measured, reverted** — `dae0f70`, reverted in `58b3151`. Not shipped, deliberately. Measured against all eight recorded occurrences: cadence is at most two errors per ten seconds against a three-in-ten threshold, so it would never have fired; and five of the eight signalling lanes recovered, one with seven occurrences — the same count as two that died. No threshold both fires and is safe. The measurement is on the backlog item so the next attempt starts from evidence.

---
name: charles-flow
description: Use FIRST, before brainstorming, debugging or TDD skills, for any bug report, feature, UI pass, or build/fix-all request in a repo with a .charles.toml. Triggers include "parallel agents", "sonnet fleet", "you be the orchestrator and reviewer", "fix all of these", "sdr flagged", "use the flow", "dispatch a fleet". Plan, implement, one isolated review, green, sign-off, close. Claude orchestrates; its own subagents explore and implement by default (codex, grok or omp only when asked); an isolated reviewer grades the diff against the plan. Not for repos without a .charles.toml.
---

# The flow

Default loop: **plan, implement, one isolated review, green, close.** The
orchestrator is a strong model; it reads code and makes small edits itself. Lanes
exist for breadth and parallelism, not as a toll booth.

**Gate:** needs a `.charles.toml` at the repo root. If there is none, say so and
offer `/charlesdr-dev-loop:init`.

## Select by work-kind

| Work-kind | Destination |
|---|---|
| Build something new | `/charlesdr-dev-loop:feature` |
| Something is broken | `/charlesdr-dev-loop:debug` |
| Improve existing behaviour | `/charlesdr-dev-loop:polish` |
| Small or medium ask, lean loop | `/charlesdr-dev-loop:fast-flow` |
| UI/UX work — router, not a flow | `/charlesdr-dev-loop:ui` |
| Publish a version | `/charlesdr-dev-loop:release` |
| Cross-repo run triage or recovery | `/charlesdr-dev-loop:ops` |

Feature, debug, polish and fast-flow run the loop below; each command says only what differs.

## The loop

1. **Understand.** Read the code yourself. Dispatch explore lanes only for broad,
   unfamiliar areas: several in parallel, each on a different angle, in the
   background. Baseline green before changing anything:
   `${CLAUDE_PLUGIN_ROOT}/scripts/green.sh "$(pwd)"`. Never attribute an
   existing red to your change.
2. **Anchor, then plan.** If the ask leaves a real fork (scope, user-visible
   behaviour, an irreversible choice), ask at most 3 questions in one message, each
   with your recommended default, then carry on with the defaults without waiting;
   fold late answers into the plan. One plan, `docs/specs/YYYY-MM-DD-<topic>.md`, written as checkable
   requirements, not steps (see Plans). Do not also write an implementation plan.
3. **Open the run.** `run-state.sh init "$(pwd)" <flow> "<goal>" --spec docs/specs/<plan>.md`.
4. **Implement.** Small, obvious edits: do them yourself. Anything bigger goes to
   implement lanes, one per disjoint slice, in parallel worktrees when there are
   2 or more (see Parallel). Dispatch with `--req <IDs>`.
5. **Review once.** One isolated review against the plan. At most 2 rounds:
   round 2 re-checks only round 1's Critical and Required findings. A GAPS verdict
   that only asks for more tests becomes a `DEFERRED` item, not another round. A
   third round only for money, auth/security or data-loss changes. Verify each
   finding against source before acting; never feed the reviewer the implementer's
   output.
   In a no-mistakes repo (`git remote get-url no-mistakes` succeeds) skip this
   review: commit on a feature branch and push through `/no-mistakes` with the
   plan's goal and requirements as `--intent`; its review, tests and CI are the
   gate. Then `run-state.sh phase "$(pwd)" review "no-mistakes: <outcome>, <PR url>"`.
6. **Green, sign off, close.** `green.sh`, complete `## Sign-off`, `run-state.sh close`.

Record `run-state.sh phase` at implement, review and green, with real output
(`47 passed, 0 failed`, not "tests pass"). A discovery you cannot finish now is
`run-state.sh defer "$(pwd)" "<text>"`, not a new dispatch.

Add on demand, not by default:

- **Grill** (`grill-rounds`): money, auth/security, migrations or destructive
  changes, 10+ requirements, or when the user asks. A missing grill verdict only
  warns; record `Grill waived: <reason>` in the plan when you skip it.
- **Brainstorm** (`superpowers:brainstorming`): only when the ask is genuinely open
  and the user is present. End it by writing the plan, not `writing-plans`.
- **Two parallel reviewers** (sol and terra): only for security- or
  concurrency-sensitive work. They overlap little; take the union.

## Plans

Write requirements: what must be true when done, which files are in scope, what
must keep working (the green command), and a nearby file to copy conventions from.
Checkable against a diff ("tighten card spacing"), never a step ("edit Card.tsx").
The reviewer grades the diff against this plan, so write it once and well.

Requirement IDs are top-level bullets: `-`, optionally `[ ]`, `[x]`, or `[X]`, then `**ID` terminated by `**`, whitespace, or a dot followed by a non-digit or end of line. Example: `- [ ] **R1** — ...`. IDs below `## Sign-off` do not count for dispatch.

For 2+ parallel-compatible slices, write `docs/specs/<plan>.chunks.json` once the
plan is settled and commit it with the plan: `[{"name":"api","files":["src/a.ts"],"req":["R1"],"task":"..."}]`.
No manifest for a single slice.

## Lanes

| Role | Lane | Default engine | Sandbox |
|---|---|---|---|
| Explore | `--lane explore` | `claude-explorer` (haiku); luna @ max when asked | read-only |
| Implement | `--lane implement` | `claude-implementer` (sonnet); luna @ max when asked | workspace-write |
| Review | `--lane review` | `claude-reviewer` (opus); sol @ medium when asked | read-only, isolated temp dir |

Default engine: `claude`, your own subagents. Use `luna`, `terra`, `grok`, `omp` or
`deepseek` only when the user asks (`--engine`, or an `/engine` preference). Failed luna/terra lanes fall back to grok,
failed grok to luna, with a `fallback_from:<engine> primary_rc:<n>` receipt.

**engine=claude:** one Agent call is the whole dispatch, no `codex-run` in Bash.
Spawn `charlesdr-dev-loop:claude-explorer` (haiku), `claude-implementer` (sonnet) or
`claude-reviewer` (opus) with header lines, a blank line, then the task:

```
charles-dir: <repo, or the worktree for implement>
charles-plan: <spec path>        # implement and review
charles-req: R1,R2               # implement only
charles-base: <ref>              # review of committed work only
```

A hook runs `codex-run --engine claude` behind the call with the same validation,
logs `start`, builds the reviewer's box and rewrites the prompt. A refusal comes
back as a denied call with the reason; fix it and spawn again. Foreground or
`run_in_background: true` both work. The `end` receipt is written when the subagent
finishes; write no receipt and delete no box yourself.

**engine=omp:** headless `omp` lanes: explore `cursor/composer-2.5-fast`, implement
`cursor/composer-2.5`, review `openai-codex/gpt-6.1-sol` (medium).
`omp:<provider>/<model>` overrides every lane; `--resume` is refused; no fallback.
Under an omp orchestrator, bash `async: true` is `run_in_background: true`.

**Orchestrating from omp:** if your tools include `task` and not `Agent`, dispatch
every lane with `task` (never `codex-run --lane` in bash, never detach or poll):
one item per lane, `agent: "claude-explorer"`, `"claude-implementer"` or
`"claude-reviewer"`, opening with the `charles-*:` headers above; a fan-out is one
`tasks[]` batch. The bridge adds a `charles-run:` line; do not cancel over it.
Never call Cursor's own `Task` tool ("Subagents are not implemented by this
client" means wrong tool; run the orchestrator on `anthropic/claude-opus-5-5`).
`codex-run` stays the tool for `run-state.sh`, `verify-receipt.sh`, `green.sh`.

## Dispatching codex, grok or omp lanes

The Bash tool caps a call at 600s, but over half of real lane runs take longer.
Explore and implement therefore run as a Bash call with `run_in_background: true`:

```bash
codex-run --lane <lane> --dir <repo> --timeout 2700 "<task>"
```

Do not redirect output, poll, or wrap it in a loop; the harness re-invokes you
when the process exits. For a fan-out, issue one background call per lane. A review
expected under about 9 minutes may run foreground with `--timeout 540`; a longer
one runs in the background with `--timeout 2700`. Never shorten a task to fit the
cap, and never re-dispatch on top of a RUNNING lane. Use `--fast` only for scoped
lookups; keep `max` where a wrong answer is expensive. Explorers: 3, at most 5. `codex-run` is on PATH (a SessionStart hook
links it); never hardcode a path into a checkout.

`--base <ref>` grades `<ref>..working-tree`; required once `HEAD` has moved, or the
reviewer sees an empty diff.

Lanes inherit no skills: name one in the brief (`ponytail`) or it does not apply.
Never point an unattended lane at interview skills (`grill-me`).

Implement lanes never run in a main checkout by default; use a `treehouse` or
`git worktree`. A second implement on one directory is refused (exit 4). Override
only deliberately with `--allow-main-tree` or `CHARLES_ALLOW_MAIN_TREE=1`.

**Verify every receipt mechanically:**

```bash
VERIFY="$(dirname "$(readlink -f "$(command -v codex-run)")")/verify-receipt.sh"
"$VERIFY" "$(pwd)" --lane <explore|implement|review> --since 1800
```

Exit 0: a lane ran, the report is admissible. Exit 1: nothing ran; discard the
report whole and record a `FAILED` item. Exit 2: all dispatches failed (`rc=143`
means killed mid-flight); the work is incomplete. The lane report's `codex/<model>`
line can be typed without running anything; `.charles/dispatches.jsonl` cannot.

**Lost completion signal:** `lane-status.sh` is the recovery probe, never a wait
loop (0 RUNNING, 1 DONE, 2 DEAD, 3 UNKNOWN). DEAD: record `FAILED`, no re-dispatch.

## Parallel

An implementer given twelve requirements does about 60% of each: 1-5 is one
slice, 6-10 two chunks on a natural seam, 11+ is probably two plans.

Read `parallel_min_chunks` from `.charles.toml` (default 2). With a valid
`.chunks.json` at that size or more and `treehouse` available:

```bash
SCRIPTS="$(dirname "$(readlink -f "$(command -v codex-run)")")"
"$SCRIPTS/parallel-chunks.sh" "$(pwd)" docs/specs/<plan>.chunks.json
```

Each chunk gets its own worktree and declares the files it may touch; a chunk that
writes outside its declaration is rejected and never merged. Declarations must be
disjoint, or overlap only on paths every overlapping chunk lists in `shared` (at
most two sharers; existing ordinary text files modified in place, no adds, deletes,
renames, mode changes, symlinks or binaries). Shared overlap requires the combined
green check, so `--no-green` is refused. With a run open, each chunk declares its
`req` IDs. Run `green.sh` once on the merged result, then `verify-receipt.sh` per
chunk.

Go serial for one chunk, a count below the threshold, undeclared overlap, an invalid manifest, or no `treehouse`. A batch that edits the flow's own
machinery (`parallel-chunks.sh`, `codex-run.sh`, anything the dispatcher runs) MUST
be serial: Bash reads a script lazily by byte offset, so rewriting a running
dispatcher kills it.

## Run state and close

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/run-state.sh init  "$(pwd)" <flow> "<goal>" --spec docs/specs/<plan>.md
${CLAUDE_PLUGIN_ROOT}/scripts/run-state.sh phase "$(pwd)" "<phase>" "<output>"
${CLAUDE_PLUGIN_ROOT}/scripts/run-state.sh item  "$(pwd)" <TYPE> "<text>"
${CLAUDE_PLUGIN_ROOT}/scripts/run-state.sh close "$(pwd)" "<outcome>" --spec docs/specs/<plan>.md
```

| Item type | Meaning |
|---|---|
| `BLOCKED-HUMAN` | needs a fact or reply only the user has |
| `PENDING-DECISION` | ready to act, needs their yes |
| `DEFERRED` | deliberately out of scope |
| `FAILED` | a lane died, work incomplete |

While a run is open, `codex-run --lane implement` requires `--req` and checks the
IDs against the run's spec. Close only when every item is resolved and the flow
reached its final phase; a run that died midway is abandoned (`/charlesdr-dev-loop:resolve`),
not finished. Runs idle for 7 days are abandoned automatically at session start.

`close` runs `flow-status.sh` and refuses (exit 5) on findings from this run:
implements with no later review, runs left open. Repo-wide backlog, a missing grill
verdict and changes no lane produced are NOTEs, not blockers. Run it before telling
the user you are done; `--force` closes anyway, deliberately.

**Sign-off.** Add `## Sign-off` to the plan, one line per requirement, copied
exactly, with pasted evidence:

```markdown
## Sign-off

- [x] <requirement, as written in the plan> — <evidence>
```

`close --spec` refuses (exit 6) when the section is missing or any `- [ ] ` line is
left; the gate matches single-spaced `- [x] ` / `- [ ] `. Append the closing
outcome to the committed plan; `.charles/` (run state, logs) is gitignored.

## Per-kind notes

- **Debug.** Reproduce and build the feedback loop first (`diagnosing-bugs`).
  Confirm the cause from source yourself, then plan the fix. The review asks "does
  this diff fix the stated cause and nothing else".
- **Polish.** One explore pass for gaps, must-haves and quality-of-life wins, one
  lens per call. Take the shortlist to the user, plan the survivor.
- **UI.** `/charlesdr-dev-loop:ui`. This one is a **router, not a flow**:
  `impeccable` owns taste. Route to ONE impeccable command; run one explore lane
  for the mechanical audit only (token drift, off-scale spacing, dead styles with
  `file:line`); taste disagreements become `BLOCKED-HUMAN`. Check contrast, focus,
  tab order and CLS did not regress; review for scope creep. Screenshots go to the
  user, never to a lane.
- **Release, ops.** `/charlesdr-dev-loop:release <semver>` and `:ops` own their steps.
  Never close, abandon or delete another repository's run without explicit human
  confirmation of repo, run id and action.
- **Fast.** `commands/fast-flow.md`: this loop on a small ask.

## Failure handling

**Never fall back to doing a failed lane's work inline.** Report the failure and
let the user decide (small edits you chose to make in step 4 are not this). Cap
green-fix cycles at 3, then record `FAILED` and stop.

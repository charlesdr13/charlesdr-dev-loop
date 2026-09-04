---
name: charles-flow
description: Charles's development loop — Claude Code orchestrates, Codex lanes do the exploring and the typing, and an isolated reviewer grades the result. Select the destination by work-kind: feature, debug, polish, UI/UX, release, or ops. Use whenever work in a repo with a .charles.toml means building a feature, fixing a bug, or hunting for improvements; also when the user says "use the flow", "dispatch a fleet", "codex fleet", or names a destination. Not for repos that have not opted in.
---

# The flow

Claude Code is the orchestrator and never the implementer. Exploration and
implementation go out to Codex lanes; grading goes to an isolated reviewer.

**Gate:** this only applies in a repo with a `.charles.toml` at its root. If
there isn't one, say so and offer `/charlesdr-dev-loop:init` — do not silently apply
the flow, and do not silently skip it either.

## Select by work-kind

Route the request by its deliverable:

| Work-kind | Destination |
|---|---|
| Build something new | `/charlesdr-dev-loop:feature` |
| Something is broken | `/charlesdr-dev-loop:debug` |
| Improve existing behaviour | `/charlesdr-dev-loop:polish` |
| Small or medium ask — adaptive fast lane | `/charlesdr-dev-loop:fast-flow` |
| UI/UX work — router, not a flow | `/charlesdr-dev-loop:ui` |
| Publish a version | `/charlesdr-dev-loop:release` |
| Cross-repo run triage or recovery | `/charlesdr-dev-loop:ops` |

## Lanes

| Role | Lane | Engine | Sandbox |
|---|---|---|---|
| Explore | `--lane explore` | gpt-5.6-luna @ max | read-only |
| Implement | `--lane implement` | gpt-5.6-luna @ max | workspace-write |
| Review | `--lane review` | sol @ medium; luna/terra @ max; `--effort` overrides | read-only, isolated temp dir |

Implement lanes never run against a main checkout by default; use a `treehouse`
worktree. If the parallel path refuses for a machinery reason, the fallback is
a hand-made worktree. An operator may deliberately waive the rule with
`--allow-main-tree` or `CHARLES_ALLOW_MAIN_TREE=1`; the override is logged in
the dispatch record.

Review accepts `--base <ref>` when grading already-committed work: it reviews
`<ref>..working-tree`, including uncommitted changes on top and untracked files.
The ref must resolve; without `--base`, review keeps its normal `HEAD` plus
cached plus untracked diff. `--base` is invalid on other lanes.
A review after `HEAD` has moved requires `--base <ref>`; otherwise the reviewer
sees an empty diff and grades nothing.

Review effort is positional: dispatch intermediate reviews with `--effort
medium`, and omit it for the final pre-close review so the model-aware default
stays sol @ medium and luna/terra @ max. This is a documented rule, not a flag.

**Long dispatches are normal — measured, not guessed.** Older all-lane baseline
(179 real runs; predates the implement remeasurement below): median successful
dispatch 8.8 min, p90 22.8 min, only 4% over 25 min. The Bash tool caps one call
at 600s, so **more than half of legitimate work cannot finish in the foreground.**
Explore and implement therefore use one primary mechanism:
the orchestrator invokes the Bash tool with `run_in_background: true` to run
`codex-run --lane <lane> --dir <repo> --timeout 2700 "<task>"`. The harness
re-invokes the orchestrator when the process exits — that callback is the
completion signal. Do not add polling loops or periodic `lane-status.sh` polling
as the primary wait. Reviews expected to finish within roughly 9 minutes may
run in the foreground with `--timeout 540`; a review expected to exceed that
(heavy diff, big repo, or terra at max) runs in the background with
`--timeout 2700` and the bounded completion protocol below.

Never shorten a task to fit the cap, and never re-dispatch on top of a RUNNING
lane. `--fast` is for wanting a shallower answer, not for beating the clock.

Add `--fast` (or `--effort high`) when latency matters more than the last
increment of rigour — scoped lookups, "where is X", a sanity check. Keep `max`
for anything where a plausible-but-wrong answer is expensive.

**luna at max is the primary engine for explore and implement.** Review uses
sol at medium by default, luna/terra at max, and `--effort` overrides.
deepseek-v4-flash is the fallback: the wrapper retries on it automatically when
luna fails, and you can force it with `--engine deepseek` when you deliberately
want a wide cheap sweep. Do not route to deepseek silently — luna first is the
default.

This costs real money on wide fan-outs. A 5-explorer luna sweep is not the
cents-per-task exercise the deepseek lane was, so size fleets to the question
rather than to the cap.

Fleet sizes: 3 explorers / 1 reviewer by default, 5 explorers at the very most.
Implementer count follows the plan: one for a serial slice, one per valid
chunk for the parallel path. Nothing enforces the explorer ceiling — it is
judgment, and at luna-at-max prices a 5-wide sweep is not free. Each parallel
implementer gets a `treehouse` worktree.

**This is now enforced, not advised.** A second `implement` dispatch on a
directory that already has one refuses with exit 4. Give the second one its own
worktree (`treehouse get`) or wait. Two writers on one tree interleave edits and
the loser is overwritten silently — observed live, not hypothetical.

### Direct background dispatch

Explore and serial implement are dispatched directly by the orchestrator. For
each, make a Bash tool call with `run_in_background: true`:

```bash
codex-run --lane <lane> --dir <repo> --timeout 2700 "<task>"
```

Do not redirect output — the harness captures each background call's output to
its own per-task file and tells you where. The harness re-invokes the
orchestrator when the process exits. For an explore fan-out, issue N separate
background Bash calls:

```bash
# Each line is a separate Bash tool call with run_in_background: true.
codex-run --lane explore --dir "$(pwd)" --timeout 2700 "<task 1>"
codex-run --lane explore --dir "$(pwd)" --timeout 2700 "<task 2>"
```

When you dispatch directly, you see the receipt yourself and nothing between
you and the lane can misreport what happened. Short reviews remain foreground
and isolated; reviews expected to exceed roughly 9 minutes use the background
path below with `--timeout 2700`. `codex-reviewer` is allowed for that lane.

The old wrapper layer bought context isolation but introduced a supervision
failure surface. Measured over one day: every supervision failure happened in
that layer and none in codex — reports claiming work was not done while files
were modified, wait loops that could not exit, 80k-token pollers, and
re-dispatch storms on top of live processes.

**The review agent is the only subagent used here.** Do not spawn `Explore`,
`general-purpose`, `Plan`, `feature-dev:*` or a language specialist to
investigate or write code in an opted-in repo — that is the same bypass as
editing inline, just wearing a hat. A hook will stop you, but the rule is the
skill's, not the hook's. Non-code agents (`google-drive`, `claude-code-guide`)
are unaffected.

The dispatcher is on PATH as `codex-run` (a SessionStart hook links it to the
installed plugin copy). Never hardcode a path into a checkout — an agent that
executes a working tree runs whatever half-finished state it is in.

**Skill-only install** (no plugin): call the dispatcher directly in a Bash tool
call with `run_in_background: true` for explore and implement:
`codex-run --lane ... --dir ...`. Keep fleets small and give parallel calls
separate `.charles/` logs.

## Plans: one artifact, and it is not a task list

Every flow writes exactly one plan. Do **not** also produce a separate
implementation plan, and do not invoke `superpowers:writing-plans` — luna at max
is being paid for its planning judgment, and handing it your ordered steps both
wastes that and tends to make the result worse, because it follows your sequence
instead of finding a better one.

When a plan yields 2+ parallel-compatible file slices, write or rewrite
`docs/specs/YYYY-MM-DD-<topic>.chunks.json` only after the plan is settled; in
flows with `grill-rounds`, that means after the grill settles, never during the
initial plan phase. Commit it alongside the plan. The manifest schema is one
object per slice:

```json
[
  {"name":"api","files":["src/a.ts"],"task":"..."}
]
```

Do not write a manifest for a single slice. The plan remains the review artifact;
the companion manifest is the dispatch contract for parallel implementers.

What a dispatch actually needs is a **brief**, which the plan already contains:

- what must be true when it is done, stated so a wrong answer is detectable
- which files it may touch, and which it must not
- what must keep working (the green command)
- a nearby file to copy conventions from — point, do not describe

The one exception is parallel implementers: parallel-compatible file slices are
a genuine implementation plan and the worktree path cannot work without the
companion manifest. A single implementer never needs one.

The same plan is consumed twice — by the grill before the work, and by the
isolated reviewer after it. That is why it must be requirements rather than
steps: "tighten the card spacing" is checkable against a diff, "step 3: edit
CampaignCard.tsx" is not.

## Finishing is not the same as dispatching

A dispatch succeeding proves a lane ran. It proves nothing about the flow. An
audit of 75 real dispatches found what that gap costs: **26 implements against 5
reviews** (two repos never reviewed at all), **13 plans carrying 1 grill
verdict**, and **4 runs open against 1 closed**. Every one of those looked fine,
because each individual dispatch had succeeded.

```bash
"$SCRIPTS/flow-status.sh" "$(pwd)"     # 0 clean · 1 outstanding
```

It reports implements with no later review, plans with no grill verdict, and
runs left open. At close time, only findings attributable to the selected run
gate; repo-wide backlog stays visible as notes, while unsourced working-tree
changes remain blocking. `run-state.sh close` runs it and **refuses to close**
when it fails (exit 5) — closing is where you declare the work done, so it is
where the check belongs. `--force` closes anyway, deliberately.
The small transition table in `scripts/flow.json` drives the expected-next hints;
`scripts/runs-sweep.sh [root...]` is the standing read-only hygiene sweep across
opted-in repos, so run it when `doctor` warns about open runs.

Run it before you tell the user you are finished. "The implementer succeeded" is
not an answer to "is it done".

## Recovery after a lost completion signal

Normally the harness callback tells the re-invoked orchestrator that a
background dispatch exited. If a session restarts or the harness dies before
that signal arrives, use `lane-status.sh` as the recovery probe:

```bash
"$SCRIPTS/lane-status.sh"     # 0 RUNNING · 1 DONE · 2 DEAD · 3 UNKNOWN
```

Never turn this recovery probe into a periodic wait. The old self-matching
process check ran 36 minutes against zero dispatches, with several such loops
keeping each other alive. `lane-status.sh` skips its own pid and parent before
deciding.

DEAD means over: record `FAILED`, do not wait, do not re-dispatch on top of it.
A dispatch that exceeded its own `--timeout` reports rc=124; one with no marker
at all was SIGKILLed, which nothing can trap, which is precisely why liveness is
answered by process rather than by file.

## What a lane inherits: nothing automatic, almost everything on request

Codex loads no Claude Code skill on its own — not `ponytail`, not your
CLAUDE.md, not your output style. But `~/.codex/skills/` mirrors 100+ of them
(impeccable, the gsap set, superpowers, tdd, the grill skills), and a lane told
to load one does. Verified: an implement lane read
`skills/ponytail/SKILL.md` and quoted it back verbatim.

So the rule is: **name the skill in the brief, or it does not apply.** The
direct implement dispatch already does this for `ponytail`.

**But check the skill's shape before pointing a lane at it.** `grill-me` and
`grill-with-docs` are interview skills — they ask one question at a time and
wait for a human. An unattended lane told to load one stalls on questions nobody
will answer. `grill-rounds` therefore borrows their checkable parts (terminology
conflicts, plan-versus-code contradictions, edge-case scenarios) and leaves the
interviewing to the round where a human is present.

## Where parallelism actually pays

Not everywhere. The explore and review figures below are from the older 179-run
population covering all lanes and predating the current implement measurement.
Measured, per lane:

- **explore** — median 5.7 min, p90 22 min. The slow lane, and already benefits
  from a 3+ background fan-out. This is where fan-out earns its cost.
- **implement** — the canonical measurement (full figures in `README.md`) covers
  successful dispatches only (`rc=0`): n=233 across all opted-in repos. Timeouts
  are counted separately: 25 of 258 ends (about 10%) hit the old 1800s cap.
  Parallel chunks are the default for disjoint or explicitly shared slices.
- **review** — median 1.7 min, read-only, no shared state. The cheapest lane,
  and the one place a second run is nearly free.

**Run two reviewers in parallel on anything security-, state- or
concurrency-sensitive.** Measured on this repo: sol-class and terra-class
reviews of the same code produced 13 findings with **one** overlap. A single
reviewer is not a weaker version of two — it is a different, mostly disjoint set.
Make each a separate Bash tool call with `run_in_background: true`:

```bash
# Each command is a separate Bash tool call with run_in_background: true.
"$SCRIPTS/codex-run.sh" --lane review --dir "$(pwd)" --plan <plan> --timeout 2700 "<focus>"
"$SCRIPTS/codex-run.sh" --lane review --engine terra --dir "$(pwd)" --plan <plan> --timeout 2700 "<focus>"
```

Each gets its own `mktemp -d`, so they cannot interfere. Take the union of the
findings and verify each one yourself before acting — two models agreeing is the
strongest signal available, and two disagreeing usually means both are partly
right.

## Chunk the dispatch, not just the scope

An implementer given twelve requirements does roughly 60% of each. The work
looks done, the diff is plausible, and the shortfall only surfaces in review —
or later, in production. Capping *scope* helps, but a single coherent slice can
still carry a long requirement list.

**Count the checkable requirements in the plan before dispatching.**

- **1-5** — usually one slice; split when the plan has a natural disjoint seam.
- **6-10** — two chunks, split on a natural seam (a layer, a module, a
  user-visible behaviour); disjoint chunks run concurrently and `green.sh`
  runs once on the combined result. A shared overlap is parallel-safe only
  when every overlapping chunk lists that path in `shared`, with no more than
  two sharers; otherwise run the chunks serially with `green.sh` between them.
- **11+** — three or more, and reconsider whether this is one plan. A plan with
  fifteen requirements is usually two features that have not been separated yet.

**Parallel is the default at 2+ valid chunks.** Three chunks at the canonical
successful-dispatch p90 of 19.1 min cost about 57 min serially against 19.1 min
in parallel, before any extra setup. Read `parallel_min_chunks` from
`.charles.toml`; it defaults to `2` and may be raised when a repo's measurements
justify a higher threshold.

For a settled plan at `docs/specs/<plan>.md`, read
`docs/specs/<plan>.chunks.json`. Use parallel when that valid manifest holds
`parallel_min_chunks` or more entries, its file declarations are disjoint or
overlap only on paths every overlapping chunk lists in `shared` (at most two
chunks per path), and `treehouse` is available. Shared manifests require the
combined green check, so `--no-green` is refused. Use serial when there is one
chunk, the count is below a raised threshold, overlap is not declared shared or
is asymmetric, the manifest is invalid, or `treehouse` is absent. Serial runs
still use `green.sh` between chunks.

```bash
SCRIPTS="$(dirname "$(readlink -f "$(command -v codex-run)")")"
CHUNKS="docs/specs/<plan>.chunks.json"
"$SCRIPTS/parallel-chunks.sh" "$(pwd)" "$CHUNKS"
# chunks.json: [{"name":"api","files":["src/a.ts"],"req":["R1"],"task":"..."}, ...]
# shared overlap: add "shared":["src/shared.ts"] to every overlapping chunk.
```

Each chunk gets its own `treehouse` worktree and **declares the files it may
touch**. Every `shared` path must also appear in that chunk's own `files`
declaration. The declaration is what makes this safe, not the worktree: overlap is
accepted only when every overlapping chunk declares the path in `shared`, no
path has more than two sharers, and the shared files are existing ordinary text
files modified in place by both chunks. Adds, deletes, renames, mode changes,
symlinks, and binary content are refused. Other overlapping declarations are
refused before anything is dispatched, and a chunk that writes outside its own
declaration is rejected and never merged. So a lane that quietly widens its
scope gets caught, which the serial path does not do.
When a run is open, every chunk declares its `req` identifiers; the runner
validates them against the plan and passes them to the child implement
dispatches.

A batch whose chunks modify the flow's own machinery — `parallel-chunks.sh`,
`codex-run.sh`, or anything the dispatcher executes — MUST run serially. Two
hazards make this mandatory: children execute the dispatcher from the runner's
script directory while the post-merge green check runs the merged root scripts;
and Bash reads a script lazily by byte offset, so rewriting the dispatcher while
it executes kills it mid-run at a stale offset. This happened in Chunk A: its
dispatcher died with `syntax error near unexpected token )` after the work had
completed.

Merging is per-file and only from accepted chunks. **Run `green.sh` once on the
combined result** — chunks that pass alone can still fail together.

Between chunks: run `green.sh`, and record progress with `run-state.sh phase`.
That is the point of chunking — a red result after chunk two implicates four
requirements, not twelve, and the run survives if the session dies midway.

Each chunk still gets its own receipt. `verify-receipt.sh` after each one, not
just at the end.

## Run state

Every flow run keeps durable state, because a run that ends in prose ends with
its open items lost:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/run-state.sh init  "$(pwd)" <flow> "<goal>" --spec docs/specs/<plan>.md
${CLAUDE_PLUGIN_ROOT}/scripts/run-state.sh phase "$(pwd)" "<phase>" "<pasted proof output>"
${CLAUDE_PLUGIN_ROOT}/scripts/run-state.sh item  "$(pwd)" <TYPE> "<text>"
${CLAUDE_PLUGIN_ROOT}/scripts/run-state.sh defer "$(pwd)" "<discovery>"
${CLAUDE_PLUGIN_ROOT}/scripts/run-state.sh close "$(pwd)" "<outcome>" --spec docs/specs/<plan>.md
```

`init` at the start, `phase` at every phase boundary (with the actual output,
per the proof protocol), `item` the moment something cannot be finished now:

| Type | Meaning |
|---|---|
| `BLOCKED-HUMAN` | needs a fact or reply only the user has |
| `PENDING-DECISION` | ready to act, needs their yes |
| `DEFERRED` | deliberately out of scope |
| `FAILED` | a lane died, work incomplete |

Open the run with `init --spec docs/specs/<plan>.md`. A discovery made
mid-flow is `DEFERRED`, not a new dispatch; `run-state.sh defer "$(pwd)"
"<text>"` is the one-command path. `codex-run --lane implement` takes
`--req A3,A5` and, while a run is open, refuses a dispatch without it, checks
the identifiers against that run's spec, and cannot dispatch a run opened
without a spec.

Close only when every item is resolved AND the flow reached its final phase. A
run that died at phase 3 with no open items is abandoned, not finished — leave
it open. `/charlesdr-dev-loop:resolve` picks up from there.

**Verify the receipt mechanically — do not eyeball it.** After every agent
returns, run:

```bash
# resolve from the symlink the SessionStart hook made, not from a variable
VERIFY="$(dirname "$(readlink -f "$(command -v codex-run)")")/verify-receipt.sh"
"$VERIFY" "$(pwd)" --lane <explore|implement|review> --since 1800
```

- exit 0 — a lane really ran; the report is admissible
- exit 1 — nothing ran. The agent answered from its own head. Discard the report
  entirely and record a `FAILED` item. Do not argue with it, do not keep the
  "useful parts" — an unrun lane's findings are unsourced by construction.
- exit 2 — dispatches exist but all failed. `rc=143` means the harness killed it
  mid-flight. The work is incomplete, not done.

The pasted `— codex/<model> · …` line is still required in the report, but it is
a courtesy for you to read: an agent can type that line without running anything.
`.charles/dispatches.jsonl` is written by the wrapper itself and cannot be forged
from inside a report, which is why the check reads that instead.

## Flow 1 — feature

1. **Brainstorm.** Use `superpowers:brainstorming`. **Override its terminal
   state:** it ends by invoking `writing-plans`; here it ends by handing the
   design to the grill. Do not invoke `writing-plans`.
2. **Explore.** Issue 3+ direct `codex-run --lane explore` calls as separate
   Bash calls with `run_in_background: true`, each on a different angle — prior
   art in this repo, the integration points, the failure modes, what a competing
   design would look like. Give each call its own `.charles/` log and synthesise
   the reports yourself; do not hand the raw reports to the user.
3. **Write the plan** to `docs/specs/YYYY-MM-DD-<topic>.md` — before the grill,
   not after. If it yields 2+ parallel-compatible file slices, record that a companion
   `.chunks.json` manifest will be needed, but do not write it yet.
   `grill-rounds` needs a file to attack and the review lane needs one to judge
   against; a plan that exists only in conversation can be neither. Write
   **checkable requirements**, not steps: what must be true when this is done,
   which files are in scope, what must keep working.
   Requirement IDs are top-level bullets: `-`, optionally `[ ]`, `[x]`, or `[X]`,
   then `**ID` terminated by `**`, whitespace, or a dot followed by a
   non-digit or end of line. Example: `- [ ] **R1** — ...`. IDs below `## Sign-off`
   do not count for dispatch.
4. **Grill.** `grill-rounds`, 2-3 rounds, amending the plan in place. Round 1 is
   adversarial and unattended. **Everything it could not settle is then
   collected and surfaced to the user in one message**, each item recorded as a
   `BLOCKED-HUMAN` run item first so the list survives a dead session. Nothing
   proceeds to implementation while one is unanswered. Three rounds is the
   ceiling — a fourth means the plan is wrong at a level grilling cannot fix.
   After the grill settles, write or rewrite the companion `.chunks.json`
   manifest beside the settled plan if it still yields 2+ parallel-compatible slices. Never
   dispatch a manifest written before the grill settled.
5. **Ground to truth.** The hard gate below. Do not proceed until all four pass.
6. **Implement.** Read `docs/specs/<plan>.chunks.json`, resolve
   `SCRIPTS="$(dirname "$(readlink -f "$(command -v codex-run)")")"` as in
   `commands/ui.md:22`, and invoke `"$SCRIPTS/parallel-chunks.sh" "$(pwd)"
   docs/specs/<plan>.chunks.json` when the valid manifest holds
   `parallel_min_chunks` or more entries. Otherwise dispatch serially with a
   Bash call marked `run_in_background: true` running
   `codex-run --lane implement --req <requirement IDs>`; one chunk, overlap not
   declared shared, an invalid manifest, missing `treehouse`, and any batch that
   edits the flow machinery are documented serial fallbacks.
7. **Review.** `codex-reviewer` against the plan. Isolated — never feed it the
   implementer's output.
8. **Debug loop.** `${CLAUDE_PLUGIN_ROOT}/scripts/green.sh "$(pwd)"` — exit 0 is
   green, and its output is the proof line. Not green → `charlesdr-dev-loop:debug`
   flow. Cap **3 cycles**, then record a `FAILED` item and stop. Do not grind.
9. **Sign off.** Complete the plan's `## Sign-off` section: one checked line per
   requirement, with the actual verification output as evidence.
10. **Close.** Use `run-state.sh close` with the plan's `--spec` path.

## Flow 2 — debug

1. `diagnosing-bugs` for the discipline — build the feedback loop first.
2. Explore fleet on the failing behaviour with direct `codex-run --lane explore`
   calls; make each Bash call with `run_in_background: true`. Each call gets the
   repro and is asked for a cause **plus** the `file:line` evidence trail, never
   a patch.
3. Ground to truth: confirm the cause yourself against source before fixing.
4. **Write the plan** to `docs/specs/YYYY-MM-DD-<bug>.md`: the confirmed cause,
   the intended fix scope, and the green command. Three short sections. If it
   yields 2+ parallel-compatible file slices, write or rewrite the companion `.chunks.json`
   manifest only after the plan is settled. This is what makes step 6 possible
   at all — the review lane needs a plan, and without one a debug fix ships
   unreviewed.
5. **Implement.** Read `docs/specs/<plan>.chunks.json`, resolve
   `SCRIPTS="$(dirname "$(readlink -f "$(command -v codex-run)")")"` as in
   `commands/ui.md:22`, and invoke `"$SCRIPTS/parallel-chunks.sh" "$(pwd)"
   docs/specs/<plan>.chunks.json` when the valid manifest holds
   `parallel_min_chunks` or more entries. Otherwise dispatch the fix serially
   with a Bash call marked `run_in_background: true` running
   `codex-run --lane implement --req <requirement IDs>`; use serial for one
   chunk, overlap not declared shared, an invalid manifest, missing `treehouse`,
   or a batch that edits the flow machinery.
6. `codex-reviewer` against that plan — "does this diff fix the stated cause and
   nothing else".
7. Verify: `${CLAUDE_PLUGIN_ROOT}/scripts/green.sh "$(pwd)"`, paste its output.
   Same 3-cycle cap, then a `FAILED` item.
8. **Sign off.** Complete the plan's `## Sign-off` section: one checked line per
   requirement, with the actual verification output as evidence.
9. **Close.** Use `run-state.sh close` with the plan's `--spec` path.

## Flow 3 — polish

1. Direct `codex-run --lane explore` calls with `run_in_background: true`, asked
   for gaps, must-haves, and quality-of-life wins — one call per lens, not three
   asked the same question.
2. Brainstorm the shortlist with the user.
3. Grill (`grill-rounds`), and write the survivor to `docs/specs/`. After the
   grill settles, write or rewrite the companion `.chunks.json` manifest beside
   it if it yields 2+ parallel-compatible file slices.
4. **Implement.** Read `docs/specs/<plan>.chunks.json`, resolve
   `SCRIPTS="$(dirname "$(readlink -f "$(command -v codex-run)")")"` as in
   `commands/ui.md:22`, and invoke `"$SCRIPTS/parallel-chunks.sh" "$(pwd)"
   docs/specs/<plan>.chunks.json` when the valid manifest holds
   `parallel_min_chunks` or more entries. Otherwise dispatch serially with a
   Bash call marked `run_in_background: true` running
   `codex-run --lane implement --req <requirement IDs>`; use serial for one
   chunk, overlap not declared shared, an invalid manifest, missing `treehouse`,
   or a batch that edits the flow machinery.
5. `codex-reviewer` against that plan.
6. Verify with `green.sh`.
7. **Sign off.** Complete the plan's `## Sign-off` section: one checked line per
   requirement, with the actual verification output as evidence.
8. **Close.** Use `run-state.sh close` with the plan's `--spec` path.

## Flow 4 — UI polish

Use `/charlesdr-dev-loop:ui`. This one is a **router, not a flow**: `impeccable`
is a 27-command UI system and owns the taste judgment. Do not rebuild it here.

1. Baseline green, open the run.
2. Route to ONE impeccable command — `polish`, `audit`, `critique`, `animate`,
   `optimize`, `bolder`/`quieter`, or `live` (needs a dev server). Motion work
   also loads the gsap skills; `gsap-performance` before shipping animation.
3. In parallel, one direct `codex-run --lane explore` call with
   `run_in_background: true` for the mechanical audit only — token drift,
   off-scale spacing, duplicate variants, dead styles, with `file:line`. It
   cannot see, so never ask it for an aesthetic opinion.
4. Merge: impeccable leads, the codex audit is the mechanical backlog. Plan to
   `docs/specs/`. Taste disagreements become `BLOCKED-HUMAN` items.
5. Verify green, confirm no regression in contrast/focus/tab-order/CLS, and run
   `codex-reviewer` for scope creep — the characteristic failure of polish work.
6. Complete the plan's `## Sign-off` section, then route through the same
   `run-state.sh close` command as the other flows.

Scope is one route or one component. Screenshots and running apps go to the
user, never to a lane: luna gets a diff, never a picture.

## Flow 5 — release

Use `/charlesdr-dev-loop:release <semver>`. It wraps `scripts/release.sh`.

1. **Guard.** Open the `release` run and confirm `.claude-plugin/` is clean.
2. **Green.** Run the repository's green command and record the `green` phase.
3. **Version.** Write the semver to the plugin and marketplace metadata.
4. **Ship.** Install and verify the cache, relink `codex-run`, and run doctor.
   Record `ship` only after those checks pass.
5. **Close.** Use `run-state.sh close` after `ship`. On failure, record a
   `FAILED` item and leave the run open.

## Flow 6 — ops

Use `/charlesdr-dev-loop:ops`. The ops run itself opens in the repository where
the command was invoked.

1. **Survey.** Run `runs-sweep.sh` as the read-only survey. It covers the
   supplied roots or its defaults, never the whole filesystem, and stays
   read-only. Record the roots in the ops run.
2. **Select.** Read the sweep and record the exact repository and run id for
   every possible action.
3. **Recover only after confirmation.** Use the existing
   `run-state.sh reopen` and `run-state.sh abandon` verbs. **Never close,
   abandon, or delete another repository's run without explicit human
   confirmation** of the exact repository, run id, and action; without it,
   leave that run alone.
4. **Report.** Record the findings, roots, confirmations, recovery results,
   and skipped targets in the ops run.
5. **Close.** Close only the ops run opened in the command's repository, after
   recording `report`. If its local close is refused, report the reason and
   leave it open.

## Flow 7 — fast

Follow `commands/fast-flow.md` for the full command contract:

1. Classify the ask and run the green baseline.
2. Explore with one read-only luna lane in the background.
3. Write the bounded plan, query prior art when configured, and open the fast run.
4. Run grill round 1 with the codex adversary.
5. Run exactly grill round 2 as one batched human message; never run round 3.
6. Implement once in a worktree with one background luna lane and merge it back.
7. Run one isolated default review, with one implement cycle for verified gaps.
8. Verify green, sign off with pasted output, and close the run.

The command file also defines the route-out rules, failure handling, two-cycle
cap, and deliberate skips.

## The ground-truth gate

A hard gate, not a checklist to wave at. All four, before any implementation:

1. **Claims are sourced.** Every factual claim in the plan cites `file:line` in
   this repo. Unsourced claims get verified or deleted — extrapolating from a
   package name is not verification.
2. **Baseline is green.** `${CLAUDE_PLUGIN_ROOT}/scripts/green.sh "$(pwd)"`
   *before* touching anything. If it is already red, you are about to attribute
   an existing failure to your change. Never eyeball this — run it.
3. **Prior art checked.** Search the repo, then whatever knowledge base this
   team keeps (a wiki, an ADR directory, a KG tool if one is configured). If the
   thing already exists, building it again is the most expensive possible outcome.
4. **Manifest scope matches.** When present, a companion manifest's declared
   files match the plan's stated scope.

## The sign-off gate

The plan is the checklist at close time. Add a `## Sign-off` section and copy
each requirement exactly, one per line, with evidence from the verification:

```markdown
## Sign-off

- [x] <requirement, as written in the plan> — <evidence>
```

Evidence is output, not assertion: paste the command output or other proof
required by the plan. `run-state.sh close --spec <file>` refuses with exit 6 if
the section is missing or contains an unticked `- [ ]` line. Fix the requirement
or record it as a run item; it does not ride out under a closed run. `--force`
deliberately overrides this gate.
The gate matches checkbox lines exactly as `- [x] ` / `- [ ] ` (single spaces); a section with no ticked line is refused.

## Proof protocol

A step is not done until you have the output. `"47 passed, 0 failed"`, not
"tests pass". `"312 lines"`, not "file written". Assertions without output are
how a loop convinces itself it is finished.

## Failure handling

A dispatch that fails on luna gets one deepseek rescue (the wrapper does this
for you). It prints a loud `fallback_from:<engine> primary_rc:<n>` receipt; if
the rescue also fails, the dispatch stops. **Never fall back to doing the work
inline.** A fallback that fires on any error turns "always dispatch" into
"dispatch when convenient", which is the same as not having the system at all.
Report the failure and let the user decide.

## Artifacts

- Plan and grill verdict → `docs/specs/YYYY-MM-DD-<topic>.md`, committed.
  **Every flow writes one** — debug and polish included, or their fix cannot be
  reviewed. A settled plan with 2+ parallel-compatible file slices also commits the
  adjacent `.chunks.json` manifest, written or rewritten after the grill
  settles.
- Run state, dispatch log, transcripts, hook state → `.charles/`, gitignored.
- The closing outcome paragraph is appended to the committed plan, so the
  durable half survives without committing forensic detail nobody rereads.

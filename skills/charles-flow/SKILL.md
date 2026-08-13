---
name: charles-flow
description: Charles's development loop — Claude Code orchestrates, Codex lanes do the exploring and the typing, and an isolated reviewer grades the result. Use whenever work in a repo with a .charles.toml means building a feature, fixing a bug, or hunting for improvements; also when the user says "use the flow", "dispatch a fleet", "codex fleet", or names the feature/debug/polish flow. Not for repos that have not opted in.
---

# The flow

Claude Code is the orchestrator and never the implementer. Exploration and
implementation go out to Codex lanes; grading goes to an isolated reviewer.

**Gate:** this only applies in a repo with a `.charles.toml` at its root. If
there isn't one, say so and offer `/charlesdr-dev-loop:init` — do not silently apply
the flow, and do not silently skip it either.

## Lanes

| Role | Lane | Engine | Sandbox |
|---|---|---|---|
| Explore | `--lane explore` | gpt-5.6-luna @ max | read-only |
| Implement | `--lane implement` | gpt-5.6-luna @ max | workspace-write |
| Review | `--lane review` | gpt-5.6-sol @ medium | read-only, isolated temp dir |

**Long dispatches are normal — measured, not guessed.** Across 179 real runs:
median successful dispatch 8.8 min, p90 22.8 min, only 4% over 25 min. The Bash
tool caps one call at 600s, so **more than half of legitimate work cannot finish
in the foreground.** Explore and implement therefore use one primary mechanism:
the orchestrator invokes the Bash tool with `run_in_background: true` to run
`codex-run --lane <lane> --dir <repo> --timeout 1800 "<task>"`. The harness
re-invokes the orchestrator when the process exits — that callback is the
completion signal. Do not add polling loops or periodic `lane-status.sh` polling
as the primary wait. Review runs in the foreground: its p90 is 3.2 min and none
has ever exceeded 540s.

Never shorten a task to fit the cap, and never re-dispatch on top of a RUNNING
lane. `--fast` is for wanting a shallower answer, not for beating the clock.

Add `--fast` (or `--effort high`) when latency matters more than the last
increment of rigour — scoped lookups, "where is X", a sanity check. Keep `max`
for anything where a plausible-but-wrong answer is expensive.

**luna at max is the primary engine for every dispatch.** deepseek-v4-flash is
the fallback: the wrapper retries on it automatically when luna fails, and you
can force it with `--engine deepseek` when you deliberately want a wide cheap
sweep. Do not route to deepseek silently — luna first is the default.

This costs real money on wide fan-outs. A 5-explorer luna sweep is not the
cents-per-task exercise the deepseek lane was, so size fleets to the question
rather than to the cap.

Fleet sizes: 3 explorers / 1 implementer / 1 reviewer by default, 5 explorers at
the very most. Nothing enforces that ceiling — it is judgment, and at luna-at-max
prices a 5-wide sweep is not free. More than one implementer requires the plan to
declare the slices disjoint, and then each gets a `treehouse` worktree.

**This is now enforced, not advised.** A second `implement` dispatch on a
directory that already has one refuses with exit 4. Give the second one its own
worktree (`treehouse get`) or wait. Two writers on one tree interleave edits and
the loser is overwritten silently — observed live, not hypothetical.

### Direct background dispatch

Explore and implement are dispatched directly by the orchestrator. For each,
make a Bash tool call with `run_in_background: true`:

```bash
codex-run --lane <lane> --dir <repo> --timeout 1800 "<task>"
```

Do not redirect output — the harness captures each background call's output to
its own per-task file and tells you where. The harness re-invokes the
orchestrator when the process exits. For a parallel fan-out, issue N separate
background Bash calls:

```bash
# Each line is a separate Bash tool call with run_in_background: true.
codex-run --lane explore --dir "$(pwd)" --timeout 1800 "<task 1>"
codex-run --lane explore --dir "$(pwd)" --timeout 1800 "<task 2>"
```

When you dispatch directly, you see the receipt yourself and nothing between
you and the lane can misreport what happened. Review remains foreground and
isolated; `codex-reviewer` is allowed for that lane.

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

**Skill-only install** (no plugin): call the dispatcher directly as
`codex-run --lane ... --dir ...`. The same background Bash mechanism applies, so
keep fleets small and give parallel calls separate `.charles/` logs.

## Plans: one artifact, and it is not a task list

Every flow writes exactly one plan. Do **not** also produce a separate
implementation plan, and do not invoke `superpowers:writing-plans` — luna at max
is being paid for its planning judgment, and handing it your ordered steps both
wastes that and tends to make the result worse, because it follows your sequence
instead of finding a better one.

What a dispatch actually needs is a **brief**, which the plan already contains:

- what must be true when it is done, stated so a wrong answer is detectable
- which files it may touch, and which it must not
- what must keep working (the green command)
- a nearby file to copy conventions from — point, do not describe

The one exception is parallel implementers: disjoint file slices are a genuine
implementation plan and the worktree path cannot work without one. A single
implementer, which is the default, never needs it.

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
runs left open. `run-state.sh close` runs it and **refuses to close** when it
fails (exit 5) — closing is where you declare the work done, so it is where the
check belongs. `--force` closes anyway, deliberately.

Run it before you tell the user you are finished. "The implementer succeeded" is
not an answer to "is it done".

## Recovery after a lost completion signal

Normally the harness callback tells the re-invoked orchestrator that a
background dispatch exited. If a session restarts or the harness dies before
that signal arrives, use `lane-status.sh` as the recovery probe:

```bash
"$SCRIPTS/lane-status.sh"     # 0 RUNNING · 1 DONE · 2 DEAD
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

Not everywhere. Measured, per lane:

- **explore** — median 5.7 min, p90 22 min. The slow lane, and already benefits
  from a 3+ background fan-out. This is where fan-out earns its cost.
- **implement** — median 1.9 min. Parallelising this buys almost nothing and
  costs a worktree per writer plus a merge. Chunks run sequentially with
  `green.sh` between them, which localises failure to four requirements instead
  of twelve. Parallel implementers stay reserved for plans that genuinely
  declare disjoint slices.
- **review** — median 1.7 min, read-only, no shared state. The cheapest lane,
  and the one place a second run is nearly free.

**Run two reviewers in parallel on anything security-, state- or
concurrency-sensitive.** Measured on this repo: sol-class and terra-class
reviews of the same code produced 13 findings with **one** overlap. A single
reviewer is not a weaker version of two — it is a different, mostly disjoint set.

```bash
"$SCRIPTS/codex-run.sh" --lane review --dir "$(pwd)" --plan <plan> "<focus>" &
"$SCRIPTS/codex-run.sh" --lane review --engine terra --dir "$(pwd)" --plan <plan> "<focus>" &
wait
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

- **1-5** — one dispatch. Splitting costs more than it saves.
- **6-10** — two dispatches, split on a natural seam (a layer, a module, a
  user-visible behaviour), `green.sh` between them.
- **11+** — three or more, and reconsider whether this is one plan. A plan with
  fifteen requirements is usually two features that have not been separated yet.

**Serial by default, parallel when it actually pays.** The median implement is
1.9 min, so parallelising two short chunks buys nothing. But p90 is 19.5 min,
and three long disjoint chunks cost ~30 min serially against ~10 in parallel.

Go parallel when **all three** hold: 3+ chunks, genuinely disjoint file sets,
and each chunk non-trivial. Otherwise sequential, with `green.sh` between chunks
so a failure implicates four requirements instead of twelve.

```bash
"$SCRIPTS/parallel-chunks.sh" "$(pwd)" chunks.json
# chunks.json: [{"name":"api","files":["src/a.ts"],"task":"..."}, ...]
```

Each chunk gets its own `treehouse` worktree and **declares the files it may
touch**. The declaration is what makes this safe, not the worktree: overlapping
declarations are refused before anything is dispatched, and a chunk that writes
outside its own declaration is rejected and never merged. So a lane that
quietly widens its scope gets caught, which the serial path does not do.

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
${CLAUDE_PLUGIN_ROOT}/scripts/run-state.sh init  "$(pwd)" <flow> "<goal>"
${CLAUDE_PLUGIN_ROOT}/scripts/run-state.sh phase "$(pwd)" "<phase>" "<pasted proof output>"
${CLAUDE_PLUGIN_ROOT}/scripts/run-state.sh item  "$(pwd)" <TYPE> "<text>"
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
   background Bash calls, each on a different angle — prior art in this repo,
   the integration points, the failure modes, what a competing design would
   look like. Give each call its own `.charles/` log and synthesise the reports
   yourself; do not hand the raw reports to the user.
3. **Write the plan** to `docs/specs/YYYY-MM-DD-<topic>.md` — before the grill,
   not after. `grill-rounds` needs a file to attack and the review lane needs one
   to judge against; a plan that exists only in conversation can be neither.
   Write **checkable requirements**, not steps: what must be true when this is
   done, which files are in scope, what must keep working.
4. **Grill.** `grill-rounds`, 2-3 rounds, amending the plan in place. Round 1 is
   adversarial and unattended. **Everything it could not settle is then
   collected and surfaced to the user in one message**, each item recorded as a
   `BLOCKED-HUMAN` run item first so the list survives a dead session. Nothing
   proceeds to implementation while one is unanswered. Three rounds is the
   ceiling — a fourth means the plan is wrong at a level grilling cannot fix.
5. **Ground to truth.** The hard gate below. Do not proceed until all three pass.
6. **Implement.** Issue the direct `codex-run --lane implement` command as a
   background Bash call with `--timeout 1800` and its own `.charles/` log.
7. **Review.** `codex-reviewer` against the plan. Isolated — never feed it the
   implementer's output.
8. **Debug loop.** `${CLAUDE_PLUGIN_ROOT}/scripts/green.sh "$(pwd)"` — exit 0 is
   green, and its output is the proof line. Not green → `charlesdr-dev-loop:debug`
   flow. Cap **3 cycles**, then record a `FAILED` item and stop. Do not grind.

## Flow 2 — debug

1. `diagnosing-bugs` for the discipline — build the feedback loop first.
2. Explore fleet on the failing behaviour with direct background
   `codex-run --lane explore` calls. Each call gets the repro and is asked for a
   cause **plus** the `file:line` evidence trail, never a patch.
3. Ground to truth: confirm the cause yourself against source before fixing.
4. **Write the plan** to `docs/specs/YYYY-MM-DD-<bug>.md`: the confirmed cause,
   the intended fix scope, and the green command. Three short sections. This is
   what makes step 6 possible at all — the review lane needs a plan, and without
   one a debug fix ships unreviewed.
5. Direct `codex-run --lane implement` for the fix, as a background Bash call
   with `--timeout 1800`.
6. `codex-reviewer` against that plan — "does this diff fix the stated cause and
   nothing else".
7. Verify: `${CLAUDE_PLUGIN_ROOT}/scripts/green.sh "$(pwd)"`, paste its output.
   Same 3-cycle cap, then a `FAILED` item.

## Flow 3 — polish

1. Direct background `codex-run --lane explore` calls asked for gaps, must-haves,
   and quality-of-life wins — one call per lens, not three asked the same
   question.
2. Brainstorm the shortlist with the user.
3. Grill (`grill-rounds`), and write the survivor to `docs/specs/`.
4. Direct background `codex-run --lane implement` call.
5. `codex-reviewer` against that plan.
6. Verify with `green.sh`.

## Flow 4 — UI polish

Use `/charlesdr-dev-loop:ui`. This one is a **router, not a flow**: `impeccable`
is a 27-command UI system and owns the taste judgment. Do not rebuild it here.

1. Baseline green, open the run.
2. Route to ONE impeccable command — `polish`, `audit`, `critique`, `animate`,
   `optimize`, `bolder`/`quieter`, or `live` (needs a dev server). Motion work
   also loads the gsap skills; `gsap-performance` before shipping animation.
3. In parallel, one direct background `codex-run --lane explore` call for the
   mechanical audit only — token drift, off-scale spacing, duplicate variants,
   dead styles, with `file:line`. It cannot see, so never ask it for an aesthetic
   opinion.
4. Merge: impeccable leads, the codex audit is the mechanical backlog. Plan to
   `docs/specs/`. Taste disagreements become `BLOCKED-HUMAN` items.
5. Verify green, confirm no regression in contrast/focus/tab-order/CLS, and run
   `codex-reviewer` for scope creep — the characteristic failure of polish work.

Scope is one route or one component. Screenshots and running apps go to the
user, never to a lane: luna gets a diff, never a picture.

## The ground-truth gate

A hard gate, not a checklist to wave at. All three, before any implementation:

1. **Claims are sourced.** Every factual claim in the plan cites `file:line` in
   this repo. Unsourced claims get verified or deleted — extrapolating from a
   package name is not verification.
2. **Baseline is green.** `${CLAUDE_PLUGIN_ROOT}/scripts/green.sh "$(pwd)"`
   *before* touching anything. If it is already red, you are about to attribute
   an existing failure to your change. Never eyeball this — run it.
3. **Prior art checked.** Search the repo, then whatever knowledge base this
   team keeps (a wiki, an ADR directory, a KG tool if one is configured). If the
   thing already exists, building it again is the most expensive possible outcome.

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
  reviewed.
- Run state, dispatch log, transcripts, hook state → `.charles/`, gitignored.
- The closing outcome paragraph is appended to the committed plan, so the
  durable half survives without committing forensic detail nobody rereads.

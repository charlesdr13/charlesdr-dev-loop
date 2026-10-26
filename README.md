# charlesdr-dev-loop

Claude Code stops writing your code and starts running the shop. Exploration,
implementation and review go to Claude's own subagents by default (haiku explorer,
sonnet implementer, opus reviewer). Codex (luna/terra/sol) or grok lanes run when
you ask for them with `--engine` or `/engine`.

```bash
cd your-repo
/charlesdr-dev-loop:init                          # opt this repo in, once
/charlesdr-dev-loop:feature add rate limiting to the API
```

That single command runs the lean loop: read the code (explore lanes with
`run_in_background: true` only for broad unfamiliar areas), one plan with checkable
requirements, implementation (small edits by the orchestrator, bigger slices on
lanes, in parallel worktrees when there are 2+), one isolated review, then your
test command until it passes. A grill is added only for risky plans.

---

## The loop

```mermaid
flowchart TD
    REQ(["add rate limiting to the API"]) --> GATE{".charles.toml<br/>in this repo?"}
    GATE -->|no| INIT["/init — opt in, infer green"]
    INIT --> GATE
    GATE -->|yes| READ["read the code · baseline green<br/>explore lanes only if broad<br/><i>run_in_background: true</i>"]

    READ --> PLAN["one plan → docs/specs/<br/>checkable requirement IDs"]
    PLAN -.->|"risky: money · auth · migrations · 10+ reqs"| GRILL["grill-rounds"]
    GRILL -.-> IMPL
    PLAN --> IMPL["implement<br/>small edits inline · bigger slices on lanes<br/>parallel worktrees at 2+ slices"]
    IMPL --> REV["one isolated review, max 2 rounds<br/><b>sol @ medium · luna/terra @ max</b>"]
    REV --> GREEN{"green.sh<br/>real exit code"}

    GREEN -->|"red, under 3 cycles"| IMPL
    GREEN -->|"red, 3 cycles"| FAILED["FAILED item"]
    GREEN -->|green| CLOSE["sign-off · close run<br/>outcome → the committed plan"]

    FAILED --> RESOLVE["/resolve<br/>next session picks up here"]
    RESOLVE --> IMPL

    classDef lane fill:#2d6a9f,stroke:#1b4368,color:#fff
    classDef gate fill:#8a6d1f,stroke:#5c4813,color:#fff
    classDef term fill:#2f6b45,stroke:#1c4029,color:#fff
    class READ,IMPL,REV lane
    class GATE,GREEN gate
    class CLOSE,RESOLVE term
```

Blue may run on a lane, amber is a gate that can send you backwards, green is an
exit. The reviewer is always isolated; everything else is the orchestrator's call.

---

## The problem this solves

An agent that writes code and then checks its own code will tell you it works.
Not from dishonesty, but because the same reasoning that produced the bug
produces the argument that it is not a bug. Self-evaluation is an agreement
loop wearing the costume of a review.

The usual fix is to ask the model to be more critical. That fails, because you
are asking the biased party to correct for its own bias.

The fix here is structural. Three separations, none of which rely on a model
choosing to behave:

**The orchestrator plans, routes, and judges.** It may make small edits itself;
bigger slices go to implement lanes, one per disjoint slice. Nothing gates its
edits or its subagents.

**The reviewer cannot see the implementer.** The review lane runs in a
`mktemp -d` containing exactly two files, `plan.md` and `changes.diff`,
read-only. It cannot reach the repo, the transcripts, or `git log`. It is not
asked to ignore the implementer's reasoning; it is unable to find it.

```mermaid
flowchart LR
    subgraph REPO["your repo"]
        SRC["source files"]
        TRANS[".charles/ transcripts<br/>git log · test output"]
        SPEC["docs/specs/plan.md"]
    end

    IMPL["implementer<br/>luna @ max"] -->|writes| SRC
    IMPL -->|reasoning| TRANS

    subgraph BOX["mktemp -d — everything the reviewer can see"]
        PLANMD["plan.md"]
        DIFF["changes.diff"]
    end

    SPEC -->|copied| PLANMD
    SRC -->|git diff HEAD| DIFF
    BOX --> REV["reviewer<br/>sol @ medium · luna/terra @ max<br/>--effort overrides · read-only"]

    TRANS -.->|"unreachable — different filesystem"| REV
    SRC  -.->|"unreachable"| REV

    classDef hidden fill:#7a2f2f,stroke:#4a1c1c,color:#fff
    classDef seen fill:#2f6b45,stroke:#1c4029,color:#fff
    class TRANS hidden
    class PLANMD,DIFF seen
```

The dotted edges are not policy. There is no path from the implementer's
reasoning to the reviewer's working directory, so there is nothing to enforce.

**Risky plans get a grill before the code.** For money, auth/security,
migrations or destructive changes, or 10+ requirements, an adversary attacks the
plan and every attack is answered from source before implementation starts. A
missing grill verdict only warns.

---

## Requirements

This wraps tools it does not ship. Before installing:

- **[Codex CLI](https://github.com/openai/codex)** on PATH, authenticated.
- **A `luna` Codex profile** at `~/.codex/luna.config.toml` — this is the
  primary engine, and without it nothing dispatches:

  ```toml
  model = "gpt-6-luna"
  model_reasoning_effort = "max"
  ```

- **`jq`**, or the hooks fail open and silently allow everything.
- **Optional — the deepseek engine.** Used only with an explicit
  `--engine deepseek`. It shells out to a `codex-ds.sh`
  wrapper at `~/.claude/skills/codex-deepseek/scripts/codex-ds.sh`, which is
  **not included in this repo**. Without it you lose only that explicit
  engine, not a lane; it is not an automatic fallback (luna and terra fall back to
  grok, grok to luna). Point `DS_SCRIPT` in
  `scripts/codex-run.sh` at your own wrapper if you have one.
- **Optional — `treehouse`** (a pre-warmed git-worktree pool for parallel agents) for
  parallel implementers. Serial implementation works without it. Install
  [kunchenguid/treehouse](https://github.com/kunchenguid/treehouse) (needs `get --lease`,
  v2+): `curl -fsSL https://kunchenguid.github.io/treehouse/install.sh | sh`.
  Its defaults need no `treehouse init`.

Run `/charlesdr-dev-loop:doctor` after install; it tells you exactly which of
these is missing and what each one costs you.

## Install

As a plugin, which is the normal path:

```bash
/plugin marketplace add charlesdr13/charlesdr-dev-loop
/plugin install charlesdr-dev-loop@charlesdr-dev-loop
```

Then check every lane resolves:

```bash
/charlesdr-dev-loop:doctor
```

As plain skills, for a harness without plugin support:

```bash
bash scripts/install-skills.sh          # --copy for an independent copy
```

The skill-only path gives you the two skills and `codex-run` on PATH. It does
not give you the agents, the commands, or the hook.

In [omp](https://github.com/can1357/oh-my-pi), to orchestrate from any model
(GPT, Grok, Cursor, Claude):

```bash
omp plugin marketplace add charlesdr13/charlesdr-dev-loop
omp plugin install charlesdr-dev-loop@charlesdr-dev-loop
```

Recommended `~/.omp/agent/config.yml`. It routes each lane agent through a model
role, so a provider outage fails over instead of killing the run:

```yaml
modelRoles:
  default: anthropic/claude-opus-5-5:medium   # the orchestrator; NOT via cursor (see below)
  explore: cursor/composer-2.5-fast
  implement: cursor/composer-2.5
  review: openai-codex/gpt-6.1-sol:medium
task:
  agentModelOverrides:
    claude-explorer: "@explore"
    claude-implementer: "@implement"
    claude-reviewer: "@review"
retry:
  fallbackChains:
    default: [cursor/claude-opus-5-5:medium]
    explore: [xai-oauth/grok-4.7, openai-codex/gpt-6-luna]
    implement: [xai-oauth/grok-4.7, openai-codex/gpt-6-luna]
    review: [openai-codex/gpt-6-astra]
```

Keep the orchestrator off the Cursor provider. Cursor serves its own `Task` subagent tool
next to omp's `task`. An orchestrator on `cursor/...` picks Cursor's tool, and omp answers
"Subagents are not implemented by this client". Lanes on Cursor models are fine.
A lane agent's frontmatter `model:` does not apply under omp. The overrides above
win over the bridge's built-in defaults. `rules/omp-lane-dispatch.md` is a
triggered rule: if the orchestrator starts typing `codex-run … --lane` into bash,
omp interrupts it and injects the task-tool rule.

omp loads the skills, commands and agents from the Claude manifest, and
`hooks/pre/charles.ts` bridges the stop warning, the
`codex-run` link and the Agent/Task lane hooks to the same shell hooks. Under omp,
spawning `claude-explorer`, `claude-implementer` or `claude-reviewer` with the
`task` tool is the dispatch, exactly as with the Agent tool in Claude Code: the
brief is rewritten with `charles-run:`, the start and end receipts are logged,
and the reviewer is confined to its review box. Each lane runs on its own
provider instead of haiku/sonnet/opus: explore `cursor/composer-2.5-fast`,
implement `cursor/composer-2.5`, review `openai-codex/gpt-6.1-sol:medium`.
A `task.agentModelOverrides` entry for the agent wins. The end receipt names the
model that actually ran. omp's own code-work agents (`task`, `scout`, `sonic`,
`designer`, `reviewer`) are unrestricted, as in Claude Code.

---

## Opting a repo in

```bash
/charlesdr-dev-loop:init
```

Writes `.charles.toml`, committed on purpose:

```toml
green = "bun test && bun run typecheck"   # what "all green" means here
parallel_min_chunks = 2                    # raise to keep smaller sets serial
```

Nothing in this plugin does anything in a repo without that file. One switch,
per repo, deliberately: behaviour you did not opt into in *this* repo is just
friction.

`green` is inferred from the repo at init time. Check it. A wrong green command
makes the debug loop confidently meaningless.

It is executed, not narrated — `scripts/green.sh` reads it, runs it, and exits
with its status, so the debug loop terminates on a real exit code rather than on
a model's recollection. With no green command set it refuses to run: a loop that
cannot verify itself cannot honestly say it is finished.

---

## The three lanes

| Role | Engine | Effort | Sandbox |
|---|---|---|---|
| explore | gpt-6-luna; grok-4.6 with `grok`; cursor/composer-2.5-fast with `omp`; `claude-explorer` subagent with `claude` | luna: max; grok: high; omp: high; claude: haiku (fixed) | read-only |
| implement | gpt-6-luna; grok-4.6 with `grok`; cursor/composer-2.5 with `omp`; `claude-implementer` subagent with `claude` | luna: max; grok: high; omp: max; claude: sonnet (fixed) | workspace-write |
| review | gpt-6.1-sol with a codex engine; gpt-6-luna/gpt-6-astra (luna/terra engines) or grok-4.6 with `--engine`; openai-codex/gpt-6.1-sol with `omp`; `claude-reviewer` subagent with `--engine claude` | sol: medium; luna/terra: max; grok: high; omp: medium (sol) or max (luna/terra); claude: opus (fixed); `--effort` overrides the non-claude engines | read-only, isolated temp dir |

With no `--engine` or `/engine` preference every lane is a claude subagent
(`CHARLES_DEFAULT_ENGINE` overrides the built-in default). When codex is chosen, luna at max
runs explore and implement, and review uses sol at medium, luna/terra at max, and `--effort` overrides. Automatic
fallback: luna and terra fall back to grok, and grok falls back to luna.
deepseek-v4-flash runs only when forced with `--engine deepseek`, for a
deliberately wide, cheap sweep.

Review effort is positional: intermediate reviews use `--effort medium`; the
final pre-close review omits `--effort` and uses the model-aware default (sol at
medium, luna/terra at max). This is a documented rule, not a flag.

Run `/charlesdr-dev-loop:engine claude` to run explore, implement AND review
as native Claude Code subagents: `claude-explorer` (haiku), `claude-implementer`
(sonnet), or `claude-reviewer` (opus). The orchestrator makes one Agent call
whose prompt opens with `charles-dir:` (plus `charles-plan:`, `charles-req:`
or `charles-base:` where the lane needs them). `hooks/claude-lane-dispatch.sh`
runs `codex-run --engine claude` behind it. The validation is unchanged, and a
refusal comes back as a denied tool call. The hook logs `start`, builds the
review box, and rewrites the prompt. The two-step path (run `codex-run`, paste
its SPAWN block) still works. The reviewer is isolated to a temp
review box the same way `codex-reviewer` is, enforced by a hook that denies it
any tool but Read/Grep/Glob and any path outside the box. A `claude`
preference is honoured on review too, the same as `grok`. `--resume` is
refused: no session id is recorded for a subagent. Claude dispatches have no
fallback. `claude-explorer` keeps Bash for read-only probes by instruction,
not by tool restriction — the same Bash-can-write ceiling as the other
read-only lanes.

Run `/charlesdr-dev-loop:engine grok` to use Grok (`grok-4.6`, local `grok`
CLI) at high effort for all three lanes — explore, implement, AND review. A
`grok` preference is honoured on review too: it is a different model family
from every codex profile, which is exactly what the isolated review wants.
`--effort max` is translated to `xhigh`, since grok has no `max`. `--resume`
is refused: no session id is recorded. Grok failures have no fallback.
Read-only grok lanes block `write`/`search_replace`; Bash writes remain the
same known isolation ceiling as claude.

Run `/charlesdr-dev-loop:engine omp` to run all three lanes as headless `omp`
processes, one model per lane by default: explore `cursor/composer-2.5-fast`,
implement `cursor/composer-2.5`, review `openai-codex/gpt-6.1-sol`.
`omp:<provider>/<model>` overrides the model for every lane (an unknown model
exits 1 at dispatch); `omp:` with nothing after it is rejected. Like `grok`,
an `omp` preference is honoured on review too, in the same isolated box.
`--resume` is refused: no session id is recorded. Omp failures have no
fallback. Under an omp orchestrator, `async: true` on its bash tool is the
same thing as this repo's `run_in_background: true`, and omp's `task` tool is
the same thing as the Agent tool.

Engine values are `luna`, `terra`, `deepseek`, `claude`, `grok`, and `omp`. `/engine <value>`
writes `<run root>/.charles/engine` in a repo with `.charles.toml`, shared by the
primary checkout and linked worktrees; elsewhere it writes the global
`$CHARLES_STATE_DIR/engine` (default: `~/.cache/charlesdr-dev-loop/engine`).
`/engine global <value>` always writes global. `/engine default` clears the
project preference; `/engine global default` clears global. The command reports
the effective scope and engine. Precedence: `--engine`, `CHARLES_ENGINE`,
project file, global file, built-in `claude`. Changes take effect on the next dispatch. `deepseek`
bills a separate key when codex quota is short.

**Older all-lane timing baseline** (179 runs; predates the implement
remeasurement below):

| lane | median | p90 | over 25 min |
|---|---|---|---|
| explore | 5.7 min | 22.0 min | |
| review | 1.7 min | 3.2 min | never |

**Current implement timing** (successful implement dispatches only; n=233 across
all opted-in repos):

Durations are SUCCESSFUL implement dispatches only (`rc=0`): median 8.9 min,
p75 13.8 min, p90 19.1 min, p95 23.1 min, max 39.6 min. Method: pair
start/end events in `.charles/dispatches.jsonl` across all opted-in repos and
filter durations to `rc=0`. Timeouts are counted separately: 25 of 258 ends,
about 10%, hit the old 1800s cap. The successful median remains roughly five
times the old 1.9-minute documentation claim, so parallel chunking still pays.

The Bash tool caps a single call at 600s, so **57% of successful explores cannot
finish in the foreground**. The orchestrator runs explore and implement directly
with `codex-run --lane <lane> --dir <repo> --timeout 2700 "<task>"` as separate Bash
calls with `run_in_background: true`.
The harness re-invokes the orchestrator when each process exits. `lane-status.sh`
is only the recovery probe when a session restart or harness death loses that
completion signal. Reviews expected to exceed roughly 9 minutes (heavy diff, big
repo, or terra at max) run in the background with `--timeout 2700` and bounded
`lane-status.sh` checks; shorter reviews may use the foreground `--timeout 540`
path.

Raising the cap does not fix the underlying cause of the 30-minute cluster, which is oversized dispatches; chunking the requirement list is the real remedy and the cap is the backstop.

**Speed.** `--fast` is shorthand for `--effort high`; `--effort max|high|medium`
sets it directly. Codex's `fast_mode` feature is globally on by default, so it is
enabled explicitly on luna and disabled on the review lane — that way "fast on
luna only" is literally true rather than inherited. Effort is the lever that
actually moves latency: a repo sweep at `max` ran 698s, a smaller one at `high`
ran 101s. Those were different questions, so treat it as a direction, not a
benchmark.

```bash
# Each explore/serial-implement command is a separate Bash call with run_in_background: true.
codex-run --lane explore   --dir REPO --timeout 2700 "why does the refresh path 401?"
codex-run --lane implement --dir REPO --req R1,A3 --timeout 2700 "add the RangeError guard from the plan"
# Short review: foreground and isolated; longer reviews use the background path below.
codex-run --lane review    --dir REPO --plan docs/specs/x.md --timeout 540 "check every requirement"
# Long review: make a separate Bash call with run_in_background: true and --timeout 2700;
# then check lane-status.sh at most three times.
codex-run --lane review --dir REPO --plan docs/specs/x.md --timeout 2700 \
  "check every requirement"
# Review committed work, including any uncommitted changes on top.
codex-run --lane review    --dir REPO --plan docs/specs/x.md --base REF "check every requirement"
```

Review uses the working-tree diff against `HEAD`, cached changes, and untracked
files by default. `--base REF` instead reviews `REF..working-tree` (with
untracked files appended); `REF` must resolve, and `--base` is review-only.
A review after `HEAD` has moved requires `--base <ref>`, or the reviewer sees an
empty diff and grades nothing.

(`codex-run` is on PATH after `install-skills.sh` or the plugin's SessionStart
hook. The orchestrator invokes it directly; no wrapper agent is needed for
explore or implement.)

Exploration and implementation both run on the strongest available reasoning,
on the view that a wrong exploration is more expensive than an expensive one.
The tradeoff is real: a five-wide luna sweep is not cheap, so size fleets to the
question rather than to the ceiling — and note that nothing enforces it, so it's judgment.

A dispatch that fails on luna or terra gets one grok rescue, and one that fails
on grok gets one luna rescue (never deepseek, unless chosen explicitly). The
wrapper prints a loud `fallback_from:<engine> primary_rc:<n>` receipt; if the
rescue also fails, the dispatch stops. It never falls back to Claude doing the work inline. A
fallback that fires on any error turns "always dispatch" into "dispatch when
convenient", which is the same as not having the system.

---

### The dispatcher has a stable path

A `SessionStart` hook symlinks `~/.local/bin/codex-run` to the installed
plugin's copy of the script. The orchestrator resolves `codex-run` from PATH
first and only falls back to `${CLAUDE_PLUGIN_ROOT}`.

That variable does not reliably expand inside Codex's shell. When it did not,
dispatches searched the filesystem, found the author's working checkout, and one
executed it mid-edit and died on a syntax error. Pointing at the installed
snapshot fixes both problems: the path is stable, and it is never someone's live
working tree.

### Concurrent writers are refused

A second `--lane implement` dispatch on a directory that already has one exits 4
rather than starting. Read-only explores alongside a writer are fine. Override
with `CHARLES_ALLOW_CONCURRENT_WRITES=1` if you genuinely mean it.

This exists because the docs promised worktree isolation that no code provided,
and a timed-out dispatch got re-dispatched while the original codex was still
writing to the same tree.

## Commands

| Command | When |
|---|---|
| `/charlesdr-dev-loop:feature <what>` | Building something new |
| `/charlesdr-dev-loop:debug <symptom>` | Something is broken |
| `/charlesdr-dev-loop:polish` | "What should I improve here" |
| `/charlesdr-dev-loop:fast-flow <ask>` | Small or medium adaptive fast lane |
| `/charlesdr-dev-loop:init` | Opt this repo in |
| `/charlesdr-dev-loop:ui <route>` | UI/UX polish — routes to impeccable, adds a codex mechanical audit |
| `/charlesdr-dev-loop:release <semver>` | Publish a version |
| `/charlesdr-dev-loop:ops` | Cross-repo run triage and recovery |
| `/charlesdr-dev-loop:resolve` | Pick up where the last run stopped |
| `/charlesdr-dev-loop:doctor` | Check every lane and dependency |

You do not have to type them. In an opted-in repo the flow triggers on intent —
"add rate limiting" is enough. The commands are for being explicit.

---

## Continuing a run

A flow that ends with open items used to end in prose, and the prose died with
the session. Every run now keeps state in `.charles/runs/<id>/RUN.md` — phases
with their pasted proof, the rollback command, and open items typed by who can
unblock them:

| Type | Meaning | Unblocked by |
|---|---|---|
| `BLOCKED-HUMAN` | needs a fact or reply only you have | you |
| `PENDING-DECISION` | ready to act, needs your yes | you |
| `DEFERRED` | deliberately out of scope | either |
| `FAILED` | a lane died, work incomplete | re-dispatch |

```bash
/charlesdr-dev-loop:resolve          # newest unclosed run
/charlesdr-dev-loop:resolve --list   # pick another
```

Open a run with `run-state.sh init <dir> <flow> "<goal>" --spec
docs/specs/<plan>.md`. A discovery made mid-flow is `DEFERRED`, not a new
dispatch; use `run-state.sh defer <dir> "<text>"`. While a run is open,
`codex-run --lane implement` requires `--req R1,A3`, validates those identifiers
against the run's spec, and cannot dispatch a run opened without `--spec`.

`resolve` surfaces `BLOCKED-HUMAN` first (usually two minutes of your time, and
everything downstream waits on them), confirms before re-dispatching a `FAILED`
lane, and closes only when every item is resolved *and* the flow reached its
final phase. A run that died at phase 3 is not finished; use
`run-state.sh abandon <dir> "<reason>"` to record it as terminal `ABANDONED`.
Runs whose `RUN.md` has not changed for 7 days (`CHARLES_STALE_DAYS`) are
abandoned automatically at session start.

Where `tasks-axi` is installed it owns the items, since it already resurfaces
them at session start; otherwise they live in `RUN.md`.

Alongside this, `codex-run.sh` appends a receipt for every dispatch to
`.charles/dispatches.jsonl` — lane, engine, model, exit code. It is written by
the script, so a lane that fails records itself with no cooperation from any
model. That log is what makes the receipt rule enforceable. `scripts/verify-receipt.sh`
reads it and exits 0 (a lane ran), 1 (nothing ran — discard the report), or 2
(dispatches exist but all failed, e.g. `rc=143` when the harness killed one).

The pasted receipt line in a report is a courtesy: an agent can type it without
running anything. The dispatch log is written by the wrapper itself and cannot be
forged from inside a report, so that is what gets checked.

## UI polish is a router, not a flow

`/charlesdr-dev-loop:ui` deliberately does **not** implement UI judgment.
`impeccable` is a 27-command UI system whose `polish`
alone covers spacing, information architecture, typography, contrast,
interaction states, micro-interactions, content, icons and forms — and nine of
its references already handle the perf/a11y floor. Rebuilding that would have
produced a worse copy.

The router adds only what impeccable lacks: durable run state, one direct
`codex-run --lane explore` call with `run_in_background: true` for the
*mechanical* audit (token drift, off-scale spacing, duplicate variants, dead
styles — grep-shaped findings an eye misses), gsap routing for motion work, and
a `codex-reviewer` pass for scope creep, which is how polish work actually goes
wrong.

Taste never goes to a lane. luna gets a diff, never a picture, so anything
needing an eye becomes a `BLOCKED-HUMAN` item rather than a guess.

## The hooks

- **`SessionStart` `link-dispatcher.sh`** links `codex-run` onto PATH and
  auto-abandons runs idle for `CHARLES_STALE_DAYS` (default 7).
- **`Stop` `warn-open-runs.sh`** warns about `FAILED` items in a run touched in
  the last 24 hours. Only `FAILED`: the others already resurface via `tasks-axi`.
- **engine=claude lane hooks** (`claude-lane-dispatch.sh`, `claude-review-box.sh`,
  `claude-lane-receipt.sh`) dispatch a `claude-*` subagent through `codex-run`,
  confine the reviewer to its box, and log the receipts.

There is no edit gate and no subagent gate: the orchestrator may edit inline and
spawn any subagent. Lane receipts are mirrored to the main checkout's
`.charles/dispatches.jsonl` when a dispatch runs in a linked worktree.

---

## Changes no lane produced

An implementer reported `FAILED`, stated it had not improvised, and had modified
two test files — against an empty dispatch log. No lane had ever run. It wrote
the files with its own tools and said it hadn't.

The tests were good. That is what makes it the dangerous failure rather than the
harmless one: **plausible code with no provenance**.

```bash
scripts/unsourced.sh .        # 0 accounted for · 1 nothing produced this
```

Since 2.49.0 this is informational: `flow-status.sh` and `close` report it as a NOTE,
never a blocker, because the orchestrator may now edit inline and other sessions
share the main checkout. Run it yourself when a lane's report and the tree disagree.

It compares the working tree against the dispatch log, ignoring what the
orchestrator legitimately authors itself (plans in `docs/specs/`, `.charles/`).
A failed dispatch does not launder edits — only `rc=0` accounts for them.

Three outcomes, because they need different answers:

| exit | meaning | what to do |
|---|---|---|
| 0 | a successful dispatch accounts for the changes | proceed |
| 1 | **no lane ran at all** | discard whole — no provenance, and something misreported |
| 2 | **a lane ran and was cut short** (124/143) | its report is worthless, its code may not be — verify with `green.sh` and `codex-reviewer`, then keep or revert |

Exit 1 is the fabrication case: discard it whole, do not keep the parts that
look correct. Exit 2 is a clock, not a liar — a dispatch killed at 2700s may
have written good code first, and throwing that away is its own kind of waste.

Every rule against this previously lived in agent prose, which is precisely what
the agent contradicted.

## Finishing is not dispatching

`verify-receipt.sh` proves a lane ran; `flow-status.sh` proves the flow did.
An audit of 75 real dispatches found 26 implements against 5 reviews, 13 plans
carrying 1 grill verdict, and 4 runs open against 1 closed — all of it passing
silently because the individual dispatches succeeded.

```bash
scripts/flow-status.sh .      # 0 clean · 1 outstanding
```

`run-state.sh close` refuses (exit 5) while anything is outstanding, since
closing is where you declare the work done. `--force` overrides. A missing grill
verdict and changes no lane produced are NOTEs, not blockers. While a run is
open, `doctor` keeps installed-content drift at WARN but FAILs on an unreviewed
implement; report that expected mid-flow failure rather than reinstalling or
trying to bypass the review.
The small transition table in `scripts/flow.json` drives the expected-next hints;
`scripts/runs-sweep.sh [root...]` is the standing read-only hygiene sweep across
opted-in repos, so run it when `doctor` warns about open runs.

## Recovery after a lost completion signal

Normally the harness callback tells the re-invoked orchestrator that a background
dispatch exited. If a session restarts or the harness dies before that signal
arrives, use `lane-status.sh` as the recovery probe. Never use periodic polling
as the primary wait or decide liveness from an output file: `.last` appears only
on success, so a killed lane leaves nothing and a waiter cannot tell "still
working" from "died twelve minutes ago".

```bash
scripts/lane-status.sh        # 0 RUNNING · 1 DONE · 2 DEAD · 3 UNKNOWN
```

Every dispatch now also writes a `.done` marker with its exit code on every
exit path it can control, so a timeout reports `rc=124`. It cannot cover
SIGKILL — nothing can — which is why liveness is answered by process, not file.

DEAD means over: record `FAILED`, stop, and never re-dispatch on top of a
RUNNING lane. The original keeps writing, and two engines racing on one tree is
how work gets silently lost.

## The lane inherits nothing

Codex runs in its own process and cannot load Claude Code skills. Not
`ponytail`, not your CLAUDE.md, not your output style. Whatever constraint you
want on the code has to be in the prompt, or it does not exist — which for a
long time meant the orchestrator had a simplicity discipline and the thing
actually writing the code had none.

**ponytail is not Claude-Code-exclusive** — it ships a real Codex plugin
(`codex plugin marketplace add DietrichGebert/ponytail`), and a lane told to
load it does: verified reading `skills/ponytail/SKILL.md` and quoting rung 1
verbatim. Every `implement` dispatch therefore points at the maintained skill
first, and falls back to a distilled ladder: need it at all,
stdlib, native platform, existing dependency, one line, minimum code. Plus the
carve-outs it must not simplify away — validation at trust boundaries, error
handling that prevents data loss, security, accessibility, anything the brief
asked for. The reviewer grades for unrequested complexity too: an abstraction
with one caller, a config value that never varies, a dependency doing what a few
lines would.

`explore` does not carry it. It writes no code.

## Chunked dispatch

An implementer given twelve requirements does about 60% of each — the diff looks
plausible and the shortfall surfaces in review, or later. Capping scope is not
enough, because one coherent slice can still carry a long list.

Chunks are counted in **plan requirements**, not files or lines: 1-5 is usually
one slice, 6-10 is two, and 11+ means three or more and probably means this is
two plans wearing one name. When the settled plan yields 2+ parallel-compatible file
slices, write or rewrite `docs/specs/YYYY-MM-DD-<topic>.chunks.json` beside it
after the grill settles, never during the initial plan phase. Read
`docs/specs/<plan>.chunks.json` and resolve the script directory as
`SCRIPTS="$(dirname "$(readlink -f "$(command -v codex-run)")")"`.

Parallel is the default when the valid manifest holds `parallel_min_chunks` or
more entries, using the value from `.charles.toml` (default `2`), its file
declarations are disjoint or overlap only on paths every overlapping chunk lists
in `shared` (at most two chunks per path), and `treehouse` is available. Shared
paths must be existing ordinary text files modified in place by both chunks;
adds, deletes, renames, mode changes, symlinks, and binary content are refused:

```bash
"$SCRIPTS/parallel-chunks.sh" "$(pwd)" docs/specs/<plan>.chunks.json
# [{"name":"api","files":["src/a.ts"],"req":["R1"],"task":"..."}, ...]
# Shared paths must also be in files and listed in shared by both chunks.
```

Use serial for one chunk, below a raised threshold, overlap not declared shared
or declared asymmetrically, an invalid manifest, or missing `treehouse`; shared
manifests refuse `--no-green` and require the combined `green.sh` run. A batch
whose chunks modify `parallel-chunks.sh`, `codex-run.sh`,
or anything the dispatcher executes MUST also run serially: children execute
the dispatcher from the runner's script directory while the post-merge green
check runs the merged root scripts, and Bash reads a script lazily by byte
offset, so rewriting the dispatcher while it executes kills it at a stale
offset. That happened in Chunk A: the dispatcher died with `syntax error near
unexpected token )` after its work completed. Every chunk in an open run carries
`req`; the runner validates it against the plan and passes it to the child.

## Baseline and proof

Run `green` *before* touching anything, or you will attribute an existing
failure to your change. Throughout, proof is output: `"47 passed, 0 failed"`,
not "tests pass"; `"312 lines"`, not "file written". Phases are recorded at
implement, review and green.

---

## Test

```bash
bash scripts/selftest.sh   # selftests for the hooks, run state, dispatcher, docs contracts
bash scripts/doctor.sh     # every lane, every dependency, this repo's config
```

Both are expected to exit non-zero when something is genuinely wrong. `doctor`
distinguishes FAIL (a dead lane) from WARN (a degraded capability).

---

## Acknowledgements

This plugin is mostly other people's ideas, arranged for one person's workflow.

[**loop-engineer**](https://github.com/LeadGrowGTM/loop-engineer) by
**Mitchell Keller ([@MitchellkellerLG](https://github.com/MitchellkellerLG))**
is where the two load-bearing ideas come from: the proof protocol, and grading
in a context that never saw the maker. Its four-agent harness solves the unattended case;
this solves the supervised one, and borrows without depending. No runtime link
between them — the ideas travelled, the code did not.

[**superpowers**](https://github.com/obra/superpowers) by Jesse Vincent (MIT)
provides the brainstorming discipline for genuinely open asks. The flow
overrides its terminal state — brainstorming here hands off to the plan (and a
grill for risky plans) rather than to `writing-plans` — which is a deviation from its design, not a defect in it.

[**mattpocock/skills**](https://github.com/mattpocock/skills) by Matt Pocock
(MIT) is the origin of `grill-me`, which `grill-rounds` forks: same relentless
interrogation, bounded to two or three rounds and front-loaded with an automated
adversary so it can run unattended. Its `diagnose` and `tdd` skills are called
unmodified. Forking rather than editing was a practical decision — installed
plugin caches get overwritten on marketplace update, so an edit in place has a
lifespan measured in days.

[**OpenAI Codex CLI**](https://github.com/openai/codex) is the wire for all
three lanes. It speaks the Responses API, which honours `reasoning_effort` —
the reason `max` is reachable here at all.

[**ponytail**](https://github.com/DietrichGebert/ponytail) by Dietrich Gebert
(MIT) is the simplicity discipline the implement lane runs under. It is not
Claude-Code-only — its Codex plugin is what lets the lane load the real skill
rather than a paraphrase of it.

**treehouse** provides the pre-warmed worktree pool that makes parallel
implementers safe.

The `codex-deepseek` dispatch wrapper this builds on was written for an earlier
project and is reused rather than reimplemented.

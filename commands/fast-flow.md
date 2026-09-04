---
description: Adaptive fast flow — one explore lane, two grill rounds, serial worktree implementation, isolated review, green sign-off
---

Run the **fast flow** from the `charles-flow` skill on: $ARGUMENTS

This keeps the plan → grill → implement → review → green → sign-off → close
skeleton for small and medium asks. It uses one luna explorer, one serial luna
implementer in a worktree, one default review, and a two-cycle debug-loop cap.

**Gate.** Before doing anything, require `.charles.toml` at the repository root.
If it is absent, stop and offer `/charlesdr-dev-loop:init`. If an already-open
run exists, stop and offer `/charlesdr-dev-loop:resolve`.

**Failure rule.** Any lane failure, any non-zero `verify-receipt.sh` exit, or
review exit 3 (empty diff) records a `FAILED` item and stops with a report:

```bash
"$SCRIPTS/run-state.sh" item "$(pwd)" FAILED "<what failed>"
```

Never fall back to inline work. Before step 3 no run is open yet, so a failure
there is reported and the flow stops without an item. Record `run-state.sh
phase` at every step boundary with the actual proof output. Every `codex-run` call below is prefixed
with `CHARLES_FAST_MODE=1`. This flow never passes `--fast` or `--effort` to a
luna lane: luna stays at its default `--effort max` and the dispatcher manages
codex `fast_mode`.

At each boundary, record the canonical phase and paste its proof:

```bash
"$SCRIPTS/run-state.sh" phase "$(pwd)" "<phase>" "<actual proof output>"
```

Resolve the installed scripts once:

```bash
SCRIPTS="$(dirname "$(readlink -f "$(command -v codex-run)")")"
```

## 1. Classify + baseline

Classify the ask in one line as `debug`, `build`, or `route-out`:

- `debug`: the ask is broken and has a symptom or repro.
- `build`: feature, polish, or refactor work.
- `route-out`: UI/UX → `/charlesdr-dev-loop:ui`; 2+ chunks, flow machinery,
  or security-, state-, or concurrency-sensitive work →
  `/charlesdr-dev-loop:feature` or `/charlesdr-dev-loop:debug`.

Classification changes only the explore brief and plan shape. Run the green
baseline before continuing:

```bash
"$SCRIPTS/green.sh" "$(pwd)"
```

If baseline is red, stop and offer `/charlesdr-dev-loop:debug`. Re-check the
same route-out conditions after the plan exists, before implementation.

## 2. Explore — one lane

Make one Bash tool call with `run_in_background: true`. The explore lane is
read-only:

```bash
CHARLES_FAST_MODE=1 codex-run --lane explore --dir "$(pwd)" --timeout 2700 "<brief>"
```

For `debug`, make `<brief>` ask for a repro and the cause with `file:line`
evidence, no patch. For `build`, ask for prior art in this repo, integration
points, files in scope, and one competing design. Then verify the receipt:

```bash
"$SCRIPTS/verify-receipt.sh" "$(pwd)" --lane explore --since 1800
```

For `debug`, confirm the reported cause against the source yourself before
step 3. A failed lane or a receipt exit other than 0 follows the failure rule.

## 3. Plan

Write `docs/specs/YYYY-MM-DD-<topic>.md` with at most six checkable
requirements using `- [ ] **R#**`, the files in scope, and the green command.
Run one knowledge-base prior-art query when a KG tool is configured. Open the
run against that plan:

```bash
"$SCRIPTS/run-state.sh" init "$(pwd)" fast "<goal>" --spec docs/specs/<plan>.md
```

Do not write a `.chunks.json` manifest. If the plan needs 2+ chunks, stop and
route to `/charlesdr-dev-loop:feature`. Also route any UI/UX or
security/state/concurrency-sensitive plan out here, even if step 1 did not.

## 4. Grill round 1 — codex adversary

Use `grill-rounds` for exactly its round-1 dispatch: one read-only explore lane,
one Bash call with `run_in_background: true`, `CHARLES_FAST_MODE=1`, and this
attack prompt:

```bash
CHARLES_FAST_MODE=1 codex-run --lane explore --dir "$(pwd)" --timeout 2700 \
'Attack this plan. You are trying to find the reason it fails, not to improve it.
Produce a numbered list of:
- unstated assumptions, and steps depending on something not established
- claims about the codebase that may be false — check them against source
- cases the plan does not handle
- anything simpler that achieves the same outcome
- terminology: terms the plan uses loosely or in more than one sense, and any
  that conflict with how the codebase or a CONTEXT.md/glossary uses them
- contradictions: where the plan says the system behaves one way and the code
  says otherwise. Quote both.
- scenarios: invent two concrete edge cases and walk the plan through them

For each item, say what evidence would settle it, with file:line where the
answer is in the repo. Do not propose a rewrite. Do not ask questions — there
is nobody to answer them.'
```

Answer every attack item from source, mark it resolved or amend the plan in
place, and keep only genuinely unresolved intent questions for round 2. Verify
the explore receipt before using its report.

## 5. Grill round 2 — one batched user message

Record every survivor first as `BLOCKED-HUMAN`:

```bash
"$SCRIPTS/run-state.sh" item "$(pwd)" BLOCKED-HUMAN "<question in one line>"
```

Then send one batched message containing `❓` for each question and `➡️` for
the recommendation. If there are zero survivors, say so and continue. If any
survive, nothing proceeds while one is unanswered. Answers that reshape the
plan amend it in place and are noted under `Accepted risks`.

There is no round 3. This flow mandates exactly two grill rounds, and the plan
must contain the full verdict block:

```markdown
## Grill verdict — YYYY-MM-DD

- Rounds: 2
- Attacks raised: N — resolved from source: N, changed the plan: N, escalated: N
- Plan changes: <one line each>
- Accepted risks: <known unhandled risks and why they are acceptable>
- Unresolved: none
```

## 6. Implement — one lane in a worktree

Use a `treehouse` worktree when available:

```bash
WT="$(treehouse get --lease --lease-holder fast-flow)"
```

Without `treehouse`, create the fallback worktree from the repository root:

```bash
WT=".claude/worktrees/fast-$(date +%s)"
git worktree add "$WT" HEAD  # git worktree add .claude/worktrees/fast-<ts> HEAD
```

Make one Bash tool call with `run_in_background: true`, naming every plan
requirement. Do not pass `--run`; the worktree has no run directory:

```bash
CHARLES_FAST_MODE=1 codex-run --lane implement --dir "$WT" --plan "$(pwd)/<plan>" --req <all R IDs> --timeout 2700 "<brief naming ponytail>"
```

Then verify the worktree receipt, aggregate it, and merge the staged diff back
into the root. The root must be clean first (`git status --porcelain` empty
apart from the plan); a dirty root or an `apply` failure is a `FAILED` item —
the diff stays in the worktree, nothing is half-merged:

```bash
"$SCRIPTS/verify-receipt.sh" "$WT" --lane implement --since 2700
cat "$WT/.charles/dispatches.jsonl" >> "$(pwd)/.charles/dispatches.jsonl"
git -C "$WT" add -A && git -C "$WT" diff --cached HEAD | git apply --index
```

Keep the worktree until step 8 is green: a `GAPS FOUND` retry dispatches into
the same `$WT`, on top of the first implementation, and is merged with the same
recipe. Return it only after green (`treehouse return "$WT"`, or
`git worktree remove --force "$WT"` for the fallback — its index is still
dirty). A failed implementation or receipt stops under the failure rule; never
implement inline.

## 7. Review — one pass

Run one isolated review with the default engine, sol at medium. Use a foreground
Bash call with outer timeout: 600 and the review's normal `--timeout 540`:

```bash
CHARLES_FAST_MODE=1 codex-run --lane review --dir "$(pwd)" --plan "$(pwd)/<plan>" --timeout 540 "<focus>"
```

Use a background Bash call with `run_in_background: true` and
`--timeout 2700` only for a heavy diff. Review exit 3 means empty diff and is a
`FAILED` item. If the review says `GAPS FOUND`, verify every finding against
source before acting, then run one implement cycle through step 6 in the same
worktree. The total implement/review/green cycle cap is two.

## 8. Verify, sign off, close

Run the green command and record its output:

```bash
"$SCRIPTS/green.sh" "$(pwd)"
```

The cap is two implement/review/green cycles. If green still fails after the
second cycle, record a `FAILED` item and stop with a report. On green, complete
`## Sign-off` in the plan with one checked line per requirement and pasted
verification output, then close the run:

```bash
"$SCRIPTS/run-state.sh" close "$(pwd)" "<outcome>" --spec docs/specs/<plan>.md
```

## Skipped by design

Fast-flow deliberately skips the brainstorming step, explorer fan-out, grill
round 3 (a deliberate departure from `grill-rounds`), the `.chunks.json`
manifest and parallel path, and the second reviewer. Prior art is one repo grep
plus one knowledge-base query when a KG tool is configured. Sensitive work is
routed to `/ui`, `/feature`, or `/debug` at classification and again after the
plan.

Keep these three meanings separate: `fast` is the flow key in
`scripts/flow.json`; `--fast` is the dispatcher flag that lowers effort to
`high` and is never passed here; codex `fast_mode` is the provider option the
dispatcher manages. `CHARLES_FAST_MODE=1` keeps that provider option enabled on
luna despite the weekly quota gate; terra remains disabled.

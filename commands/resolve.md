---
description: Pick up where the last flow run stopped — show its state and drive open items to closure
---

Continue the most recent unclosed run. `--list` to choose a different one.

## 1. Read the state

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/run-state.sh show "$(pwd)" $ARGUMENTS
```

That prints the run's phases with their proof output, its open items, the
rollback command, and the mechanical dispatch log — including any lane that
failed, which is the one thing nothing else tracks.

If there is no open run, say so and stop. Do not invent one.

## 2. Work the items, in this order

**`BLOCKED-HUMAN` first.** These are usually two minutes of the user's time and
they are blocking everything downstream. Surface them before anything else, even
though they are not yours to solve. In the run this feature was built for, the
whole 17-minute loop ended with a colleague still waiting six hours for an answer
only the user had.

**`FAILED` next.** A lane died, so the work is genuinely incomplete. **Confirm
before re-dispatching** — a stale run may predate changes in the repo, and
re-running is real money at luna-at-max. Ask, then dispatch.

**`PENDING-DECISION`** — put the decision to the user with your recommendation.
Record the answer, then act on it.

**`DEFERRED`** — report only. These were skipped deliberately; do not quietly
un-defer them because they are easy.

## 3. Close, or leave it open

Close only when every item is resolved AND the run reached its flow's final
phase:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/run-state.sh close "$(pwd)" "<one paragraph: what shipped, what did not, what was decided>" --spec docs/specs/<the plan>.md
```

A run whose items are all resolved but which died mid-flow is **abandoned, not
finished** — leave it open. Those are the ones worth seeing again.

If new work comes out of resolving, that is a new run, not an extension of this
one. Start it with the appropriate flow.

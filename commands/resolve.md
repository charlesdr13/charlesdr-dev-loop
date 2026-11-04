---
description: Pick up where the last flow run stopped — show its state and drive open items to closure
---

Continue the most recent unclosed run. `--list` to choose a different one.

## 1. Read the state

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/run-state.sh show "$(pwd)" $ARGUMENTS
```

That prints the run's phases with proof output, open items, the rollback command,
and the mechanical dispatch log, including any failed lane (which nothing else
tracks). No open run: say so and stop; do not invent one.

The `next expected:` line after the phase list shows where the run stopped and the
legal next phase(s); treat it as advisory.

## 2. Work the items, in this order

**`BLOCKED-HUMAN` first.** Usually minutes of the user's time, and they block
everything downstream (a colleague once waited six hours on one). Surface them
before anything else.

**`FAILED` next.** A lane died; the work is incomplete. Confirm with the user
before re-dispatching: a stale run may predate repo changes, and re-running costs
real money at luna-at-max.

**`PENDING-DECISION`**: put it to the user with your recommendation, record the
answer, then act.

**`DEFERRED`**: report only; do not quietly un-defer.

## 3. Close, or leave it open

Close only when every item is resolved AND the run reached its flow's final
phase:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/run-state.sh close "$(pwd)" "<one paragraph: what shipped, what did not, what was decided>" --spec docs/specs/<the plan>.md
```

A run with all items resolved that died mid-flow is abandoned, not finished: leave
it open. New work that comes out of resolving is a new run under the appropriate
flow.

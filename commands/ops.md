---
description: Survey and recover open flow runs across selected repositories
---

Run the **ops flow** from `scripts/flow.json`: survey, select, recover, report.

## 1. Survey first

`runs-sweep.sh` is always the first step. It is read-only by design: it reports
open and abandoned runs and never closes, abandons, or deletes anything.

It covers exactly the supplied roots, or `CHARLES_SWEEP_ROOTS` (colon-separated)
when no roots are supplied, or the defaults `~/MACH4` and `~/MACH4_2`. It does
not sweep the whole filesystem. Record the roots in the ops run.

```bash
SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
ROOTS="${ARGUMENTS:-${CHARLES_SWEEP_ROOTS:-$HOME/MACH4:$HOME/MACH4_2}}"
SWEEP="$("$SCRIPTS/runs-sweep.sh" ${ARGUMENTS:-})"
printf '%s\n' "$SWEEP"

OPS_RUN="$("$SCRIPTS/run-state.sh" init "$(pwd)" ops \
  "cross-repo run triage; roots swept: $ROOTS")"
"$SCRIPTS/run-state.sh" phase "$(pwd)" survey \
  "read-only sweep; roots swept: $ROOTS" --run "$OPS_RUN"
printf 'ops run: %s\n' "$OPS_RUN"
```

Keep the printed `OPS_RUN` id for the remaining steps.

## 2. Pick targets

Read the sweep output and record the exact repository and run id selected for
each action:

```bash
"$SCRIPTS/run-state.sh" phase "$(pwd)" select \
  "targets: <repo>/<run-id> — <reason>" --run "$OPS_RUN"
```

## 3. Recover only after confirmation

HARD RULE: NEVER close, abandon, or delete another repository's run without
EXPLICIT human confirmation of the exact repository, run id, and action. No
confirmation means do not run a recovery command.

Use the existing verbs only:

- `run-state.sh reopen <dir> --run <id>`
- `run-state.sh abandon <dir> [--run <id>] "<reason>"`

After explicit confirmation for each target, run the matching command:

```bash
"$SCRIPTS/run-state.sh" reopen "<dir>" --run "<id>"
"$SCRIPTS/run-state.sh" abandon "<dir>" --run "<id>" "<reason>"
```

Then record what happened, including actions skipped for lack of confirmation:

```bash
"$SCRIPTS/run-state.sh" phase "$(pwd)" recover \
  "confirmed actions: <reopened, abandoned, or skipped targets>" --run "$OPS_RUN"
```

## 4. Report

Report the roots swept, findings, confirmations, recovery results, and skipped
targets. Record the report, then close only this ops run in the repository where
the command was invoked:

```bash
"$SCRIPTS/run-state.sh" phase "$(pwd)" report \
  "roots swept: $ROOTS; findings and recovery outcomes reported" --run "$OPS_RUN"
"$SCRIPTS/run-state.sh" close "$(pwd)" \
  "reported cross-repo triage and recovery; roots swept: $ROOTS" --run "$OPS_RUN"
```

If that local close is refused by the existing state checks, report the reason
and leave the ops run open; never bypass the checks for another repository.

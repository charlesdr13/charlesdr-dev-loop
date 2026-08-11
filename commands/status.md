---
description: What is outstanding in this repo — ungraded implements, unchallenged plans, open runs
---

```bash
SCRIPTS="$(dirname "$(readlink -f "$(command -v codex-run)")")"
"$SCRIPTS/flow-status.sh" "$(pwd)"
"$SCRIPTS/run-state.sh" show "$(pwd)" --list
```

Report what came back. For each issue, say what closes it:

- **ungraded implements** → `codex-reviewer` against the plan in `docs/specs/`
- **plans with no grill verdict** → `grill-rounds` on that plan
- **open runs** → `/charlesdr-dev-loop:resolve`

Do not offer to `--force` a close unless the user asks. The point of the check
is that "the dispatches succeeded" is not the same as "the work is done".

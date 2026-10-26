---
description: Feature flow — the lean loop (plan, implement, one review, green, close) for something new
---

Run the **lean loop** from the `charles-flow` skill on: $ARGUMENTS

Differs from the default only here: write the plan first (brainstorm only if the
ask is genuinely open and the user is present; grill only for money,
auth/security, migrations or 10+ requirements). Implementation follows the skill's
Parallel section: `parallel-chunks.sh` for a valid `.chunks.json` with
`parallel_min_chunks` or more entries, otherwise one implement lane in a Bash call
with `run_in_background: true`:

```bash
codex-run --lane implement --dir <repo> --req <R1,A3> --timeout 2700 "<task>"
```

Open the run with `run-state.sh init ... --spec docs/specs/<plan>.md`; defer
mid-flow discoveries with `run-state.sh defer <dir> "<text>"`.

No `.charles.toml`: stop and offer `/charlesdr-dev-loop:init`.

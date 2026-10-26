---
description: Debug flow — the lean loop, reproduce and confirm the cause from source first
---

Run the **lean loop** from the `charles-flow` skill on: $ARGUMENTS

Differs from the default only here: build the feedback loop and reproduce first
(`diagnosing-bugs`), and confirm the cause from source yourself before planning.
Explore lanes, if any, return a cause with `file:line` evidence, never a patch.
The plan holds the confirmed cause, the fix scope and the green command; the
review asks whether the diff fixes that cause and nothing else. No grill unless
the bug touches money, auth/security or data loss.

Implement per the skill (parallel chunks when the manifest warrants, otherwise a
Bash call with `run_in_background: true`):

```bash
codex-run --lane implement --dir <repo> --req <R1,A3> --timeout 2700 "<task>"
```

Cap green-fix cycles at 3, then record a `FAILED` item and stop.

No `.charles.toml`: stop and offer `/charlesdr-dev-loop:init`.

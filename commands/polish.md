---
description: Improvement flow — the lean loop after one explore pass for gaps and wins
---

Run the **lean loop** from the `charles-flow` skill on: $ARGUMENTS
(no argument = this repo as a whole)

Differs from the default only here: start with one explore pass in the background
(Bash with `run_in_background: true`), one lens per call (gaps, must-haves,
quality-of-life), never the same question twice. Take the shortlist to the user,
plan the survivor, then the normal loop. Implement per the skill:

```bash
codex-run --lane implement --dir <repo> --req <R1,A3> --timeout 2700 "<task>"
```

Review for scope creep, the characteristic failure of polish work.

No `.charles.toml`: stop and offer `/charlesdr-dev-loop:init`.

---
description: Full feature flow — brainstorm, direct background codex explore fleet, grill, ground-truth gate, direct background codex implement, isolated review, debug loop
---

Run the **feature flow** from the `charles-flow` skill on: $ARGUMENTS

Invoke `charles-flow` and follow Flow 1 exactly. Do not skip the ground-truth
gate, and do not implement anything yourself — use the direct background
`codex-run --lane implement --dir <repo> --timeout 1800 "<task>"` dispatch.

If this repo has no `.charles.toml`, stop and offer `/charlesdr-dev-loop:init` first.

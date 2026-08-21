---
description: Full feature flow — brainstorm, direct background codex explore fleet, grill, ground-truth gate, parallel-first implement, isolated review, debug loop
---

Run the **feature flow** from the `charles-flow` skill on: $ARGUMENTS

Invoke `charles-flow` and follow Flow 1 exactly. Do not skip the ground-truth
gate, and do not implement anything yourself. For 2+ disjoint file slices, use
the plan phase's committed `.chunks.json` manifest and the parallel default;
otherwise use the direct background
`codex-run --lane implement --dir <repo> --timeout 2700 "<task>"` dispatch.

If this repo has no `.charles.toml`, stop and offer `/charlesdr-dev-loop:init` first.

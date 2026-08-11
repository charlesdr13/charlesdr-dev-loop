---
description: Debug flow — diagnosing-bugs discipline, codex explore fleet on the cause, ground to truth, codex fix, verify
---

Run the **debug flow** from the `charles-flow` skill on: $ARGUMENTS

Invoke `charles-flow` and follow Flow 2 exactly. Build the feedback loop before
hypothesising (that is the `diagnosing-bugs` discipline, and it is the part that
actually finds bugs). Explorers return causes with `file:line` evidence, never
patches. Cap at 3 cycles, then stop and report.

If this repo has no `.charles.toml`, stop and offer `/charlesdr-dev-loop:init` first.

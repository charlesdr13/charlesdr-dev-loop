---
description: Improvement flow — codex fleet finds gaps/must-haves/QoL wins, then brainstorm, grill, implement, verify
---

Run the **polish flow** from the `charles-flow` skill on: $ARGUMENTS
(no argument = this repo as a whole)

Invoke `charles-flow` and follow Flow 3. Give each explorer a different lens —
gaps, must-haves, quality-of-life — rather than asking three agents the same
question and getting three versions of the same answer.

When the survivor plan yields 2+ disjoint file slices, its plan phase writes the
committed `.chunks.json` manifest and the implement phase uses the parallel
default; otherwise it dispatches one implement lane.

If this repo has no `.charles.toml`, stop and offer `/charlesdr-dev-loop:init` first.

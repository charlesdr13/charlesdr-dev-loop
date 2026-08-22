---
description: Full feature flow — brainstorm, direct background codex explore fleet, grill, ground-truth gate, parallel-first implement, isolated review, debug loop
---

Run the **feature flow** from the `charles-flow` skill on: $ARGUMENTS

Invoke `charles-flow` and follow Flow 1 exactly. Do not skip the ground-truth
gate, and do not implement anything yourself. For 2+ disjoint file slices, read
`docs/specs/<plan>.chunks.json`, resolve
`SCRIPTS="$(dirname "$(readlink -f "$(command -v codex-run)")")"` as in
`commands/ui.md:22`, and invoke
`"$SCRIPTS/parallel-chunks.sh" "$(pwd)" docs/specs/<plan>.chunks.json` when
the valid manifest holds `parallel_min_chunks` or more entries. Use serial for
one chunk, overlapping declarations, an invalid manifest, missing `treehouse`,
or a batch that edits the flow machinery.

Otherwise use the direct background
`codex-run --lane implement --dir <repo> --req <R1,A3> --timeout 2700 "<task>"`
dispatch. While a run is open, every implement dispatch names its requirements;
open the run with `run-state.sh init ... --spec docs/specs/<plan>.md`, and defer
mid-flow discoveries with `run-state.sh defer <dir> "<text>"`.

If this repo has no `.charles.toml`, stop and offer `/charlesdr-dev-loop:init` first.

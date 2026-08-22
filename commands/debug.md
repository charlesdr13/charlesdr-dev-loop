---
description: Debug flow — diagnosing-bugs discipline, codex explore fleet on the cause, ground to truth, codex fix, verify
---

Run the **debug flow** from the `charles-flow` skill on: $ARGUMENTS

Invoke `charles-flow` and follow Flow 2 exactly. Build the feedback loop before
hypothesising (that is the `diagnosing-bugs` discipline, and it is the part that
actually finds bugs). Explorers return causes with `file:line` evidence, never
patches. Cap at 3 cycles, then stop and report.

When the confirmed fix plan yields 2+ disjoint file slices, read
`docs/specs/<plan>.chunks.json`, resolve
`SCRIPTS="$(dirname "$(readlink -f "$(command -v codex-run)")")"` as in
`commands/ui.md:22`, and invoke
`"$SCRIPTS/parallel-chunks.sh" "$(pwd)" docs/specs/<plan>.chunks.json` when
the valid manifest holds `parallel_min_chunks` or more entries. Use serial for
one chunk, overlapping declarations, an invalid manifest, missing `treehouse`,
or a batch that edits the flow machinery.

The serial implement step uses
`codex-run --lane implement --dir <repo> --req <R1,A3> --timeout 2700 "<task>"`;
while a run is open, every implement dispatch must name its requirements. Open
the run with `run-state.sh init ... --spec docs/specs/<plan>.md`, and defer
mid-flow discoveries with `run-state.sh defer <dir> "<text>"`.

If this repo has no `.charles.toml`, stop and offer `/charlesdr-dev-loop:init` first.

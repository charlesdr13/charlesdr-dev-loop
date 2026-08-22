---
description: Improvement flow — codex fleet finds gaps/must-haves/QoL wins, then brainstorm, grill, implement, verify
---

Run the **polish flow** from the `charles-flow` skill on: $ARGUMENTS
(no argument = this repo as a whole)

Invoke `charles-flow` and follow Flow 3. Give each explorer a different lens —
gaps, must-haves, quality-of-life — rather than asking three agents the same
question and getting three versions of the same answer.

When the survivor plan yields 2+ disjoint file slices, read
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

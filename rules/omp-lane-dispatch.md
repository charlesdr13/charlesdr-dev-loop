---
description: Under omp, a charlesdr-dev-loop lane is a task call, never codex-run in bash
condition: "codex-run(\\.sh)?\"?\\s+[^\\n|;&]*--lane"
scope: tool:bash
---
Stop. In omp, an explore, implement, or review lane is dispatched with the `task`
tool, not with `codex-run --lane` in bash. Use one `task` item per lane:
`agent: "claude-explorer"`, `"claude-implementer"`, or `"claude-reviewer"`, with
the `charles-dir:` (and, where the lane needs them, `charles-plan:`,
`charles-req:`, `charles-base:`) header lines opening `task`. Put a fan-out in
one `tasks[]` batch, and take the results as they arrive or call `wait`. The
`task` path is what gives each lane its own model and its receipts. Keep using
bash for the non-lane scripts (`run-state.sh`, `verify-receipt.sh`, `green.sh`).

---
description: Fast flow — the lean loop on a small or medium ask, one worktree implement lane, one review
---

Run the **lean loop** from the `charles-flow` skill on: $ARGUMENTS

For a small or medium ask. Needs a `.charles.toml` (else offer
`/charlesdr-dev-loop:init`); if a run is already open, offer
`/charlesdr-dev-loop:resolve`.

```bash
SCRIPTS="$(dirname "$(readlink -f "$(command -v codex-run)")")"
```

1. **Classify and baseline.** `debug`, `build`, or route out: UI/UX to
   `/charlesdr-dev-loop:ui`; 2+ chunks, flow machinery, or money/auth/concurrency
   work to `/charlesdr-dev-loop:feature` or `:debug`. Run `"$SCRIPTS/green.sh" "$(pwd)"`;
   red baseline means stop and offer `:debug`.
2. **Understand.** Read the code yourself. Only if the area is unfamiliar, one
   explore lane in a Bash call with `run_in_background: true`:
   `CHARLES_FAST_MODE=1 codex-run --lane explore --dir "$(pwd)" --timeout 2700 "<brief>"`.
   For a bug, confirm the cause against source yourself.
3. **Plan.** `docs/specs/YYYY-MM-DD-<topic>.md`, at most six `- [ ] **R#**`
   requirements, scope, green command. Open the run:
   `"$SCRIPTS/run-state.sh" init "$(pwd)" fast "<goal>" --spec docs/specs/<plan>.md`.
   No `.chunks.json`; if it needs 2+ chunks, route to `:feature`.
4. **Implement.** A small obvious edit: do it yourself. Otherwise one lane in a
   worktree (`treehouse get --lease --lease-holder fast-flow`, or
   `git worktree add .claude/worktrees/fast-<ts> HEAD`), via a Bash call with
   `run_in_background: true`, no `--run` (the worktree has no run directory):
   `CHARLES_FAST_MODE=1 codex-run --lane implement --dir "$WT" --plan "$(pwd)/<plan>" --req <all R IDs> --timeout 2700 "<brief naming ponytail>"`.
   Then `"$SCRIPTS/verify-receipt.sh" "$WT" --lane implement --since 2700`, and merge:
   `git -C "$WT" add -A && git -C "$WT" diff --cached HEAD | git apply --index`.
   The root must be clean first (apart from the plan); a dirty root or failed
   `apply` is a `FAILED` item and the diff stays in the worktree. Keep the
   worktree until green; return it after (`treehouse return --force "$WT"`, or
   `git worktree remove --force "$WT"`).
5. **Review once.** `CHARLES_FAST_MODE=1 codex-run --lane review --dir "$(pwd)" --plan "$(pwd)/<plan>" --timeout 540 "<focus>"`
   (foreground, outer timeout 600; background with `--timeout 2700` for a heavy
   diff). Exit 3 is an empty diff: a `FAILED` item. Verify findings against source;
   run one more implement cycle in the same worktree only for verified gaps.
6. **Green, sign off, close.** `"$SCRIPTS/green.sh" "$(pwd)"`, complete `## Sign-off`,
   `"$SCRIPTS/run-state.sh" close "$(pwd)" "<outcome>" --spec docs/specs/<plan>.md`.
   At most two implement/review/green cycles, then a `FAILED` item and a report.

Record `run-state.sh phase` at implement, review and green. Any lane failure,
non-zero `verify-receipt.sh`, or review exit 3 records
`"$SCRIPTS/run-state.sh" item "$(pwd)" FAILED "<what failed>"` and stops; never
rescue a failed lane inline. Never pass `--fast` or `--effort` to a luna lane
here; `CHARLES_FAST_MODE=1` keeps codex `fast_mode` on for luna (terra stays off).

# Sign-off gate

## Why

`flow-status.sh` proves the flow ran: an implement has a later review, a plan has
a grill verdict, no run is left open. Nothing proves the plan's *requirements*
were met one by one. The isolated reviewer grades the diff against the plan in
prose, and `green.sh` proves the repo still works — neither is a per-requirement
check, so a plan carrying eight requirements can close on a review paragraph that
silently covers six.

The gate is the missing half of `run-state.sh close`: closing is where the work
is declared done, so it is where each requirement has to be ticked with evidence.

## Requirements

1. `run-state.sh close <dir> "<outcome>" --spec <file>` refuses to close when
   `<file>` has no `## Sign-off` section. Exit code 6, message names the spec and
   the missing section. `--force` closes anyway, as it already does for open items.
2. It also refuses (same exit 6) when the `## Sign-off` section contains any
   unticked `- [ ]` line. An unmet requirement is either fixed or recorded as a
   run item; it never rides out under a closed run.
3. Both refusals happen before anything is written: no `## Outcome` block in
   `RUN.md`, no `## Run outcome` appended to the spec. A refused close is a no-op.
4. Close with no `--spec` is unchanged. The gate has nothing to read, and
   `flow-status.sh` already covers the plan-less case.
5. `## Sign-off` line format, documented in `skills/charles-flow/SKILL.md`:
   `- [x] <requirement, as written in the plan> — <evidence>`. Evidence is output,
   not assertion, per the existing proof protocol.
6. `skills/charles-flow/SKILL.md` gains a `## The sign-off gate` section next to
   `## The ground-truth gate`, and flows 1, 2 and 3 gain a sign-off step between
   their verify step and close. Flow 4 routes through the same close.
7. `scripts/selftest.sh` proves all of it against real files in a temp repo:
   refusal with no section, refusal with an unticked box, success with every box
   ticked, `--force` overriding both refusals, and no-`--spec` close unaffected.
   Also asserts requirement 3 — that a refused close leaves `RUN.md` and the spec
   byte-identical.
8. Version is 2.19.0 in `.claude-plugin/plugin.json` and both `version` fields of
   `.claude-plugin/marketplace.json`.
9. `bash scripts/selftest.sh && bash scripts/doctor.sh` stays green: 130 existing
   tests keep passing, doctor gains no new FAIL.

## Files in scope

- `scripts/run-state.sh` — the gate itself, in `close` only
- `skills/charles-flow/SKILL.md` — the gate's documentation and the flow steps
- `scripts/selftest.sh` — the tests
- `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` — version

## Files out of scope — do not touch

- `scripts/flow-status.sh` — its checks are structural and stay that way
- `scripts/doctor.sh`, `scripts/codex-run.sh`, `hooks/`, `commands/`
- Every file already carrying uncommitted changes for the 2.18.1 engine switch,
  beyond the two version files above

## What must keep working

`bash scripts/selftest.sh && bash scripts/doctor.sh`

## Convention to copy

`run-state.sh` close's existing open-items refusal (the `grep -q '^- \[ \] '`
block guarded by `$force`) is the shape to follow — same guard, same exit-before-
write ordering, a distinct exit code.

## Grill verdict

Grill skipped deliberately: the design is the user-approved shape from the
conversation that opened this run, and the gate is a refusal on a grep of a file
the flow already writes. The isolated review lane still grades the diff.

## Sign-off

- [x] close --spec refuses (exit 6) when the spec has no `## Sign-off` section — probed live on this spec before this section existed: `REFUSING to close — docs/specs/2026-08-20-signoff-gate.md is missing the ## Sign-off section.` exit=6 (run-state.sh:181-184)
- [x] close --spec refuses (exit 6) on any unticked `- [ ]` line, listing them — selftest `close refuses unticked sign-off requirement` (run-state.sh:191-196)
- [x] A refused close is a no-op — probed live: 0 `## Outcome` lines in RUN.md and 0 appended `## Run outcome` in the spec after the exit-6 refusal; four selftests assert byte-identity with `cmp -s`
- [x] Close with no --spec is unchanged — content checks guarded by `[ -n "$spec" ]`; selftest `close without --spec remains unaffected`
- [x] Line format `- [x] <requirement> — <evidence>` documented, matched exactly — SKILL.md `## The sign-off gate`
- [x] SKILL.md carries `## The sign-off gate`; flows 1-3 gained a sign-off step before close, flow 4 routes through the same close
- [x] selftest.sh proves all of it in a temp repo — 16 tests across the gate; the symlink guard proven non-vacuous by disabling it (`FAIL ... rc=0`) and restoring
- [x] Version is 2.19.0 in plugin.json and both marketplace.json fields
- [x] Green holds — `146 passed, 0 failed` (was 130); doctor `17 ok, 0 failing`

Hardening added during two review cycles, beyond the nine requirements above:

- [x] A `## Sign-off` section with no ticked line is refused — an empty section previously closed clean
- [x] A `--spec` resolving outside the repository is refused, and NOT overridable by `--force` — the outcome append would otherwise write through to a file outside the repo
- [x] A symlinked `--spec` is refused when `realpath` is unavailable to resolve it — the `cd`+`pwd -P` fallback resolves the directory chain but not a final symlink

## Run outcome — 2026-08-20

Sign-off gate shipped as 2.19.0: run-state.sh close --spec now refuses (exit 6) a plan with no ## Sign-off section, a section with no ticked requirement, or any unticked requirement — all before any write, so a refused close is a no-op. --spec resolving outside the repository is refused unconditionally (not overridable by --force, because the outcome append would write through it), as is a symlinked spec when realpath is unavailable. Documented as a named gate in charles-flow SKILL.md with a sign-off step in flows 1-4. Selftest 130 -> 146. Two isolated review cycles: first GAPS FOUND (empty section closes clean; --spec path traversal), second GAPS FOUND (final-symlink write-through in the no-realpath fallback); both fixed, third pass clean. The gate was proven on this run's own spec — the first close attempt was refused exit 6 and wrote nothing. Grill skipped deliberately. Three tooling bugs surfaced and carried to tasks-axi cdl-signoff-infra, not fixed here: the review lane silently grades an empty diff when --plan is outside the repo, the codex-reviewer agent can return a verdict with no dispatch receipt, and a refused dispatch reports exit 0. Unrelated uncommitted 2.18.1 engine-switch work left intact. Rollback: git checkout -- scripts/run-state.sh scripts/selftest.sh skills/charles-flow/SKILL.md .claude-plugin/ && rm docs/specs/2026-08-20-signoff-gate.md

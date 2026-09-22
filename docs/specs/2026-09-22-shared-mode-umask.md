# Shared-path mode check fails under umask 0002

## Cause

`scripts/parallel-chunks.sh:604-605` compares a shared file's full permission
bits (`stat -c '%a'`, e.g. `664`) against the last three digits of its git blob
mode (`100644` -> `644`). Git records only the executable bit, so any umask
other than `022` (this box: `0002`) makes every in-place edit look like a mode
change and rejects both chunks with "shared path '<p>' changed mode".

Evidence: `scripts/selftest.sh` fails "clean shared three-way merge must be
accepted" and "conflicting shared merge must reject before root mutation" under
umask 0002 (419/2) and passes 421/0 under `umask 022`, same tree.

## Fix scope

- [ ] **R1** `parallel-chunks.sh` compares only executability: the shared file
  must be executable iff the base mode is `100755`. Permission bits git does
  not track (group/other write, etc.) are ignored. A real exec-bit flip is
  still rejected with the same "changed mode" message.
- [ ] **R2** `selftest.sh` pins the regression: the two shared-merge cases pass
  regardless of the caller's umask (run them with `umask 0002` forced), and one
  case proves an exec-bit flip on a shared path is still rejected.

Files: `scripts/parallel-chunks.sh`, `scripts/selftest.sh`. Nothing else.

## Green

`bash scripts/selftest.sh && bash scripts/doctor.sh`

## Grill verdict

Grill waived: Flow 2 has no grill step by design.

## Sign-off

- [x] **R1** exec-bit-only comparison in `parallel-chunks.sh`. Proof: `434 passed, 0 failed`.
- [x] **R2** fixtures get `chmod g+w`, and a new exec-flip case is added. Proof: with the fix reverted under `umask 022`, `420 passed, 2 failed`; with the fix, `422 passed, 0 failed`. Opus review GAPS FOUND (the forced umask never reached the checked file) → fixed.

## Run outcome — 2026-09-22

Fixed: shared-path mode check compares exec bit only; regression pinned. Graded by an Opus subagent outside the dispatcher (pre-2.41 claude engine), so there is no review receipt.

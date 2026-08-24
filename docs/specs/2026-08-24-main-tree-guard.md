# Main-tree guard, and a scope check that stops lying

## Why

On 2026-08-24 a chunk-C implement lane, dispatched with `--dir` pointing at the
main checkout of `infra-orchestrator`, ran a `git checkout -- .`-class revert. It
destroyed two landed chunks and the operator's uncommitted edits to
`tests/conftest.py` and `src/infra_orchestrator/adapters/landing_factory.py`, then
reported "chunk B is not actually landed" — describing damage it had itself caused.
Its `git clean` was refused only because `clean.requireForce` happened to be set.

The dispatch brief carried the destructive-command prohibition verbatim. A lane
ignored it. A prohibition a lane can ignore is not a control, so the guard has to
be mechanical.

The lane was in the main tree because the parallel path had refused it for a
MACHINERY reason, not a scope reason: `parallel-chunks.sh` scope-checks with
`git status --porcelain -z -uall --ignored`, and the old parser treated a fresh
worktree running `npm install` as writing 34,154 gitignored `node_modules`
paths outside the chunk's declared files. Chunk A was rejected for installing
its own dependencies. Both halves are fixed here, because fixing only the guard
leaves the pressure that pushed the flow into the main tree.

## Requirements

- **G1** `codex-run.sh --lane implement` refuses to run when `--dir` resolves to a primary working tree of a git repository. Exit code 4, before the `start` event is written, so a refused dispatch orphans nothing.

- **G2** A pure filesystem walk first looks from `--dir` up to `/` for a `.git` file or directory. If none exists, the directory is not refused; if one exists, `git rev-parse --git-dir` against `--git-common-dir` distinguishes a linked worktree from a primary checkout. Any rev-parse failure refuses with exit 4, while an absent git binary still allows the dispatch. Bare repositories remain refused.

- **G3** The refusal message names the directory and points at the fix: `treehouse get`, then re-run with `--dir <that worktree>`.

- **G4** An explicit escape hatch exists for the case where the operator means it: `--allow-main-tree` on the command line, or `CHARLES_ALLOW_MAIN_TREE=1` in the environment. Both are logged into the dispatch record so a later audit can see the guard was waived.

- **G5** Only the `implement` lane is guarded. `explore` is read-only sandboxed and `review` never touches the repo it grades.

- **G6** `parallel-chunks.sh` keeps `--ignored` in its scope check. `!!` paths are reported with a count and a short path preview, then excluded from rejection and merge; untracked non-ignored paths and tracked undeclared paths still reject.

- **G7** A comment at that call site records why ignored setup output such as `node_modules` is reported but never rejected, so the scope check does not push the flow back into the main tree.

- **G8** `scripts/selftest.sh` proves all of it against real git repos in a temp dir: an implement dispatch into a primary checkout is refused with exit 4 and writes no `start` event; rev-parse failure refuses; the same dispatch into a linked worktree is allowed; both escape hatches allow it and mark the record in separate fixtures; explore and review into a primary checkout are unaffected; a non-git directory is unaffected; bare repositories remain refused; and the scope check reports but does not merge or reject a gitignored directory while still catching an undeclared tracked file.

- **G9** `skills/charles-flow/SKILL.md` states the rule where the lanes are described: implement lanes use a worktree by default, the machinery fallback is a hand-made worktree, and `--allow-main-tree` or `CHARLES_ALLOW_MAIN_TREE=1` is a deliberate, logged override.

- **G10** Version is 2.32.0 in `.claude-plugin/plugin.json` and both `version` fields of `.claude-plugin/marketplace.json`.

- **G11** `bash scripts/selftest.sh && bash scripts/doctor.sh` stays green: the 236 existing tests keep passing and doctor gains no new FAIL.

## Files in scope

- `scripts/codex-run.sh` — the guard, the flag, the env var, the log field
- `scripts/parallel-chunks.sh` — the `--ignored` removal and its comment
- `skills/charles-flow/SKILL.md` — the rule
- `scripts/selftest.sh` — the tests
- `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` — version

## Files out of scope — do not touch

- `scripts/run-state.sh`, `scripts/flow-status.sh`, `scripts/doctor.sh`
- `hooks/`, `commands/`, `docs/specs/` other than this file

## What must keep working

`bash scripts/selftest.sh && bash scripts/doctor.sh`

## Convention to copy

`codex-run.sh`'s existing single-writer refusal (the block ending at the
`treehouse get` hint, around line 626-632) is the shape to follow: a refusal
before the start event, a message that names the fix, a distinct exit code.

## Grill verdict

Grill skipped deliberately: the design is a mechanical restatement of a rule the
operator had already written into CLAUDE.md after the incident, and both halves
are refusals on facts git reports directly. The isolated review lane still grades
the diff.

## Sign-off

- [x] **G1** implement into a primary checkout refuses — proven live twice, in the worktree and again after merge: `REFUSING — implement dispatch cannot run against primary working tree: /home/del13s_ubuntu/MACH4_2/charlesdr-dev-loop`, `exit=4`
- [x] **G2** detection is git-dir vs git-common-dir, hardened past the original design: physical `pwd -P` probe, `rev-parse --is-bare-repository` in place of a config regex, a sanitized git environment, and any other rev-parse failure refusing rather than allowing
- [x] **G3** message names the directory and points at `treehouse get`, then `--dir <that worktree>` — asserted in `implement primary checkout is refused before start`
- [x] **G4** `--allow-main-tree` and `CHARLES_ALLOW_MAIN_TREE=1` both waive, and the waiver is recorded on the start and end records
- [x] **G5** only implement is guarded — explore into a primary checkout passes the guard (0 matches for the refusal text)
- [x] **G6** the scope check no longer rejects gitignored setup output; ignored paths are reported with a count, and an ignored symlink escaping the worktree still rejects
- [x] **G7** the comment at the call site names the `node_modules` case and says reported-never-rejected
- [x] **G8** selftests use real git repos and real worktrees — `249 passed, 0 failed`, up from 236; the GIT_DIR test proven non-vacuous by removing the sanitization (`FAIL … rc=0`) and restoring it
- [x] **G9** `skills/charles-flow/SKILL.md` states the rule and names the waiver as a deliberate, logged override
- [x] **G10** version is 2.32.0 in plugin.json and both marketplace.json fields
- [x] **G11** green holds — `249 passed, 0 failed`; doctor `22 ok, 0 failing`

Hardening added across three review cycles, beyond the eleven requirements:

- [x] Git errors no longer fail open — only a genuine "no repository anywhere up the tree" allows; a corrupt or unreadable repo refuses
- [x] A symlinked `--dir` can no longer make the walk ascend the wrong tree
- [x] An inherited `GIT_DIR` / `GIT_WORK_TREE` can no longer disguise a primary checkout as a linked worktree — verified: unsanitized git reports differing dirs for the main tree, sanitized reports `.git` / `.git`
- [x] Ignored paths are sanitized before printing, so a crafted filename cannot forge log lines

## Run outcome — 2026-08-24

Main-tree guard shipped as 2.32.0. codex-run.sh refuses an implement dispatch against a primary working tree with exit 4, before the start event, so a refused dispatch orphans nothing; --allow-main-tree and CHARLES_ALLOW_MAIN_TREE waive it and the waiver is logged on both records. Detection survived three adversarial review cycles: physical pwd -P probe (symlinked --dir bypass), rev-parse --is-bare-repository instead of a config regex (bare = 1/yes/on), a sanitized git environment (an inherited GIT_DIR made the main tree look linked), and fail-closed on any other rev-parse failure. parallel-chunks.sh keeps --ignored but reports ignored paths instead of rejecting them - the node_modules false rejection is what pushed the infra-orchestrator run into the main tree in the first place; an ignored symlink resolving outside the worktree still rejects. Selftest 236 -> 249. Guard proven live twice against this repo's own main checkout, and the GIT_DIR test proven non-vacuous by disabling the sanitization. Built entirely in a leased worktree, never the main tree. Closed with --force: the only outstanding flow-status ISSUEs are two 2026-08-21 orphan dispatches predating HEAD 6fdfcfa, carried to tasks-axi cdl-stale-orphans. Rollback: git checkout -- scripts/codex-run.sh scripts/parallel-chunks.sh scripts/selftest.sh skills/charles-flow/SKILL.md .claude-plugin/ && rm docs/specs/2026-08-24-main-tree-guard.md

# claude lane — sonnet @ medium for explore and implement

## Goal

Add a `claude` engine so exploration and implementation run on Claude Sonnet at
medium effort instead of a codex lane, and make the engine choice settable per
project rather than only globally.

Review is deliberately NOT included. In claude mode the review lane still
dispatches to codex sol @ medium: a grader from a different model family than
the implementer is the entire point of the isolated review.

## Grill verdict

- Rounds: 1

Round 1 (luna @ max, read-only) rejected the first draft with 10 findings; all
are folded in below. The three that would have shipped broken:

- `implement --read-only` would have received `bypassPermissions` while the
  writer lock at `codex-run.sh:1004` only engages for `workspace-write` — two
  concurrent read-only dispatches could both write, unlocked. Fixed in R3.
- `run_attempt` never creates `$RUN.last`; codex makes it itself via `-o`
  (`codex-run.sh:789`). A successful claude lane would leave `.last` absent and
  `lane-status.sh:170` would call it DEAD. Fixed in R4.
- "Per-project" was undefined for worktrees. Implement runs in a treehouse
  (`commands/fast-flow.md:170`) which never receives the gitignored
  `.charles/engine`, so explore would use claude and implement would silently
  use the global engine. Fixed in R6.

Verified during the grill, not assumed: `CHARLES_INLINE_OK=1` does silently
allow both routing hooks (real payloads, exit 0, no output) — no other variable
is needed for them.

## Requirements

- [ ] **R1. Engine accepted.** `--engine claude` is valid for `--lane explore`
  and `--lane implement`. Both engine validation `case` statements (near
  `codex-run.sh:990` and `:1040`) accept it alongside luna|terra|deepseek.

- [ ] **R2. Provenance is tracked separately from selection.** `ENGINE_SET` does
  not mean "explicit flag" — env and file resolution set it too
  (`codex-run.sh:210`). Add a distinct marker (e.g. `ENGINE_FROM_FLAG`) set only
  by the `--engine` argument, and use that wherever the flag/file distinction
  matters. Do not change what `ENGINE_SET` means for existing callers.

- [ ] **R3. Permission posture follows the sandbox, never the lane name.**
  The claude lane derives its posture from `$SANDBOX`, which `--read-only`
  already sets:
  - `workspace-write` → `--permission-mode bypassPermissions`
  - `read-only` → no bypass; pass
    `--disallowed-tools "Edit Write MultiEdit NotebookEdit"`
  This covers `--lane explore` and `--lane implement --read-only` by the same
  rule. An implement dispatch that skips the writer lock must never hold write
  permission.

- [ ] **R4. Result publication matches the deepseek adapter, not run_gpt.**
  `run_attempt` supervises and records rc; it does not create `$RUN.last`.
  The claude adapter writes stdout to a scratch file and only on rc=0 copies it
  to `$RUN.last`; on any non-zero rc it truncates `$RUN.last` to empty, exactly
  as `run_deepseek` does at `codex-run.sh:823`. Never redirect the live command
  straight into `.last`: `lane-status.sh:115` skips liveness inspection while
  `.last` is nonempty and `:163` then calls it DONE, so partial or error output
  would be published as the final result.

- [ ] **R5. The command.** Dispatched through `run_attempt` so the watchdog,
  process-group kill and `.charles/dispatches.jsonl` events work unchanged.
      claude -p --model claude-sonnet-5 --effort "$EFFORT" --output-format text
  - Pin the full model id, not the `sonnet` alias:
    `ANTHROPIC_DEFAULT_SONNET_MODEL` can silently repoint an alias, which would
    make the logged receipt lie about what ran.
  - Default `EFFORT` is `medium` when `--effort` was not given (mirror the
    `EFFORT_SET` handling the review lane uses for sol).
  - Logged engine `claude`, logged model `claude-sonnet-5`.
  - Prompt is `$TASK` plus the same `$GUARD` suffix `run_gpt` appends, plus
    `$LADDER` for implement.
  - `< /dev/null` and the same `timeout -k 30s "$TIMEOUT"` wrapper as `run_gpt`.

- [ ] **R6. Environment is sanitised, and the child is told it is the worker.**
  `run_attempt` passes the inherited environment through untouched
  (`codex-run.sh:675`); `setsid`/`timeout` do not sanitise it. The claude lane
  must run with:
  - `CHARLES_INLINE_OK=1` — without it this plugin's own `route-to-codex.sh`
    fires inside the lane and blocks the lane's edits.
  - `CLAUDECODE` and `CLAUDE_CODE_EFFORT_LEVEL` unset. The former has broken
    nested print launches; the latter overrides `--effort` and would make the
    receipt false.
  - An appended instruction stating the lane IS the worker and must do the work
    itself — it must not dispatch another lane, invoke `codex-run`, or spawn a
    subagent. Suppressing the hooks does not remove `CLAUDE.md:9`, which
    otherwise tells a compliant child to redispatch.

- [ ] **R7. `--resume` is refused for claude.** Exit 2 with a message. Codex
  handles resume explicitly (`codex-run.sh:782`); `claude --continue` would pick
  the newest conversation in the directory, which may be the orchestrator or
  another lane. The text adapter records no session id, so correct resume is not
  available and silently starting fresh is worse than refusing.

- [ ] **R8. Per-project engine, resolved at the run root.** Resolution order,
  highest first: explicit `--engine` flag; `CHARLES_ENGINE`; per-project file;
  global `$STATE_DIR/engine`. The per-project file lives at
  `<run root>/.charles/engine` where the root comes from `charles_run_root`
  (`run-common.sh:6`), which resolves a linked worktree to its common directory
  — so a treehouse implement lane reads the same preference the primary checkout
  wrote. Engine resolution currently runs before root resolution
  (`codex-run.sh:206`); reorder or resolve the root early as needed. `claude` is
  a valid value at every layer. The deepseek peak-window substitution keeps
  working unchanged.

- [ ] **R9. Review never breaks because of a project setting.**
  - `--engine claude --lane review` (explicit flag, per R2) → exit 2, message
    naming sol.
  - `claude` arriving from `CHARLES_ENGINE`, the project file, or the global
    file → the review lane runs on sol @ medium. It must NOT fall through to
    the next layer: with a global `terra` that would produce terra @ max.
  - An explicit `--effort` on review is still honoured, as today
    (`codex-run.sh:935`); only the unset default becomes medium.

- [ ] **R10. `/engine` writes per project by default.** In `commands/engine.md`:
  `claude` is an accepted value; `/engine <value>` writes the per-project file
  (same root as R8) when the cwd is inside a repo containing `.charles.toml`,
  otherwise the global file; `/engine global <value>` always writes global;
  `/engine default` clears the per-project file and `/engine global default`
  clears the global one. The echoed line names the scope in effect and the
  resolved engine, so a project override is never invisible.

- [ ] **R11. `mark-inline-ok.sh` gains the same bypass.** It has no
  `CHARLES_INLINE_OK` check (unlike `route-to-codex.sh:27` and
  `route-subagents.sh:27`), so a lane's edit against a fresh `pending-ask` for
  the same file converts it to `inline-ok` — the outer session inherits an
  approval no human gave, and success-only cleanup (`codex-run.sh:1085`) never
  removes it after a failed dispatch. Add the bypass at the top, matching the
  other two hooks.

- [ ] **R12. `doctor.sh`** reports FAIL when the resolved engine is `claude` and
  the `claude` binary is not on PATH, matching how it treats a missing codex.

- [ ] **R13. Tests** in `scripts/selftest.sh`, using the existing
  fake-binary-on-PATH pattern. Argv assertions alone are not enough — cover the
  contracts, not just the flags:
  - explore builds a command with `--model claude-sonnet-5` and `--effort medium`
  - implement (workspace-write) passes `--permission-mode bypassPermissions`;
    `implement --read-only` does NOT, and passes the disallowed-tools list
  - the lane runs with `CHARLES_INLINE_OK=1` and without `CLAUDECODE`
  - rc=0 publishes stdout to `$RUN.last`; a non-zero rc leaves `$RUN.last` empty
  - `--engine claude --resume` exits 2
  - explicit `--engine claude --lane review` exits 2
  - a project `.charles/engine` of `claude` runs review on sol even when the
    global file says `terra`
  - precedence: `CHARLES_ENGINE` beats the project file, which beats global
  - a dispatch with `--dir` pointing at a linked worktree reads the primary
    checkout's project engine file

- [ ] **R14. Version** 2.38.0 in all three places: `.claude-plugin/plugin.json`
  and both `version` fields in `.claude-plugin/marketplace.json`.

- [ ] **R15. Docs.** The engine list in the `codex-run.sh` header comment,
  `commands/engine.md`, and the engine section of `README.md` describe the claude
  engine and the per-project scope. Match the existing terse register.

## Explicit non-goals

- No fallback chain change. A failed claude dispatch is reported as a failure;
  it does not fall back to deepseek and does not escalate to terra.
- No new key in `.charles.toml`. The mode is a preference, not a fact about the
  repo, and committing it would dirty the tree on every switch.
- `doctor.sh` keeps requiring a luna profile even in claude mode. Review still
  runs on codex, so codex remains a real dependency of a complete flow; making
  doctor's checks track the selected lanes is a separate change.
- No change to `run_gpt`, `run_deepseek`, or the review prompt.

## Known ceiling

`--disallowed-tools` blocks the edit tools but not a write performed through
Bash, so a read-only claude lane is weaker isolation than codex's `-s read-only`
sandbox. Mark it with a `ponytail:` comment naming the ceiling. Do not build a
sandbox for it.

## Green

bash scripts/selftest.sh && bash scripts/doctor.sh

## Sign-off

- [x] **R1-R2.** `--engine claude` accepted for explore/implement; `ENGINE_FROM_FLAG`
  added so flag-vs-file provenance survives resolution — selftest, 32 new checks.
- [x] **R3.** Permission posture follows `$SANDBOX`: read-only gets no bypass.
  Asserted directly — `implement --read-only` does not pass `bypassPermissions`.
- [x] **R4.** `$RUN.last` published only on rc=0 and truncated on failure, per the
  deepseek adapter. Asserted both directions.
- [x] **R5-R6.** Pinned `claude-sonnet-5`, not the alias; env sanitised
  (`CHARLES_INLINE_OK=1` set, `CLAUDECODE` unset); stdin proved `/dev/null` via
  `readlink /proc/$$/fd/0`; worker instruction carried in the prompt.
- [x] **R7.** `--engine claude --resume` exits 2.
- [x] **R8.** Per-project engine resolved at `charles_run_root`, so a linked
  worktree reads the primary checkout's preference — asserted with a real worktree.
  Peak-window deepseek substitution verified unchanged: `PEAK_SUB` is write-only
  in HEAD and after, so peak-substituted luna keeps `weekly_quota_fast_mode`.
- [x] **R9.** Explicit `--engine claude --lane review` exits 2; a project-file
  `claude` runs review on sol even when the global file says `terra`.
- [x] **R10.** `/engine` project-by-default, `global` prefix, scope echoed.
  Verified live against the real command block, including the sol-caught defect:
  `clear`/`reset` outside a project now clears the global file, not a phantom
  project path.
- [x] **R11.** `mark-inline-ok.sh` gained the `CHARLES_INLINE_OK` bypass, closing
  the pre-existing hole where a lane's edit could convert a fresh `pending-ask`
  into a human-looking `inline-ok`.
- [x] **R12.** `doctor.sh` FAILs when the resolved engine is claude and the binary
  is absent.
- [x] **R13-R15.** 32 contract checks, version 2.38.0 in all three places, docs
  updated in `codex-run.sh` header, `commands/engine.md`, `README.md`.

Green, measured against a clean `e7a1c08` checkout under the same `umask 0002`:
clean 363 passed / 2 failed, 1 doctor FAIL; after 395 passed / 2 failed, 1 doctor
FAIL. Same two failures (shared three-way merge, umask-sensitive) and the same
pre-existing luna-profile FAIL. Net +32 checks, no regressions.

Isolated sol review: R3/R4/R8/R9 confirmed honoured in code. One defect found and
fixed (R10 above). Two findings dismissed with evidence — the deepseek fast_mode
doc change corrects stale text rather than contradicting R8, and
`.claude/settings.local.json` is a pre-existing untracked file dated 08-13, not
part of this change.

## Run outcome — 2026-09-08

claude engine (claude-sonnet-5 @ medium) for explore/implement + per-project engine scope; 32 new checks, no regressions. Forced: the outstanding dispatch is the 18:52 implement that stopped to ask about selftest's git usage and wrote nothing — no diff exists to grade. The 19:07 implement that did the work was reviewed by sol at 19:16.

# Proof-gated review, and cstack by default in Claude, Codex and Grok (3.1.0)

Goal: review findings are acted on only when a run proves them (borrowed from
Cursor pstack's `interrogate`), and the flow is the default for non-trivial
build/fix work whichever harness orchestrates: Claude Code, Codex or Grok.

Asked by Charles 2026-11-04: "go upgrade cstack, also make codex, claude, grok,
use it by default".

Green: `bash scripts/selftest.sh && bash scripts/doctor.sh`.
Conventions to copy: `scripts/codex-run.sh` engine-preference block (around
line 225), `agents/claude-reviewer.md` report section.

## Requirements

- [x] **R1** Both review prompts (`agents/claude-reviewer.md` and the codex/grok
  review prompt in `scripts/codex-run.sh`) require every `Critical:` and
  `Required:` defect finding to end with a `Repro:` line: one shell command, run
  from the repo root, that fails or prints the wrong result while the defect
  exists, or `Repro: none (<why it cannot be run>)`.
- [x] **R2** `skills/charles-flow/SKILL.md` step 5: the orchestrator runs each
  finding's `Repro:` in the implemented tree before acting. A finding is proven
  when the run shows the failure; only proven findings are fixed and re-checked
  in round 2. An unproven finding is recorded as a `DEFERRED` item
  (`unproven: <finding>`), not fixed, except findings with no `Repro:` line (a
  missing requirement or check) and `Critical:` findings on money, auth/security
  or data loss, which are still checked from source. Sign-off
  states how many findings were proven and how many were dropped.
- [x] **R3** `scripts/codex-run.sh`: when the engine comes from the built-in
  default (no `--engine`, env or engine file) and resolves to `claude`, but the
  caller is not Claude Code (`CLAUDECODE` unset), the engine becomes `luna` when
  an ancestor process is `codex` and `grok` when it is `grok`, with one stderr
  line saying so. `CHARLES_ORCHESTRATOR=claude|codex|grok` pins the detection.
  An explicit `--engine claude` is never swapped. Selftest asserts the codex,
  grok and explicit-flag cases.
- [x] **R4** `skills/charles-flow/SKILL.md` runs outside Claude Code: no
  `${CLAUDE_PLUGIN_ROOT}` paths (scripts resolve from `codex-run` on PATH), and a
  short "Orchestrating from Codex or Grok" section: no `/cstack:*` commands, run
  the loop directly, every lane is a `codex-run --lane` Bash call.
- [x] **R5** Default on: a repo without `.charles.toml` no longer stops the
  flow. The skill runs `init-repo.sh` itself (green inferred), says so in one
  line, and continues. Small asks still skip the flow. The skill description no
  longer says "Not for repos without a .charles.toml".
- [x] **R6** `scripts/install-skills.sh --codex` links the skills into
  `~/.codex/skills` (plus `codex-run` on PATH).
- [x] **R7** Version 3.1.0 in all three manifest fields; README notes the
  proof-gated review and the Codex/Grok install.
- [x] **R8** `scripts/doctor.sh` uses the same built-in default engine as
  `codex-run.sh` (`claude` unless `CHARLES_DEFAULT_ENGINE` says otherwise), so an
  unconfigured machine no longer fails doctor on a missing luna profile (found
  2026-11-04: doctor exited 1 on master).

Out of scope: a per-repo verify skill (pstack `create-verification-skill`, next
item), the `correct` audit, Codex lanes for engine=claude.

Grill waived: no money, auth, migration or destructive change; 8 requirements.

## Sign-off

- [x] **R1** — `Repro:` paragraph in `agents/claude-reviewer.md` and the codex-run review prompt; selftest greps both
- [x] **R2** — step 5 "Prove before fixing"; review fix: findings with no `Repro:` and any Critical on money, auth/security or data loss are checked from source (the reviewer's own carve-out finding was one, its repro grep matched other lines)
- [x] **R3** — swap in codex-run.sh after the built-in default; 4 selftest cases (pinned codex, pinned grok, real codex parent, explicit `--engine claude` kept); review fix: selftest pins `CHARLES_ORCHESTRATOR=claude`, proven by `CHARLES_ORCHESTRATOR=codex bash scripts/selftest.sh` going 480/1 → 481/0
- [x] **R4** — no `CLAUDE_PLUGIN_ROOT` in the skill; scripts from `$SCRIPTS`; review fix: no `codex-run` on PATH now stops the flow (repro showed `SCRIPTS` falling back to a wrong directory)
- [x] **R5** — automatic `init-repo.sh`; description and plugin.json no longer say opt-in only
- [x] **R6** — `install-skills.sh --codex`
- [x] **R7** — 3.1.0 in plugin.json and both marketplace.json fields; README sections (Grok line also installs `codex-run`)
- [x] **R8** — doctor defaults to engine claude; doctor rc 1 → 0 on this machine
- [x] Review: 4 proven (R2 Repro-less, R3 leak, R4 PATH, R2 carve-out checked from source), 0 dropped; nits taken: restored "stop" on the green-fix cap, stale descriptions. Nits deferred: doctor does not apply the Codex/Grok swap, Grok detection only matches a process named `grok`, a mistyped `CHARLES_ORCHESTRATOR` is silent, install-skills.sh reads only `$1`.
- [x] Green: selftest 481 passed, 0 failed (also 481/0 with `CHARLES_ORCHESTRATOR=codex`); doctor rc 0

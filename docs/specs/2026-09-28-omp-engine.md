# omp engine: lanes on any model, omp as the default harness

Goal: the orchestrator runs in omp (Opus 5.5, pinned by `~/.omp/agent/config.yml`
`modelRoles.default`, no enforcement code). Lanes run as headless omp processes
on a different model family per lane. The codex/grok/claude engines stay as they are.

User decisions (2026-09-27): lane models are mixed families: explore
`xai-oauth/grok-4.7`, implement `openai-codex/gpt-5.6-luna`, review
`openai-codex/gpt-5.6-sol`. Orchestrator pin is config only.

## Facts (sourced)

- Engine selection: flag/env/project/global at `scripts/codex-run.sh:219-244`;
  validation `:1161`; dispatch table `:1225-1232`; CLI presence checks `:1170-1187`;
  fallback only for luna|terra `:1248`; `--resume` refusal for claude `:252-255`.
- The engine string is used in filenames: `codex-run.sh:118`
  (`${watchdog_done%.done}.${watchdog_engine}.end`) and `:632` (`$RUN.$1.end`),
  both `mkdir`ed. A `/` in the engine breaks them, so the engine value stays `omp`
  and the model rides in a separate variable.
- `log_dispatch` maps engine to model at `codex-run.sh:640-649`.
- grok is the template: `run_grok` `codex-run.sh:910-942`, review branch
  `:1116-1133`, selftest grok contracts `scripts/selftest.sh:3350-3618`.
- omp CLI (checked with `omp --help`, `omp models`): `--model provider/model`,
  `--thinking off|minimal|low|medium|high|xhigh|max|auto`, `--cwd`, `--tools`
  (read,bash,edit,write,glob,grep,…), `--approval-mode yolo`, `--no-session`,
  `--no-skills`, `-p`. Unknown model gives exit 1.
- The installed plugin's `hooks/pre/charles.ts` loads in every omp process and
  gates edits via `hooks/route-to-codex.sh`, which `CHARLES_INLINE_OK=1` bypasses (`:27`).
- `hooks/link-dispatcher.sh:21-29` refuses a git working tree. omp's plugin cache
  `~/.omp/plugins/cache/plugins/charlesdr-dev-loop___*` is a git checkout, so an
  omp-only install never gets `codex-run` on PATH.
- `scripts/release.sh:75-107` installs and verifies Claude Code only. `scripts/doctor.sh:18-40`
  checks engine dependencies, and treats missing codex as FAIL unless engine=claude.
- `commands/engine.md:17-28` validates engine values with a closed list.

## Requirements

- [ ] **R1** — `codex-run --lane explore|implement --engine omp` runs
  `omp -p --no-session --no-skills --model <m> --thinking <effort> --cwd <dir> --approval-mode yolo`
  with stdin from /dev/null. Default `<m>` is `xai-oauth/grok-4.7` for explore and
  `openai-codex/gpt-5.6-luna` for implement. Explore adds `--tools read,grep,glob,bash`.
  The lane env carries `CHARLES_INLINE_OK=1`. The prompt carries the same "you ARE
  the worker lane" guard grok's does. Effort passes through unchanged (omp accepts `max`).
  No deepseek fallback. `--resume` exits 2. Only the `omp` CLI is required (not
  codex). The dispatch record has `engine:"omp"` and `model:` = the model actually run.
- [ ] **R2** — `codex-run --lane review` with an omp preference runs omp in the
  isolated review box (`--cwd <box>`, `--tools read,grep,glob`, default model
  `openai-codex/gpt-5.6-sol`). It publishes `RUN.last` and `RUN.diff` and removes
  the box on success and on failure, the same way the grok review branch does.
- [ ] **R3** — The engine value `omp:<provider>/<model>` (from `--engine`,
  `CHARLES_ENGINE`, `.charles/engine`, or the global engine file) sets `ENGINE=omp`
  and overrides the model for every lane. The `/` never reaches a filename.
  Grammar: exactly `omp`, or `omp:` followed by a non-empty model string passed
  verbatim to `omp --model` (omp resolves it; an unknown model exits 1 at dispatch).
  `omp:` with nothing after it is an unknown engine (exit 2, the error lists `omp`).
  `commands/engine.md` accepts and reports `omp` and `omp:<provider>/<model>`.
- [ ] **R4** — `hooks/link-dispatcher.sh` links `codex-run` to the omp plugin cache
  copy when that is the only installed copy (a git checkout under
  `~/.omp/plugins/cache/plugins/`). Any other git working tree is still refused.
  `scripts/release.sh`, after the Claude steps, refreshes omp when `omp` is on PATH
  (`omp plugin marketplace update charlesdr-dev-loop`, then
  `omp plugin install charlesdr-dev-loop@charlesdr-dev-loop --force`, then check that
  `~/.omp/plugins/cache/plugins/charlesdr-dev-loop___charlesdr-dev-loop___$VERSION` exists)
  and fails the release if any of those fails. `scripts/doctor.sh`: omp missing is
  WARN, or FAIL when the engine is omp. Missing codex or luna is WARN, not FAIL, when the engine is omp.
- [ ] **R5** — Docs: `commands/engine.md`, `skills/charles-flow/SKILL.md`, and the
  README engine list describe the omp engine and its per-lane models. They also note
  the omp tool equivalents for an omp orchestrator: bash `async: true` = `run_in_background: true`,
  and the `task` tool = the Agent tool. The version is 2.44.0 in `.claude-plugin/plugin.json`
  and both `version` fields of `.claude-plugin/marketplace.json`.
- [ ] **R6** — `scripts/selftest.sh` covers R1-R4 with a stub `omp` binary on PATH,
  mirroring the grok cases: argv per lane, default and overridden model,
  `CHARLES_INLINE_OK=1` in the lane env, the review box holding two files and being
  removed, rc≠0 with no fallback, `--resume` refused, the omp-only PATH, the
  `omp:<m>` preference with `/` (no stray files), and link-dispatcher accepting the
  omp cache while still refusing another git tree.

Files in scope: `scripts/codex-run.sh`, `scripts/selftest.sh`, `scripts/doctor.sh`,
`scripts/release.sh`, `hooks/link-dispatcher.sh`, `commands/engine.md`,
`skills/charles-flow/SKILL.md`, `README.md`, `.claude-plugin/plugin.json`,
`.claude-plugin/marketplace.json`. Nothing else.

Must keep working: `bash scripts/selftest.sh && bash scripts/doctor.sh` (the
`green` command). Copy conventions from the grok engine.

Out of code scope, done by the orchestrator after release: `/engine global omp`
(the global preference is currently `claude`).

Chunking: 6 requirements over one seam. Chunk A = R1, R2, R3 (codex-run +
engine.md + selftest). Chunk B = R4, R5, R6 remainder (hooks, doctor, release,
docs, version, selftest). Both edit flow machinery, so they run serially with
green between them, and no `.chunks.json` is written.

## Grill verdict — 2026-09-28

- Rounds: 2
- Attacks raised: 11 — resolved from source: 9, changed the plan: 2, escalated: 0
- Plan changes: R3 now defines the `omp` / `omp:<model>` grammar and refuses an empty `omp:`; R4 names the exact omp refresh commands and the versioned cache dir it verifies.
- Resolved: missing omp branches at codex-run.sh:229/242/1161/1173-1187/1225/1050 are the work itself (R1-R3); `--thinking max` confirmed by `omp --help`; omp cache is `~/.omp/plugins/cache/plugins/charlesdr-dev-loop___charlesdr-dev-loop___<ver>` with `.git` (ls, `omp plugin install` output 2026-09-28); charles.ts loads in omp's own Bun runtime (live gate test 2026-09-27, no Node dependency); no fallback on omp failure is intended (codex-run.sh:1248).
- Round 2: zero survivors. The user decided model mapping and orchestrator pinning on 2026-09-27.
- Accepted risks: an explore lane's bash tool can still write (same ceiling as grok, codex-run.sh:917-920); the lane loads this repo's CLAUDE.md, which says to delegate, and relies on the worker-lane prompt guard plus `--no-skills` rather than a hard block; model auth failures surface only as rc=1 at dispatch time, since doctor does not probe provider login.
- Unresolved: none

# no-mistakes as the final gate (2.50.0)

Charles, 2026-10-26: "do recom" on "use no-mistakes as the final check where a repo already runs it, instead of also running the plugin review".
Fleet rule already says no-mistakes repos and dev-loop-review repos are "never both"; the flow still demanded its own review receipt, so no-mistakes repos paid for two reviews or closed with `--force`.

A no-mistakes repo is one where `git -C <repo> remote get-url no-mistakes` succeeds (the remote `no-mistakes init` adds).

## Requirements

- [ ] **R1** — `skills/charles-flow/SKILL.md` step 5: in a no-mistakes repo, skip the plugin's isolated review; commit on a feature branch and push through the no-mistakes pipeline (`/no-mistakes`, the plan's goal and requirements as `--intent`); its review, tests and CI are the gate. Then record `run-state.sh phase "$(pwd)" review "no-mistakes: passed, <PR url>"`, running `green.sh` before the push. Elsewhere the isolated review stays. One short paragraph; the skill stays at most 260 lines.
- [ ] **R2** — `scripts/flow-status.sh`: when closing a run in a no-mistakes repo whose RUN.md has a `review` phase whose own proof block says `no-mistakes: passed`, implement dispatches attributable to that run that were never reviewed are reported as one NOTE ("graded by no-mistakes") instead of an ISSUE, so close succeeds without `--force`. Without the remote, or without that phase, behaviour is unchanged. Repo-backlog (not this close) findings are unchanged.
- [ ] **R3** — Selftest: (a) no-mistakes remote + review phase mentioning no-mistakes + an ungraded implement for the run → close exits 0 and prints the NOTE; (b) same without the remote → still an ISSUE / close refuses; (c) remote present but no such phase → still an ISSUE; (d) a failed no-mistakes review, or no-mistakes mentioned only in a later phase → still an ISSUE.
- [ ] **R4** — `README.md` and `commands/status.md` (if it lists close blockers) mention the no-mistakes path in one or two lines. Version 2.50.0 in `.claude-plugin/plugin.json` and both `version` fields of `.claude-plugin/marketplace.json`.

Out of scope: running or wrapping no-mistakes from codex-run; changing receipts.

Green: `bash scripts/selftest.sh && bash scripts/doctor.sh`.

## Grill verdict

Grill waived: small, reversible, directly requested; behaviour outside no-mistakes repos is pinned by R3(b)/(c).

## Sign-off

- [x] **R1** — SKILL.md step 5: green.sh first, push through /no-mistakes with the plan as --intent, record `review "no-mistakes: passed, <PR>"`; 258 lines, cap pinned by selftest — review round 2 resolved
- [x] **R2** — flow-status counts only the `review` phase's own proof block saying `no-mistakes: passed`, only with the remote; repo-backlog path unchanged — review round 2 resolved
- [x] **R3** — 5 cases: graded, no-remote, no-phase, failed, later-phase; mutation to loose matching fails 2 of them — selftest 471 passed, 0 failed
- [x] **R4** — README paragraph, commands/status.md line, 2.50.0 in plugin.json and both marketplace.json fields

## Run outcome — 2026-10-26

shipped 2.50.0 (PR #6, installed)

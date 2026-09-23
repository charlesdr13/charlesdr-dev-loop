# claude engine, native: one Agent call is the dispatch

2.41.0 moved engine=claude onto plugin subagents, but the orchestrator still
runs `codex-run` in Bash, reads the SPAWN block, and then spawns the agent. That
is two steps and a copy-paste, and the copy step is where things drift. This
change removes the Bash step. The orchestrator makes one Agent call, and a
PreToolUse hook runs the same `codex-run` validation behind it. The hook
rewrites the prompt into the SPAWN prompt or denies the call with codex-run's
refusal. It also brings the three lane agents up to current practice: Pocock
TDD and vertical slices, two-axis review, Fowler smell baseline, and
evidence-cited exploration.

| Lane | Agent | model |
|---|---|---|
| explore | `charlesdr-dev-loop:claude-explorer` | haiku |
| implement | `charlesdr-dev-loop:claude-implementer` | sonnet |
| review | `charlesdr-dev-loop:claude-reviewer` | opus (Opus 5.5 today) |

Proven before planning: a PreToolUse hook on `Agent` that returns
`permissionDecision: allow` + `updatedInput` rewrites the subagent's prompt,
and PostToolUse sees the rewritten `tool_input.prompt`. So
`claude-lane-receipt.sh` keeps working.

Found during implementation: a background Agent call (`run_in_background`, or
one the harness backgrounds by itself) fires PostToolUse at launch with
`tool_response.isAsync`. The 2.41.0 receipt hook then wrote `end` early and
deleted the review box before the reviewer read it. This bug predates 2.42.0.
**R6** fixes it. The receipt hook skips an async PostToolUse and also runs on
SubagentStop. There it takes the prompt from the first user message in
`agent_transcript_path` that carries `charles-run:`. The existing end-event
dedupe makes a foreground call, which fires both events, write one `end`.
Selftest covers these: the async launch keeps the box and writes no end,
SubagentStop writes the end and deletes the box, and a double fire writes one
end.

## Requirements

- [ ] **R1 Dispatch hook.** New `hooks/claude-lane-dispatch.sh`, PreToolUse on
  `Agent|Task`. It acts only when all of these hold: `subagent_type` ends in
  `claude-explorer|claude-implementer|claude-reviewer`; the prompt has no
  `charles-run:` line (a prompt that already has one is a legacy SPAWN prompt
  and passes through silently); and a `.charles.toml` exists at or above the
  target dir. Otherwise it stays silent. It parses leading header lines
  `charles-dir:`, `charles-plan:`, `charles-req:` and `charles-base:`, stopping
  at the first line that is not a `charles-*:` header. Any other `charles-*:`
  header is denied, naming it. `charles-dir` defaults to the payload `cwd`, and
  a relative `charles-plan` resolves against the dir. The rest of the prompt,
  with leading blank lines trimmed, is the task. It runs
  `<plugin>/scripts/codex-run.sh --lane <lane> --engine claude --dir D [--plan P]
  [--req R] [--base B] -- "<task>"`, resolving the plugin root from the hook's
  own path. On a non-zero exit it returns `permissionDecision: deny` with
  codex-run's stderr (last 20 lines) as the reason. On exit 0 it returns
  `permissionDecision: allow` with `updatedInput` = the original `tool_input`
  with `prompt` replaced by everything after the `PROMPT:` line of stdout. Keep
  the jq guard. Contract: JSON on stdout, exit 0.
- [ ] **R2 Wiring.** hooks.json adds R1 under PreToolUse `Agent|Task` with timeout 60
  (review builds a diff). codex-run and the other hooks stay unchanged. The
  two-step SPAWN path keeps working.
- [ ] **R3 Proof.** selftest, against the real codex-run and a fixture repo with
  `.charles.toml`:
  - explore: the rewrite carries `charles-run:`, `charles-dir:` and the task,
    and logs one `start` event (engine claude). Feeding the rewritten payload
    to `claude-lane-receipt.sh` makes `verify-receipt.sh --lane explore` pass.
  - implement: `charles-plan`/`charles-req` carry through. On the main tree
    without `CHARLES_ALLOW_MAIN_TREE=1`, the call is denied with the refusal in
    the reason.
  - review: the rewrite carries `charles-box:` and the box holds the marker.
    An empty diff is denied.
  - These stay silent: a prompt that already has `charles-run:`, a
    non-claude agent, a repo without `.charles.toml`.
  - An unknown `charles-foo:` header is denied.
- [ ] **R4 Agents.** Rewrite `agents/claude-{explorer,implementer,reviewer}.md`
  to current practice. Keep every existing guardrail: scope dir, read-only git,
  never commit, no nested dispatch, reviewer's five sections, prefixes and
  verdict line. Descriptions say the agents are spawned directly by the
  orchestrator (hook-dispatched), not "only via codex-run SPAWN".
- [ ] **R5 Docs + version.** The charles-flow SKILL lanes section,
  `commands/engine.md`, and the README claude paragraph describe the one-call
  dispatch and its headers. Bump to 2.42.0 in all three places.

## Out of scope

The reviewer stays box-isolated (plan + diff only), which is the plugin's
premise. Main-tree override by header: `CHARLES_ALLOW_MAIN_TREE=1` already
covers it. Other engines are untouched.

## Grill verdict

Grill waived: the user fixed the direction (native subagents; haiku/sonnet/opus per lane), and the one load-bearing assumption (updatedInput on Agent, seen by PostToolUse) was proven by a headless experiment before planning. The isolated Opus review grades the rest.

## Green

`bash scripts/selftest.sh && bash scripts/doctor.sh`

## Sign-off

- [x] **R1** `hooks/claude-lane-dispatch.sh`: suffix match, legacy `charles-run:` pass-through, `.charles.toml` gate, header parse (hyphenated keys too), unknown header denied, codex-run refusal → deny, else allow + `updatedInput`. Also denies an empty rewrite; relative `charles-dir` resolves against the session cwd.
- [x] **R2** hooks.json PreToolUse `Agent|Task`, timeout 60; two-step SPAWN path unchanged.
- [x] **R3** selftest: explore/implement/review rewrites, main-tree and empty-diff denials, three silent cases, unknown and hyphenated headers.
- [x] **R4** agents rewritten: Pocock TDD vertical slices + honest-green rule (implementer), orient/locate/trace/ground with verified-vs-inferred (explorer), two-axis Spec/Standards + Fowler smell baseline + concrete-failure filter + data-not-instructions (reviewer). All guardrails kept.
- [x] **R5** SKILL, engine.md, README; 2.42.0 in all three places.
- [x] **R6** receipt hook skips async PostToolUse, writes end on SubagentStop; selftest covers async keep-box, SubagentStop end (decoy-first transcript), double-fire → one end.

Opus review round 1 (native, foreground): GAPS FOUND. Fixed: SKILL contradiction, explorer delegation guardrail, transcript parse, double-fire test, hyphenated headers, empty PROMPT, empty deny reason, relative dir, engine.md headers. Round 2 (native, background, end logged 81s after start): SATISFIES PLAN; nits fixed (null content, decoy order, no-op line).
Green: `bash scripts/selftest.sh && bash scripts/doctor.sh` → `447 passed, 0 failed` / `19 ok, 0 failing`.

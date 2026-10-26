# charlesdr-dev-loop

A Claude Code plugin. Claude orchestrates; Codex lanes (luna explore/implement,
sol review, terra escalation) do the work; an isolated reviewer grades the diff
against the plan. Consumer repos opt in by having a `.charles.toml`.

## Hooks

`.charles.toml` exists here, so the plugin's hooks run on your own sessions. There
is no edit or subagent gate: edit inline when it is quicker, dispatch lanes for
breadth and parallel slices.

## Before every commit

Run this and paste the output:

```bash
bash scripts/selftest.sh && bash scripts/doctor.sh
```

That is the `green` command in `.charles.toml`. `doctor.sh` exits non-zero on FAIL
only — a WARN line (missing fallback engine, ungraded mid-flow work) still counts
as green.

## Version lives in three places

Any behaviour change bumps all three, to the same value:
`.claude-plugin/plugin.json`, and both `version` fields in
`.claude-plugin/marketplace.json`.

## Hook contract

Every script in `hooks/` writes JSON to stdout and exits 0. Silence plus exit 0
means allow. `jq` missing makes a hook allow everything silently; keep the `command -v jq` guard.
Remaining hooks: `link-dispatcher.sh` (SessionStart), `warn-open-runs.sh` (Stop) and
the `claude-lane-*` / `claude-review-box.sh` lane hooks. Fallback order: luna/terra
to grok, grok to luna; deepseek only when chosen explicitly.

Prove hook changes with `scripts/selftest.sh`, which feeds real payloads and
asserts allow/ask. A change that only looks right in the diff is unverified.

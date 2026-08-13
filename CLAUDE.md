# charlesdr-dev-loop

A Claude Code plugin. Claude orchestrates; Codex lanes (luna explore/implement,
sol review, terra escalation) do the work; an isolated reviewer grades the diff
against the plan. Consumer repos opt in by having a `.charles.toml`.

## This repo runs its own hooks

`.charles.toml` exists here, so `hooks/route-to-codex.sh` gates your own edits.
Obey its thresholds as written — over 40 lines or 3 files, dispatch a codex lane
instead of editing inline. Set `CHARLES_INLINE_OK=1` only when the hook itself is
the thing under test.

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
means allow. Two consequences to keep in mind when editing them:

- `jq` missing makes a hook allow everything silently. Keep the `command -v jq` guard.
- Writes via Bash (`sed -i`, heredocs) bypass `route-to-codex.sh` on purpose —
  matching Bash would fire on every redirect. Leave that hole open.

Prove hook changes with `scripts/selftest.sh`, which feeds real payloads and
asserts allow/ask. A change that only looks right in the diff is unverified.

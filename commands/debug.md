---
description: Debug flow — the lean loop, reproduce and confirm the cause from source first
---

Run the **lean loop** from the `charles-flow` skill on: $ARGUMENTS

Differs from the default only here: reproduce first, and confirm the cause from
source yourself before planning. Explore lanes, if any, return a cause with
`file:line` evidence, never a patch. The plan holds the confirmed cause, the fix
scope and the green command; the review asks whether the diff fixes that cause and
nothing else. No grill unless the bug touches money, auth/security or data loss.

**1. Loop before theory.** Get one command that goes red on the user's exact
symptom (failing test, curl, CLI call with a fixture, script replaying a captured
payload) and keep its output. It must show the reported symptom, not a nearby
failure; make it fast and deterministic (pin time, seed randomness, isolate files),
and for a flaky bug loop it until the failure rate is workable. No loop possible:
stop and say what you tried and what you need (access, a log, a captured request);
do not guess-and-patch.

**2. Is it even running your code?** Check before the next hypothesis:

- Installed copy vs source: plugins, packages and global CLIs run a copy, so
  editing the repo changes nothing until reinstall (Claude Code plugins also need a
  version bump and restart).
- PATH order: `type -a <cmd>` lists every copy; an old symlink earlier on PATH wins.
- Stale deploy: edge platforms can serve the previous build for a minute or two;
  check the serving version, wait, retest.
- Config not reloaded: `docker restart` does not re-read `.env`; `docker compose
  up -d` recreates changed containers. Many servers read env only at start.
- Wrong target: the deploy went to another account, project or environment. Print
  the target (`wrangler whoami`, project id, branch-to-env mapping) before trusting
  a result.
- Env var "missing": a secret empty in your shell may be injected only into the
  process; check how the process gets it, without printing the value.

**3. Cause, not symptom.** Change one thing at a time and re-run the loop. State
each hypothesis with the evidence that would kill it, then run that check; keep
survivors with `file:line`. Trust the live system (deployed schema, serving
version, actual env) over docs and repo. "Completed" is not "worked": a job that
swallows its own failure reports success forever, so look at what it produced.
Count for real before calling data empty (planner statistics can say zero rows on
a full table).

**4. Fix once.** Grep every caller of what you change; a guard in the shared
function beats a guard in the caller the ticket names. Failing test first, then the
fix, then re-run the step-1 loop: it must go green on the exact symptom. Remove
temporary logging and debug flags.

Report: symptom, loop command and its red output; root cause with `file:line` and
what ruled out the other hypotheses; the fix, its test and the loop's green output;
any sibling caller or neighbouring system with the same flaw.

Implement per the skill (parallel chunks when the manifest warrants, otherwise a
Bash call with `run_in_background: true`):

```bash
codex-run --lane implement --dir <repo> --req <R1,A3> --timeout 2700 "<task>"
```

Cap green-fix cycles at 3, then record a `FAILED` item and stop, reporting what you ruled out and what you would try next.

No `.charles.toml`: stop and offer `/cstack:init`.

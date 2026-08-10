# charlesdr13

Claude Code as orchestrator only. Codex lanes do the exploring and the typing.
An isolated reviewer grades the result without ever seeing who wrote it.

## Install

```bash
/plugin marketplace add ~/MACH4_2/charlesdr13-plugin
/plugin install charlesdr13@charlesdr13-plugin
```

Then, **in each repo you want it active**:

```bash
/charlesdr13:init
```

That writes `.charles.toml`. Nothing in this plugin does anything in a repo
without one — no hook, no auto-routing. One switch, per repo, on purpose.

## Lanes

| Role | Model | Effort | Sandbox |
|---|---|---|---|
| explore | deepseek-v4-flash | max | read-only |
| implement | gpt-5.6-luna | max | workspace-write |
| review | gpt-5.6-sol | medium | read-only, isolated temp dir |

```bash
scripts/codex-run.sh --lane explore   --dir REPO "question"
scripts/codex-run.sh --lane implement --dir REPO "task"
scripts/codex-run.sh --lane review    --dir REPO --plan docs/specs/x.md "focus"
```

A lane failure retries once on the other lane, then hard-stops. It never falls
back to Claude doing the work inline — a fallback that fires on any error turns
"always dispatch" into "dispatch when convenient".

## Commands

| Command | What |
|---|---|
| `/charlesdr13:feature` | brainstorm → explore fleet → grill → ground-truth gate → implement → review → debug loop |
| `/charlesdr13:debug` | diagnosing-bugs → explore fleet → validate → fix → verify |
| `/charlesdr13:polish` | gap-finding fleet → brainstorm → grill → implement → verify |
| `/charlesdr13:init` | opt this repo in |
| `/charlesdr13:doctor` | check every lane and dependency |

## The hook

`PreToolUse` on `Edit|Write|MultiEdit`. In an opted-in repo, on a code file, it
asks you to dispatch codex instead when an edit touches ≥`inline_lines` (40) or
you have touched ≥`inline_files` (3) distinct files since the last dispatch.

Always allowed: new files (scaffolding), non-code extensions, repos without
`.charles.toml`, and anything at all when `CHARLES_INLINE_OK=1`.

**Known hole:** writes through Bash (`sed -i`, heredocs, `tee`) are not
intercepted. Matching those would fire on every `bun test > out.log` and the
hook would be switched off within a day. The flow skill is what keeps Claude
dispatching; the hook is a backstop, not a sandbox.

## Why the reviewer runs in a temp directory

The model that wrote the code grades its own homework generously — and a grader
that can read the author's reasoning inherits the same bias. So the review lane
gets a `mktemp -d` containing exactly two files, `plan.md` and `changes.diff`,
and runs read-only inside it. It cannot reach the repo, the transcripts, or
`git log`. The isolation is a property of the filesystem rather than a request
in a prompt, which is the only reason it holds.

Borrowed from [loop-engineer](https://github.com/LeadGrowGTM/loop-engineer),
along with the proof protocol (`"47 passed, 0 failed"`, not "tests pass").
No runtime dependency on it — the ideas travelled, the code did not.

## Config

`.charles.toml`, committed:

```toml
green = "bun test && bun run typecheck"   # what "all green" means here
inline_lines = 40
inline_files = 3
max_fleet = 5
```

## Test

```bash
bash scripts/selftest.sh   # 8 assertions on the hook's allow/ask branches
bash scripts/doctor.sh     # every lane and dependency
```

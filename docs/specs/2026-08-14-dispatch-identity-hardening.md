# Dispatch identity, loud fallback, worktree-aware hooks, release automation

Evidence base: two luna explore reports (raw:
`~/.cache/charlesdr-dev-loop/20260813-230616-1388903-explore.jsonl`, lane A same
day), a transcript sweep across 7 project histories, and cross-repo dispatch-log
aggregation (13 repos, 376 dispatches, 41 rc!=0, 17 open runs, 136/628
zero-byte cache transcripts).

## Chunk A — dispatch identity and loud fallback

Files: `scripts/codex-run.sh`, `scripts/verify-receipt.sh`,
`scripts/unsourced.sh`, `scripts/flow-status.sh`, `scripts/lane-status.sh`,
`scripts/run-state.sh`, `scripts/selftest.sh`.

1. `codex-run.sh` appends a **start event** to `<dir>/.charles/dispatches.jsonl`:
   `{ts, event:"start", lane, engine, run, dir, task}` where `run` is the
   basename of `$RUN` (`codex-run.sh:83`) and `dir` is the resolved `$DIR`.
   The start is written **after** every validation and after the implement
   flock is acquired (`codex-run.sh:305`) — an exit-4 refusal must never write
   a start (the existing second-writer selftest at `selftest.sh:168` gains an
   assertion for exactly that). End events (`log_dispatch`, `codex-run.sh:145`)
   gain `event:"end"`, `run` as basename, and `dir`. Lines with no `event`
   field are legacy end events everywhere; legacy records are never migrated.
2. **Orphan rule.** A start whose `run` has no end event in the same file is an
   orphan. Consumers must first ask `lane-status.sh` about that run: RUNNING →
   report "lane in flight" and refuse to conclude; DONE/DEAD → the lane was
   killed mid-write. `unsourced.sh` reports orphans with a new exit code 3
   ("killed lane may own these changes — census before discarding"), distinct
   from its existing codes, and never classifies tree changes as unsourced
   while an orphan implement start exists (`unsourced.sh:66`).
   `flow-status.sh` lists each orphan as an ISSUE line. `run-state.sh close`
   keeps its existing gate mechanics (`run-state.sh:113`): the flow-status
   failure now includes orphans, and `--force` still overrides — that escape
   is by design and stays.
3. `verify-receipt.sh` binds to identity: `--run <id>` (basename or full path,
   normalized to basename) verifies that exact dispatch and prints its end
   event. Default mode (lane+window, window measured against the **start** ts,
   ends paired by `run` id regardless of window edge) exits with a new
   distinct code when any matched start is an orphan, and its message says to
   consult `lane-status.sh`. Accepting an rc=0 end while an orphaned start
   exists in the same lane+window must be impossible.
4. **Fallback pairing rule.** A run may log multiple end events (primary fail,
   then deepseek — `codex-run.sh:343,352`); the LAST end for a `run` id is the
   authoritative outcome, and all consumers follow that rule. The rescue end
   event carries `fallback_from:<engine>` and `primary_rc:<n>`; the stderr
   receipt line and `$RUN.last` (which the deepseek attempt writes for the
   same `$RUN`) carry the same two facts. `flow-status.sh` reports recent
   fallback ends as a non-blocking note (its `ok` channel with a "fallback"
   marker, NOT an ISSUE — a rescued dispatch succeeded and must not block
   close). Process exit stays 0.
5. `lane-status.sh` gains `--dir <repo>`: consider only state files whose run
   id appears in `<repo>/.charles/dispatches.jsonl` (start or end events carry
   `dir`/`run`; legacy state files unmatched by any log line are ignored in
   scoped mode). With no `--dir` and no run id, default to the repo found by
   walking up from `$PWD` for `.charles/`; global-newest selection survives
   only when no repo context exists. If the repo log names no runs, report
   NONE — never fall through to another repo's state.
6. `selftest.sh` proves, with hermetic fixtures: start written only after the
   flock (refused second writer logs nothing); orphaned start → unsourced exit
   3, flow-status ISSUE, close refusal without `--force`; `--run` receipt
   verification hits its dispatch and no other; last-end-wins pairing when a
   run has two ends; fallback fields present on the rescue end; `--dir`
   scoping picks the right state file when two fixture repos both have
   dispatches and the other repo's is newer.

## Chunk B — worktree-aware routing hook

Files: `hooks/route-to-codex.sh`, `scripts/selftest.sh`.

7. Edits to any path containing a `/.claude/worktrees/` segment are allowed
   silently AND excluded from the `.charles/touched` counter
   (`route-to-codex.sh:66` — a worktree edit must not push later root edits
   over the file threshold). Worktrees living elsewhere are out of scope of
   the exemption; the pattern is the path segment, nothing smarter. Evidence:
   every one of 29 historical asks was approved, and the approved edits
   resolved into `.claude/worktrees/` paths.
8. The ask message names the controls precisely: `CHARLES_INLINE_OK=1` as the
   session bypass, `inline_lines`/`inline_files` in `.charles.toml` as the
   thresholds that fired (they already exist, `route-to-codex.sh:51-52` —
   document, do not build). Do not call thresholds "outs".
9. `selftest.sh` proves: over-threshold edit on an existing code file under a
   fixture `.claude/worktrees/` path → silent allow and no touched-counter
   growth; the same file outside worktrees still asks; the ask text contains
   `CHARLES_INLINE_OK`, `inline_lines`, and `inline_files`.

## Chunk C — release automation and doc truth

Files: `scripts/release.sh` (new), `skills/grill-rounds/SKILL.md`, `README.md`,
`skills/charles-flow/SKILL.md`, `.claude-plugin/plugin.json`,
`.claude-plugin/marketplace.json`, `scripts/doctor.sh`.

10. `scripts/release.sh <version>` accepts any semver and runs, in order:
    (a) refuse if `.claude-plugin/*.json` have uncommitted changes or the
    green command fails; (b) write `<version>` into all three fields;
    (c) `claude plugin marketplace update … && claude plugin install …`;
    (d) verify `~/.claude/plugins/cache/charlesdr-dev-loop/charlesdr-dev-loop/<version>/`
    exists, then `ln -sfn` `codex-run` to that copy's `scripts/codex-run.sh`
    directly — NEVER via `link-dispatcher.sh`, whose ambient
    `CLAUDE_PLUGIN_ROOT` still names the old version inside a live session
    (`link-dispatcher.sh:13`, `doctor.sh:68`); (e) run `doctor.sh` and exit
    with its status. If (c) or (d) fails, restore the three version fields
    (`git checkout -- .claude-plugin/` is safe given (a)) and exit nonzero.
    Evidence: 200+ transcript mentions of hand-running this sequence; the
    symlink went stale twice this week.
11. `skills/grill-rounds/SKILL.md:21` stops dispatching the deleted
    `codex-explorer` agent: the adversary round is a direct background
    `codex-run --lane explore` call, consistent with charles-flow.
12. Doc truth fixes in NORMATIVE docs only (README, SKILL.md files, hook
    messages): `skills/charles-flow/SKILL.md:410` and `README.md:250`
    "hard-stops" corrected to describe the deepseek rescue + loud receipt;
    README's stale "23 assertions" claim (`README.md:509`) replaced with
    wording that does not encode a count; remaining wrapper-agent references
    removed. Historical records (docs/specs/*, dated code comments like
    `unsourced.sh:4`) are records, not promises — leave them.
13. `doctor.sh` drift check derives its file list from the installed cache
    copy (every file present in both cache and repo, `.charles/` excluded)
    instead of the hand-maintained list at `doctor.sh:56`. It WARNs on end
    events from the last 7 days in this repo with rc!=0 or a `fallback_from`
    field — NEW-format events only; legacy deepseek ends are indistinguishable
    from deliberate `--engine deepseek` and are never flagged.
14. This release ships as `2.14.0`: after chunk C passes review, the operator
    runs `release.sh 2.14.0` as the final step (the tool takes any version;
    2.14.0 is this release's number, not a constraint of the tool). Chunks A
    and B do not touch versions.

## Out of scope

`parallel-chunks.sh` internals, `green.sh` timeout, tasks-axi integration,
threshold value changes, auto-closing stale runs.

## Must keep working

`bash scripts/selftest.sh && bash scripts/doctor.sh` green after every chunk.
Old `dispatches.jsonl` files (no `event` field) must keep parsing everywhere —
13 repos already have them and are not migrated.

## Sequencing

Chunks run serially, A → B → C, green between each. All three touch
`selftest.sh`; that is why they are serial, not parallel.

## Grill verdict

Round 1 (adversarial luna explore vs. this spec, raw:
`~/.cache/charlesdr-dev-loop/` run `20260814-*-explore`) returned 14 findings,
4 blockers. All resolved by amendment above: start events moved after the
flock with a no-start-on-refusal assertion (f.1, f.13); orphan semantics given
their own exit code and an explicit `--force`-stays design note (f.2); `dir`
added to events and legacy state files excluded from scoped mode (f.3);
last-end-wins pairing rule + fallback fields on the rescue end + non-blocking
flow-status note (f.4); window anchored to start ts with run-id pairing (f.5);
release.sh relinks directly to the fresh cache, never via link-dispatcher, and
restores versions on failure (f.6); legacy deepseek ends never flagged (f.7);
worktree exemption defined as a path segment and excluded from the touched
counter (f.8, f.9); normative-vs-historical doc boundary stated (f.10);
threshold keys named in the ask text (f.12). No round-2 contradictions left
that require a human; zero BLOCKED-HUMAN items.

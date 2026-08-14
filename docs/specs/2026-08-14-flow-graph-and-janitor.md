# Explicit flow transitions, script hardening, cross-repo run janitor

Evidence: 2026-08-13 probe synthesis (17 open runs across 13 opted-in repos;
parallel-chunks child exit codes unchecked; green.sh unbounded; selftest never
feeds a `Task` payload — tasks-axi cdl-1786425693-15926); graphs-vs-loops
research verdict: steal the explicit transition table, skip the framework.
Baseline note: doctor's one FAIL at run start is the known docs/specs drift
(spec outcome appended after 2.14.0 install; same-version cache cannot
refresh) — requirement 10 removes the class.

## Chunk A — transition table (graph-lite)

Files: `scripts/flow.json` (new), `scripts/run-state.sh`,
`scripts/flow-status.sh`, `commands/resolve.md`, `scripts/selftest.sh`.

1. `scripts/flow.json` — exact schema:
   `{"<flow>": {"phases": {"<name>": {"next": [..], "proof": ".."}}, "first": "<name>", "terminal": [..]}}`
   for flows `feature`, `debug`, `polish`, `ui` (ui is a router but records
   phases identically, so it gets a table too). Canonical phase names per
   flow, drawn from the SKILL's flow sections: feature =
   brainstorm→explore→plan→grill→implement→review→verify; debug =
   diagnose→explore→plan→implement→review→verify; polish =
   explore→brainstorm→grill→implement→review→verify; ui =
   baseline→route→audit→plan→verify→review. Loops encode themselves
   (review lists implement; grill lists grill). Terminal phases list
   `"close"` in next. Pure data, no code in the file.
2. **Prefix-family matching.** Recorded phases are free text and stay free
   text (`implement-chunk-A`, `review-pass`, `debug-cycle-2` are real
   examples in `.charles/runs/`). Lookup maps a recorded phase to the
   LONGEST canonical name that is a prefix of it (after lowercasing);
   `review-pass` → `review`, `implement-chunk-A` → `implement`. No match →
   `(unmapped)`. `run-state.sh phase` WARNs on **stderr** for unmapped names
   but still records — the table guides, it does not imprison.
   `run-state.sh show` prints after the phase list:
   `next expected: <a> | <b>` (successors joined with ` | `); no phases
   recorded yet → `next expected: <flow's first phase>`; unmapped last
   phase → `next expected: (unmapped)`. `init` also gains a collision-proof
   run id (append `-$$`): two inits in the same second currently overwrite
   one RUN.md (`run-state.sh:39-40`).
3. `flow-status.sh` adds one line per open run: run id, last phase, expected
   next (same lookup). An open run whose MAPPED last phase is non-terminal
   is an ISSUE ("died mid-flow at <phase>") — this makes the documented
   "close requires the final phase" promise (`commands/resolve.md:37-47`)
   mechanical for the first time. Unmapped phases produce a note line, not
   an ISSUE (free-text phases must never brick closing). Missing or
   unparseable flow.json: every consumer (flow-status, run-state phase/show,
   runs-sweep) degrades to current behaviour with a **stderr** WARN — stdout
   is captured and discarded by `run-state.sh close` (`run-state.sh:120-129`),
   so advisory warnings must not travel on stdout. Consumers on older
   installed copies simply have no flow.json: same degrade path, by
   construction.
4. `commands/resolve.md`: add an explicit step — read `next expected:` from
   `show` to know where the run stopped and what is legal next (new
   behaviour; today resolve reads only prose state).
5. `selftest.sh` proves: prefix mapping (`implement-chunk-A` → next
   expected review); unknown phase warns on stderr and records; terminal
   phase expects close; no-phase run expects the flow's first phase; a
   fixture open run mid-flow yields the ISSUE line; absent flow.json
   degrades silently on stdout with the WARN on stderr.

## Chunk B — script hardening + Task payload

Files: `scripts/green.sh`, `scripts/parallel-chunks.sh`, `scripts/selftest.sh`.

6. `green.sh` runs the green command under `timeout` (default **480s** — it
   must fit inside the Bash tool's 600s foreground cap, or the outer tool
   kills the call before green.sh can report; overridable via
   `green_timeout = N` in `.charles.toml`, same integer-only `cfg` grammar
   as the hook). On rc=124 print
   `RED (rc 124 — timed out at Ns, or the command itself returned 124)`;
   the ambiguity is real and the message owns it. No `timeout` binary →
   run unbounded with a stderr WARN.
7. `parallel-chunks.sh` closes all three success-lying paths: (a) each
   child's `wait "$p"` status is recorded; nonzero → chunk rejected like
   out-of-bounds, named, not merged, script exit 3; (b) a failed
   `treehouse` lease (`parallel-chunks.sh:55-59`) marks that chunk failed
   and forces exit 3 — today it is skipped silently and the script can
   exit 0 having dispatched nothing; (c) a failed `cp` during merge
   (`parallel-chunks.sh:92-96`) forces exit 3. Exit 0 must mean literally
   every declared chunk dispatched, passed, and merged.
8. `selftest.sh` feeds `hooks/route-subagents.sh` a payload with
   `tool_name:"Task"` and asserts ask/allow parity with the `Agent`
   payloads, AND asserts `hooks.json`'s PreToolUse matcher string contains
   both `Agent` and `Task` (wiring regression guard — the harness itself
   cannot be exercised from selftest; that limit is accepted and stated in
   the test's comment). Marking tasks-axi `cdl-1786425693-15926` done is an
   OPERATOR step after green, not a repo requirement.

## Chunk C — janitor and drift class fix

Files: `scripts/runs-sweep.sh` (new), `scripts/doctor.sh`, `README.md`,
`skills/charles-flow/SKILL.md`, `scripts/selftest.sh`.

9. `scripts/runs-sweep.sh [root...]`: roots from args, else
   `$CHARLES_SWEEP_ROOTS` (colon-separated), else `~/MACH4 ~/MACH4_2`
   (where all 13 opted-in repos live today — repos elsewhere need the env
   or an arg, documented in the header). A missing/unreadable root prints
   its own visible `root not found:` line; exit stays 0 (report, not gate).
   For every repo with `.charles.toml`, list open runs (RUN.md without
   `## Outcome`) as
   `repo · run-id · age-days · open-items · last-phase → expected-next`
   (chunk A lookup; unmapped phases print verbatim with `(unmapped)`).
   Age from the run's UTC `started:` metadata line, falling back to RUN.md
   mtime. Read-only, no auto-closing — stale runs are surfaced, never
   tidied by a script.
10. `doctor.sh` drift: differences under `docs/specs/` downgrade to WARN
    (close-time outcome appends after install are expected and same-version
    cache cannot refresh); everything else remains FAIL. Specs stay visible
    — flow-status reads them for grill verdicts, so hiding their drift
    entirely would mask a stale shipped review contract. The drift loop's
    known asymmetry (repo files absent from cache are invisible pre-release)
    is accepted and out of scope.
11. README + charles-flow SKILL: one short paragraph each — the transition
    table and where `runs-sweep.sh` fits (a standing hygiene sweep, run it
    when doctor WARNs about open runs).
12. Ships as 2.15.0 via `release.sh` after review passes (operator step).

## Out of scope

Auto-closing stale runs; graph frameworks or new runtime dependencies;
threshold changes; tasks-axi API integration beyond marking the item done.

## Must keep working

All 87 selftest assertions; legacy dispatches.jsonl parsing; repos without
flow.json in their installed plugin copy (consumers may lag a version —
every flow.json consumer must tolerate the file's absence).

## Sequencing

A → B → C serially, green between chunks (A's lookup is reused by C's sweep;
B is independent but shares selftest.sh).

## Grill verdict

Round 1 (adversarial luna explore, 9 findings, 2 blockers) — all resolved by
amendment: exact flow.json schema + canonical phase lists + prefix-family
matching over real free-text phase names (f.1); init collision-proof run id,
no-phase and multi-successor output formats defined, mapped-non-terminal open
runs become a flow-status ISSUE making the documented close promise mechanical
(f.2); green timeout default 480s inside the 600s foreground cap, rc-124
ambiguity owned in the message (f.3); all three parallel-chunks success-lying
paths closed — wait statuses, lease failures, merge cp failures (f.4); Task
payload parity + hooks.json matcher-string guard, harness limit stated,
tasks-axi closure reclassified as operator step (f.5); sweep roots via
args/env/default with visible missing-root lines, age from UTC started
metadata (f.6); docs/specs drift downgraded to WARN instead of excluded,
asymmetry accepted explicitly (f.7); advisory warnings routed to stderr
because close captures and discards stdout (f.8); resolve.md step framed as
new behaviour (f.9). DEFERRED (recorded as run item): newest_open can update
the wrong run when two runs are open — pre-existing, out of this spec's scope.
Zero BLOCKED-HUMAN items.

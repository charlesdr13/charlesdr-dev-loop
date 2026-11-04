---
name: grill-rounds
description: Batch-grill a written plan, spec or design doc before building it. Use when the user says grill this, poke holes in this, stress-test this plan, red-team this plan, what did I miss, is this plan solid, find the gaps, or play devil's advocate; and when charles-flow invokes it for risky plans (money, auth/security, migrations or destructive changes, 10+ requirements). Runs up to five unattended rounds where an adversary attacks the plan and every attack is settled from source, then asks the user once, in one batch, only what the agent could not answer. Usable unattended. Not for reviewing a code diff.
---

# grill-rounds

`grill-me` interviews the user one question at a time, unbounded: right when the
subject is their intent, wrong when the plan is written and most open questions are
answerable from the codebase. This skill is the bounded version, front-loaded with
an adversary.

**Input:** a written plan file. If the plan only exists in chat, write it to a file
first.

## Rounds 1-5 — unattended adversary

Each round, issue a direct background `codex-run --lane explore` call (read-only; it
cannot edit) with the prompt below, plus the plan path and a "Prior rounds" list
(the resolved/changed items so far, or "none"). Without codex, a read-only
general-purpose subagent works.

> Attack this plan. You are trying to find the reason it fails, not to improve
> it. Produce a numbered list of:
>
> - unstated assumptions, and steps depending on something not established
> - claims about the codebase that may be false — check them against source
> - cases the plan does not handle
> - anything simpler that achieves the same outcome
> - **terminology**: terms the plan uses loosely or in more than one sense, and
>   any that conflict with how the codebase or a CONTEXT.md/glossary uses them
> - **contradictions**: where the plan says the system behaves one way and the
>   code says otherwise. Quote both.
> - **scenarios**: invent two concrete edge cases and walk the plan through them
>
> For each item, say what evidence would settle it, with `file:line` where the
> answer is in the repo. Do not propose a rewrite. Do not ask questions — there
> is nobody to answer them. Do not edit any file. Items settled in "Prior rounds"
> are not new; raise them again only with new evidence.

Do not tell the lane to load `grill-me` or `grill-with-docs`: they are interview
skills and the unattended lane would stall waiting for a human. The last three
bullets are the checkable parts of `grill-with-docs`.

Then answer each item yourself from source (read the files, run the command, check
the docs or API). Every item ends in one state:

- **Resolved** — record the answer with `file:line`.
- **Plan changed** — the attack landed; amend the plan and note what changed.
- **Needs the user** — intent, priority, spend, or outside knowledge. A fact you
  could look up never goes here; if nearly all items land here, you are being lazy
  about verification.

Stop early when a round raises nothing new.

## Round 6 — one batch to the user

Collect everything that survived and put it to the user in **one message**, not one
at a time. Record each first, so the list survives a dead session:

```bash
"$SCRIPTS/run-state.sh" item "$(pwd)" BLOCKED-HUMAN "<the question, in one line>"
```

For each item: the question; **why the adversary could not settle it** (not in the
code, intent or priority, or two defensible answers with no way to choose from
source); your recommendation with reasoning. An item that only needs a repo fact
does not belong here; a list padded with lookups teaches the user to skim it.

Nothing proceeds to implementation while an item is unanswered. If the user goes
quiet, the run stays open with its `BLOCKED-HUMAN` items for `/cstack:resolve`.

```
❓ Q1 — <title>: <question, with the options if there are options>
➡️ <your recommendation, and why>
```

## Round 7 — only if the answers reshape the plan

If round 6's answers invalidate something structural, amend the plan and run one
more batch on the newly exposed decisions; if they only fill in details, stop. Seven
is the ceiling: another means the plan is wrong at a level grilling cannot fix, so
say so and reopen the ask with the user.

## Verdict

Append to the plan file:

```markdown
## Grill verdict — YYYY-MM-DD

- Rounds: N (self) + N (user)
- Attacks raised: N — resolved from source: N, changed the plan: N, escalated: N
- Plan changes: <one line each>
- Accepted risks: <what we know is unhandled, and why that is acceptable>
- Unresolved: <anything still open, and what would settle it>
```

Recount the numbers before writing them. An empty "accepted risks" on a non-trivial plan means the grill was theatre.

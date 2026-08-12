---
name: grill-rounds
description: Bounded adversarial grilling of a written plan — round 1 is a codex adversary attacking the plan while Claude answers from source, remaining contradictions come back as one batched human round. Use before implementing any plan produced by brainstorming, or when the user says "grill the plan", "stress-test this", "grill-rounds". Fork of grill-me, bounded to 2-3 rounds and usable unattended.
---

# grill-rounds

`grill-me` interviews the user until shared understanding, one question at a
time, unbounded. That is the right shape when the user is sitting there and the
subject is their intent. It is the wrong shape when the plan is already written
and most of the open questions are answerable from the codebase — you burn the
user's attention on facts you could have looked up.

This is that skill, bounded and front-loaded with an adversary.

**Input:** a written plan file. If there isn't one, write it first — you cannot
grill a plan that only exists in the conversation, and neither can the adversary.

## Round 1 — automated adversary

Dispatch a `codex-explorer` (read-only, so it cannot "fix" anything) with:

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
> is nobody to answer them.

The last three come from `grill-with-docs`, which is available to codex as a
skill. **Do not tell the lane to load `grill-me` or `grill-with-docs`**: both
are interview skills that ask one question at a time and wait for a human. In an
unattended dispatch the lane would stall on questions nobody will answer. Take
their checkable parts, as above, and leave the interview to round 2 where a
human actually is present.

Then, for each item it raises, **answer it yourself from source** — read the
files, run the command, check the API. Every item ends in one of three states:

- **Resolved** — you found the answer; record it with `file:line`.
- **Plan changed** — the attack landed; amend the plan and note what changed.
- **Needs the user** — genuinely a matter of intent, priority, or outside
  knowledge. This is the only category that survives to round 2.

Most items should resolve here. If nearly everything is landing in "needs the
user", you are being lazy about verification, not thorough about grilling.

## Round 2 — one batched human round

Put every surviving item to the user **in a single message**, numbered, each with
your recommended answer. Not one at a time — that shape exists for open-ended
discovery, and this is a fixed list you already know the extent of.

Format each as:

```
❓ Q1 — <title>: <question, with the options if there are options>
➡️ <your recommendation, and why>
```

## Round 3 — only if the answers reshape the plan

If round 2's answers invalidate something structural, amend the plan and run one
more batched round on the newly-exposed decisions. If they only fill in details,
stop at two. Three is the ceiling: a fourth round means the plan is wrong at a
level grilling cannot fix — say so and go back to brainstorming.

## Verdict

Append to the plan file:

```markdown
## Grill verdict — YYYY-MM-DD

- Rounds: N
- Attacks raised: N — resolved from source: N, changed the plan: N, escalated: N
- Plan changes: <one line each>
- Accepted risks: <what we know is unhandled, and why that is acceptable>
- Unresolved: <anything still open, and what would settle it>
```

An empty "accepted risks" section on a non-trivial plan means the grill was
theatre. Every real plan has something it deliberately does not handle; naming
it is the difference between a known limitation and a future incident.

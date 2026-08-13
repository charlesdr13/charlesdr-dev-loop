---
description: UI/UX polish — routes to impeccable for taste, dispatches direct background codex for the mechanical audit, wraps both in run state and a scope-creep review
---

Polish the interface for: $ARGUMENTS (no argument = the current route)

This is a **router, not a flow**. `impeccable` is a 27-command UI system and is
the source of truth for taste — do not reimplement its judgment here. What this
adds is the machinery impeccable lacks: durable run state, a codex lane for the
mechanical half of the audit, and a scope-creep review at the end.

**Gate:** requires `.charles.toml`. No file → offer `/charlesdr-dev-loop:init`.

**Scope: one route or one component.** Whole-app polish produces a diff nobody
can review, where a single bad judgment contaminates everything. If the user
names more, polish the first and say what you deferred.

## 1. Open the run

```bash
# every script lives beside the dispatcher the SessionStart hook linked
SCRIPTS="$(dirname "$(readlink -f "$(command -v codex-run)")")"
"$SCRIPTS/run-state.sh" init "$(pwd)" ui "<route>: <what should feel better>"
"$SCRIPTS/green.sh" "$(pwd)"      # baseline BEFORE touching anything
```

A red baseline means you are about to blame your change for an existing failure.

## 2. Route to impeccable — pick one, do not run several

| Intent | Command |
|---|---|
| "make this better at what it is" | `/impeccable polish` |
| "what's wrong with this?" | `/impeccable audit` or `critique` |
| motion, transitions, scroll | `/impeccable animate` + the gsap skills below |
| slow, janky, heavy | `/impeccable optimize` |
| too bland / too loud | `/impeccable bolder` / `quieter` |
| iterate live in the browser | `/impeccable live` — needs a running dev server |

**Do not invoke a direction-setting skill by default.** Polish means better at
what it already is; `design-taste-frontend`, `gpt-taste` and friends change the
direction, which is a different job the user has to ask for by name.

Motion work also routes: `gsap-scrolltrigger` for scroll-linked or pinned
sections, `gsap-react` in React or Next (cleanup on unmount is where this breaks),
`gsap-timeline` for sequencing, and `gsap-performance` before shipping any of it.

## 3. In parallel — one direct background codex explore call for the mechanical audit

While you do the visual pass, make this a separate Bash tool call with
`run_in_background: true`. It cannot see, so give it only what is legible in
source:

```bash
codex-run --lane explore --dir "$(pwd)" --timeout 1800 "<audit task>"
```

> Audit `<route>` and the components it imports for **mechanical** inconsistency
> only — no aesthetic opinions, they are not yours to give. Report with
> `file:line` for each: hardcoded colours where a token or CSS variable exists;
> spacing values off the project's scale; duplicate component variants that
> differ only in trivial ways; repeated literal values that should be one
> constant; dead styles with no matching selector; inline styles overriding the
> system. Rank by how many places each appears. If the project has no token
> system, say so instead of inventing one.

"These 14 buttons use 9 different paddings" is a grep-shaped finding your eye
will miss and impeccable's pass is not built to enumerate. Verify the receipt
before using it:

```bash
"$SCRIPTS/verify-receipt.sh" "$(pwd)" --lane explore --since 1800
```

Exit 1 means nothing ran — discard the report entirely.

## 4. Decide, then implement

Merge the two inputs yourself: impeccable's judgment leads, the codex audit
supplies the mechanical backlog. Write the survivors to
`docs/specs/YYYY-MM-DD-ui-<route>.md` — this is what makes step 5 possible.

Record anything you are not doing as a run item, typed:

```bash
"$SCRIPTS/run-state.sh" item "$(pwd)" DEFERRED "<what and why>"
"$SCRIPTS/run-state.sh" item "$(pwd)" BLOCKED-HUMAN "<needs a taste call from you>"
```

Taste disagreements belong in `BLOCKED-HUMAN`. Do not resolve them by guessing
what the user would prefer.

## 5. Verify — three checks, none optional

1. **Green** — `"$SCRIPTS/green.sh" "$(pwd)"`, paste the output.
2. **No regression on the floor.** Prettier must not mean less usable. Contrast,
   focus visibility, tab order, and CLS/LCP must be no worse than the baseline.
   `npx lighthouse` is available (12.8.2) if the route is servable; if you cannot
   measure, say so plainly rather than implying you checked.
3. **Scope creep** — `codex-reviewer` against the plan. It cannot judge whether
   the result looks better, but it can catch "the plan said tighten the card and
   the diff also rewrote the auth hook", which is how polish work actually goes
   wrong.

Then close, or leave open if items remain:

```bash
"$SCRIPTS/run-state.sh" close "$(pwd)" "<what changed, what was deferred>" --spec docs/specs/<plan>.md
```

## What this command will not do

Judge taste on your behalf. Screenshots and a running app go to you, not to a
codex lane — luna gets a diff, never a picture. If a decision needs an eye, it
is a `BLOCKED-HUMAN` item, not a coin flip.

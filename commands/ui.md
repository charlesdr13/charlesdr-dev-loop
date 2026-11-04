---
description: UI/UX polish — routes to impeccable for taste, dispatches direct background codex for the mechanical audit, wraps both in run state and a scope-creep review
---

Polish the interface for: $ARGUMENTS (no argument = the current route)

This is a **router, not a flow**. `impeccable` is the source of truth for taste;
do not reimplement its judgment. This adds what it lacks: durable run state, a
codex lane for the mechanical half of the audit, and a scope-creep review.

**Gate:** requires `.charles.toml`. No file → offer `/cstack:init`.

**Scope: one route or one component.** If the user names more, polish the first
and say what you deferred.

## 1. Baseline, then open the run

```bash
# every script lives beside the dispatcher the SessionStart hook linked
SCRIPTS="$(dirname "$(readlink -f "$(command -v codex-run)")")"
"$SCRIPTS/green.sh" "$(pwd)"      # baseline BEFORE opening the run or touching anything
"$SCRIPTS/run-state.sh" init "$(pwd)" ui "<route>: <what should feel better>"
```

If the baseline is red, stop before `init`.

## 2. Route to impeccable — pick one

| Intent | Command |
|---|---|
| "make this better at what it is" | `/impeccable polish` |
| "what's wrong with this?" | `/impeccable audit` or `critique` |
| motion, transitions, scroll | `/impeccable animate` + the gsap skills below |
| slow, janky, heavy | `/impeccable optimize` |
| too bland / too loud | `/impeccable bolder` / `quieter` |
| iterate live in the browser | `/impeccable live` — needs a running dev server |

Do not invoke a direction-setting skill by default: `design-taste-frontend`,
`gpt-taste` and friends change direction, a different job the user must ask for by
name.

Motion also routes: `gsap-scrolltrigger` (scroll-linked or pinned sections),
`gsap-react` (React or Next; cleanup on unmount is where this breaks),
`gsap-timeline` (sequencing), `gsap-performance` before shipping any of it.

## 3. In parallel — one direct background codex explore call for the mechanical audit

While you do the visual pass, run this as a separate Bash call with
`run_in_background: true`. It cannot see, so give it only what is legible in
source:

```bash
codex-run --lane explore --dir "$(pwd)" --timeout 2700 "<audit task>"
```

> Audit `<route>` and the components it imports for **mechanical** inconsistency
> only — no aesthetic opinions. Report with
> `file:line` for each: hardcoded colours where a token or CSS variable exists;
> spacing values off the project's scale; duplicate component variants that
> differ only in trivial ways; repeated literal values that should be one
> constant; dead styles with no matching selector; inline styles overriding the
> system. Rank by how many places each appears. If the project has no token
> system, say so instead of inventing one.

Verify the receipt before using the report:

```bash
"$SCRIPTS/verify-receipt.sh" "$(pwd)" --lane explore --since 1800
```

Exit 1 means nothing ran: discard the report and record a `FAILED` item:

```bash
"$SCRIPTS/run-state.sh" item "$(pwd)" FAILED "codex explore returned no receipt"
```

## 4. Decide, then implement

Impeccable's judgment leads; the codex audit supplies the mechanical backlog.
Write the survivors to
`docs/specs/YYYY-MM-DD-ui-<route>.md`, then bind that plan to the open run before
implementing:

```bash
"$SCRIPTS/run-state.sh" spec "$(pwd)" docs/specs/<plan>.md
```

Record anything you are not doing as a run item, typed:

```bash
"$SCRIPTS/run-state.sh" item "$(pwd)" DEFERRED "<what and why>"
"$SCRIPTS/run-state.sh" item "$(pwd)" BLOCKED-HUMAN "<needs a taste call from you>"
```

Taste disagreements go in `BLOCKED-HUMAN`; do not guess the user's preference.

The router has no grill step. Note under the plan's `## Grill verdict`:
`Grill waived: UI router has no grill step by design.` (a missing verdict only
warns).

## 5. Verify — four checks

1. **Green** — `"$SCRIPTS/green.sh" "$(pwd)"`, paste the output.
2. **No regression on the floor.** Contrast, focus visibility, tab order and
   CLS/LCP no worse than the baseline. `npx lighthouse` (12.8.2) if the route is
   servable; if you cannot measure, say so rather than implying you checked.
3. **Scope creep** — `codex-reviewer` against the plan. It cannot judge looks, but
   it catches "the plan said tighten the card and the diff also rewrote the auth
   hook".
4. **Sign off.** Complete the plan's `## Sign-off` section: one checked line per
   requirement, with the actual verification output as evidence.

Then close, or leave open if items remain:

```bash
"$SCRIPTS/run-state.sh" close "$(pwd)" "<what changed, what was deferred>" --spec docs/specs/<plan>.md
```

## What this command will not do

Judge taste on your behalf. Screenshots and a running app go to you, not to a
codex lane (luna gets a diff, never a picture). A decision that needs an eye is a
`BLOCKED-HUMAN` item.

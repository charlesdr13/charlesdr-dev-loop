# Unknown engine preference must refuse, not become luna

## Goal

An engine name that the dispatcher does not recognise — from `CHARLES_ENGINE`,
`<run root>/.charles/engine`, or the global `$CHARLES_STATE_DIR/engine` — must
be refused by name. Today the resolution `case` in `scripts/codex-run.sh` has no
default arm, so an unrecognised value leaves `ENGINE` at its `luna` initialiser
and the dispatch silently runs luna.

## Why (observed, 2026-09-16)

The global preference was `grok` while another session still ran the installed
2.39.0 plugin, whose resolver predates grok. Every lane in that session died
with `fallback receipt fallback_from:luna primary_rc:1` and a codex quota error.
The word `grok` appeared nowhere: a stale cache presented as "charles-flow has
no working engine". Reproduced deliberately against both dispatchers — 2.39.0
runs luna on a `grok` preference, 2.40.0 runs grok.

## Grill verdict

Grill waived: a `*)` arm in one `case`, its message, and one test. The failure it
fixes was reproduced live against both dispatchers before writing this.

## Requirements

- [ ] **R1. Refuse by name.** The preference `case` in `codex-run.sh` gains a
  `*)` arm for a non-empty unrecognised value: exit 2, naming the offending
  value, the source layer it came from (env / project file / global file) and
  the valid set. An empty or absent preference keeps today's behaviour — the
  luna default is correct when nothing asked for anything.
- [ ] **R2. Precedence is unchanged.** `--engine` still wins; a bad value in a
  lower layer is never reached when a higher layer resolves. Do not validate
  layers the resolver did not consult.
- [ ] **R3. No new coupling.** Reuse the engine list already asserted by the
  pre-dispatch `case`; do not introduce a second source of truth for it.
- [ ] **R4. Test** in `scripts/selftest.sh`: a project `.charles/engine` of
  `bogus` exits 2 with a message containing the value and the source, and no
  engine is spawned; `CHARLES_ENGINE=bogus` likewise; an explicit
  `--engine grok` still runs with a bogus file present (R2).
- [ ] **R5. Version** 2.40.1 in `.claude-plugin/plugin.json` and both
  `version` fields in `.claude-plugin/marketplace.json`.

## Explicit non-goals

- No change to the deepseek peak-window substitution, the luna/terra fallback,
  or `/engine`'s own validation (it already rejects unknown values on write —
  this is about values that reached the file some other way, including a cache
  older than the name).

## Green

bash scripts/selftest.sh && bash scripts/doctor.sh

## Isolated review — grok-4.6

Verdict: **SATISFIES PLAN**. The regressions worth fearing were checked and do
not hit the new arm: an empty or newline-only file still falls through (`$()`
strips trailing newlines), a higher layer that already resolved never opens the
files, and the deepseek peak-window arm closes before the new ones. A
whitespace-padded value (`luna `, `luna\r`) now refuses where it used to become
luna silently — that is R1's rule, not a lost dispatch.

Three nits, all folded in: `src` renamed to `pref_src` (a new script-global
assigned on every preference-resolved run, collision unproven but free to
avoid), stray blank lines removed, and the untested `src="global file"` string
now has its own check.

## Sign-off

- [x] **R1-R5.** Unknown preference exits 2 naming value + layer + valid set;
  absent preference still defaults to luna; `--engine` still wins; no second
  allowlist; 4 checks; version 2.40.1.

Green: 418 passed, 2 failed — the same two shared-three-way-merge failures red
at HEAD~. Verified through the installed dispatcher, not just this checkout:
`codex-run --lane explore` returns `grok/grok-4.6`, and
`CHARLES_ENGINE=nonsense` returns
`unknown engine 'nonsense' from env (luna|terra|deepseek|claude|grok)`.

## Run outcome — 2026-09-15

unknown engine preference now refuses by name; 4 checks; grok review SATISFIES PLAN

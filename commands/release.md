---
description: Release this plugin at a semver and record the result
---

Open the release run, then pass exactly one semver argument through the
existing release script:

```bash
set -e
SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
RELEASE_RUN="$("$SCRIPTS/run-state.sh" init "$(pwd)" release "release $ARGUMENTS")"

set +e
output="$("$SCRIPTS/release.sh" "$ARGUMENTS" 2>&1)"
rc=$?
set -e

printf '%s\n' "$output"
if [ "$rc" -ne 0 ]; then
  "$SCRIPTS/run-state.sh" item "$(pwd)" FAILED \
    "release.sh failed for $ARGUMENTS (exit $rc)" --run "$RELEASE_RUN"
  exit "$rc"
fi

# release.sh owns the checks and executes these stages in order. Record each
# completed flow boundary with its complete output as the proof.
"$SCRIPTS/run-state.sh" phase "$(pwd)" guard "$output" --run "$RELEASE_RUN"
"$SCRIPTS/run-state.sh" phase "$(pwd)" green "$output" --run "$RELEASE_RUN"
"$SCRIPTS/run-state.sh" phase "$(pwd)" version "$output" --run "$RELEASE_RUN"
"$SCRIPTS/run-state.sh" phase "$(pwd)" ship "$output" --run "$RELEASE_RUN"
"$SCRIPTS/run-state.sh" close "$(pwd)" "released $ARGUMENTS" --run "$RELEASE_RUN"
```

Pass `$ARGUMENTS` straight through; do not add validation or reimplement any
of `release.sh`'s checks. It already refuses on a dirty `.claude-plugin/` and
on a red green command, then installs, verifies the cache, relinks `codex-run`,
and runs doctor.

`release.sh` takes exactly one semver and exits 2 otherwise. It computes the
plugin root from its own location, so it always releases this plugin regardless
of the caller's working directory.

The script output is recorded as proof for the release flow's `guard`, `green`,
`version`, and `ship` phases. On failure, record the `FAILED` item above and
leave that release run open; do not close it.

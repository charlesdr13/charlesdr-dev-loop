---
description: Release this plugin at a semver and record the result
---

Run exactly one semver argument through the existing release script:

```bash
set +e
output="$("${CLAUDE_PLUGIN_ROOT}/scripts/release.sh" "$ARGUMENTS" 2>&1)"
rc=$?
set -e

printf '%s\n' "$output"
"${CLAUDE_PLUGIN_ROOT}/scripts/run-state.sh" phase "$(pwd)" "release $ARGUMENTS" "$output"
if [ "$rc" -ne 0 ]; then
  "${CLAUDE_PLUGIN_ROOT}/scripts/run-state.sh" item "$(pwd)" FAILED \
    "release.sh failed for $ARGUMENTS (exit $rc)"
  exit "$rc"
fi
```

Pass `$ARGUMENTS` straight through; do not add validation or reimplement any
of `release.sh`'s checks. It already refuses on a dirty `.claude-plugin/` and
on a red green command, then installs, verifies the cache, relinks `codex-run`,
and runs doctor.

`release.sh` takes exactly one semver and exits 2 otherwise. It computes the
plugin root from its own location, so it always releases this plugin regardless
of the caller's working directory.

The script output is recorded as a phase on the open run. On failure, record
the `FAILED` item above and leave the run open; do not close the run here.

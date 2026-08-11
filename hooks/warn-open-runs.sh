#!/usr/bin/env bash
# warn-open-runs.sh — Stop hook. Warn about FAILED items in an unclosed run.
#
# Only FAILED. Items awaiting the user (BLOCKED-HUMAN, PENDING-DECISION) already
# resurface through tasks-axi at session start, and there are enough Stop hooks
# talking already. FAILED means a lane died and work is genuinely incomplete —
# nothing else tracks that.
set -euo pipefail

root="$PWD"
while [ "$root" != "/" ] && [ ! -f "$root/.charles.toml" ]; do root="$(dirname "$root")"; done
[ -f "$root/.charles.toml" ] || exit 0

runs="$root/.charles/runs"
[ -d "$runs" ] || exit 0

for d in $(ls -1d "$runs"/*/ 2>/dev/null | sort -r); do
  grep -q '^## Outcome' "$d/RUN.md" 2>/dev/null && continue
  n="$(grep -c '^- \[ \] \*\*FAILED\*\*' "$d/RUN.md" 2>/dev/null || echo 0)"
  if [ "$n" -gt 0 ]; then
    echo "charlesdr-dev-loop: run $(basename "${d%/}") has $n FAILED item(s) — work is incomplete."
    grep '^- \[ \] \*\*FAILED\*\*' "$d/RUN.md" | sed 's/^/  /'
    echo "  Resume with /charlesdr-dev-loop:resolve"
  fi
  break   # newest open run only
done
exit 0

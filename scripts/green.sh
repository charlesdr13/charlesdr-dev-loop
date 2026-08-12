#!/usr/bin/env bash
# green.sh — run this repo's green command and report the result.
#
# The debug loop's exit condition used to be prose: "run the green command until
# it passes". That made the loop's termination depend on a model remembering to
# parse a TOML string. This executes it, so the exit condition is a real exit
# code and the output is the proof line the protocol demands.
#
#   green.sh [dir]           run it, stream output, exit with its status
#   green.sh [dir] --quiet   only the last 20 lines and the verdict
set -uo pipefail

DIR="${1:-$PWD}"
[ "${DIR}" = "--quiet" ] && DIR="$PWD"
QUIET=0
for a in "$@"; do [ "$a" = "--quiet" ] && QUIET=1; done

[ -d "$DIR" ] || { echo "green.sh: no such directory: $DIR" >&2; exit 2; }
DIR="$(cd "$DIR" && pwd)"

root="$DIR"
root="$(realpath -m "$root" 2>/dev/null || echo "$root")"
while [ "$root" != "/" ] && [ ! -f "$root/.charles.toml" ]; do
  parent="$(dirname "$root")"; [ "$parent" = "$root" ] && break; root="$parent"
done
if [ ! -f "$root/.charles.toml" ]; then
  echo "green.sh: no .charles.toml at or above $DIR — run /charlesdr-dev-loop:init" >&2
  exit 2
fi

green="$(grep -oE '^[[:space:]]*green[[:space:]]*=[[:space:]]*".*"' "$root/.charles.toml" \
         | head -1 | sed 's/.*=[[:space:]]*"//; s/"[[:space:]]*$//')"

if [ -z "$green" ]; then
  echo "green.sh: no green command set in $root/.charles.toml" >&2
  echo "green.sh: set it before running a debug loop — an unverifiable loop cannot terminate honestly" >&2
  exit 2
fi

echo "green.sh: $green" >&2
out="$(cd "$root" && eval "$green" 2>&1)"
rc=$?

if [ "$QUIET" -eq 1 ]; then printf '%s\n' "$out" | tail -20; else printf '%s\n' "$out"; fi

if [ $rc -eq 0 ]; then
  echo "GREEN — \`$green\` passed" >&2
else
  echo "RED (exit $rc) — \`$green\` failed" >&2
fi
exit $rc

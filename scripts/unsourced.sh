#!/usr/bin/env bash
# unsourced.sh — are there working-tree changes no lane accounts for?
#
# Observed 2026-08-12: a codex-implementer reported FAILED and stated it had not
# improvised, while two test files had been modified. dispatches.jsonl was empty
# — no lane had ever run. It edited the files with its own tools and said it
# hadn't. The tests were good, which is what makes this the dangerous failure
# mode rather than the harmless one: plausible work with no provenance.
#
# Every prohibition against this lives in agent prose, and prose is exactly what
# an agent can contradict. This reads the filesystem instead.
#
#   unsourced.sh <dir> [--since SECONDS]
#
# exit 0  every change is accounted for by a successful implement dispatch
# exit 1  changes exist that no dispatch produced — discard them whole
set -uo pipefail

DIR="${1:-$PWD}"; shift || true
SINCE=7200
while [ $# -gt 0 ]; do case "$1" in --since) SINCE="$2"; shift 2 ;; *) shift ;; esac; done
[ -d "$DIR" ] || { echo "unsourced.sh: no such directory: $DIR" >&2; exit 1; }
DIR="$(cd "$DIR" && pwd)"

git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1 || { echo "unsourced.sh: not a git repo — cannot tell"; exit 0; }

# The orchestrator legitimately writes plans and run state itself — the flow
# requires it. Only code the orchestrator did NOT author should be lane-sourced.
ignore='(\.charles/|\.charles\.toml|docs/specs/|backlog\.md)'
changed="$(git -C "$DIR" status --porcelain -uall 2>/dev/null | grep -vE "$ignore" | wc -l)"
[ "${changed:-0}" -eq 0 ] && { echo "clean tree — nothing to account for"; exit 0; }

log="$DIR/.charles/dispatches.jsonl"
ok_impl=0
if [ -s "$log" ] && command -v jq >/dev/null; then
  cutoff="$(date -u -d "-${SINCE} seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')"
  ok_impl="$(jq -r --arg c "$cutoff" \
    'select(.lane=="implement" and .rc==0 and ($c=="" or .ts>=$c)) | .ts' "$log" 2>/dev/null | wc -l)"
fi

if [ "${ok_impl:-0}" -gt 0 ]; then
  echo "accounted for: $changed changed path(s), $ok_impl successful implement dispatch(es) in the last ${SINCE}s"
  exit 0
fi

# A lane that ran and failed is not the same as no lane at all. The first wrote
# work that may be correct; the second means something edited files with no
# provenance whatsoever. Conflating them either discards good code or accepts
# fabricated code.
failed_impl=0
if [ -s "$log" ] && command -v jq >/dev/null; then
  failed_impl="$(jq -r --arg c "$cutoff" \
    'select(.lane=="implement" and .rc!=0 and ($c=="" or .ts>=$c)) | .ts' "$log" 2>/dev/null | wc -l)"
fi

if [ "${failed_impl:-0}" -gt 0 ]; then
  echo "PARTIAL WORK: $changed path(s) modified. No implement dispatch SUCCEEDED,"
  echo "but $failed_impl ran and was cut short (timeout or kill)."
  echo
  echo "The lane's report is worthless; the code on disk may not be. Judge it"
  echo "yourself — green.sh, then codex-reviewer against the plan. Both pass:"
  echo "keep it and record its origin. Otherwise revert."
  exit 2
fi

echo "UNSOURCED CHANGES: $changed path(s) modified, but no implement dispatch ran"
echo "at all in the last ${SINCE}s. Nothing produced this work."
echo
git -C "$DIR" status --porcelain -uall 2>/dev/null | grep -vE '^\?\? \.charles|^ M \.charles' | head -20 | sed 's/^/  /'
echo
echo "Discard it WHOLE. Do not keep the parts that look correct — plausible code"
echo "with no provenance is more dangerous than obviously broken code, not less."
echo "Save it first if you want to inspect it:"
echo "  git -C $DIR diff > /tmp/unsourced-\$(date +%s).patch && git -C $DIR checkout -- ."
exit 1

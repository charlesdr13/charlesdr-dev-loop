#!/usr/bin/env bash
# doctor.sh — is every lane and dependency actually reachable?
set -uo pipefail

ok=0; bad=0
say() { printf '  %-6s %s\n' "$1" "$2"; [ "$1" = "FAIL" ] && bad=$((bad+1)) || ok=$((ok+1)); }
have() { command -v "$1" >/dev/null 2>&1; }

echo "charlesdr-dev-loop doctor"
echo
echo "Lanes:"
have codex && say OK "codex CLI on PATH ($(command -v codex))" || say FAIL "codex CLI not on PATH — all three lanes are dead"
[ -f "$HOME/.codex/luna.config.toml" ] && say OK "luna profile (implement lane)" || say FAIL "missing ~/.codex/luna.config.toml — implement lane dead"
[ -f "$HOME/.codex/deepseek.config.toml" ] && say OK "deepseek profile (explore lane)" || say FAIL "missing ~/.codex/deepseek.config.toml — explore lane dead"
[ -f "$HOME/.config/lg-cc-deepseek/key.env" ] && say OK "deepseek key present" || say FAIL "missing ~/.config/lg-cc-deepseek/key.env — explore lane dead"
[ -x "$HOME/.claude/skills/codex-deepseek/scripts/codex-ds.sh" ] && say OK "codex-ds.sh wrapper" || say FAIL "missing codex-ds.sh — explore lane dead"
grep -q 'model = "gpt-5.6-sol"' "$HOME/.codex/config.toml" 2>/dev/null && say OK "sol base model (review lane)" || say WARN "base model is not gpt-5.6-sol — review lane will use whatever ~/.codex/config.toml says"

echo
echo "Tools:"
have jq && say OK "jq (the hook needs it)" || say FAIL "jq missing — the hook silently allows everything without it"
have git && say OK "git (review lane diffs)" || say FAIL "git missing"
have treehouse && say OK "treehouse (parallel implementers)" || say WARN "treehouse missing — parallel implementers unavailable, serial still fine"
have python3 && say OK "python3 (selftest)" || say WARN "python3 missing — selftest cannot run"

echo
echo "This repo:"
if [ -f "$PWD/.charles.toml" ]; then
  say OK "opted in (.charles.toml present)"
  g="$(grep -oE '^green[[:space:]]*=[[:space:]]*".*"' "$PWD/.charles.toml" | sed 's/.*= *"//; s/"$//')"
  [ -n "$g" ] && say OK "green command: $g" || say WARN "no green command set — the debug loop will refuse to start"
else
  say WARN "not opted in — run /charlesdr-dev-loop:init to enable the hook and flows here"
fi

echo
echo "$ok ok, $bad failing"
[ "$bad" -eq 0 ]

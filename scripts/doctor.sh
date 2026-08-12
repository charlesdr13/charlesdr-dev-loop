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
[ -f "$HOME/.codex/luna.config.toml" ] && say OK "luna profile (PRIMARY engine)" || say FAIL "missing ~/.codex/luna.config.toml — explore AND implement dead"
[ -f "$HOME/.codex/terra.config.toml" ] && say OK "terra profile (escalation engine)" || say WARN "missing ~/.codex/terra.config.toml — no escalation when work comes back wrong twice"
[ -f "$HOME/.codex/deepseek.config.toml" ] && say OK "deepseek profile (fallback engine)" || say WARN "missing ~/.codex/deepseek.config.toml — no fallback if luna fails"
[ -f "$HOME/.config/lg-cc-deepseek/key.env" ] && say OK "deepseek key present" || say WARN "missing ~/.config/lg-cc-deepseek/key.env — no fallback if luna fails"
[ -x "$HOME/.claude/skills/codex-deepseek/scripts/codex-ds.sh" ] && say OK "codex-ds.sh wrapper" || say WARN "missing codex-ds.sh — no fallback if luna fails"
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
have tasks-axi && say OK "tasks-axi (open items)" || say WARN "tasks-axi missing — open items stay in RUN.md instead"
if [ -d "$PWD/.charles/runs" ]; then
  open_n=0
  for d in "$PWD"/.charles/runs/*/; do
    [ -f "$d/RUN.md" ] || continue
    grep -q '^## Outcome' "$d/RUN.md" || open_n=$((open_n+1))
  done
  [ "$open_n" -eq 0 ] && say OK "no unclosed runs" || say WARN "$open_n unclosed run(s) — /charlesdr-dev-loop:resolve"
fi


echo
echo "Installed plugin:"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VER="$(jq -r '.version' "$REPO_ROOT/.claude-plugin/plugin.json" 2>/dev/null)"
CACHE="$HOME/.claude/plugins/cache/charlesdr-dev-loop/charlesdr-dev-loop/$VER"
if [ ! -d "$CACHE" ]; then
  say WARN "v$VER not installed — run: claude plugin marketplace update charlesdr-dev-loop && claude plugin install charlesdr-dev-loop@charlesdr-dev-loop"
else
  drift=0
  for f in scripts/codex-run.sh scripts/run-state.sh scripts/green.sh \
           hooks/route-to-codex.sh hooks/route-subagents.sh hooks/warn-open-runs.sh \
           agents/codex-explorer.md agents/codex-implementer.md agents/codex-reviewer.md \
           skills/charles-flow/SKILL.md; do
    cmp -s "$CACHE/$f" "$REPO_ROOT/$f" || { drift=$((drift+1)); echo "         drifted: $f"; }
  done
  # The installed plugin is a COPY taken at install time, not a live view. Editing
  # the repo changes nothing until you bump the version and reinstall. This check
  # exists because that surprise has now cost three separate debugging detours.
  [ "$drift" -eq 0 ] && say OK "installed v$VER matches this repo" \
    || say FAIL "$drift file(s) differ from installed v$VER — bump the version and reinstall, or you are running old code"

  # The codex-run symlink is only refreshed by the SessionStart hook, so a
  # reinstall leaves it pointing at the previous version until the next session.
  want="$CACHE/scripts/codex-run.sh"
  have="$(readlink -f "$(command -v codex-run 2>/dev/null)" 2>/dev/null)"
  if [ -z "$have" ]; then
    say WARN "codex-run not on PATH — starts working after one new session, or run hooks/link-dispatcher.sh"
  elif [ "$have" = "$(readlink -f "$want")" ]; then
    say OK "codex-run -> installed v$VER"
  else
    say FAIL "codex-run points at $have, not v$VER — restart the session or re-run hooks/link-dispatcher.sh"
  fi
fi


if [ -f "$PWD/.charles.toml" ]; then
  echo
  echo "Flow completeness:"
  fs="$(dirname "$0")/flow-status.sh"
  if [ -x "$fs" ]; then
    if out="$("$fs" "$PWD" 2>&1)"; then
      say OK "no ungraded work, no open runs"
    else
      # WARN not FAIL: a repo mid-flow legitimately has ungraded implements.
      # The blocking check lives in `run-state.sh close`, where you declare done.
      while IFS= read -r line; do
        case "$line" in *ISSUE*) say WARN "${line#*ISSUE  }" ;; esac
      done <<< "$out"
    fi
  fi
fi

echo
echo "$ok ok, $bad failing"
[ "$bad" -eq 0 ]

#!/usr/bin/env bash
# selftest.sh — asserts the hook allows what it should and asks on what it shouldn't.
# ponytail: one runnable check for the only non-trivial branch logic in the plugin.
set -uo pipefail

HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/route-to-codex.sh"
BOX="$(mktemp -d)"; trap 'rm -rf "$BOX"' EXIT
pass=0; fail=0

check() { # check NAME EXPECT(allow|ask) PAYLOAD
  local name="$1" expect="$2" payload="$3" out decision
  out="$(printf '%s' "$payload" | bash "$HOOK" 2>/dev/null)"
  if [ -z "$out" ]; then decision=allow
  else decision="$(jq -r '.hookSpecificOutput.permissionDecision // "allow"' <<<"$out" 2>/dev/null)"; fi
  if [ "$decision" = "$expect" ]; then
    echo "  PASS  $name (expected $expect)"; pass=$((pass+1))
  else
    echo "  FAIL  $name — expected $expect, got $decision"; echo "        $out"; fail=$((fail+1))
  fi
}

big="$(python3 -c 'print("\n".join("line %d" % i for i in range(80)))')"
small="$(python3 -c 'print("\n".join("line %d" % i for i in range(5)))')"

# --- repo WITHOUT .charles.toml: hook must stay out of the way ----------------
mkdir -p "$BOX/plain"; echo "x" > "$BOX/plain/a.ts"
check "opted-out repo, huge edit" allow \
  "$(jq -nc --arg p "$BOX/plain/a.ts" --arg c "$big" '{tool_name:"Write",tool_input:{file_path:$p,content:$c}}')"

# --- opted-in repo -----------------------------------------------------------
mkdir -p "$BOX/repo"; printf 'inline_lines = 40\ninline_files = 3\n' > "$BOX/repo/.charles.toml"
for f in a.ts b.ts c.ts d.md; do echo "x" > "$BOX/repo/$f"; done

check "small edit" allow \
  "$(jq -nc --arg p "$BOX/repo/a.ts" --arg c "$small" '{tool_name:"Write",tool_input:{file_path:$p,content:$c}}')"

check "markdown, huge" allow \
  "$(jq -nc --arg p "$BOX/repo/d.md" --arg c "$big" '{tool_name:"Write",tool_input:{file_path:$p,content:$c}}')"

check "new file, huge (scaffolding)" allow \
  "$(jq -nc --arg p "$BOX/repo/brand-new.ts" --arg c "$big" '{tool_name:"Write",tool_input:{file_path:$p,content:$c}}')"

bypass_out="$(CHARLES_INLINE_OK=1 bash "$HOOK" <<<"$(jq -nc --arg p "$BOX/repo/a.ts" --arg c "$big" '{tool_name:"Write",tool_input:{file_path:$p,content:$c}}')" 2>/dev/null)"
if [ -z "$bypass_out" ]; then echo "  PASS  CHARLES_INLINE_OK bypass (expected allow)"; pass=$((pass+1))
else echo "  FAIL  CHARLES_INLINE_OK bypass — expected allow, got $bypass_out"; fail=$((fail+1)); fi

: > "$BOX/repo/.charles/touched" 2>/dev/null || mkdir -p "$BOX/repo/.charles"
check "big edit trips line threshold" ask \
  "$(jq -nc --arg p "$BOX/repo/a.ts" --arg c "$big" '{tool_name:"Write",tool_input:{file_path:$p,content:$c}}')"

# 3rd distinct file trips the file threshold even though each edit is tiny.
: > "$BOX/repo/.charles/touched"
printf '%s\n' "$BOX/repo/a.ts" "$BOX/repo/b.ts" > "$BOX/repo/.charles/touched"
check "3rd file trips file threshold" ask \
  "$(jq -nc --arg p "$BOX/repo/c.ts" --arg s "$small" '{tool_name:"Edit",tool_input:{file_path:$p,old_string:"x",new_string:$s}}')"

# a dispatch clears the counter -> back to allow
: > "$BOX/repo/.charles/touched"
check "counter cleared after dispatch" allow \
  "$(jq -nc --arg p "$BOX/repo/c.ts" --arg s "$small" '{tool_name:"Edit",tool_input:{file_path:$p,old_string:"x",new_string:$s}}')"

# --- Claude Code worktrees are exempt and do not count -----------------------
WT="$BOX/repo/.claude/worktrees/fixture"; mkdir -p "$WT"
echo "x" > "$WT/a.ts"
: > "$BOX/repo/.charles/touched"
worktree_out="$(jq -nc --arg p "$WT/a.ts" --arg c "$big" '{tool_name:"Write",tool_input:{file_path:$p,content:$c}}' | CHARLES_INLINE_OK=0 bash "$HOOK" 2>/dev/null)"
worktree_count="$(wc -l < "$BOX/repo/.charles/touched")"
if [ -z "$worktree_out" ] && [ "$worktree_count" -eq 0 ]; then
  echo "  PASS  worktree edit is silent and not counted"; pass=$((pass+1))
else
  echo "  FAIL  worktree edit should be silent and leave the counter empty"; fail=$((fail+1))
fi

check "same over-threshold edit outside worktrees still asks" ask \
  "$(jq -nc --arg p "$BOX/repo/a.ts" --arg c "$big" '{tool_name:"Write",tool_input:{file_path:$p,content:$c}}')"

ask_text="$(jq -nc --arg p "$BOX/repo/a.ts" --arg c "$big" '{tool_name:"Write",tool_input:{file_path:$p,content:$c}}' | CHARLES_INLINE_OK=0 bash "$HOOK" 2>/dev/null)"
if grep -qF 'CHARLES_INLINE_OK' <<<"$ask_text" \
  && grep -qF 'inline_lines' <<<"$ask_text" \
  && grep -qF 'inline_files' <<<"$ask_text"; then
  echo "  PASS  ask text names the bypass and threshold keys"; pass=$((pass+1))
else
  echo "  FAIL  ask text must name CHARLES_INLINE_OK, inline_lines, and inline_files"; fail=$((fail+1))
fi

# --- subagent routing hook ----------------------------------------------------
SUBHOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/route-subagents.sh"

scheck() { # scheck NAME EXPECT SUBAGENT_TYPE CWD
  local name="$1" expect="$2" out decision
  out="$(jq -nc --arg s "$3" --arg c "$4" '{tool_name:"Agent",cwd:$c,tool_input:{subagent_type:$s,prompt:"x"}}' | bash "$SUBHOOK" 2>/dev/null)"
  if [ -z "$out" ]; then decision=allow
  else decision="$(jq -r '.hookSpecificOutput.permissionDecision // "allow"' <<<"$out" 2>/dev/null)"; fi
  if [ "$decision" = "$expect" ]; then
    echo "  PASS  $name (expected $expect)"; pass=$((pass+1))
  else
    echo "  FAIL  $name — expected $expect, got $decision"; echo "        $out"; fail=$((fail+1))
  fi
}

echo
scheck "opted-out repo, general-purpose" allow general-purpose "$BOX/plain"
scheck "codex-reviewer remains allowed" allow codex-reviewer "$BOX/repo"

message_check() { # message_check NAME SUBAGENT_TYPE CWD EXPECTED-DISPATCH
  local name="$1" out
  out="$(jq -nc --arg s "$2" --arg c "$3" '{tool_name:"Agent",cwd:$c,tool_input:{subagent_type:$s,prompt:"x"}}' | bash "$SUBHOOK" 2>/dev/null)"
  if grep -qF "$4" <<<"$out" && grep -qF 'run_in_background: true' <<<"$out"; then
    echo "  PASS  $name"; pass=$((pass+1))
  else
    echo "  FAIL  $name — expected direct background dispatch"; echo "        $out"; fail=$((fail+1))
  fi
}

message_check "Explore block points to direct dispatch" Explore "$BOX/repo" \
  "codex-run --lane explore --dir <repo> --timeout 1800"
message_check "implement block points to direct dispatch" python-pro "$BOX/repo" \
  "codex-run --lane implement --dir <repo> --timeout 1800"
scheck "google-drive is not code work"  allow google-drive "$BOX/repo"
scheck "Explore must route to a lane"    ask Explore "$BOX/repo"
scheck "general-purpose must route"      ask general-purpose "$BOX/repo"
scheck "python-pro must route"           ask python-pro "$BOX/repo"
scheck "feature-dev:code-explorer routes" ask "feature-dev:code-explorer" "$BOX/repo"

# --- run state lifecycle ------------------------------------------------------
RS="$(cd "$(dirname "$0")/.." && pwd)/scripts/run-state.sh"
WARN="$(cd "$(dirname "$0")/.." && pwd)/hooks/warn-open-runs.sh"
RT="$BOX/runrepo"; mkdir -p "$RT/docs/specs"
( cd "$RT" && git init -q && git config user.name tester && git config user.email tester@example.invalid )
printf 'green = "true"\n' > "$RT/.charles.toml"
printf '# Plan\n\n## Grill verdict\n\n- Rounds: 2\n' > "$RT/docs/specs/p.md"

rcheck() { # rcheck NAME EXPECT-SUBSTRING COMMAND...
  local name="$1" want="$2"; shift 2
  local out; out="$("$@" 2>&1 || true)"
  if grep -qF "$want" <<<"$out"; then echo "  PASS  $name"; pass=$((pass+1))
  else echo "  FAIL  $name — expected to contain: $want"; fail=$((fail+1)); fi
}

echo
bash "$RS" init "$RT" debug "test goal" >/dev/null
rcheck "run state records a phase"  "Phase 1"  bash "$RS" phase "$RT" "Phase 1" "3 passed"
rcheck "run state records an item"  "FAILED"   bash "$RS" item  "$RT" FAILED "lane timed out"
rcheck "bad item type is rejected"  "bad type" bash "$RS" item  "$RT" NONSENSE "x"
rcheck "show surfaces the open run" "test goal" bash "$RS" show "$RT"

warn_out="$( cd "$RT" && bash "$WARN" 2>&1 || true )"
if grep -q 'FAILED item' <<<"$warn_out"; then
  echo "  PASS  stop hook warns on FAILED"; pass=$((pass+1))
else
  echo "  FAIL  stop hook warns on FAILED"; fail=$((fail+1))
fi

# An OPEN run with zero FAILED items must be silent. This branch was uncovered
# and shipped broken: grep -c prints 0 and exits 1, so `|| echo 0` yielded "0\n0".
RT2="$BOX/runrepo2"; mkdir -p "$RT2"
printf 'green = "true"\n' > "$RT2/.charles.toml"
bash "$RS" init "$RT2" feature "open, nothing failed" >/dev/null
bash "$RS" item "$RT2" PENDING-DECISION "awaiting a yes" >/dev/null
warn_out="$( cd "$RT2" && bash "$WARN" 2>&1 || true )"
if [ -z "$warn_out" ]; then
  echo "  PASS  stop hook silent on open run with no FAILED"; pass=$((pass+1))
else
  echo "  FAIL  stop hook silent on open run with no FAILED — got: $warn_out"; fail=$((fail+1))
fi

# the run recorded a FAILED item earlier; a real flow resolves it before closing
sed -i 's/^- \[ \] /- [x] /' "$RT"/.charles/runs/*/RUN.md 2>/dev/null
bash "$RS" close "$RT" "done" --spec docs/specs/p.md >/dev/null
warn_out="$( cd "$RT" && bash "$WARN" 2>&1 || true )"
if [ -z "$warn_out" ]; then
  echo "  PASS  stop hook silent after close"; pass=$((pass+1))
else
  echo "  FAIL  stop hook silent after close"; fail=$((fail+1))
fi

rcheck "outcome promoted to committed plan" "Run outcome" cat "$RT/docs/specs/p.md"

# --- concurrent-writer lock ---------------------------------------------------
# A fake `codex` on PATH lets us produce a process whose cmdline matches what the
# lock greps for, without dispatching anything real.
RUN_SH="$(cd "$(dirname "$0")/.." && pwd)/scripts/codex-run.sh"
LOCKDIR="$BOX/locktest"; mkdir -p "$LOCKDIR/bin"
printf '#!/usr/bin/env bash\nsleep 25\n' > "$LOCKDIR/bin/codex"; chmod +x "$LOCKDIR/bin/codex"

mkdir -p "$LOCKDIR/.charles"
# hold the real lock the way a live writer would, then try to start a second
( flock 9 && touch "$LOCKDIR/lock-ready" && while [ ! -f "$LOCKDIR/release-lock" ]; do sleep 0.05; done ) 9>"$LOCKDIR/.charles/implement.lock" &
decoy=$!
lock_ready=0
for _ in $(seq 1 100); do
  if [ -f "$LOCKDIR/lock-ready" ]; then lock_ready=1; break; fi
  kill -0 "$decoy" 2>/dev/null || break
  sleep 0.05
done

if [ "$lock_ready" -eq 1 ]; then
  out="$(CHARLES_STATE_DIR="$LOCKDIR/state" PATH="$LOCKDIR/bin:$PATH" bash "$RUN_SH" --lane implement --dir "$LOCKDIR" "second writer" 2>&1)"; rc=$?
  if [ "$rc" -eq 4 ] && grep -q 'REFUSING' <<<"$out"; then
    echo "  PASS  second writer on the same tree is refused"; pass=$((pass+1))
  else
    echo "  FAIL  second writer should have been refused (rc=$rc)"; fail=$((fail+1))
  fi
  if [ ! -s "$LOCKDIR/.charles/dispatches.jsonl" ]; then
    echo "  PASS  refused second writer writes no dispatch event"; pass=$((pass+1))
  else
    echo "  FAIL  refused second writer must not write a dispatch event"; fail=$((fail+1))
  fi
else
  echo "  FAIL  lock holder did not report readiness after flock"; fail=$((fail+1))
fi

# A read-only explore alongside the held writer is fine and must NOT be refused.
out="$(CHARLES_STATE_DIR="$LOCKDIR/state" PATH="$LOCKDIR/bin:$PATH" bash "$RUN_SH" --lane explore --dir "$LOCKDIR" --no-fallback --timeout 2 "reader" 2>&1)"
if grep -q 'REFUSING' <<<"$out"; then
  echo "  FAIL  explore was refused; the lock must only guard writers"; fail=$((fail+1))
else
  echo "  PASS  explore alongside a writer is allowed"; pass=$((pass+1))
fi

rm -f "$LOCKDIR/.charles/dispatches.jsonl"
touch "$LOCKDIR/release-lock"
wait "$decoy" 2>/dev/null
out="$(CHARLES_STATE_DIR="$LOCKDIR/state" PATH="$LOCKDIR/bin:$PATH" bash "$RUN_SH" --lane implement --dir "$LOCKDIR" --no-fallback --timeout 2 "accepted" 2>&1)"; accepted_rc=$?
start_count="$(jq -r 'select(.event == "start") | .run' "$LOCKDIR/.charles/dispatches.jsonl" 2>/dev/null | wc -l)"
if [ "$accepted_rc" -ne 4 ] && [ "$start_count" -eq 1 ]; then
  echo "  PASS  accepted writer records one start after the lock"; pass=$((pass+1))
else
  echo "  FAIL  accepted writer should record one start after the lock (rc=$accepted_rc, got $start_count)"; fail=$((fail+1))
fi
lock_run="$(jq -r 'select(.event == "start") | .run' "$LOCKDIR/.charles/dispatches.jsonl" 2>/dev/null | head -1)"
if jq -e --arg d "$LOCKDIR" --arg r "$lock_run" \
  'select(.event == "start" and .run == $r and .dir == $d) | select((.run | contains("/")) | not)' \
  "$LOCKDIR/.charles/dispatches.jsonl" >/dev/null 2>&1; then
  echo "  PASS  new start carries resolved dir and basename run"; pass=$((pass+1))
else
  echo "  FAIL  new start identity fields are incomplete"; fail=$((fail+1))
fi
if jq -e --arg d "$LOCKDIR" --arg r "$lock_run" \
  'select(.event == "end" and .run == $r and .dir == $d)' \
  "$LOCKDIR/.charles/dispatches.jsonl" >/dev/null 2>&1; then
  echo "  PASS  new end carries resolved dir and basename run"; pass=$((pass+1))
else
  echo "  FAIL  new end identity fields are incomplete"; fail=$((fail+1))
fi

# --- dispatcher symlink hook --------------------------------------------------
# Agents cannot rely on ${CLAUDE_PLUGIN_ROOT} expanding in their shell; when it
# did not, they hunted the filesystem and executed a live working copy. The hook
# gives them a stable `codex-run` instead.
LINK="$(cd "$(dirname "$0")/.." && pwd)/hooks/link-dispatcher.sh"
FAKEROOT="$BOX/fakeplugin"; mkdir -p "$FAKEROOT/scripts"
printf '#!/usr/bin/env bash\necho dispatched\n' > "$FAKEROOT/scripts/codex-run.sh"
chmod +x "$FAKEROOT/scripts/codex-run.sh"

HOME_ORIG="$HOME"
export HOME="$BOX/fakehome"; mkdir -p "$HOME"
( cd "$BOX" && CLAUDE_PLUGIN_ROOT="$FAKEROOT" bash "$LINK" ) >/dev/null 2>&1
if [ "$(readlink "$HOME/.local/bin/codex-run" 2>/dev/null)" = "$FAKEROOT/scripts/codex-run.sh" ]; then
  echo "  PASS  session hook links codex-run onto PATH"; pass=$((pass+1))
else
  echo "  FAIL  session hook did not create the codex-run symlink"; fail=$((fail+1))
fi

second="$(cd "$BOX" && CLAUDE_PLUGIN_ROOT="$FAKEROOT" bash "$LINK" 2>&1)"
if [ -z "$second" ]; then
  echo "  PASS  hook is idempotent on reinstall"; pass=$((pass+1))
else
  echo "  FAIL  hook should be silent when the link is already correct"; fail=$((fail+1))
fi

# with no plugin root it must exit quietly rather than erroring
if ( cd "$BOX" && CLAUDE_PLUGIN_ROOT="" bash "$LINK" ) >/dev/null 2>&1; then
  echo "  PASS  hook is a no-op without a plugin root"; pass=$((pass+1))
else
  echo "  FAIL  hook errored when CLAUDE_PLUGIN_ROOT was empty"; fail=$((fail+1))
fi
export HOME="$HOME_ORIG"

# --- receipt verification -----------------------------------------------------
# "A report without a receipt is discarded" was documented and enforced by
# nothing. This checks the dispatch log an agent cannot forge.
VR="$(cd "$(dirname "$0")/.." && pwd)/scripts/verify-receipt.sh"
VD="$BOX/receipts"; mkdir -p "$VD/.charles"

bash "$VR" "$VD" >/dev/null 2>&1
[ $? -eq 1 ] && { echo "  PASS  no dispatch log -> report rejected"; pass=$((pass+1)); } \
             || { echo "  FAIL  empty dispatch log should reject"; fail=$((fail+1)); }

VNOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","lane":"implement","engine":"luna","model":"m","rc":143,"run":"/x","task":"t"}\n' "$VNOW" > "$VD/.charles/dispatches.jsonl"
bash "$VR" "$VD" --since 99999 >/dev/null 2>&1
[ $? -eq 2 ] && { echo "  PASS  killed dispatch (rc=143) is not a valid receipt"; pass=$((pass+1)); } \
             || { echo "  FAIL  rc=143 should not count as success"; fail=$((fail+1)); }

printf '{"ts":"%s","lane":"implement","engine":"luna","model":"m","rc":0,"run":"/y","task":"t"}\n' "$VNOW" >> "$VD/.charles/dispatches.jsonl"
bash "$VR" "$VD" --since 99999 >/dev/null 2>&1
[ $? -eq 0 ] && { echo "  PASS  successful dispatch accepted"; pass=$((pass+1)); } \
             || { echo "  FAIL  successful dispatch should be accepted"; fail=$((fail+1)); }

bash "$VR" "$VD" --lane review --since 99999 >/dev/null 2>&1
[ $? -eq 1 ] && { echo "  PASS  a different lane's receipt does not count"; pass=$((pass+1)); } \
             || { echo "  FAIL  lane filter should reject"; fail=$((fail+1)); }

# an hour-old receipt must fall outside a 5-second window. Relative, not
# hardcoded: a fixed date silently ages out and the test starts failing a day later.
printf '{"ts":"%s","lane":"implement","engine":"luna","model":"m","rc":0,"run":"/z","task":"t"}\n' \
  "$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)" > "$VD/.charles/dispatches.jsonl"
bash "$VR" "$VD" --since 5 >/dev/null 2>&1
[ $? -eq 1 ] && { echo "  PASS  a stale receipt does not count"; pass=$((pass+1)); } \
             || { echo "  FAIL  time window should reject"; fail=$((fail+1)); }

# identity-bound receipt selection and last-end-wins pairing
VID="$BOX/identity-receipts"; mkdir -p "$VID/.charles"
VSTART="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","event":"start","lane":"implement","engine":"luna","run":"one","dir":"%s","task":"one"}\n' "$VSTART" "$VID" > "$VID/.charles/dispatches.jsonl"
printf '{"ts":"%s","event":"end","lane":"implement","engine":"luna","model":"m","rc":0,"run":"one","dir":"%s","task":"one"}\n' "$VSTART" "$VID" >> "$VID/.charles/dispatches.jsonl"
printf '{"ts":"%s","event":"start","lane":"implement","engine":"luna","run":"two","dir":"%s","task":"two"}\n' "$VSTART" "$VID" >> "$VID/.charles/dispatches.jsonl"
printf '{"ts":"%s","event":"end","lane":"implement","engine":"luna","model":"m","rc":0,"run":"two","dir":"%s","task":"two"}\n' "$VSTART" "$VID" >> "$VID/.charles/dispatches.jsonl"
identity_out="$(bash "$VR" "$VID" --run "$VID/one" 2>&1)"; identity_rc=$?
if [ "$identity_rc" -eq 0 ] && grep -q '"run":"one"' <<<"$identity_out" && ! grep -q '"run":"two"' <<<"$identity_out"; then
  echo "  PASS  --run verifies only the requested dispatch and prints its end"; pass=$((pass+1))
else
  echo "  FAIL  --run must isolate one dispatch (rc=$identity_rc)"; fail=$((fail+1))
fi

printf '{"ts":"%s","event":"start","lane":"implement","engine":"luna","run":"last","dir":"%s","task":"last"}\n' "$VSTART" "$VID" >> "$VID/.charles/dispatches.jsonl"
printf '{"ts":"%s","event":"end","lane":"implement","engine":"luna","model":"m","rc":0,"run":"last","dir":"%s","task":"last"}\n' "$VSTART" "$VID" >> "$VID/.charles/dispatches.jsonl"
printf '{"ts":"%s","event":"end","lane":"implement","engine":"luna","model":"m","rc":7,"run":"last","dir":"%s","task":"last"}\n' "$VSTART" "$VID" >> "$VID/.charles/dispatches.jsonl"
identity_out="$(bash "$VR" "$VID" --run last --since 99999 2>&1)"; identity_rc=$?
if [ "$identity_rc" -eq 2 ] && grep -q '"rc":7' <<<"$identity_out" && ! grep -q '"rc":0' <<<"$identity_out"; then
  echo "  PASS  last end wins when a run has multiple ends"; pass=$((pass+1))
else
  echo "  FAIL  last end should be authoritative (rc=$identity_rc)"; fail=$((fail+1))
fi

printf '{"ts":"%s","event":"end","lane":"implement","engine":"luna","model":"m","rc":0,"run":"missing-start","dir":"%s","task":"missing"}\n' "$VSTART" "$VID" > "$VID/.charles/dispatches.jsonl"
identity_out="$(bash "$VR" "$VID" --run missing-start 2>&1)"; identity_rc=$?
if [ "$identity_rc" -eq 1 ] && grep -q 'start record is missing' <<<"$identity_out"; then
  echo "  PASS  unmatched new-format end is rejected as missing its start"; pass=$((pass+1))
else
  echo "  FAIL  unmatched new-format end should name the missing start (rc=$identity_rc)"; fail=$((fail+1))
fi

printf '{"ts":"%s","lane":"implement","engine":"luna","model":"m","rc":0,"run":"legacy","task":"legacy"}\n' "$VSTART" > "$VID/.charles/dispatches.jsonl"
bash "$VR" "$VID" --run legacy >/dev/null 2>&1; identity_rc=$?
if [ "$identity_rc" -eq 0 ]; then
  echo "  PASS  legacy no-event receipt remains valid"; pass=$((pass+1))
else
  echo "  FAIL  legacy no-event receipt should remain valid (rc=$identity_rc)"; fail=$((fail+1))
fi

# --- lane liveness ------------------------------------------------------------
# Waiting on .last cannot distinguish "not finished yet" from "killed"; agents
# sat stuck 27 minutes on dead engines. lane-status asks the process instead.
LS="$(cd "$(dirname "$0")/.." && pwd)/scripts/lane-status.sh"
LD="$BOX/lanes"; mkdir -p "$LD"

missing_dir_out="$(timeout 2 bash "$LS" --dir 2>&1)"; missing_dir_rc=$?
if [ "$missing_dir_rc" -eq 2 ] && grep -q 'usage:' <<<"$missing_dir_out"; then
  echo "  PASS  --dir without an operand exits 2 with usage"; pass=$((pass+1))
else
  echo "  FAIL  --dir without an operand should exit 2 with usage (rc=$missing_dir_rc)"; fail=$((fail+1))
fi

touch "$LD/20260101-000000-111111-explore.jsonl"
printf '124\n' > "$LD/20260101-000000-111111-explore.done"
CHARLES_STATE_DIR="$LD" bash "$LS" 20260101-000000-111111-explore >/dev/null 2>&1
[ $? -eq 2 ] && { echo "  PASS  timed-out dispatch reports DEAD"; pass=$((pass+1)); } \
             || { echo "  FAIL  timed-out dispatch should be DEAD"; fail=$((fail+1)); }

touch "$LD/20260101-000000-222222-explore.jsonl"
CHARLES_STATE_DIR="$LD" bash "$LS" 20260101-000000-222222-explore >/dev/null 2>&1
[ $? -eq 2 ] && { echo "  PASS  SIGKILLed dispatch (no marker) reports DEAD"; pass=$((pass+1)); } \
             || { echo "  FAIL  unmarked dispatch should be DEAD"; fail=$((fail+1)); }

touch "$LD/20260101-000000-333333-explore.jsonl"
printf 'result\n' > "$LD/20260101-000000-333333-explore.last"
CHARLES_STATE_DIR="$LD" bash "$LS" 20260101-000000-333333-explore >/dev/null 2>&1
[ $? -eq 1 ] && { echo "  PASS  finished dispatch reports DONE"; pass=$((pass+1)); } \
             || { echo "  FAIL  dispatch with a result should be DONE"; fail=$((fail+1)); }

# --dir scopes newest selection to the repo's dispatch log, even when another
# fixture repo has a newer state file.
SCOPE_STATE="$BOX/scoped-state"; SCOPE_A="$BOX/scoped-a"; SCOPE_B="$BOX/scoped-b"
mkdir -p "$SCOPE_STATE" "$SCOPE_A/.charles" "$SCOPE_B/.charles"
SCOPE_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","event":"start","lane":"explore","engine":"luna","run":"scope-a","dir":"%s","task":"a"}\n{"ts":"%s","event":"end","lane":"explore","engine":"luna","rc":0,"run":"scope-a","dir":"%s","task":"a"}\n' "$SCOPE_NOW" "$SCOPE_A" "$SCOPE_NOW" "$SCOPE_A" > "$SCOPE_A/.charles/dispatches.jsonl"
printf '{"ts":"%s","event":"start","lane":"explore","engine":"luna","run":"scope-b","dir":"%s","task":"b"}\n{"ts":"%s","event":"end","lane":"explore","engine":"luna","rc":0,"run":"scope-b","dir":"%s","task":"b"}\n' "$SCOPE_NOW" "$SCOPE_B" "$SCOPE_NOW" "$SCOPE_B" > "$SCOPE_B/.charles/dispatches.jsonl"
touch "$SCOPE_STATE/scope-a.jsonl" "$SCOPE_STATE/scope-b.jsonl"
printf 'result\n' > "$SCOPE_STATE/scope-a.last"
printf 'result\n' > "$SCOPE_STATE/scope-b.last"
touch -d '+1 minute' "$SCOPE_STATE/scope-b.jsonl" 2>/dev/null || true
scope_out="$(CHARLES_STATE_DIR="$SCOPE_STATE" bash "$LS" --dir "$SCOPE_A" 2>&1)"; scope_rc=$?
if [ "$scope_rc" -eq 1 ] && grep -q 'scope-a' <<<"$scope_out" && ! grep -q 'scope-b' <<<"$scope_out"; then
  echo "  PASS  --dir lane status ignores another repo's newer state"; pass=$((pass+1))
else
  echo "  FAIL  --dir must select the state named by this repo (rc=$scope_rc)"; fail=$((fail+1))
fi

# A start is recorded before Codex creates a transcript. The empty state file
# must remain alive-pending while the process is being checked.
PENDING="$BOX/pending"; mkdir -p "$PENDING/bin"
printf '#!/usr/bin/env bash\nwhile [ ! -f "$CHARLES_TEST_RELEASE" ]; do sleep 0.05; done\n' > "$PENDING/bin/codex"
chmod +x "$PENDING/bin/codex"
( CHARLES_STATE_DIR="$PENDING/state" CHARLES_TEST_RELEASE="$PENDING/release" PATH="$PENDING/bin:$PATH" \
  bash "$RUN_SH" --lane explore --dir "$PENDING" --no-fallback --timeout 5 "pending" ) \
  >"$PENDING/run.out" 2>&1 &
pending_pid=$!
pending_run=""
for _ in $(seq 1 40); do
  pending_run="$(jq -r 'select(.event == "start") | .run' "$PENDING/.charles/dispatches.jsonl" 2>/dev/null | head -1)"
  [ -n "$pending_run" ] && break
  sleep 0.05
done
pending_out="$(CHARLES_STATE_DIR="$PENDING/state" bash "$LS" --dir "$PENDING" "$pending_run" 2>&1)"; pending_rc=$?
if [ "$pending_rc" -eq 0 ] && grep -q 'RUNNING: ' <<<"$pending_out" \
  && grep -q 'state pending' <<<"$pending_out" \
  && [ -f "$PENDING/state/$pending_run.jsonl" ] && [ ! -s "$PENDING/state/$pending_run.jsonl" ]; then
  echo "  PASS  start with empty state is alive-pending"; pass=$((pass+1))
else
  echo "  FAIL  start with empty state should remain alive-pending (rc=$pending_rc)"; fail=$((fail+1))
fi
touch "$PENDING/release"
wait "$pending_pid" 2>/dev/null

# --- flow completeness --------------------------------------------------------
# A dispatch succeeding is not a flow finishing. The audit that motivated this
# found 19% review coverage and 1 grill verdict across 13 plans.
FS="$(cd "$(dirname "$0")/.." && pwd)/scripts/flow-status.sh"
FD="$BOX/flowrepo"; mkdir -p "$FD/.charles" "$FD/docs/specs"
printf 'green = "true"\n' > "$FD/.charles.toml"
FNOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","lane":"implement","engine":"luna","model":"m","rc":0,"run":"/x","task":"t"}\n' "$FNOW" > "$FD/.charles/dispatches.jsonl"

bash "$FS" "$FD" >/dev/null 2>&1
[ $? -eq 1 ] && { echo "  PASS  implement with no review is flagged"; pass=$((pass+1)); } \
             || { echo "  FAIL  ungraded implement should be flagged"; fail=$((fail+1)); }

bash "$RS" init "$FD" feature "g" >/dev/null 2>&1
bash "$RS" close "$FD" "done" >/dev/null 2>&1
[ $? -eq 5 ] && { echo "  PASS  close refuses while work is ungraded"; pass=$((pass+1)); } \
             || { echo "  FAIL  close should refuse with exit 5"; fail=$((fail+1)); }

bash "$RS" close "$FD" "done" --force >/dev/null 2>&1
[ $? -eq 0 ] && { echo "  PASS  --force closes deliberately"; pass=$((pass+1)); } \
             || { echo "  FAIL  --force should close"; fail=$((fail+1)); }

printf '{"ts":"%s","lane":"review","engine":"review","model":"m","rc":0,"run":"/y","task":"t"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$FD/.charles/dispatches.jsonl"
printf '# Plan\n\n## Grill verdict\n\n- Rounds: 2\n' > "$FD/docs/specs/p.md"
bash "$FS" "$FD" >/dev/null 2>&1
[ $? -eq 0 ] && { echo "  PASS  reviewed, grilled and closed reports clean"; pass=$((pass+1)); } \
             || { echo "  FAIL  a complete flow should report clean"; fail=$((fail+1)); }

# --- simplicity ladder --------------------------------------------------------
# codex cannot load Claude Code skills, so ponytail's constraint has to travel in
# the prompt or the implementer has none at all.
LB="$BOX/ladder"; mkdir -p "$LB/bin"
printf '#!/usr/bin/env bash\nfor a in "$@"; do echo "$a"; done > %s/prompt.txt\n' "$LB" > "$LB/bin/codex"
chmod +x "$LB/bin/codex"

PATH="$LB/bin:$PATH" CHARLES_STATE_DIR="$LB" bash "$RUN_SH" --lane implement --dir "$LB" --timeout 5 "t" >/dev/null 2>&1
if grep -q 'Does this need to exist at all' "$LB/prompt.txt" 2>/dev/null; then
  echo "  PASS  implement dispatch carries the simplicity ladder"; pass=$((pass+1))
else
  echo "  FAIL  implement dispatch is missing the ladder"; fail=$((fail+1))
fi
if grep -q 'Do NOT simplify away' "$LB/prompt.txt" 2>/dev/null; then
  echo "  PASS  ladder keeps its carve-outs (validation, security, a11y)"; pass=$((pass+1))
else
  echo "  FAIL  ladder must keep its carve-outs"; fail=$((fail+1))
fi

rm -f "$LB/prompt.txt"
PATH="$LB/bin:$PATH" CHARLES_STATE_DIR="$LB" bash "$RUN_SH" --lane explore --dir "$LB" --timeout 5 "t" >/dev/null 2>&1
if grep -q 'Does this need to exist at all' "$LB/prompt.txt" 2>/dev/null; then
  echo "  FAIL  explore should not carry the ladder; it writes no code"; fail=$((fail+1))
else
  echo "  PASS  explore correctly omits the ladder"; pass=$((pass+1))
fi

# --- unsourced changes --------------------------------------------------------
# An implementer reported FAILED while having edited two files, against an empty
# dispatch log. Prose forbade it; prose is what the agent contradicted.
US="$(cd "$(dirname "$0")/.." && pwd)/scripts/unsourced.sh"
UD="$BOX/unsourced"; mkdir -p "$UD"
( cd "$UD" && git init -q && git config user.name tester && git config user.email tester@example.invalid
  echo orig > a.ts && git add -A && git commit -qm init ) >/dev/null 2>&1
printf 'edited by nobody\n' > "$UD/a.ts"

bash "$US" "$UD" >/dev/null 2>&1
[ $? -eq 1 ] && { echo "  PASS  edits with no dispatch are flagged unsourced"; pass=$((pass+1)); } \
             || { echo "  FAIL  unsourced edits should be flagged"; fail=$((fail+1)); }

mkdir -p "$UD/.charles"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","lane":"implement","engine":"luna","model":"m","rc":0,"run":"/x","task":"t"}\n' "$NOW" \
  > "$UD/.charles/dispatches.jsonl"
bash "$US" "$UD" >/dev/null 2>&1
[ $? -eq 0 ] && { echo "  PASS  the same edits with a real dispatch are accounted for"; pass=$((pass+1)); } \
             || { echo "  FAIL  dispatched edits should be accounted for"; fail=$((fail+1)); }

printf '{"ts":"%s","lane":"implement","engine":"luna","model":"m","rc":143,"run":"/y","task":"t"}\n' "$NOW" \
  > "$UD/.charles/dispatches.jsonl"
# rc!=0 must never mean "accounted for". It now means "verify it yourself" (2)
# rather than "discard whole" (1): a lane cut short may still have written good
# code, and the receipt governs its claim, not its artifact.
bash "$US" "$UD" >/dev/null 2>&1
[ $? -eq 2 ] && { echo "  PASS  a failed dispatch does not launder edits (2, not 0)"; pass=$((pass+1)); } \
             || { echo "  FAIL  rc!=0 must not account for edits"; fail=$((fail+1)); }

# --- engine routing -----------------------------------------------------------
# terra is the capability escalation; deepseek is the availability fallback.
ED="$BOX/engines"; mkdir -p "$ED/bin"
printf '#!/usr/bin/env bash\necho "$@" > %s/args.txt\n' "$ED" > "$ED/bin/codex"
chmod +x "$ED/bin/codex"

PATH="$ED/bin:$PATH" CHARLES_STATE_DIR="$ED" bash "$RUN_SH" --lane implement --engine terra --dir "$ED" --timeout 5 "t" >/dev/null 2>&1
if grep -q -- '-p terra' "$ED/args.txt" 2>/dev/null; then
  echo "  PASS  --engine terra dispatches the terra profile"; pass=$((pass+1))
else
  echo "  FAIL  terra profile not selected"; fail=$((fail+1))
fi

PATH="$ED/bin:$PATH" CHARLES_STATE_DIR="$ED" bash "$RUN_SH" --lane implement --dir "$ED" --timeout 5 "t" >/dev/null 2>&1
if grep -q -- '-p luna' "$ED/args.txt" 2>/dev/null; then
  echo "  PASS  luna remains the default engine"; pass=$((pass+1))
else
  echo "  FAIL  default should still be luna"; fail=$((fail+1))
fi

PATH="$ED/bin:$PATH" CHARLES_STATE_DIR="$ED" bash "$RUN_SH" --lane implement --engine terra --dir "$ED" --timeout 5 "t" >/dev/null 2>&1
if grep -q -- '--disable fast_mode' "$ED/args.txt" 2>/dev/null; then
  echo "  PASS  terra runs with fast_mode disabled"; pass=$((pass+1))
else
  echo "  FAIL  terra must not use fast_mode"; fail=$((fail+1))
fi

PATH="$ED/bin:$PATH" CHARLES_STATE_DIR="$ED" bash "$RUN_SH" --lane implement --dir "$ED" --timeout 5 "t" >/dev/null 2>&1
if grep -q -- '--enable fast_mode' "$ED/args.txt" 2>/dev/null; then
  echo "  PASS  luna keeps fast_mode enabled"; pass=$((pass+1))
else
  echo "  FAIL  luna should keep fast_mode"; fail=$((fail+1))
fi

out="$(PATH="$ED/bin:$PATH" CHARLES_STATE_DIR="$ED" bash "$RUN_SH" --lane implement --engine nonsense --dir "$ED" --timeout 5 "t" 2>&1)"
if grep -q 'unknown engine' <<<"$out"; then
  echo "  PASS  an unknown engine is rejected"; pass=$((pass+1))
else
  echo "  FAIL  unknown engine should be rejected"; fail=$((fail+1))
fi

# A missing start-event write is fatal for implement, but read-only lanes warn
# and continue so their investigation result is still available.
STARTFAIL="$BOX/start-write-fail"; mkdir -p "$STARTFAIL/bin" "$STARTFAIL/.charles"
mkdir "$STARTFAIL/.charles/dispatches.jsonl"
printf '#!/usr/bin/env bash\ntouch "%s/codex-ran"\n' "$STARTFAIL" > "$STARTFAIL/bin/codex"
chmod +x "$STARTFAIL/bin/codex"
start_out="$(CHARLES_STATE_DIR="$STARTFAIL/state" PATH="$STARTFAIL/bin:$PATH" bash "$RUN_SH" --lane implement --dir "$STARTFAIL" --no-fallback --timeout 5 "start write failure" 2>&1)"; start_rc=$?
if [ "$start_rc" -eq 6 ] && grep -q 'failed to write implement start event' <<<"$start_out" \
  && [ ! -e "$STARTFAIL/codex-ran" ]; then
  echo "  PASS  implement aborts when its start event cannot be written"; pass=$((pass+1))
else
  echo "  FAIL  implement start-write failure should abort distinctly (rc=$start_rc)"; fail=$((fail+1))
fi

STARTWARN="$BOX/start-write-warn"; mkdir -p "$STARTWARN/bin" "$STARTWARN/.charles"
mkdir "$STARTWARN/.charles/dispatches.jsonl"
printf '#!/usr/bin/env bash\ntouch "%s/codex-ran"\n' "$STARTWARN" > "$STARTWARN/bin/codex"
chmod +x "$STARTWARN/bin/codex"
start_out="$(CHARLES_STATE_DIR="$STARTWARN/state" PATH="$STARTWARN/bin:$PATH" bash "$RUN_SH" --lane explore --dir "$STARTWARN" --no-fallback --timeout 5 "start write warning" 2>&1)"; start_rc=$?
if [ "$start_rc" -eq 0 ] && grep -q 'WARNING.*failed to write explore start event' <<<"$start_out" \
  && [ -e "$STARTWARN/codex-ran" ]; then
  echo "  PASS  explore warns loudly and continues when its start event fails"; pass=$((pass+1))
else
  echo "  FAIL  explore start-write failure should warn and continue (rc=$start_rc)"; fail=$((fail+1))
fi

# fallback receipt fields stay on the rescue end and the shared result file
FB="$BOX/fallback"; mkdir -p "$FB/bin" "$FB/home/.claude/skills/codex-deepseek/scripts" "$FB/repo"
printf '#!/usr/bin/env bash\ncase " $* " in *" -p luna "*) exit 7;; esac\nexit 0\n' > "$FB/bin/codex"
chmod +x "$FB/bin/codex"
printf '#!/usr/bin/env bash\nprintf "deepseek result\\n"\n' > "$FB/home/.claude/skills/codex-deepseek/scripts/codex-ds.sh"
chmod +x "$FB/home/.claude/skills/codex-deepseek/scripts/codex-ds.sh"
fb_out="$(HOME="$FB/home" CHARLES_STATE_DIR="$FB/state" PATH="$FB/bin:$PATH" bash "$RUN_SH" --lane explore --dir "$FB/repo" --timeout 2 "fallback" 2>&1)"; fb_rc=$?
fb_run="$(jq -r 'select(.event == "end") | .run' "$FB/repo/.charles/dispatches.jsonl" 2>/dev/null | tail -1)"
if [ "$fb_rc" -eq 0 ] && grep -q 'fallback_from:luna' <<<"$fb_out" && grep -q 'primary_rc:7' <<<"$fb_out"; then
  echo "  PASS  fallback receipt is printed on stderr"; pass=$((pass+1))
else
  echo "  FAIL  fallback stderr receipt is missing its fields (rc=$fb_rc)"; fail=$((fail+1))
fi
if jq -e --arg r "$fb_run" 'select(.event == "end" and .run == $r and .fallback_from == "luna" and .primary_rc == 7)' "$FB/repo/.charles/dispatches.jsonl" >/dev/null 2>&1; then
  echo "  PASS  rescue end carries fallback fields"; pass=$((pass+1))
else
  echo "  FAIL  rescue end should carry fallback fields"; fail=$((fail+1))
fi
if ! jq -e --arg r "$fb_run" 'select(.event == "end" and .run == $r and .engine == "luna" and has("fallback_from"))' "$FB/repo/.charles/dispatches.jsonl" >/dev/null 2>&1; then
  echo "  PASS  primary end does not carry fallback fields"; pass=$((pass+1))
else
  echo "  FAIL  fallback fields belong on the rescue end only"; fail=$((fail+1))
fi
if grep -q 'fallback_from:luna' "$FB/state/$fb_run.last" 2>/dev/null && grep -q 'primary_rc:7' "$FB/state/$fb_run.last" 2>/dev/null; then
  echo "  PASS  fallback result carries the same fields"; pass=$((pass+1))
else
  echo "  FAIL  fallback result should carry the same fields"; fail=$((fail+1))
fi

# --- relative paths must not hang the parent walk -----------------------------
# dirname "." is "." forever. Both hooks span-locked at rc 124 when a payload
# carried a relative path from a directory with no .charles.toml above it.
NC="$BOX/nocharles"; mkdir -p "$NC"

( cd "$NC" && printf '{"tool_name":"Write","tool_input":{"file_path":"a.ts","content":"x"}}' \
  | timeout 5 bash "$HOOK" ) >/dev/null 2>&1
[ $? -ne 124 ] && { echo "  PASS  relative file_path does not hang the edit hook"; pass=$((pass+1)); } \
               || { echo "  FAIL  edit hook hung on a relative path"; fail=$((fail+1)); }

( cd "$NC" && printf '{"tool_name":"Agent","cwd":".","tool_input":{"subagent_type":"Explore","prompt":"x"}}' \
  | timeout 5 bash "$SUBHOOK" ) >/dev/null 2>&1
[ $? -ne 124 ] && { echo "  PASS  relative cwd does not hang the subagent hook"; pass=$((pass+1)); } \
               || { echo "  FAIL  subagent hook hung on a relative cwd"; fail=$((fail+1)); }

( cd "$NC" && timeout 5 bash "$WARN" ) >/dev/null 2>&1
[ $? -ne 124 ] && { echo "  PASS  stop hook does not hang outside an opted-in repo"; pass=$((pass+1)); } \
               || { echo "  FAIL  stop hook hung"; fail=$((fail+1)); }

# --- partial work is not fabricated work --------------------------------------
# A lane cut short at its timeout may have written correct code before the clock
# stopped it. Discarding that is as wrong as accepting work no lane produced.
PW="$BOX/partial"; mkdir -p "$PW/.charles"
( cd "$PW" && git init -q && git config user.name tester && git config user.email tester@example.invalid
  printf 'orig\n' > a.ts && git add -A && git commit -qm init ) >/dev/null 2>&1
printf 'changed\n' > "$PW/a.ts"
PNOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

bash "$US" "$PW" >/dev/null 2>&1
[ $? -eq 1 ] && { echo "  PASS  no dispatch at all -> discard whole (1)"; pass=$((pass+1)); } \
             || { echo "  FAIL  no dispatch should exit 1"; fail=$((fail+1)); }

printf '{"ts":"%s","lane":"implement","engine":"luna","model":"m","rc":124,"run":"/x","task":"t"}\n' \
  "$PNOW" > "$PW/.charles/dispatches.jsonl"
bash "$US" "$PW" >/dev/null 2>&1
[ $? -eq 2 ] && { echo "  PASS  timed-out lane -> verify it yourself (2), not discard"; pass=$((pass+1)); } \
             || { echo "  FAIL  partial work should exit 2"; fail=$((fail+1)); }

printf '{"ts":"%s","lane":"implement","engine":"luna","model":"m","rc":0,"run":"/y","task":"t"}\n' \
  "$PNOW" >> "$PW/.charles/dispatches.jsonl"
bash "$US" "$PW" >/dev/null 2>&1
[ $? -eq 0 ] && { echo "  PASS  successful lane -> accounted for (0)"; pass=$((pass+1)); } \
             || { echo "  FAIL  successful dispatch should exit 0"; fail=$((fail+1)); }

# orphaned implement start: census is required before classifying tree changes
OR="$BOX/orphan"; OR_STATE="$BOX/orphan-state"; OR_RUN="orphan-run"
mkdir -p "$OR/.charles" "$OR_STATE"
( cd "$OR" && git init -q && git config user.name tester && git config user.email tester@example.invalid
  printf 'orig\n' > a.ts && git add -A && git commit -qm init && printf 'changed\n' > a.ts ) >/dev/null 2>&1
OR_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","event":"start","lane":"implement","engine":"luna","run":"%s","dir":"%s","task":"orphan"}\n' "$OR_NOW" "$OR_RUN" "$OR" > "$OR/.charles/dispatches.jsonl"
touch "$OR_STATE/$OR_RUN.jsonl"
printf '143\n' > "$OR_STATE/$OR_RUN.done"
orphan_out="$(CHARLES_STATE_DIR="$OR_STATE" bash "$US" "$OR" 2>&1)"; orphan_rc=$?
if [ "$orphan_rc" -eq 3 ] && grep -q 'killed lane may own these changes' <<<"$orphan_out"; then
  echo "  PASS  orphaned implement start gets census exit 3"; pass=$((pass+1))
else
  echo "  FAIL  orphaned implement start should exit 3 (rc=$orphan_rc)"; fail=$((fail+1))
fi
orphan_flow="$(CHARLES_STATE_DIR="$OR_STATE" bash "$FS" "$OR" 2>&1)"; orphan_flow_rc=$?
if [ "$orphan_flow_rc" -eq 1 ] && grep -q 'ISSUE.*orphan' <<<"$orphan_flow"; then
  echo "  PASS  flow status lists the orphan as an ISSUE"; pass=$((pass+1))
else
  echo "  FAIL  flow status should list the orphan (rc=$orphan_flow_rc)"; fail=$((fail+1))
fi
bash "$RS" init "$OR" feature "orphan close" >/dev/null 2>&1
orphan_close="$(CHARLES_STATE_DIR="$OR_STATE" bash "$RS" close "$OR" done 2>&1)"; orphan_close_rc=$?
if [ "$orphan_close_rc" -eq 5 ] && grep -q 'orphan' <<<"$orphan_close"; then
  echo "  PASS  close refuses while an orphan exists"; pass=$((pass+1))
else
  echo "  FAIL  close should refuse on an orphan (rc=$orphan_close_rc)"; fail=$((fail+1))
fi

# The orphan census must fail closed when it cannot inspect the dispatch log.
CF="$BOX/census-fail"; mkdir -p "$CF"
( cd "$CF" && git init -q && git config user.name tester && git config user.email tester@example.invalid
  printf 'orig\n' > a.ts && git add -A && git commit -qm init && printf 'changed\n' > a.ts ) >/dev/null 2>&1
NOJQ_BIN="$BOX/no-jq-bin"; mkdir -p "$NOJQ_BIN"
ln -s "$(command -v bash)" "$NOJQ_BIN/bash"
ln -s "$(command -v git)" "$NOJQ_BIN/git"
census_out="$(PATH="$NOJQ_BIN" bash "$US" "$CF" 2>&1)"; census_rc=$?
if [ "$census_rc" -eq 3 ] && grep -qi 'census impossible' <<<"$census_out"; then
  echo "  PASS  missing jq makes the orphan census fail closed"; pass=$((pass+1))
else
  echo "  FAIL  missing jq should return orphan code 3 (rc=$census_rc)"; fail=$((fail+1))
fi

mkdir -p "$CF/.charles"
printf '{malformed\n' > "$CF/.charles/dispatches.jsonl"
census_out="$(bash "$US" "$CF" 2>&1)"; census_rc=$?
if [ "$census_rc" -eq 3 ] && grep -qi 'census impossible' <<<"$census_out"; then
  echo "  PASS  malformed dispatch log makes the orphan census fail closed"; pass=$((pass+1))
else
  echo "  FAIL  malformed dispatch log should return orphan code 3 (rc=$census_rc)"; fail=$((fail+1))
fi

chmod 000 "$CF/.charles/dispatches.jsonl"
census_out="$(bash "$US" "$CF" 2>&1)"; census_rc=$?
chmod 644 "$CF/.charles/dispatches.jsonl"
if [ "$census_rc" -eq 3 ] && grep -qi 'census impossible' <<<"$census_out"; then
  echo "  PASS  unreadable dispatch log makes the orphan census fail closed"; pass=$((pass+1))
else
  echo "  FAIL  unreadable dispatch log should return orphan code 3 (rc=$census_rc)"; fail=$((fail+1))
fi

# --- review engine selection --------------------------------------------------
# Two models reviewing the same code overlapped on 1 finding out of 13, and
# review is the cheapest lane, so a second opinion is close to free.
RD="$BOX/reviewengine"; mkdir -p "$RD/bin" "$RD/docs"
printf '#!/usr/bin/env bash\necho "$@" > %s/args.txt\n' "$RD" > "$RD/bin/codex"
chmod +x "$RD/bin/codex"
( cd "$RD" && git init -q && git config user.name tester && git config user.email tester@example.invalid
  printf 'x\n' > a.ts && git add -A && git commit -qm init && printf 'changed\n' > a.ts ) >/dev/null 2>&1
printf '# Plan\n' > "$RD/docs/p.md"

PATH="$RD/bin:$PATH" CHARLES_STATE_DIR="$RD" bash "$RUN_SH" --lane review --dir "$RD" --plan "$RD/docs/p.md" --timeout 5 "t" >/dev/null 2>&1
if grep -q -- '-m gpt-5.6-sol' "$RD/args.txt" 2>/dev/null; then
  echo "  PASS  review defaults to sol even though luna is the global default"; pass=$((pass+1))
else
  echo "  FAIL  review must default to sol"; fail=$((fail+1))
fi

PATH="$RD/bin:$PATH" CHARLES_STATE_DIR="$RD" bash "$RUN_SH" --lane review --engine terra --dir "$RD" --plan "$RD/docs/p.md" --timeout 5 "t" >/dev/null 2>&1
if grep -q -- '-m gpt-5.6-terra' "$RD/args.txt" 2>/dev/null; then
  echo "  PASS  --engine terra gives a second-opinion reviewer"; pass=$((pass+1))
else
  echo "  FAIL  review --engine terra not honoured"; fail=$((fail+1))
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]

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
scheck "codex-explorer is the right thing" allow codex-explorer "$BOX/repo"
scheck "codex-implementer is the right thing" allow codex-implementer "$BOX/repo"
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
( flock 9 && sleep 20 ) 9>"$LOCKDIR/.charles/implement.lock" &
decoy=$!
sleep 1

out="$(PATH="$LOCKDIR/bin:$PATH" bash "$RUN_SH" --lane implement --dir "$LOCKDIR" "second writer" 2>&1)"; rc=$?
if [ "$rc" -eq 4 ] && grep -q 'REFUSING' <<<"$out"; then
  echo "  PASS  second writer on the same tree is refused"; pass=$((pass+1))
else
  echo "  FAIL  second writer should have been refused (rc=$rc)"; fail=$((fail+1))
fi

out="$(CHARLES_ALLOW_CONCURRENT_WRITES=1 PATH="$LOCKDIR/bin:$PATH" bash "$RUN_SH" --lane implement --dir "$LOCKDIR" --timeout 2 "override" 2>&1)"
if grep -q 'override set' <<<"$out"; then
  echo "  PASS  explicit override is honoured"; pass=$((pass+1))
else
  echo "  FAIL  override should have been honoured"; fail=$((fail+1))
fi

# a read-only explore alongside a writer is fine and must NOT be refused
out="$(PATH="$LOCKDIR/bin:$PATH" bash "$RUN_SH" --lane explore --dir "$LOCKDIR" --timeout 2 "reader" 2>&1)"
if grep -q 'REFUSING' <<<"$out"; then
  echo "  FAIL  explore was refused; the lock must only guard writers"; fail=$((fail+1))
else
  echo "  PASS  explore alongside a writer is allowed"; pass=$((pass+1))
fi

kill "$decoy" 2>/dev/null; wait "$decoy" 2>/dev/null

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
CLAUDE_PLUGIN_ROOT="$FAKEROOT" bash "$LINK" >/dev/null 2>&1
if [ "$(readlink "$HOME/.local/bin/codex-run" 2>/dev/null)" = "$FAKEROOT/scripts/codex-run.sh" ]; then
  echo "  PASS  session hook links codex-run onto PATH"; pass=$((pass+1))
else
  echo "  FAIL  session hook did not create the codex-run symlink"; fail=$((fail+1))
fi

second="$(CLAUDE_PLUGIN_ROOT="$FAKEROOT" bash "$LINK" 2>&1)"
if [ -z "$second" ]; then
  echo "  PASS  hook is idempotent on reinstall"; pass=$((pass+1))
else
  echo "  FAIL  hook should be silent when the link is already correct"; fail=$((fail+1))
fi

# with no plugin root it must exit quietly rather than erroring
if CLAUDE_PLUGIN_ROOT="" bash "$LINK" >/dev/null 2>&1; then
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

# --- lane liveness ------------------------------------------------------------
# Waiting on .last cannot distinguish "not finished yet" from "killed"; agents
# sat stuck 27 minutes on dead engines. lane-status asks the process instead.
LS="$(cd "$(dirname "$0")/.." && pwd)/scripts/lane-status.sh"
LD="$BOX/lanes"; mkdir -p "$LD"

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

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]

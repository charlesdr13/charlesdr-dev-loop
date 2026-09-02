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
for f in a.ts b.ts c.ts d2.ts d.md; do echo "x" > "$BOX/repo/$f"; done

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

# --- approving an ask is remembered ------------------------------------------
# The nag bug: nfiles only grows, so before this every edit for the next hour
# re-asked after the 3rd file. Approval must buy silence.
MARK="$(cd "$(dirname "$0")/.." && pwd)/hooks/mark-inline-ok.sh"
: > "$BOX/repo/.charles/touched"
printf '%s\n' "$BOX/repo/a.ts" "$BOX/repo/b.ts" > "$BOX/repo/.charles/touched"
rm -f "$BOX/repo/.charles/inline-ok" "$BOX/repo/.charles/pending-ask"

edit_c="$(jq -nc --arg p "$BOX/repo/c.ts" --arg s "$small" '{tool_name:"Edit",tool_input:{file_path:$p,old_string:"x",new_string:$s}}')"
check "ask fires on the 3rd file" ask "$edit_c"

# the edit lands -> PostToolUse converts pending-ask into the grant
printf '%s' "$edit_c" | bash "$MARK" >/dev/null 2>&1
if [ -f "$BOX/repo/.charles/inline-ok" ]; then
  echo "  PASS  approved edit writes inline-ok"; pass=$((pass+1))
else
  echo "  FAIL  approved edit writes inline-ok — marker missing"; fail=$((fail+1))
fi

check "4th file stays quiet after approval" allow \
  "$(jq -nc --arg p "$BOX/repo/d2.ts" --arg s "$small" '{tool_name:"Edit",tool_input:{file_path:$p,old_string:"x",new_string:$s}}')"
check "big edit stays quiet after approval" allow \
  "$(jq -nc --arg p "$BOX/repo/a.ts" --arg c "$big" '{tool_name:"Write",tool_input:{file_path:$p,content:$c}}')"

# an expired grant re-arms the gate
touch -d '2 hours ago' "$BOX/repo/.charles/inline-ok"
check "expired grant asks again" ask \
  "$(jq -nc --arg p "$BOX/repo/a.ts" --arg c "$big" '{tool_name:"Write",tool_input:{file_path:$p,content:$c}}')"

# a DENIED ask must not be cashable by a later edit to another file
rm -f "$BOX/repo/.charles/inline-ok"
printf '%s\n' "$BOX/repo/a.ts" > "$BOX/repo/.charles/pending-ask"
printf '%s' "$(jq -nc --arg p "$BOX/repo/b.ts" --arg s "$small" '{tool_name:"Edit",tool_input:{file_path:$p,old_string:"x",new_string:$s}}')" | bash "$MARK" >/dev/null 2>&1
if [ ! -f "$BOX/repo/.charles/inline-ok" ]; then
  echo "  PASS  mismatched pending-ask grants nothing"; pass=$((pass+1))
else
  echo "  FAIL  mismatched pending-ask grants nothing — grant was written"; fail=$((fail+1))
fi
rm -f "$BOX/repo/.charles/inline-ok" "$BOX/repo/.charles/pending-ask"

# --- Claude Code worktrees are exempt and do not count -----------------------
WT="$BOX/repo/.claude/worktrees/fixture"; mkdir -p "$WT"
rm -f "$BOX/repo/.charles/inline-ok"
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

# --- scripts reached through a PATH symlink must still find run-common.sh -----
# v2.30.0 sourced "$SCRIPT_DIR/run-common.sh" with SCRIPT_DIR taken from an
# UNRESOLVED $BASH_SOURCE, so every dispatch through the ~/.local/bin symlink
# died with "No such file or directory". A max-effort review had just passed the
# same diff. Only running it through the symlink caught it.
SYMROOT="$(cd "$(dirname "$0")/.." && pwd)"
SYMBOX="$(mktemp -d)"
ln -sfn "$SYMROOT/scripts/codex-run.sh"       "$SYMBOX/codex-run"
ln -sfn "$SYMROOT/scripts/run-state.sh"       "$SYMBOX/run-state"
ln -sfn "$SYMROOT/scripts/parallel-chunks.sh" "$SYMBOX/parallel-chunks"
sym_bad=""
for tool in codex-run run-state parallel-chunks; do
  out="$(bash "$SYMBOX/$tool" 2>&1 </dev/null || true)"
  case "$out" in *"run-common.sh: No such file"*) sym_bad="$sym_bad $tool" ;; esac
done
rm -rf "$SYMBOX"
if [ -z "$sym_bad" ]; then
  echo "  PASS  scripts source run-common.sh through a symlink"; pass=$((pass+1))
else
  echo "  FAIL  symlinked invocation cannot find run-common.sh:$sym_bad"; fail=$((fail+1))
fi

# --- every script must start with a real shebang ------------------------------
# codex-run.sh carried a blank line 1 for months: the kernel saw no shebang, so
# exec'ing it directly (timeout codex-run, cron, any non-bash caller) fell back
# to sh and died on `set -o pipefail`. Invoking it as `bash codex-run.sh` hid it.
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
shebang_bad=""
for f in "$REPO_ROOT"/scripts/*.sh "$REPO_ROOT"/hooks/*.sh; do
  [ -f "$f" ] || continue
  case "$(head -c 2 "$f")" in '#!') ;; *) shebang_bad="$shebang_bad ${f#"$REPO_ROOT"/}" ;; esac
done
if [ -z "$shebang_bad" ]; then
  echo "  PASS  every script starts with a shebang"; pass=$((pass+1))
else
  echo "  FAIL  script(s) with no shebang on line 1:$shebang_bad"; fail=$((fail+1))
fi

# --- subagent routing hook ----------------------------------------------------
SUBHOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/route-subagents.sh"

scheck_tool() { # scheck_tool NAME EXPECT TOOL SUBAGENT_TYPE CWD
  local name="$1" expect="$2" tool="$3" out decision
  out="$(jq -nc --arg t "$tool" --arg s "$4" --arg c "$5" '{tool_name:$t,cwd:$c,tool_input:{subagent_type:$s,prompt:"x"}}' | bash "$SUBHOOK" 2>/dev/null)"
  if [ -z "$out" ]; then decision=allow
  else decision="$(jq -r '.hookSpecificOutput.permissionDecision // "allow"' <<<"$out" 2>/dev/null)"; fi
  if [ "$decision" = "$expect" ]; then
    echo "  PASS  $name (expected $expect)"; pass=$((pass+1))
  else
    echo "  FAIL  $name — expected $expect, got $decision"; echo "        $out"; fail=$((fail+1))
  fi
}

echo

routing_cases=(
  "opted-out repo, general-purpose|allow|general-purpose|$BOX/plain"
  "codex-reviewer remains allowed|allow|codex-reviewer|$BOX/repo"
  "google-drive is not code work|allow|google-drive|$BOX/repo"
  "Explore must route to a lane|ask|Explore|$BOX/repo"
  "general-purpose must route|ask|general-purpose|$BOX/repo"
  "python-pro must route|ask|python-pro|$BOX/repo"
  "feature-dev:code-explorer routes|ask|feature-dev:code-explorer|$BOX/repo"
)
for tool in Agent Task; do
  for test_case in "${routing_cases[@]}"; do
    IFS='|' read -r name expect sub cwd <<<"$test_case"
    scheck_tool "$tool $name" "$expect" "$tool" "$sub" "$cwd"
  done
done

message_check() { # message_check NAME SUBAGENT_TYPE CWD EXPECTED-DISPATCH
  local name="$1" out
  out="$(jq -nc --arg s "$2" --arg c "$3" '{tool_name:"Agent",cwd:$c,tool_input:{subagent_type:$s,prompt:"x"}}' | bash "$SUBHOOK" 2>/dev/null)"
  if grep -qF "$4" <<<"$out" && grep -qF 'run_in_background: true' <<<"$out"; then
    echo "  PASS  $name"; pass=$((pass+1))
  else
    echo "  FAIL  $name — expected direct background dispatch"; echo "        $out"; fail=$((fail+1))
  fi
}

# --- approving a SPAWN grants too (fresh session: no edit has happened yet) ----
rm -f "$BOX/repo/.charles/inline-ok" "$BOX/repo/.charles/pending-ask"
spawn_payload="$(jq -nc --arg c "$BOX/repo" '{tool_name:"Agent",cwd:$c,tool_input:{subagent_type:"Explore",prompt:"x"}}')"
scheck_tool "first spawn of a session asks" ask Agent Explore "$BOX/repo"
printf '%s' "$spawn_payload" | bash "$MARK" >/dev/null 2>&1
if [ -f "$BOX/repo/.charles/inline-ok" ]; then
  echo "  PASS  approved spawn writes inline-ok"; pass=$((pass+1))
else
  echo "  FAIL  approved spawn writes inline-ok — marker missing"; fail=$((fail+1))
fi
scheck_tool "second spawn stays quiet" allow Agent general-purpose "$BOX/repo"
# a denied spawn must not be cashed by a different agent type
rm -f "$BOX/repo/.charles/inline-ok"
printf 'agent:Explore\n' > "$BOX/repo/.charles/pending-ask"
printf '%s' "$(jq -nc --arg c "$BOX/repo" '{tool_name:"Agent",cwd:$c,tool_input:{subagent_type:"python-pro",prompt:"x"}}')" | bash "$MARK" >/dev/null 2>&1
if [ ! -f "$BOX/repo/.charles/inline-ok" ]; then
  echo "  PASS  mismatched spawn pending grants nothing"; pass=$((pass+1))
else
  echo "  FAIL  mismatched spawn pending grants nothing — grant was written"; fail=$((fail+1))
fi
rm -f "$BOX/repo/.charles/inline-ok" "$BOX/repo/.charles/pending-ask"

# --- the inline grant reaches the subagent gate, on a shorter clock -----------
: > "$BOX/repo/.charles/inline-ok"
scheck_tool "fresh grant quiets the subagent gate" allow Agent Explore "$BOX/repo"
# 10-minute default: older than the edit gate's 60 tolerates, still asks here.
touch -d '30 minutes ago' "$BOX/repo/.charles/inline-ok"
scheck_tool "grant older than 10min re-arms the subagent gate" ask Agent Explore "$BOX/repo"
rm -f "$BOX/repo/.charles/inline-ok"

message_check "Explore block points to direct dispatch" Explore "$BOX/repo" \
  "codex-run --lane explore --dir <repo> --timeout 2700"
message_check "implement block points to direct dispatch" python-pro "$BOX/repo" \
  "codex-run --lane implement --dir <repo> --timeout 2700"

# The Claude hook harness cannot be exercised from selftest; this matcher string
# guard is the accepted wiring limit.
HOOKS_JSON="$(cd "$(dirname "$0")/.." && pwd)/hooks/hooks.json"
if jq -e '.hooks.PreToolUse[]?.matcher | strings | select(contains("Agent") and contains("Task"))' \
  "$HOOKS_JSON" >/dev/null 2>&1; then
  echo "  PASS  hooks matcher wires both Agent and Task"; pass=$((pass+1))
else
  echo "  FAIL  hooks matcher must contain both Agent and Task"; fail=$((fail+1))
fi

# --- script hardening ---------------------------------------------------------
GREEN="$(cd "$(dirname "$0")/.." && pwd)/scripts/green.sh"
GD="$BOX/green"; mkdir -p "$GD"
printf 'green = "exit 124"\ngreen_timeout = 7\n' > "$GD/.charles.toml"
green_out="$(bash "$GREEN" "$GD" 2>&1)"; green_rc=$?
if [ "$green_rc" -eq 124 ] \
  && grep -qF 'RED (rc 124 — timed out at 7s, or the command itself returned 124)' <<<"$green_out"; then
  echo "  PASS  green reports the configured rc-124 ambiguity"; pass=$((pass+1))
else
  echo "  FAIL  green must report configured rc-124 ambiguity (rc=$green_rc)"; fail=$((fail+1))
fi

printf 'green = "exit 124"\n' > "$GD/.charles.toml"
green_out="$(bash "$GREEN" "$GD" 2>&1)"; green_rc=$?
if [ "$green_rc" -eq 124 ] \
  && grep -qF 'RED (rc 124 — timed out at 480s, or the command itself returned 124)' <<<"$green_out"; then
  echo "  PASS  green uses the 480s default"; pass=$((pass+1))
else
  echo "  FAIL  green must use the 480s default (rc=$green_rc)"; fail=$((fail+1))
fi

printf 'green = "exit 124"\ngreen_timeout = 12junk\n' > "$GD/.charles.toml"
green_out="$(bash "$GREEN" "$GD" 2>&1)"; green_rc=$?
if [ "$green_rc" -eq 124 ] \
  && grep -qF 'WARN: invalid green_timeout; using default 480' <<<"$green_out" \
  && grep -qF 'timed out at 480s' <<<"$green_out"; then
  echo "  PASS  green rejects a non-integer timeout and warns"; pass=$((pass+1))
else
  echo "  FAIL  green must reject a non-integer timeout with a warning (rc=$green_rc)"; fail=$((fail+1))
fi

PARALLEL="$(cd "$(dirname "$0")/.." && pwd)/scripts/parallel-chunks.sh"
PD="$BOX/parallel"; mkdir -p "$PD/bin"

parallel_fixture() { # parallel_fixture REPO WORKTREE GREEN-COMMAND [TRACKED-OUTSIDE]
  local repo="$1" worktree="$2" green_command="$3" tracked_outside="${4:-}" shared_file="${5:-}"
  mkdir -p "$repo" "$(dirname "$worktree")"
  (
    cd "$repo" && git init -q && git config user.name tester \
      && git config user.email tester@example.invalid \
      && printf 'green = "%s"\n' "$green_command" > .charles.toml \
      && printf 'base\n' > alpha && printf 'base\n' > beta \
      && { [ "$tracked_outside" != tracked ] || printf 'base\n' > outside; } \
      && { [ -z "$shared_file" ] || printf 'base\nbase\nbase\n' > "$shared_file"; } \
      && git add . && git commit -qm init
  )
  git -C "$repo" worktree add -q "$worktree" HEAD
}

parallel_swap_fixture() { # parallel_swap_fixture REPO WORKTREE
  local repo="$1" worktree="$2"
  mkdir -p "$repo" "$(dirname "$worktree")"
  (
    cd "$repo" && git init -q && git config user.name tester \
      && git config user.email tester@example.invalid \
      && printf 'green = "true"\n' > .charles.toml \
      && printf 'alpha base\n' > alpha && printf 'beta base\n' > beta \
      && printf 'base\n' > gamma && git add . && git commit -qm init
  )
  git -C "$repo" worktree add -q "$worktree" HEAD
}

parallel_fixture "$PD/good-repo" "$PD/good-alpha" true
parallel_fixture "$PD/oob-repo" "$PD/oob-alpha" true
parallel_fixture "$PD/failed-repo" "$PD/failed-alpha" true
parallel_fixture "$PD/red-repo" "$PD/red-alpha" false
parallel_fixture "$PD/missing-repo" "$PD/missing-alpha" true
parallel_fixture "$PD/ignored-repo" "$PD/ignored-alpha" true
parallel_fixture "$PD/ignored-link-repo" "$PD/ignored-link-alpha" true
parallel_fixture "$PD/tracked-oob-repo" "$PD/tracked-oob-alpha" true tracked
parallel_fixture "$PD/delete-repo" "$PD/delete-alpha" true
parallel_fixture "$PD/rename-repo" "$PD/rename-alpha" true
parallel_fixture "$PD/bad-receipt-repo" "$PD/bad-receipt-alpha" true
parallel_fixture "$PD/space-repo" "$PD/space-alpha" false '' 'space file'
parallel_fixture "$PD/r10-repo" "$PD/r10-alpha" true
parallel_swap_fixture "$PD/swap-repo" "$PD/swap-alpha"
parallel_fixture "$PD/shared-clean-repo" "$PD/shared-clean-alpha" true '' shared
parallel_fixture "$PD/shared-conflict-repo" "$PD/shared-conflict-alpha" true '' shared
parallel_fixture "$PD/stale-repo" "$PD/stale-alpha" true
parallel_fixture "$PD/head-moved-repo" "$PD/head-moved-alpha" true
git -C "$PD/good-repo" worktree add -q "$PD/good-beta" HEAD
git -C "$PD/oob-repo" worktree add -q "$PD/oob-beta" HEAD
git -C "$PD/failed-repo" worktree add -q "$PD/failed-beta" HEAD
git -C "$PD/red-repo" worktree add -q "$PD/red-beta" HEAD
git -C "$PD/missing-repo" worktree add -q "$PD/missing-beta" HEAD
git -C "$PD/ignored-repo" worktree add -q "$PD/ignored-beta" HEAD
git -C "$PD/ignored-link-repo" worktree add -q "$PD/ignored-link-beta" HEAD
git -C "$PD/tracked-oob-repo" worktree add -q "$PD/tracked-oob-beta" HEAD
git -C "$PD/delete-repo" worktree add -q "$PD/delete-beta" HEAD
git -C "$PD/rename-repo" worktree add -q "$PD/rename-beta" HEAD
git -C "$PD/bad-receipt-repo" worktree add -q "$PD/bad-receipt-beta" HEAD
git -C "$PD/r10-repo" worktree add -q "$PD/r10-beta" HEAD
git -C "$PD/shared-clean-repo" worktree add -q "$PD/shared-clean-beta" HEAD
git -C "$PD/shared-conflict-repo" worktree add -q "$PD/shared-conflict-beta" HEAD
(
  cd "$PD/stale-repo" && printf 'current\n' > current && git add current && git commit -qm advance
)
git -C "$PD/stale-repo" worktree add -q "$PD/stale-beta" HEAD
git -C "$PD/head-moved-repo" worktree add -q "$PD/head-moved-beta" HEAD
git -C "$PD/space-repo" worktree add -q "$PD/space-beta" HEAD
git -C "$PD/swap-repo" worktree add -q "$PD/swap-gamma" HEAD
printf 'ignored-dir/\nignored-*\n' >> "$PD/ignored-repo/.git/info/exclude"
printf 'ignored-link\n' >> "$PD/ignored-link-repo/.git/info/exclude"
printf 'outside\n' > "$PD/ignored-link-target"

printf '[{"name":"alpha","files":["alpha"],"task":"x"},{"name":"beta","files":["beta"],"task":"x"}]\n' > "$PD/spec.json"
printf '[{"name":"swap","files":["alpha","beta"],"task":"x"},{"name":"gamma","files":["gamma"],"task":"x"}]\n' > "$PD/swap-spec.json"
printf '[{"name":"delete","files":["alpha"],"task":"x"},{"name":"beta","files":["beta"],"task":"x"}]\n' > "$PD/delete-spec.json"
printf '[{"name":"rename","files":["renamed"],"task":"x"},{"name":"beta","files":["beta"],"task":"x"}]\n' > "$PD/rename-spec.json"
printf '[{"name":"bad","files":["alpha"],"task":"x"},{"name":"beta","files":["beta"],"task":"x"}]\n' > "$PD/bad-receipt-spec.json"
printf '[{"name":"space","files":["space file"],"task":"x"},{"name":"beta","files":["beta"],"task":"x"}]\n' > "$PD/space-spec.json"
printf '[{"name":"alpha","files":["shared"],"shared":["shared"],"task":"x"},{"name":"beta","files":["shared"],"shared":["shared"],"task":"x"}]\n' > "$PD/shared-spec.json"
printf '#!/usr/bin/env bash\nexit 1\n' > "$PD/bin/treehouse"; chmod +x "$PD/bin/treehouse"
mkdir -p "$PD/lease-repo"; ( cd "$PD/lease-repo" && git init -q && git config user.name tester \
  && git config user.email tester@example.invalid && printf 'seed\n' > seed && git add seed && git commit -qm init ) >/dev/null 2>&1
parallel_out="$(PATH="$PD/bin:$PATH" bash "$PARALLEL" "$PD/lease-repo" "$PD/spec.json" 2>&1)"; parallel_rc=$?
if [ "$parallel_rc" -eq 3 ] && grep -qF 'refusing the whole batch' <<<"$parallel_out" \
  && ! grep -qF 'dispatching 2 chunks' <<<"$parallel_out"; then
  echo "  PASS  failed chunk lease dispatches nothing and exits 3"; pass=$((pass+1))
else
  echo "  FAIL  failed chunk lease must refuse the batch (rc=$parallel_rc)"; fail=$((fail+1))
fi

RECOVERY_REPO="$PD/recovery-repo"; RECOVERY_WT="$PD/recovery-first"
mkdir -p "$RECOVERY_REPO"; ( cd "$RECOVERY_REPO" && git init -q && git config user.name tester \
  && git config user.email tester@example.invalid && printf 'seed\n' > seed && git add seed && git commit -qm init ) >/dev/null 2>&1
git -C "$RECOVERY_REPO" worktree add -q "$RECOVERY_WT" HEAD
printf '0\n' > "$PD/recovery-get-count"; : > "$PD/recovery-returns"
cat > "$PD/bin/treehouse" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  get)
    count=0
    [ -f "$PD/recovery-get-count" ] && read -r count < "$PD/recovery-get-count"
    count=\$((count + 1))
    printf '%s\n' "\$count" > "$PD/recovery-get-count"
    if [ "\$count" -eq 1 ]; then printf '%s\n' "$RECOVERY_WT"; else exit 1; fi
    ;;
  return)
    printf '%s\n' "\${2:-}" >> "$PD/recovery-returns"
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$PD/bin/treehouse"
recovery_out="$(PATH="$PD/bin:$PATH" bash "$PARALLEL" "$RECOVERY_REPO" "$PD/spec.json" 2>&1)"; recovery_rc=$?
if [ "$recovery_rc" -eq 3 ] && ! grep -qF 'dispatching 2 chunks' <<<"$recovery_out" \
  && grep -qF "$RECOVERY_WT" "$PD/recovery-returns"; then
  echo "  PASS  partial lease failure returns the first worktree without dispatching"; pass=$((pass+1))
else
  echo "  FAIL  partial lease failure must return the first worktree (rc=$recovery_rc)"; fail=$((fail+1))
fi

cat > "$PD/bin/treehouse" <<EOF
#!/usr/bin/env bash
if [ -n "\${CHARLES_TREEHOUSE_CALLS:-}" ]; then printf '%s\n' "\${1:-}" >> "\$CHARLES_TREEHOUSE_CALLS"; fi
case "\${1:-}" in
  get)
    holder="\${4:-}"
    case "\${PWD##*/}:\$holder" in
      good-repo:chunk-alpha) printf '%s\n' "$PD/good-alpha" ;;
      good-repo:chunk-beta) printf '%s\n' "$PD/good-beta" ;;
      oob-repo:chunk-alpha) printf '%s\n' "$PD/oob-alpha" ;;
      oob-repo:chunk-beta) printf '%s\n' "$PD/oob-beta" ;;
      failed-repo:chunk-alpha) printf '%s\n' "$PD/failed-alpha" ;;
      failed-repo:chunk-beta) printf '%s\n' "$PD/failed-beta" ;;
      red-repo:chunk-alpha) printf '%s\n' "$PD/red-alpha" ;;
      red-repo:chunk-beta) printf '%s\n' "$PD/red-beta" ;;
      missing-repo:chunk-alpha) printf '%s\n' "$PD/missing-alpha" ;;
      missing-repo:chunk-beta) printf '%s\n' "$PD/missing-beta" ;;
      ignored-repo:chunk-alpha) printf '%s\n' "$PD/ignored-alpha" ;;
      ignored-repo:chunk-beta) printf '%s\n' "$PD/ignored-beta" ;;
      ignored-link-repo:chunk-alpha) printf '%s\n' "$PD/ignored-link-alpha" ;;
      ignored-link-repo:chunk-beta) printf '%s\n' "$PD/ignored-link-beta" ;;
      tracked-oob-repo:chunk-alpha) printf '%s\n' "$PD/tracked-oob-alpha" ;;
      tracked-oob-repo:chunk-beta) printf '%s\n' "$PD/tracked-oob-beta" ;;
      delete-repo:chunk-delete) printf '%s\n' "$PD/delete-alpha" ;;
      delete-repo:chunk-beta) printf '%s\n' "$PD/delete-beta" ;;
      rename-repo:chunk-rename) printf '%s\n' "$PD/rename-alpha" ;;
      rename-repo:chunk-beta) printf '%s\n' "$PD/rename-beta" ;;
      r10-repo:chunk-alpha) printf '%s\n' "$PD/r10-alpha" ;;
      r10-repo:chunk-beta) printf '%s\n' "$PD/r10-beta" ;;
      shared-clean-repo:chunk-alpha) printf '%s\n' "$PD/shared-clean-alpha" ;;
      shared-clean-repo:chunk-beta) printf '%s\n' "$PD/shared-clean-beta" ;;
      shared-conflict-repo:chunk-alpha) printf '%s\n' "$PD/shared-conflict-alpha" ;;
      shared-conflict-repo:chunk-beta) printf '%s\n' "$PD/shared-conflict-beta" ;;
      stale-repo:chunk-alpha) printf '%s\n' "$PD/stale-alpha" ;;
      stale-repo:chunk-beta) printf '%s\n' "$PD/stale-beta" ;;
      head-moved-repo:chunk-alpha) printf '%s\n' "$PD/head-moved-alpha" ;;
      head-moved-repo:chunk-beta) printf '%s\n' "$PD/head-moved-beta" ;;
      bad-receipt-repo:chunk-bad) printf '%s\n' "$PD/bad-receipt-alpha" ;;
      bad-receipt-repo:chunk-beta) printf '%s\n' "$PD/bad-receipt-beta" ;;
      space-repo:chunk-space) printf '%s\n' "$PD/space-alpha" ;;
      space-repo:chunk-beta) printf '%s\n' "$PD/space-beta" ;;
      swap-repo:chunk-swap) printf '%s\n' "$PD/swap-alpha" ;;
      swap-repo:chunk-gamma) printf '%s\n' "$PD/swap-gamma" ;;
      *) exit 1 ;;
    esac
    ;;
  return) printf '%s\n' "\${2:-}" >> "\${CHARLES_RETURN_RECORD:?}" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$PD/bin/treehouse"

manifest_check() { # manifest_check NAME JSON
  local name="$1" manifest="$2" out rc
  printf '%s\n' "$manifest" > "$PD/manifest-$name.json"
  out="$(bash "$PARALLEL" "$PD/lease-repo" "$PD/manifest-$name.json" 2>&1)"; rc=$?
  if [ "$rc" -eq 1 ] && grep -qF 'invalid manifest' <<<"$out"; then
    echo "  PASS  invalid manifest is refused: $name"; pass=$((pass+1))
  else
    echo "  FAIL  invalid manifest must be refused: $name (rc=$rc)"; fail=$((fail+1))
  fi
}

manifest_check "not-array" '{"name":"alpha"}'
manifest_check "missing-field" '[{"name":"alpha","files":["alpha"]}]'
manifest_check "duplicate-names" '[{"name":"alpha","files":["alpha"],"task":"x"},{"name":"alpha","files":["beta"],"task":"x"}]'
manifest_check "absolute-path" '[{"name":"alpha","files":["/alpha"],"task":"x"},{"name":"beta","files":["beta"],"task":"x"}]'
manifest_check "dot-dot-path" '[{"name":"alpha","files":["../alpha"],"task":"x"},{"name":"beta","files":["beta"],"task":"x"}]'
manifest_check "bad-req-shape" '[{"name":"alpha","files":["alpha"],"task":"x","req":"R1"},{"name":"beta","files":["beta"],"task":"x"}]'
manifest_check "malformed-req-id" '[{"name":"alpha","files":["alpha"],"task":"x","req":["R1.bad"]},{"name":"beta","files":["beta"],"task":"x"}]'

manifest_refusal() { # manifest_refusal NAME JSON REASON
  local name="$1" manifest="$2" reason="$3" out rc
  printf '%s\n' "$manifest" > "$PD/manifest-$name.json"
  out="$(bash "$PARALLEL" "$PD/lease-repo" "$PD/manifest-$name.json" 2>&1)"; rc=$?
  if [ "$rc" -eq 1 ] && grep -qF "$reason" <<<"$out"; then
    echo "  PASS  manifest refusal names the reason: $name"; pass=$((pass+1))
  else
    echo "  FAIL  manifest refusal must name the reason: $name (rc=$rc)"; fail=$((fail+1))
  fi
}

manifest_refusal "undeclared-overlap" \
  '[{"name":"alpha","files":["shared"],"task":"x"},{"name":"beta","files":["shared"],"task":"x"}]' \
  'chunks declare overlapping files'
manifest_refusal "one-sided-shared" \
  '[{"name":"alpha","files":["shared"],"shared":["shared"],"task":"x"},{"name":"beta","files":["shared"],"task":"x"}]' \
  "shared path 'shared' is not declared shared by every overlapping chunk"
manifest_refusal "shared-outside-files" \
  '[{"name":"alpha","files":["alpha"],"shared":["shared"],"task":"x"},{"name":"beta","files":["beta"],"task":"x"}]' \
  "shared path 'shared' is not in files for chunk alpha"
manifest_refusal "three-shared" \
  '[{"name":"alpha","files":["shared"],"shared":["shared"],"task":"x"},{"name":"beta","files":["shared"],"shared":["shared"],"task":"x"},{"name":"gamma","files":["shared"],"shared":["shared"],"task":"x"}]' \
  "shared path 'shared' is declared by 3 chunks"

cat > "$PD/bin/codex" <<'EOF'
#!/usr/bin/env bash
[ -z "${CHARLES_LANE_MARKER:-}" ] || : > "$CHARLES_LANE_MARKER"
case "$PWD" in
  */good-alpha) printf 'alpha merged\n' > alpha; exit 0 ;;
  */good-beta) printf 'beta merged\n' > beta; exit 0 ;;
  */oob-alpha) printf 'alpha changed\n' > alpha; printf 'not allowed\n' > outside; exit 0 ;;
  */oob-beta) printf 'beta changed\n' > beta; exit 0 ;;
  */tracked-oob-alpha) printf 'alpha changed\n' > alpha; printf 'not allowed\n' > outside; exit 0 ;;
  */tracked-oob-beta) printf 'beta changed\n' > beta; exit 0 ;;
  */failed-alpha) printf 'alpha changed\n' > alpha; exit 7 ;;
  */failed-beta) printf 'beta changed\n' > beta; exit 0 ;;
  */red-alpha) printf 'alpha merged\n' > alpha; exit 0 ;;
  */red-beta) printf 'beta merged\n' > beta; exit 0 ;;
  */ignored-alpha) printf 'alpha changed\n' > alpha; mkdir -p ignored-dir; printf 'not allowed\n' > ignored-dir/outside; printf 'not allowed\n' > $'ignored-\033[31mline\nbreak'; exit 0 ;;
  */ignored-beta) printf 'beta changed\n' > beta; exit 0 ;;
  */ignored-link-alpha) printf 'alpha changed\n' > alpha; ln -s "${IGNORED_LINK_TARGET:?}" ignored-link; exit 0 ;;
  */ignored-link-beta) printf 'beta changed\n' > beta; exit 0 ;;
  */delete-alpha) rm -f alpha; exit 0 ;;
  */delete-beta) printf 'beta changed\n' > beta; exit 0 ;;
  */rename-alpha) mv alpha renamed; exit 0 ;;
  */rename-beta) printf 'beta changed\n' > beta; exit 0 ;;
  */r10-alpha) printf 'alpha merged\n' > alpha; exit 0 ;;
  */r10-beta) printf 'beta merged\n' > beta; exit 0 ;;
  */shared-clean-alpha) printf 'alpha\nbase\nbase\n' > shared; exit 0 ;;
  */shared-clean-beta) printf 'base\nbase\nbeta\n' > shared; exit 0 ;;
  */shared-conflict-alpha) printf 'base\nalpha\nbase\n' > shared; exit 0 ;;
  */shared-conflict-beta) printf 'base\nbeta\nbase\n' > shared; exit 0 ;;
  */stale-alpha) printf 'stale alpha\n' > alpha; exit 0 ;;
  */stale-beta) printf 'stale beta\n' > beta; exit 0 ;;
  */head-moved-alpha)
    printf 'moved alpha\n' > alpha
    printf 'head moved\n' > "$CHARLES_TARGET_ROOT/moved"
    git -C "$CHARLES_TARGET_ROOT" add -- moved && git -C "$CHARLES_TARGET_ROOT" commit -qm 'move head'
    exit $?
    ;;
  */head-moved-beta) printf 'moved beta\n' > beta; exit 0 ;;
  */bad-receipt-alpha) printf 'alpha changed\n' > alpha; printf '{malformed\n' > .charles/dispatches.jsonl; exit 0 ;;
  */bad-receipt-beta) printf 'beta changed\n' > beta; exit 0 ;;
  */missing-alpha)
    printf 'alpha changed\n' > alpha
    rm -f .charles/dispatches.jsonl
    mkdir -p .charles/dispatches.jsonl
    exit 0 ;;
  */missing-beta) printf 'beta changed\n' > beta; exit 0 ;;
  */space-alpha) printf 'space merged\n' > 'space file'; exit 0 ;;
  */space-beta) printf 'beta merged\n' > beta; exit 0 ;;
  */swap-alpha)
    mv alpha .swap-alpha
    mv beta alpha
    mv .swap-alpha beta
    exit 0 ;;
  */swap-gamma) printf 'gamma merged\n' > gamma; exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$PD/bin/codex"

# Git status cannot infer a two-way swap while both original paths remain
# present, so feed the merger the exact rename records for this fixture.
REAL_GIT="$(command -v git)"
cat > "$PD/bin/git" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "-C" ] && [ "\${2:-}" = "$PD/swap-alpha" ] && [ "\${3:-}" = "status" ]; then
  printf 'R  beta\\0alpha\\0R  alpha\\0beta\\0'
else
  exec "$REAL_GIT" "\$@"
fi
EOF
chmod +x "$PD/bin/git"

mkdir -p "$PD/r10-repo/docs/specs"
printf '# Plan\n\n## Grill verdict\n\n- Rounds: 1\n\n- [ ] **R1.2. alpha work**\n- [ ] **R2.3b. beta work**\n' \
  > "$PD/r10-repo/docs/specs/plan.md"
printf '[{"name":"alpha","files":["alpha"],"task":"x","req":["R1.2"]},{"name":"beta","files":["beta"],"task":"x","req":["R2.3b"]}]\n' \
  > "$PD/r10-repo/docs/specs/plan.chunks.json"
mkdir -p "$PD/r10-repo/.charles/runs/open-run" "$PD/r10-repo/.charles/runs/other-run"
printf '# Run open-run\n\n- flow: feature\n- spec: docs/specs/plan.md\n\n## Phases\n\n## Open items\n\n## Rollback\n\n' \
  > "$PD/r10-repo/.charles/runs/open-run/RUN.md"
printf '# Run other-run\n\n- flow: feature\n- spec: docs/specs/plan.md\n\n## Phases\n\n## Open items\n\n## Rollback\n\n' \
  > "$PD/r10-repo/.charles/runs/other-run/RUN.md"
: > "$PD/r10-returns"
r10_out="$(PATH="$PD/bin:$PATH" CHARLES_RETURN_RECORD="$PD/r10-returns" CHARLES_STATE_DIR="$PD/state" \
  bash "$PARALLEL" "$PD/r10-repo" "$PD/r10-repo/docs/specs/plan.chunks.json" --run open-run --no-green 2>&1)"; r10_rc=$?
if [ "$r10_rc" -eq 0 ] \
  && jq -e 'select(.event == "start" and .lane == "implement" and .req == ["R1.2"])' "$PD/r10-alpha/.charles/dispatches.jsonl" >/dev/null 2>&1 \
  && jq -e 'select(.event == "start" and .lane == "implement" and .req == ["R2.3b"])' "$PD/r10-beta/.charles/dispatches.jsonl" >/dev/null 2>&1; then
  echo "  PASS  parallel children receive their req on their own receipts"; pass=$((pass+1))
else
  echo "  FAIL  parallel children must receive req on their own receipts (rc=$r10_rc)"; fail=$((fail+1))
fi

printf '[{"name":"alpha","files":["gamma"],"task":"x","req":["R1.2"]},{"name":"beta","files":["delta"],"task":"x","req":["R999"]}]\n' \
  > "$PD/r10-repo/docs/specs/bad-req.chunks.json"
cp "$PD/r10-repo/docs/specs/plan.md" "$PD/r10-repo/docs/specs/bad-req.md"
: > "$PD/r10-treehouse-calls"
rm -f "$PD/r10-lane-ran"
r10_bad_out="$(PATH="$PD/bin:$PATH" CHARLES_TREEHOUSE_CALLS="$PD/r10-treehouse-calls" \
  CHARLES_LANE_MARKER="$PD/r10-lane-ran" CHARLES_STATE_DIR="$PD/state" \
  bash "$PARALLEL" "$PD/r10-repo" "$PD/r10-repo/docs/specs/bad-req.chunks.json" --run open-run --no-green 2>&1)"; r10_bad_rc=$?
if [ "$r10_bad_rc" -eq 1 ] \
  && grep -qF 'requirement R999 is not in' <<<"$r10_bad_out" \
  && [ ! -s "$PD/r10-treehouse-calls" ] && [ ! -e "$PD/r10-lane-ran" ]; then
  echo "  PASS  unknown manifest requirement is refused before leasing"; pass=$((pass+1))
else
  echo "  FAIL  unknown manifest requirement must be refused before leasing (rc=$r10_bad_rc)"; fail=$((fail+1))
fi

printf 'parallel_min_chunks = 3\n' >> "$PD/good-repo/.charles.toml"
threshold_out="$(PATH="$PD/bin:$PATH" bash "$PARALLEL" "$PD/good-repo" "$PD/spec.json" 2>&1)"; threshold_rc=$?
if [ "$threshold_rc" -eq 1 ] && grep -qF 'fewer than two chunks' <<<"$threshold_out" \
  && ! grep -qF 'leasing 2 chunks' <<<"$threshold_out"; then
  echo "  PASS  parallel_min_chunks refuses below the configured threshold"; pass=$((pass+1))
else
  echo "  FAIL  parallel_min_chunks must refuse below the configured threshold (rc=$threshold_rc)"; fail=$((fail+1))
fi

: > "$PD/good-returns"
good_out="$(PATH="$PD/bin:$PATH" CHARLES_PARALLEL_MIN_CHUNKS=2 CHARLES_RETURN_RECORD="$PD/good-returns" CHARLES_STATE_DIR="$PD/state" bash "$PARALLEL" "$PD/good-repo" "$PD/spec.json" 2>&1)"; good_rc=$?
good_runs="$(jq -r '.run // empty' "$PD/good-repo/.charles/dispatches.jsonl" 2>/dev/null | sort -u)"
good_run_output=1
while IFS= read -r run_id; do
  [ -n "$run_id" ] || continue
  grep -qF "run $run_id" <<<"$good_out" || good_run_output=0
done <<<"$good_runs"
if [ "$good_rc" -eq 0 ] && [ "$(cat "$PD/good-repo/alpha")" = "alpha merged" ] \
  && [ "$(cat "$PD/good-repo/beta")" = "beta merged" ] \
  && [ "$(printf '%s\n' "$good_runs" | sed '/^$/d' | wc -l)" -eq 2 ] \
  && [ "$good_run_output" -eq 1 ] \
  && grep -Fxq "$PD/good-alpha" "$PD/good-returns" \
  && grep -Fxq "$PD/good-beta" "$PD/good-returns"; then
  echo "  PASS  successful two-chunk merge aggregates and prints receipts"; pass=$((pass+1))
else
  echo "  FAIL  successful two-chunk merge must land files and receipts (rc=$good_rc)"; fail=$((fail+1))
fi

cp "$PD/oob-repo/beta" "$PD/oob-beta.before"
: > "$PD/oob-returns"
oob_out="$(PATH="$PD/bin:$PATH" CHARLES_RETURN_RECORD="$PD/oob-returns" CHARLES_STATE_DIR="$PD/state" bash "$PARALLEL" "$PD/oob-repo" "$PD/spec.json" 2>&1)"; oob_rc=$?
if [ "$oob_rc" -eq 3 ] && [ "$(cat "$PD/oob-repo/alpha")" = "base" ] \
  && cmp -s "$PD/oob-repo/beta" "$PD/oob-beta.before" \
  && [ ! -e "$PD/oob-repo/outside" ] && grep -qF 'wrote outside' <<<"$oob_out" \
  && grep -qF "$PD/oob-alpha" <<<"$oob_out" \
  && ! grep -Fxq "$PD/oob-alpha" "$PD/oob-returns" \
  && grep -Fxq "$PD/oob-beta" "$PD/oob-returns"; then
  echo "  PASS  non-ignored untracked undeclared file is rejected and kept"; pass=$((pass+1))
else
  echo "  FAIL  untracked undeclared file must not merge (rc=$oob_rc)"; fail=$((fail+1))
fi

cp "$PD/tracked-oob-repo/beta" "$PD/tracked-oob-beta.before"
: > "$PD/tracked-oob-returns"
tracked_oob_out="$(PATH="$PD/bin:$PATH" CHARLES_RETURN_RECORD="$PD/tracked-oob-returns" CHARLES_STATE_DIR="$PD/state" bash "$PARALLEL" "$PD/tracked-oob-repo" "$PD/spec.json" 2>&1)"; tracked_oob_rc=$?
if [ "$tracked_oob_rc" -eq 3 ] && [ "$(cat "$PD/tracked-oob-repo/alpha")" = "base" ] \
  && cmp -s "$PD/tracked-oob-repo/beta" "$PD/tracked-oob-beta.before" \
  && [ "$(cat "$PD/tracked-oob-repo/outside")" = "base" ] \
  && grep -qF 'wrote outside' <<<"$tracked_oob_out" \
  && grep -qF "$PD/tracked-oob-alpha" <<<"$tracked_oob_out" \
  && ! grep -Fxq "$PD/tracked-oob-alpha" "$PD/tracked-oob-returns" \
  && grep -Fxq "$PD/tracked-oob-beta" "$PD/tracked-oob-returns"; then
  echo "  PASS  non-ignored tracked undeclared file is rejected and kept"; pass=$((pass+1))
else
  echo "  FAIL  tracked undeclared file must not merge (rc=$tracked_oob_rc)"; fail=$((fail+1))
fi

: > "$PD/ignored-returns"
ignored_out="$(PATH="$PD/bin:$PATH" CHARLES_RETURN_RECORD="$PD/ignored-returns" CHARLES_STATE_DIR="$PD/state" bash "$PARALLEL" "$PD/ignored-repo" "$PD/spec.json" 2>&1)"; ignored_rc=$?
if [ "$ignored_rc" -eq 0 ] && [ "$(cat "$PD/ignored-repo/alpha")" = "alpha changed" ] \
  && [ "$(cat "$PD/ignored-repo/beta")" = "beta changed" ] \
  && [ ! -e "$PD/ignored-repo/ignored-dir" ] \
  && grep -qF 'ignored 2 path(s):' <<<"$ignored_out" \
  && grep -qF 'ignored-[31mlinebreak' <<<"$ignored_out" \
  && ! grep -q $'\033' <<<"$ignored_out"; then
  echo "  PASS  ignored write is reported without rejection and sanitized"; pass=$((pass+1))
else
  echo "  FAIL  ignored write must be reported without rejection and sanitized (rc=$ignored_rc)"; fail=$((fail+1))
fi

: > "$PD/ignored-link-returns"
ignored_link_out="$(PATH="$PD/bin:$PATH" IGNORED_LINK_TARGET="$PD/ignored-link-target" CHARLES_RETURN_RECORD="$PD/ignored-link-returns" CHARLES_STATE_DIR="$PD/state" bash "$PARALLEL" "$PD/ignored-link-repo" "$PD/spec.json" 2>&1)"; ignored_link_rc=$?
if [ "$ignored_link_rc" -eq 3 ] && [ "$(cat "$PD/ignored-link-repo/alpha")" = "base" ] \
  && [ "$(cat "$PD/ignored-link-repo/beta")" = "base" ] \
  && [ ! -e "$PD/ignored-link-repo/ignored-link" ] \
  && grep -qF 'wrote outside its declared files' <<<"$ignored_link_out" \
  && grep -qF 'ignored-link' <<<"$ignored_link_out"; then
  echo "  PASS  ignored symlink escaping the worktree is rejected"; pass=$((pass+1))
else
  echo "  FAIL  ignored symlink escape must reject the chunk (rc=$ignored_link_rc)"; fail=$((fail+1))
fi

: > "$PD/missing-returns"
cp "$PD/missing-repo/alpha" "$PD/missing-alpha.before"
cp "$PD/missing-repo/beta" "$PD/missing-beta.before"
missing_out="$(PATH="$PD/bin:$PATH" CHARLES_RETURN_RECORD="$PD/missing-returns" CHARLES_STATE_DIR="$PD/state" bash "$PARALLEL" "$PD/missing-repo" "$PD/spec.json" 2>&1)"; missing_rc=$?
if [ "$missing_rc" -eq 3 ] && grep -qF 'missing receipt' <<<"$missing_out" \
  && grep -qF "$PD/missing-alpha" <<<"$missing_out" \
  && cmp -s "$PD/missing-repo/alpha" "$PD/missing-alpha.before" \
  && cmp -s "$PD/missing-repo/beta" "$PD/missing-beta.before" \
  && ! grep -Fxq "$PD/missing-alpha" "$PD/missing-returns" \
  && grep -Fxq "$PD/missing-beta" "$PD/missing-returns"; then
  echo "  PASS  missing receipt fails before changing the root"; pass=$((pass+1))
else
  echo "  FAIL  missing receipt must fail before changing the root (rc=$missing_rc)"; fail=$((fail+1))
fi

: > "$PD/bad-receipt-returns"
bad_receipt_out="$(PATH="$PD/bin:$PATH" CHARLES_RETURN_RECORD="$PD/bad-receipt-returns" CHARLES_STATE_DIR="$PD/state" bash "$PARALLEL" "$PD/bad-receipt-repo" "$PD/bad-receipt-spec.json" 2>&1)"; bad_receipt_rc=$?
if [ "$bad_receipt_rc" -eq 3 ] && grep -qF 'invalid receipt' <<<"$bad_receipt_out" \
  && [ "$(cat "$PD/bad-receipt-repo/alpha")" = "base" ] \
  && ! grep -Fxq "$PD/bad-receipt-alpha" "$PD/bad-receipt-returns"; then
  echo "  PASS  malformed receipt fails before merge"; pass=$((pass+1))
else
  echo "  FAIL  malformed receipt must fail before merge (rc=$bad_receipt_rc)"; fail=$((fail+1))
fi

: > "$PD/swap-returns"
swap_out="$(PATH="$PD/bin:$PATH" CHARLES_RETURN_RECORD="$PD/swap-returns" CHARLES_STATE_DIR="$PD/state" bash "$PARALLEL" "$PD/swap-repo" "$PD/swap-spec.json" 2>&1)"; swap_rc=$?
if [ "$swap_rc" -eq 0 ] && [ "$(cat "$PD/swap-repo/alpha")" = "beta base" ] \
  && [ "$(cat "$PD/swap-repo/beta")" = "alpha base" ] \
  && [ "$(cat "$PD/swap-repo/gamma")" = "gamma merged" ] \
  && grep -qF 'merged rename' <<<"$swap_out"; then
  echo "  PASS  rename swap preserves both destinations"; pass=$((pass+1))
else
  echo "  FAIL  rename swap must preserve both destinations (rc=$swap_rc)"; fail=$((fail+1))
fi

: > "$PD/failed-returns"
failed_out="$(PATH="$PD/bin:$PATH" CHARLES_RETURN_RECORD="$PD/failed-returns" CHARLES_STATE_DIR="$PD/state" bash "$PARALLEL" "$PD/failed-repo" "$PD/spec.json" 2>&1)"; failed_rc=$?
if [ "$failed_rc" -eq 3 ] && [ "$(cat "$PD/failed-repo/alpha")" = "base" ] \
  && [ "$(cat "$PD/failed-repo/beta")" = "base" ] \
  && grep -qF 'child exited' <<<"$failed_out" && grep -qF "$PD/failed-alpha" <<<"$failed_out" \
  && ! grep -Fxq "$PD/failed-alpha" "$PD/failed-returns"; then
  echo "  PASS  failed sibling blocks every merge"; pass=$((pass+1))
else
  echo "  FAIL  failed sibling must block every merge (rc=$failed_rc)"; fail=$((fail+1))
fi

: > "$PD/rename-returns"
rename_out="$(PATH="$PD/bin:$PATH" CHARLES_RETURN_RECORD="$PD/rename-returns" CHARLES_STATE_DIR="$PD/state" bash "$PARALLEL" "$PD/rename-repo" "$PD/rename-spec.json" 2>&1)"; rename_rc=$?
if [ "$rename_rc" -eq 3 ] && [ "$(cat "$PD/rename-repo/alpha")" = "base" ] \
  && [ ! -e "$PD/rename-repo/renamed" ] && grep -qF 'wrote outside' <<<"$rename_out"; then
  echo "  PASS  one-sided rename is rejected"; pass=$((pass+1))
else
  echo "  FAIL  one-sided rename must be rejected (rc=$rename_rc)"; fail=$((fail+1))
fi

: > "$PD/delete-returns"
delete_out="$(PATH="$PD/bin:$PATH" CHARLES_RETURN_RECORD="$PD/delete-returns" CHARLES_STATE_DIR="$PD/state" bash "$PARALLEL" "$PD/delete-repo" "$PD/delete-spec.json" 2>&1)"; delete_rc=$?
if [ "$delete_rc" -eq 0 ] && [ ! -e "$PD/delete-repo/alpha" ] \
  && [ "$(cat "$PD/delete-repo/beta")" = "beta changed" ] \
  && grep -qF 'merged deletion alpha' <<<"$delete_out"; then
  echo "  PASS  declared deletion is removed from the root"; pass=$((pass+1))
else
  echo "  FAIL  declared deletion must be merged (rc=$delete_rc)"; fail=$((fail+1))
fi

: > "$PD/space-returns"
space_out="$(PATH="$PD/bin:$PATH" CHARLES_RETURN_RECORD="$PD/space-returns" CHARLES_STATE_DIR="$PD/state" bash "$PARALLEL" "$PD/space-repo" "$PD/space-spec.json" --no-green 2>&1)"; space_rc=$?
if [ "$space_rc" -eq 0 ] && [ "$(cat "$PD/space-repo/space file")" = "space merged" ] \
  && [ "$(cat "$PD/space-repo/beta")" = "beta merged" ] \
  && grep -qF 'combined green check skipped (--no-green)' <<<"$space_out" \
  && ! grep -qF 'running combined green check' <<<"$space_out"; then
  echo "  PASS  spaced declaration merges and --no-green skips green"; pass=$((pass+1))
else
  echo "  FAIL  spaced declaration and --no-green must work (rc=$space_rc)"; fail=$((fail+1))
fi

: > "$PD/red-returns"
red_out="$(PATH="$PD/bin:$PATH" CHARLES_RETURN_RECORD="$PD/red-returns" CHARLES_STATE_DIR="$PD/state" bash "$PARALLEL" "$PD/red-repo" "$PD/spec.json" 2>&1)"; red_rc=$?
if [ "$red_rc" -ne 0 ] && [ "$(cat "$PD/red-repo/alpha")" = "alpha merged" ] \
  && [ "$(cat "$PD/red-repo/beta")" = "beta merged" ] \
  && grep -qF 'running combined green check' <<<"$red_out"; then
  echo "  PASS  combined-green failure fails the batch after merge"; pass=$((pass+1))
else
  echo "  FAIL  combined-green failure must fail the batch (rc=$red_rc)"; fail=$((fail+1))
fi

: > "$PD/shared-no-green-returns"
shared_no_green_out="$(PATH="$PD/bin:$PATH" CHARLES_RETURN_RECORD="$PD/shared-no-green-returns" CHARLES_STATE_DIR="$PD/state" \
  bash "$PARALLEL" "$PD/shared-clean-repo" "$PD/shared-spec.json" --no-green 2>&1)"; shared_no_green_rc=$?
if [ "$shared_no_green_rc" -eq 1 ] \
  && grep -qF 'shared files require the combined green check' <<<"$shared_no_green_out" \
  && [ ! -s "$PD/shared-no-green-returns" ]; then
  echo "  PASS  shared manifest refuses --no-green before leasing"; pass=$((pass+1))
else
  echo "  FAIL  shared manifest must refuse --no-green before leasing (rc=$shared_no_green_rc)"; fail=$((fail+1))
fi

: > "$PD/shared-clean-returns"
shared_clean_out="$(PATH="$PD/bin:$PATH" CHARLES_RETURN_RECORD="$PD/shared-clean-returns" CHARLES_STATE_DIR="$PD/state" \
  bash "$PARALLEL" "$PD/shared-clean-repo" "$PD/shared-spec.json" 2>&1)"; shared_clean_rc=$?
if [ "$shared_clean_rc" -eq 0 ] \
  && [ "$(cat "$PD/shared-clean-repo/shared")" = $'alpha\nbase\nbeta' ] \
  && grep -qF 'merged shared shared' <<<"$shared_clean_out" \
  && grep -qF 'running combined green check' <<<"$shared_clean_out"; then
  echo "  PASS  clean shared three-way merge is accepted"; pass=$((pass+1))
else
  echo "  FAIL  clean shared three-way merge must be accepted (rc=$shared_clean_rc)"; fail=$((fail+1))
fi

shared_conflict_before="$PD/shared-conflict-before"
cp "$PD/shared-conflict-repo/shared" "$shared_conflict_before"
: > "$PD/shared-conflict-returns"
shared_conflict_out="$(PATH="$PD/bin:$PATH" CHARLES_RETURN_RECORD="$PD/shared-conflict-returns" CHARLES_STATE_DIR="$PD/state" \
  bash "$PARALLEL" "$PD/shared-conflict-repo" "$PD/shared-spec.json" 2>&1)"; shared_conflict_rc=$?
if [ "$shared_conflict_rc" -eq 3 ] \
  && grep -qF "shared path 'shared' has a conflicting merge" <<<"$shared_conflict_out" \
  && cmp -s "$PD/shared-conflict-repo/shared" "$shared_conflict_before" \
  && ! grep -qF 'merged shared shared' <<<"$shared_conflict_out"; then
  echo "  PASS  conflicting shared merge rejects before changing the root"; pass=$((pass+1))
else
  echo "  FAIL  conflicting shared merge must reject before root mutation (rc=$shared_conflict_rc)"; fail=$((fail+1))
fi

: > "$PD/stale-returns"
rm -f "$PD/stale-lane-ran"
stale_batch_head="$(git -C "$PD/stale-repo" rev-parse HEAD)"
stale_lease_head="$(git -C "$PD/stale-alpha" rev-parse HEAD)"
stale_out="$(PATH="$PD/bin:$PATH" CHARLES_RETURN_RECORD="$PD/stale-returns" CHARLES_LANE_MARKER="$PD/stale-lane-ran" CHARLES_STATE_DIR="$PD/state" \
  bash "$PARALLEL" "$PD/stale-repo" "$PD/spec.json" 2>&1)"; stale_rc=$?
if [ "$stale_rc" -eq 3 ] && grep -qF 'lease HEAD' <<<"$stale_out" \
  && grep -qF "$stale_batch_head" <<<"$stale_out" && grep -qF "$stale_lease_head" <<<"$stale_out" \
  && ! grep -qF 'dispatching 2 chunks' <<<"$stale_out" && [ ! -e "$PD/stale-lane-ran" ] \
  && grep -Fxq "$PD/stale-alpha" "$PD/stale-returns"; then
  echo "  PASS  stale lease refuses before dispatch"; pass=$((pass+1))
else
  echo "  FAIL  stale lease must refuse before dispatch (rc=$stale_rc)"; fail=$((fail+1))
fi

head_moved_before="$(git -C "$PD/head-moved-repo" rev-parse HEAD)"
head_moved_alpha_before="$(cat "$PD/head-moved-repo/alpha")"
head_moved_beta_before="$(cat "$PD/head-moved-repo/beta")"
head_moved_out="$(PATH="$PD/bin:$PATH" CHARLES_TARGET_ROOT="$PD/head-moved-repo" CHARLES_RETURN_RECORD="$PD/head-moved-returns" CHARLES_STATE_DIR="$PD/state" \
  bash "$PARALLEL" "$PD/head-moved-repo" "$PD/spec.json" 2>&1)"; head_moved_rc=$?
head_moved_after="$(git -C "$PD/head-moved-repo" rev-parse HEAD)"
if [ "$head_moved_rc" -eq 3 ] && [ "$head_moved_after" != "$head_moved_before" ] \
  && grep -qF 'target HEAD changed during batch' <<<"$head_moved_out" \
  && grep -qF "$head_moved_before" <<<"$head_moved_out" && grep -qF "$head_moved_after" <<<"$head_moved_out" \
  && [ "$(cat "$PD/head-moved-repo/alpha")" = "$head_moved_alpha_before" ] \
  && [ "$(cat "$PD/head-moved-repo/beta")" = "$head_moved_beta_before" ] \
  && [ -e "$PD/head-moved-repo/moved" ]; then
  echo "  PASS  target HEAD move refuses before merge"; pass=$((pass+1))
else
  echo "  FAIL  target HEAD move must refuse before merge (rc=$head_moved_rc)"; fail=$((fail+1))
fi

# --- run state lifecycle ------------------------------------------------------
RS="$(cd "$(dirname "$0")/.." && pwd)/scripts/run-state.sh"
RUN_SH="$(cd "$(dirname "$0")/.." && pwd)/scripts/codex-run.sh"
WARN="$(cd "$(dirname "$0")/.." && pwd)/hooks/warn-open-runs.sh"

# --- main-tree guard ----------------------------------------------------------
GUARD_ROOT="$BOX/main-tree-guard"
mkdir -p "$GUARD_ROOT/bin" "$GUARD_ROOT/primary" "$GUARD_ROOT/not-git"
(
  cd "$GUARD_ROOT/primary" && git init -q && git config user.name tester \
    && git config user.email tester@example.invalid \
    && printf 'base\n' > tracked && git add tracked && git commit -qm init
)
git -C "$GUARD_ROOT/primary" worktree add -q "$GUARD_ROOT/linked" HEAD
mkdir -p "$GUARD_ROOT/primary/inside"
ln -s "$GUARD_ROOT/primary/inside" "$GUARD_ROOT/primary-link"
printf '#!/usr/bin/env bash\nexit 0\n' > "$GUARD_ROOT/bin/codex"
chmod +x "$GUARD_ROOT/bin/codex"
printf '# Guard plan\n' > "$GUARD_ROOT/plan.md"

GUARD_ENV="$GUARD_ROOT/env"
mkdir -p "$GUARD_ENV"
(
  cd "$GUARD_ENV" && git init -q && git config user.name tester \
    && git config user.email tester@example.invalid \
    && printf 'base\n' > tracked && git add tracked && git commit -qm init
)

guard_run() {
  local state="$1"
  shift
  PATH="$GUARD_ROOT/bin:$PATH" CHARLES_STATE_DIR="$GUARD_ROOT/state-$state" \
    bash "$RUN_SH" "$@"
}

guard_primary_out="$(guard_run primary --lane implement --dir "$GUARD_ROOT/primary" --no-fallback "guard primary" 2>&1)"; guard_primary_rc=$?
if [ "$guard_primary_rc" -eq 4 ] \
  && grep -qF "primary working tree: $GUARD_ROOT/primary" <<<"$guard_primary_out" \
  && grep -qF 'treehouse get' <<<"$guard_primary_out" \
  && grep -qF -- '--dir <that worktree>' <<<"$guard_primary_out" \
  && [ ! -e "$GUARD_ROOT/primary/.charles/dispatches.jsonl" ]; then
  echo "  PASS  implement primary checkout is refused before start"; pass=$((pass+1))
else
  echo "  FAIL  implement primary checkout must be refused before start (rc=$guard_primary_rc)"; fail=$((fail+1))
fi

guard_symlink_out="$(guard_run primary-link --lane implement --dir "$GUARD_ROOT/primary-link" --no-fallback "guard symlink" 2>&1)"; guard_symlink_rc=$?
if [ "$guard_symlink_rc" -eq 4 ] \
  && grep -qF "primary working tree: $GUARD_ROOT/primary-link" <<<"$guard_symlink_out" \
  && [ ! -e "$GUARD_ROOT/primary-link/.charles/dispatches.jsonl" ]; then
  echo "  PASS  symlinked --dir into a primary checkout is refused"; pass=$((pass+1))
else
  echo "  FAIL  symlinked --dir into a primary checkout must be refused (rc=$guard_symlink_rc)"; fail=$((fail+1))
fi

# An inherited GIT_DIR/GIT_WORK_TREE makes rev-parse describe a DIFFERENT repo,
# so an unsanitized guard reads the primary tree as a linked worktree and allows it.
guard_env_out="$(GIT_DIR="$GUARD_ROOT/linked/.git" GIT_WORK_TREE="$GUARD_ROOT/linked" \
  guard_run primary-gitenv --lane implement --dir "$GUARD_ROOT/primary" --no-fallback "guard gitenv" 2>&1)"; guard_env_rc=$?
if [ "$guard_env_rc" -eq 4 ] \
  && grep -qF "primary working tree: $GUARD_ROOT/primary" <<<"$guard_env_out" \
  && [ ! -e "$GUARD_ROOT/primary/.charles/dispatches.jsonl" ]; then
  echo "  PASS  inherited GIT_DIR cannot disguise a primary checkout"; pass=$((pass+1))
else
  echo "  FAIL  inherited GIT_DIR must not bypass the guard (rc=$guard_env_rc)"; fail=$((fail+1))
fi

GUARD_FAIL="$BOX/main-tree-guard-revparse"
mkdir -p "$GUARD_FAIL/bin" "$GUARD_FAIL/repo"
(
  cd "$GUARD_FAIL/repo" && git init -q && git config user.name tester \
    && git config user.email tester@example.invalid \
    && printf 'base\n' > tracked && git add tracked && git commit -qm init
)
printf '#!/usr/bin/env bash\nexit 1\n' > "$GUARD_FAIL/bin/git"
printf '#!/usr/bin/env bash\nexit 0\n' > "$GUARD_FAIL/bin/codex"
chmod +x "$GUARD_FAIL/bin/git" "$GUARD_FAIL/bin/codex"
guard_revparse_out="$(PATH="$GUARD_FAIL/bin:$PATH" CHARLES_STATE_DIR="$GUARD_FAIL/state" \
  bash "$RUN_SH" --lane implement --dir "$GUARD_FAIL/repo" --no-fallback \
  "guard rev-parse failure" 2>&1)"; guard_revparse_rc=$?
if [ "$guard_revparse_rc" -eq 4 ] \
  && grep -qF 'repository state could not be determined' <<<"$guard_revparse_out" \
  && [ ! -e "$GUARD_FAIL/repo/.charles/dispatches.jsonl" ]; then
  echo "  PASS  rev-parse failure refuses with exit 4"; pass=$((pass+1))
else
  echo "  FAIL  rev-parse failure must refuse before start (rc=$guard_revparse_rc)"; fail=$((fail+1))
fi

guard_link_out="$(guard_run linked --lane implement --dir "$GUARD_ROOT/linked" --no-fallback "guard linked" 2>&1)"; guard_link_rc=$?
if [ "$guard_link_rc" -eq 0 ] \
  && jq -e 'select(.event == "start" and .lane == "implement" and .allow_main_tree == false)' \
    "$GUARD_ROOT/linked/.charles/dispatches.jsonl" >/dev/null 2>&1; then
  echo "  PASS  linked worktree implement dispatch is allowed"; pass=$((pass+1))
else
  echo "  FAIL  linked worktree implement dispatch must be allowed (rc=$guard_link_rc)"; fail=$((fail+1))
fi

guard_flag_out="$(guard_run flag --lane implement --allow-main-tree --dir "$GUARD_ROOT/primary" --no-fallback "guard flag" 2>&1)"; guard_flag_rc=$?
if [ "$guard_flag_rc" -eq 0 ] \
  && jq -e -s 'any(.[]; .event == "start" and .lane == "implement" and .allow_main_tree == true)
              and any(.[]; .event == "end" and .lane == "implement" and .allow_main_tree == true)' \
    "$GUARD_ROOT/primary/.charles/dispatches.jsonl" >/dev/null 2>&1; then
  echo "  PASS  --allow-main-tree records the waiver"; pass=$((pass+1))
else
  echo "  FAIL  --allow-main-tree must record the waiver (rc=$guard_flag_rc)"; fail=$((fail+1))
fi

guard_env_out="$(CHARLES_ALLOW_MAIN_TREE=1 guard_run env --lane implement --dir "$GUARD_ENV" --no-fallback "guard env" 2>&1)"; guard_env_rc=$?
if [ "$guard_env_rc" -eq 0 ] \
  && jq -e -s 'any(.[]; .event == "start" and .lane == "implement" and .allow_main_tree == true)
              and any(.[]; .event == "end" and .lane == "implement" and .allow_main_tree == true)' \
    "$GUARD_ENV/.charles/dispatches.jsonl" >/dev/null 2>&1; then
  echo "  PASS  CHARLES_ALLOW_MAIN_TREE records the waiver"; pass=$((pass+1))
else
  echo "  FAIL  CHARLES_ALLOW_MAIN_TREE must record the waiver (rc=$guard_env_rc)"; fail=$((fail+1))
fi

guard_explore_out="$(guard_run explore --lane explore --dir "$GUARD_ROOT/primary" --no-fallback "guard explore" 2>&1)"; guard_explore_rc=$?
if [ "$guard_explore_rc" -eq 0 ] \
  && jq -e 'select(.event == "start" and .lane == "explore")' \
    "$GUARD_ROOT/primary/.charles/dispatches.jsonl" >/dev/null 2>&1; then
  echo "  PASS  explore primary checkout is unaffected"; pass=$((pass+1))
else
  echo "  FAIL  explore primary checkout must be unaffected (rc=$guard_explore_rc)"; fail=$((fail+1))
fi

printf 'changed\n' > "$GUARD_ROOT/primary/changed"
guard_review_out="$(guard_run review --lane review --dir "$GUARD_ROOT/primary" --plan "$GUARD_ROOT/plan.md" --no-fallback "guard review" 2>&1)"; guard_review_rc=$?
if [ "$guard_review_rc" -eq 0 ] \
  && jq -e 'select(.event == "start" and .lane == "review")' \
    "$GUARD_ROOT/primary/.charles/dispatches.jsonl" >/dev/null 2>&1; then
  echo "  PASS  review primary checkout is unaffected"; pass=$((pass+1))
else
  echo "  FAIL  review primary checkout must be unaffected (rc=$guard_review_rc)"; fail=$((fail+1))
fi

printf 'base\n' > "$GUARD_ROOT/not-git/file"
guard_nongit_out="$(guard_run non-git --lane implement --dir "$GUARD_ROOT/not-git" --no-fallback "guard non-git" 2>&1)"; guard_nongit_rc=$?
if [ "$guard_nongit_rc" -eq 0 ] \
  && jq -e 'select(.event == "start" and .lane == "implement" and .allow_main_tree == false)' \
    "$GUARD_ROOT/not-git/.charles/dispatches.jsonl" >/dev/null 2>&1; then
  echo "  PASS  non-git implement dispatch is unaffected"; pass=$((pass+1))
else
  echo "  FAIL  non-git implement dispatch must be unaffected (rc=$guard_nongit_rc)"; fail=$((fail+1))
fi

GUARD_BARE="$BOX/main-tree-guard-bare"
git init --bare -q "$GUARD_BARE"
sed -i 's/^bare = true$/bare = 1/' "$GUARD_BARE/config"
guard_bare_out="$(guard_run bare --lane implement --dir "$GUARD_BARE" --no-fallback "guard bare" 2>&1)"; guard_bare_rc=$?
if [ "$guard_bare_rc" -eq 4 ] && grep -qF 'bare repository' <<<"$guard_bare_out"; then
  echo "  PASS  bare repository implement dispatch remains refused"; pass=$((pass+1))
else
  echo "  FAIL  bare repository implement dispatch must remain refused (rc=$guard_bare_rc)"; fail=$((fail+1))
fi

RT="$BOX/runrepo"; mkdir -p "$RT/docs/specs"
( cd "$RT" && git init -q && git config user.name tester && git config user.email tester@example.invalid )
printf 'green = "true"\n' > "$RT/.charles.toml"
printf '# Plan\n\n## Grill verdict\n\n- Rounds: 2\n\n## Sign-off\n\n- [x] existing lifecycle fixture — selftest output\n' > "$RT/docs/specs/p.md"

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

# --- R11 run selection and spec agreement ------------------------------------
R11="$BOX/r11-runstate"; mkdir -p "$R11/docs/specs"
for plan in alpha beta third legacy first second; do
  printf '# Plan\n\n## Grill verdict\n\n- Rounds: 1\n\n## Sign-off\n\n- [x] %s\n' "$plan" \
    > "$R11/docs/specs/$plan.md"
done
r11_a="$(bash "$RS" init "$R11" feature "run alpha" --spec docs/specs/alpha.md 2>/dev/null)"
r11_b="$(bash "$RS" init "$R11" feature "run beta" --spec docs/specs/beta.md 2>/dev/null)"

r11_phase_out="$(bash "$RS" phase "$R11" "ambiguous phase" 2>&1)"; r11_phase_rc=$?
if [ "$r11_phase_rc" -eq 2 ] && grep -qF "$r11_a" <<<"$r11_phase_out" \
  && grep -qF "$r11_b" <<<"$r11_phase_out" && grep -qF -- '--run <id>' <<<"$r11_phase_out"; then
  echo "  PASS  phase refuses two open runs without a selector"; pass=$((pass+1))
else
  echo "  FAIL  phase must refuse two open runs without a selector (rc=$r11_phase_rc)"; fail=$((fail+1))
fi
r11_item_out="$(bash "$RS" item "$R11" PENDING-DECISION "ambiguous item" 2>&1)"; r11_item_rc=$?
if [ "$r11_item_rc" -eq 2 ] && grep -qF "$r11_a" <<<"$r11_item_out" \
  && grep -qF "$r11_b" <<<"$r11_item_out"; then
  echo "  PASS  item refuses two open runs without a selector"; pass=$((pass+1))
else
  echo "  FAIL  item must refuse two open runs without a selector (rc=$r11_item_rc)"; fail=$((fail+1))
fi

r11_prefix="$r11_a"
for ((r11_n=1; r11_n<${#r11_a}; r11_n++)); do
  r11_candidate="${r11_a:0:r11_n}"
  if [[ "$r11_b" != "$r11_candidate"* ]]; then r11_prefix="$r11_candidate"; break; fi
done
cp "$R11/.charles/runs/$r11_b/RUN.md" "$R11/r11-beta.before"
r11_phase_out="$(bash "$RS" phase "$R11" "selected phase" --run "$r11_prefix" 2>&1)"; r11_phase_rc=$?
if [ "$r11_phase_rc" -eq 0 ] && grep -qF 'selected phase' "$R11/.charles/runs/$r11_a/RUN.md" \
  && cmp -s "$R11/.charles/runs/$r11_b/RUN.md" "$R11/r11-beta.before"; then
  echo "  PASS  phase prefix writes only to the selected run"; pass=$((pass+1))
else
  echo "  FAIL  phase prefix must write only to the selected run (rc=$r11_phase_rc)"; fail=$((fail+1))
fi

r11_close_out="$(bash "$RS" close "$R11" "selected outcome" --run "$r11_a" --spec docs/specs/alpha.md --force 2>&1)"; r11_close_rc=$?
if [ "$r11_close_rc" -eq 0 ] && grep -q '^## Outcome$' "$R11/.charles/runs/$r11_a/RUN.md" \
  && ! grep -q '^## Outcome$' "$R11/.charles/runs/$r11_b/RUN.md"; then
  echo "  PASS  close --run closes the selected run, not the newest"; pass=$((pass+1))
else
  echo "  FAIL  close --run must close only the selected run (rc=$r11_close_rc)"; fail=$((fail+1))
fi
r11_show_out="$(bash "$RS" show "$R11" 2>&1)"; r11_show_rc=$?
if [ "$r11_show_rc" -eq 0 ] && grep -qF "showing run: $r11_b" <<<"$r11_show_out"; then
  echo "  PASS  show names the run it defaults to"; pass=$((pass+1))
else
  echo "  FAIL  show must name its defaulted run (rc=$r11_show_rc)"; fail=$((fail+1))
fi

R11D="$BOX/r11-defer"; mkdir -p "$R11D"
r11d_a="$(bash "$RS" init "$R11D" feature "defer alpha" 2>/dev/null)"
r11d_b="$(bash "$RS" init "$R11D" feature "defer beta" 2>/dev/null)"
cp "$R11D/.charles/runs/$r11d_b/RUN.md" "$R11D/defer-beta.before"
r11_defer_out="$(bash "$RS" defer "$R11D" "selected deferred item" --run "$r11d_a" 2>&1)"; r11_defer_rc=$?
if [ "$r11_defer_rc" -eq 0 ] && grep -qF 'selected deferred item' "$R11D/.charles/runs/$r11d_a/RUN.md" \
  && cmp -s "$R11D/.charles/runs/$r11d_b/RUN.md" "$R11D/defer-beta.before"; then
  echo "  PASS  defer --run targets the selected open run"; pass=$((pass+1))
else
  echo "  FAIL  defer --run must target only the selected open run (rc=$r11_defer_rc)"; fail=$((fail+1))
fi

# init --spec must reject the same unusable paths as the later spec verb.
INITSPEC="$BOX/init-spec"; mkdir -p "$INITSPEC/docs/specs"
printf '# Valid plan\n' > "$INITSPEC/docs/specs/valid.md"
printf '# Outside plan\n' > "$BOX/init-outside.md"
init_missing_out="$(bash "$RS" init "$INITSPEC" feature "missing init spec" --spec docs/specs/missing.md 2>&1)"; init_missing_rc=$?
if [ "$init_missing_rc" -eq 2 ] && grep -qF 'does not exist or is unreadable' <<<"$init_missing_out" \
  && [ ! -d "$INITSPEC/.charles/runs" ]; then
  echo "  PASS  init --spec refuses a missing path before creating a run"; pass=$((pass+1))
else
  echo "  FAIL  init --spec must refuse a missing path before creating a run (rc=$init_missing_rc)"; fail=$((fail+1))
fi
init_outside_out="$(bash "$RS" init "$INITSPEC" feature "outside init spec" --spec ../init-outside.md 2>&1)"; init_outside_rc=$?
if [ "$init_outside_rc" -eq 2 ] && grep -qF 'resolves outside the repository' <<<"$init_outside_out" \
  && [ ! -d "$INITSPEC/.charles/runs" ]; then
  echo "  PASS  init --spec refuses an outside path before creating a run"; pass=$((pass+1))
else
  echo "  FAIL  init --spec must refuse an outside path before creating a run (rc=$init_outside_rc)"; fail=$((fail+1))
fi
init_valid_run="$(bash "$RS" init "$INITSPEC" feature "valid init spec" --spec docs/specs/valid.md 2>/dev/null)"; init_valid_rc=$?
if [ "$init_valid_rc" -eq 0 ] && grep -qF -- '- spec: docs/specs/valid.md' "$INITSPEC/.charles/runs/$init_valid_run/RUN.md"; then
  echo "  PASS  init --spec records a validated in-repo path"; pass=$((pass+1))
else
  echo "  FAIL  init --spec must record a valid in-repo path (rc=$init_valid_rc)"; fail=$((fail+1))
fi

# A run created before init learned --spec can be repaired in place, then gated
# against the attached plan like any other run.
SPECBIND="$BOX/spec-bind"; mkdir -p "$SPECBIND/bin" "$SPECBIND/docs/specs" \
  "$SPECBIND/.charles/runs/legacy-run"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SPECBIND/bin/codex"; chmod +x "$SPECBIND/bin/codex"
printf '# Old plan\n\n## Grill verdict\n\n- Rounds: 1\n\n- [ ] **R1. old requirement**\n' > "$SPECBIND/docs/specs/old.md"
printf '# New plan\n\n## Grill verdict\n\n- Rounds: 1\n\n- [ ] **R1. replacement requirement**\n' > "$SPECBIND/docs/specs/new.md"
printf '# Run legacy-run\n\n- flow: feature\n- started: now\n\n## Phases\n\n## Open items\n\n## Rollback\n\n' \
  > "$SPECBIND/.charles/runs/legacy-run/RUN.md"
printf '# Outside plan\n\n- [ ] **R1. outside requirement**\n' > "$BOX/outside-plan.md"
bind_before="$(cat "$SPECBIND/.charles/runs/legacy-run/RUN.md")"
outside_bind_out="$(bash "$RS" spec "$SPECBIND" "$BOX/outside-plan.md" --run legacy-run 2>&1)"; outside_bind_rc=$?
if [ "$outside_bind_rc" -eq 2 ] && grep -qF 'resolves outside the repository' <<<"$outside_bind_out" \
  && [ "$(cat "$SPECBIND/.charles/runs/legacy-run/RUN.md")" = "$bind_before" ]; then
  echo "  PASS  run-state spec refuses a path outside the repository"; pass=$((pass+1))
else
  echo "  FAIL  run-state spec must apply the repository containment rule (rc=$outside_bind_rc)"; fail=$((fail+1))
fi
bind_out="$(bash "$RS" spec "$SPECBIND" docs/specs/old.md --run legacy-run 2>&1)"; bind_rc=$?
if [ "$bind_rc" -eq 0 ] && grep -qF 'bound spec: docs/specs/old.md to run: legacy-run' <<<"$bind_out" \
  && grep -q '^\- spec: docs/specs/old.md$' "$SPECBIND/.charles/runs/legacy-run/RUN.md"; then
  echo "  PASS  run-state spec binds a plan to the selected legacy run"; pass=$((pass+1))
else
  echo "  FAIL  run-state spec must bind the selected legacy run (rc=$bind_rc)"; fail=$((fail+1))
fi
mkdir -p "$SPECBIND/fail-bin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$SPECBIND/fail-bin/mv"; chmod +x "$SPECBIND/fail-bin/mv"
bind_before="$(cat "$SPECBIND/.charles/runs/legacy-run/RUN.md")"
failed_bind_out="$(PATH="$SPECBIND/fail-bin:$PATH" bash "$RS" spec "$SPECBIND" docs/specs/new.md --run legacy-run 2>&1)"; failed_bind_rc=$?
if [ "$failed_bind_rc" -ne 0 ] && ! grep -qF 'bound spec:' <<<"$failed_bind_out" \
  && [ "$(cat "$SPECBIND/.charles/runs/legacy-run/RUN.md")" = "$bind_before" ]; then
  echo "  PASS  failed spec bind exits non-zero without success output"; pass=$((pass+1))
else
  echo "  FAIL  failed spec bind must fail without printing success (rc=$failed_bind_rc)"; fail=$((fail+1))
fi
bind_dispatch_out="$(PATH="$SPECBIND/bin:$PATH" CHARLES_STATE_DIR="$SPECBIND/state" \
  bash "$RUN_SH" --lane implement --dir "$SPECBIND" --run legacy-run --req R1 \
  --no-fallback --timeout 2 "bound spec" 2>&1)"; bind_dispatch_rc=$?
if [ "$bind_dispatch_rc" -eq 0 ] \
  && jq -e 'select(.event == "start" and .req == ["R1"])' "$SPECBIND/.charles/dispatches.jsonl" >/dev/null 2>&1; then
  echo "  PASS  attached spec permits a requirement-scoped implement dispatch"; pass=$((pass+1))
else
  echo "  FAIL  attached spec must permit --req dispatch (rc=$bind_dispatch_rc)"; fail=$((fail+1))
fi
bash "$RS" spec "$SPECBIND" docs/specs/new.md --run legacy-run >/dev/null 2>&1
if [ "$(grep -c '^\- spec: ' "$SPECBIND/.charles/runs/legacy-run/RUN.md")" -eq 1 ] \
  && grep -q '^\- spec: docs/specs/new.md$' "$SPECBIND/.charles/runs/legacy-run/RUN.md" \
  && ! grep -q '^\- spec: docs/specs/old.md$' "$SPECBIND/.charles/runs/legacy-run/RUN.md"; then
  echo "  PASS  run-state spec replaces the existing spec field"; pass=$((pass+1))
else
  echo "  FAIL  run-state spec must replace, not append, the spec field"; fail=$((fail+1))
fi
missing_bind_out="$(bash "$RS" spec "$SPECBIND" docs/specs/missing.md --run legacy-run 2>&1)"; missing_bind_rc=$?
if [ "$missing_bind_rc" -eq 2 ] && grep -qF 'docs/specs/missing.md' <<<"$missing_bind_out"; then
  echo "  PASS  run-state spec refuses a nonexistent path"; pass=$((pass+1))
else
  echo "  FAIL  run-state spec must refuse a nonexistent path (rc=$missing_bind_rc)"; fail=$((fail+1))
fi
mkdir -p "$SPECBIND/.charles/runs/second-run"
printf '# Run second-run\n\n- flow: feature\n\n## Phases\n\n## Open items\n\n## Rollback\n\n' \
  > "$SPECBIND/.charles/runs/second-run/RUN.md"
multi_bind_out="$(bash "$RS" spec "$SPECBIND" docs/specs/old.md 2>&1)"; multi_bind_rc=$?
if [ "$multi_bind_rc" -eq 2 ] && grep -qF 'legacy-run' <<<"$multi_bind_out" \
  && grep -qF 'second-run' <<<"$multi_bind_out" && grep -qF -- '--run <id>' <<<"$multi_bind_out"; then
  echo "  PASS  run-state spec refuses two open runs without a selector"; pass=$((pass+1))
else
  echo "  FAIL  run-state spec must refuse two open runs without a selector (rc=$multi_bind_rc)"; fail=$((fail+1))
fi

# A spec bind must share the writer lock with phase updates, or its mv can erase
# a phase written from the same open run.
RACESTATE="$BOX/spec-race"; mkdir -p "$RACESTATE/docs/specs"
printf '# Race plan\n' > "$RACESTATE/docs/specs/race.md"
race_run="$(bash "$RS" init "$RACESTATE" feature "spec race" --spec docs/specs/race.md 2>/dev/null)"
mkdir -p "$RACESTATE/.charles"
(
  flock 9
  : > "$RACESTATE/lock-ready"
  while [ ! -e "$RACESTATE/release-lock" ]; do sleep 0.02; done
) 9>"$RACESTATE/.charles/run-state.lock" &
race_holder=$!
race_ready=0
for _ in $(seq 1 100); do
  if [ -e "$RACESTATE/lock-ready" ]; then race_ready=1; break; fi
  sleep 0.02
done
(
  bash "$RS" spec "$RACESTATE" docs/specs/race.md --run "$race_run" > "$RACESTATE/spec.out" 2>&1
  printf '%s\n' "$?" > "$RACESTATE/spec.rc"
  : > "$RACESTATE/spec.done"
) &
race_spec_pid=$!
(
  bash "$RS" phase "$RACESTATE" "serialized phase" --run "$race_run" > "$RACESTATE/phase.out" 2>&1
  printf '%s\n' "$?" > "$RACESTATE/phase.rc"
  : > "$RACESTATE/phase.done"
) &
race_phase_pid=$!
sleep 0.1
race_waiting=1
[ ! -e "$RACESTATE/spec.done" ] || race_waiting=0
[ ! -e "$RACESTATE/phase.done" ] || race_waiting=0
touch "$RACESTATE/release-lock"
wait "$race_holder" 2>/dev/null
wait "$race_spec_pid" 2>/dev/null
wait "$race_phase_pid" 2>/dev/null
if [ "$race_ready" -eq 1 ] && [ "$race_waiting" -eq 1 ] \
  && [ "$(cat "$RACESTATE/spec.rc" 2>/dev/null)" = 0 ] \
  && [ "$(cat "$RACESTATE/phase.rc" 2>/dev/null)" = 0 ] \
  && grep -qF 'serialized phase' "$RACESTATE/.charles/runs/$race_run/RUN.md" \
  && grep -qF -- '- spec: docs/specs/race.md' "$RACESTATE/.charles/runs/$race_run/RUN.md"; then
  echo "  PASS  spec binding serializes with concurrent phase writes"; pass=$((pass+1))
else
  echo "  FAIL  spec binding must preserve a concurrent phase write"; fail=$((fail+1))
fi

R11M="$BOX/r11-mismatch"; mkdir -p "$R11M/docs/specs"
for plan in first second third; do
  printf '# Plan\n\n## Sign-off\n\n- [x] %s\n' "$plan" > "$R11M/docs/specs/$plan.md"
done
bash "$RS" init "$R11M" feature "first run" --spec docs/specs/first.md >/dev/null
bash "$RS" init "$R11M" feature "second run" --spec docs/specs/second.md >/dev/null
r11_newest_path="$(find "$R11M/.charles/runs" -mindepth 1 -maxdepth 1 -type d -print | sort -r | head -1)"
r11_newest="${r11_newest_path##*/}"
r11_recorded="$(sed -n 's/^- spec: //p' "$r11_newest_path/RUN.md" | head -1)"
r11_mismatch_out="$(bash "$RS" close "$R11M" "wrong plan" --run "$r11_newest" --spec docs/specs/third.md --force 2>&1)"; r11_mismatch_rc=$?
if [ "$r11_mismatch_rc" -eq 2 ] \
  && grep -qF "recorded spec: $r11_recorded" <<<"$r11_mismatch_out" \
  && grep -qF -- '--spec given:  docs/specs/third.md' <<<"$r11_mismatch_out" \
  && ! grep -q '^## Outcome$' "$r11_newest_path/RUN.md"; then
  echo "  PASS  close refuses a spec that disagrees with the selected run"; pass=$((pass+1))
else
  echo "  FAIL  close must name both sides of a spec mismatch (rc=$r11_mismatch_rc)"; fail=$((fail+1))
fi

R11L="$BOX/r11-legacy"; mkdir -p "$R11L/docs/specs"
printf '# Plan\n\n## Sign-off\n\n- [x] legacy close\n' > "$R11L/docs/specs/legacy.md"
r11_legacy="$(bash "$RS" init "$R11L" feature "legacy run" 2>/dev/null)"
r11_legacy_out="$(bash "$RS" close "$R11L" "legacy outcome" --run "$r11_legacy" --spec docs/specs/legacy.md --force 2>&1)"; r11_legacy_rc=$?
if [ "$r11_legacy_rc" -eq 0 ] && grep -q '^## Outcome$' "$R11L/.charles/runs/$r11_legacy/RUN.md"; then
  echo "  PASS  close accepts --spec for a run with no recorded spec"; pass=$((pass+1))
else
  echo "  FAIL  close must accept --spec for an older run without recorded spec (rc=$r11_legacy_rc)"; fail=$((fail+1))
fi

DEFER="$BOX/defer"; mkdir -p "$DEFER/docs/specs"
printf 'green = "true"\n' > "$DEFER/.charles.toml"
printf '# Plan\n\n## Sign-off\n\n- [x] shipped one\n- [x] shipped two\n' > "$DEFER/docs/specs/p.md"
defer_run="$(bash "$RS" init "$DEFER" feature "defer test" --spec docs/specs/p.md 2>/dev/null)"
defer_item_out="$(bash "$RS" defer "$DEFER" "new discovery" 2>&1)"
if grep -qF 'recorded item: DEFERRED — new discovery' <<<"$defer_item_out" \
  && grep -qF 'DEFERRED' "$DEFER/.charles/runs/$defer_run/RUN.md"; then
  echo "  PASS  defer records a DEFERRED run item in one command"; pass=$((pass+1))
else
  echo "  FAIL  defer must record a DEFERRED run item"; fail=$((fail+1))
fi
defer_close_out="$(bash "$RS" close "$DEFER" done --spec docs/specs/p.md --force 2>&1)"; defer_close_rc=$?
if [ "$defer_close_rc" -eq 0 ] && grep -qF '2 requirements shipped, 1 items deferred' <<<"$defer_close_out"; then
  echo "  PASS  close reports shipped requirements and deferred items"; pass=$((pass+1))
else
  echo "  FAIL  close must report shipped requirements and deferred items (rc=$defer_close_rc)"; fail=$((fail+1))
fi

# --- concurrent-writer lock ---------------------------------------------------
# A fake `codex` on PATH lets us produce a process whose cmdline matches what the
# lock greps for, without dispatching anything real.
if grep -qE '^TIMEOUT=2700([[:space:]]|$)' "$RUN_SH"; then
  echo "  PASS  codex-run uses the 2700s default"; pass=$((pass+1))
else
  echo "  FAIL  codex-run must use the 2700s default"; fail=$((fail+1))
fi
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

# --- requirement-scoped implement dispatches ----------------------------------
REQDIR="$BOX/req-scope"; mkdir -p "$REQDIR/bin" "$REQDIR/docs/specs" "$REQDIR/.charles/runs/open-run"
printf '#!/usr/bin/env bash\n[ -z "${CHARLES_LANE_MARKER:-}" ] || : > "$CHARLES_LANE_MARKER"\nexit 0\n' \
  > "$REQDIR/bin/codex"; chmod +x "$REQDIR/bin/codex"
printf '# Plan\n\n## Grill verdict\n\n- Rounds: 1\n\n- [ ] **R1. first requirement**\n- [ ] **A3. second requirement**\n' \
  > "$REQDIR/docs/specs/plan.md"
printf '# Run open-run\n\n- flow: feature\n- spec: docs/specs/plan.md\n\n## Phases\n\n## Open items\n\n## Rollback\n\n' \
  > "$REQDIR/.charles/runs/open-run/RUN.md"
req_out="$(PATH="$REQDIR/bin:$PATH" CHARLES_STATE_DIR="$REQDIR/state" \
  bash "$RUN_SH" --lane implement --dir "$REQDIR" --no-fallback --timeout 2 "scope" 2>&1)"; req_rc=$?
if [ "$req_rc" -eq 2 ] && grep -qF 'docs/specs/plan.md' <<<"$req_out" \
  && [ ! -s "$REQDIR/.charles/dispatches.jsonl" ]; then
  echo "  PASS  open-run implement without --req is refused with its spec"; pass=$((pass+1))
else
  echo "  FAIL  open-run implement without --req must be refused (rc=$req_rc)"; fail=$((fail+1))
fi
req_out="$(PATH="$REQDIR/bin:$PATH" CHARLES_STATE_DIR="$REQDIR/state" \
  bash "$RUN_SH" --lane implement --dir "$REQDIR" --req R1,A3 --no-fallback --timeout 2 "scope" 2>&1)"; req_rc=$?
if [ "$req_rc" -eq 0 ] \
  && jq -e 'select(.event == "start" and .req == ["R1","A3"])' "$REQDIR/.charles/dispatches.jsonl" >/dev/null 2>&1 \
  && jq -e 'select(.event == "end" and .req == ["R1","A3"])' "$REQDIR/.charles/dispatches.jsonl" >/dev/null 2>&1; then
  echo "  PASS  implement records validated req identifiers on both events"; pass=$((pass+1))
else
  echo "  FAIL  implement must record validated req identifiers (rc=$req_rc)"; fail=$((fail+1))
fi
: > "$REQDIR/.charles/dispatches.jsonl"
rm -f "$REQDIR/lane-ran"
req_out="$(PATH="$REQDIR/bin:$PATH" CHARLES_STATE_DIR="$REQDIR/state" \
  CHARLES_LANE_MARKER="$REQDIR/lane-ran" bash "$RUN_SH" --lane implement --dir "$REQDIR" \
  --req $'R1\nR9' --no-fallback --timeout 2 "scope" 2>&1)"; req_rc=$?
if [ "$req_rc" -eq 2 ] && grep -qF 'requirement R9 is not in' <<<"$req_out" \
  && [ ! -s "$REQDIR/.charles/dispatches.jsonl" ] && [ ! -e "$REQDIR/lane-ran" ]; then
  echo "  PASS  invalid whitespace-separated req is refused before dispatch"; pass=$((pass+1))
else
  echo "  FAIL  invalid whitespace-separated req must refuse without a lane (rc=$req_rc)"; fail=$((fail+1))
fi

REQMATCH="$BOX/req-matcher"; mkdir -p "$REQMATCH/bin" "$REQMATCH/docs/specs" "$REQMATCH/.charles/runs/open-run"
cp "$REQDIR/bin/codex" "$REQMATCH/bin/codex"
printf '# Plan\n\n## Grill verdict\n\n- Rounds: 1\n\n- [ ] **R1. own convention**\n- **A1** alternate convention\n- [X] **R1.1. dotted identifier**\n- **R2.3b** suffixed identifier\n- [x] **X2c. suffixed identifier**\n\n## Sign-off\n\n- [x] **R9. sign-off only**\n- [x] **R1.1-R1.3** ranged sign-off\n' \
  > "$REQMATCH/docs/specs/matcher.md"
printf '# Run open-run\n\n- flow: feature\n- spec: docs/specs/matcher.md\n\n## Phases\n\n## Open items\n\n## Rollback\n\n' \
  > "$REQMATCH/.charles/runs/open-run/RUN.md"
matcher_out="$(PATH="$REQMATCH/bin:$PATH" CHARLES_STATE_DIR="$REQMATCH/state" \
  bash "$RUN_SH" --lane implement --dir "$REQMATCH" --req A1 --validate-only --no-fallback --timeout 2 "scope" 2>&1)"; matcher_rc=$?
if [ "$matcher_rc" -eq 0 ]; then
  echo "  PASS  alternate requirement bullet convention validates"; pass=$((pass+1))
else
  echo "  FAIL  alternate requirement bullet convention must validate (rc=$matcher_rc): $matcher_out"; fail=$((fail+1))
fi
matcher_out="$(PATH="$REQMATCH/bin:$PATH" CHARLES_STATE_DIR="$REQMATCH/state" \
  bash "$RUN_SH" --lane implement --dir "$REQMATCH" --req R1.1,R2.3b,X2c --validate-only --no-fallback --timeout 2 "scope" 2>&1)"; matcher_rc=$?
if [ "$matcher_rc" -eq 0 ]; then
  echo "  PASS  dotted and suffixed requirement identifiers validate"; pass=$((pass+1))
else
  echo "  FAIL  dotted and suffixed requirement identifiers must validate (rc=$matcher_rc): $matcher_out"; fail=$((fail+1))
fi
matcher_bad=1
for matcher_req in R9 R1.2; do
  matcher_out="$(PATH="$REQMATCH/bin:$PATH" CHARLES_STATE_DIR="$REQMATCH/state" \
    bash "$RUN_SH" --lane implement --dir "$REQMATCH" --req "$matcher_req" --validate-only --no-fallback --timeout 2 "scope" 2>&1)"; matcher_rc=$?
  if [ "$matcher_rc" -ne 2 ] || ! grep -qF "requirement $matcher_req is not in docs/specs/matcher.md" <<<"$matcher_out"; then
    matcher_bad=0
  fi
done
if [ "$matcher_bad" -eq 1 ]; then
  echo "  PASS  Sign-off-only and ranged requirements are refused"; pass=$((pass+1))
else
  echo "  FAIL  Sign-off-only and ranged requirements must be refused"; fail=$((fail+1))
fi
matcher_out="$(PATH="$REQMATCH/bin:$PATH" CHARLES_STATE_DIR="$REQMATCH/state" \
  bash "$RUN_SH" --lane implement --dir "$REQMATCH" --req A9 --validate-only --no-fallback --timeout 2 "scope" 2>&1)"; matcher_rc=$?
if [ "$matcher_rc" -eq 2 ] && grep -qF 'requirement A9 is not in docs/specs/matcher.md' <<<"$matcher_out"; then
  echo "  PASS  absent requirement names its id and plan"; pass=$((pass+1))
else
  echo "  FAIL  absent requirement must name its id and plan (rc=$matcher_rc)"; fail=$((fail+1))
fi
malformed_ok=1
REQMAL="$BOX/req-malformed"; mkdir -p "$REQMAL"
for bad_id in lowercase1 1A R; do
  malformed_out="$(CHARLES_STATE_DIR="$REQMAL/state" \
    bash "$RUN_SH" --lane implement --dir "$REQMAL" --plan "$REQMAL/missing.md" --req "$bad_id" --validate-only --no-fallback --timeout 2 "scope" 2>&1)"; malformed_rc=$?
  if [ "$malformed_rc" -ne 2 ] || ! grep -qF "invalid requirement identifier '$bad_id'" <<<"$malformed_out" \
    || grep -qF 'no readable plan file' <<<"$malformed_out"; then
    malformed_ok=0
  fi
done
for empty_req in "" " "; do
  empty_out="$(CHARLES_STATE_DIR="$REQMAL/state" \
    bash "$RUN_SH" --lane implement --dir "$REQMAL" --plan "$REQMAL/missing.md" --req "$empty_req" --validate-only --no-fallback --timeout 2 "scope" 2>&1)"; empty_rc=$?
  if [ "$empty_rc" -ne 2 ] || ! grep -qF -- '--req needs at least one requirement identifier' <<<"$empty_out"; then
    malformed_ok=0
  fi
done
comma_out="$(PATH="$REQDIR/bin:$PATH" CHARLES_STATE_DIR="$REQDIR/state" \
  bash "$RUN_SH" --lane implement --dir "$REQDIR" --req 'R1,' --validate-only --no-fallback --timeout 2 "scope" 2>&1)"; comma_rc=$?
if [ "$comma_rc" -eq 2 ] && grep -qF "invalid requirement identifier ''" <<<"$comma_out"; then
  echo "  PASS  trailing requirement separator is refused"; pass=$((pass+1))
else
  echo "  FAIL  trailing requirement separator must refuse an empty identifier (rc=$comma_rc)"; fail=$((fail+1))
fi
if [ "$malformed_ok" -eq 1 ]; then
  echo "  PASS  malformed and empty requirement identifiers refuse before plan read"; pass=$((pass+1))
else
  echo "  FAIL  malformed and empty requirement identifiers must refuse before plan read"; fail=$((fail+1))
fi

REQWT="$BOX/req-worktree"; mkdir -p "$REQWT/bin" "$REQWT/main/docs/specs"
(
  cd "$REQWT/main" && git init -q && git config user.name tester \
    && git config user.email tester@example.invalid \
    && printf '# Plan\n\n## Grill verdict\n\n- Rounds: 1\n\n- [ ] **R1. worktree requirement**\n' > docs/specs/plan.md \
    && git add . && git commit -qm init
)
git -C "$REQWT/main" worktree add -q "$REQWT/worktree" HEAD
mkdir -p "$REQWT/main/.charles/runs/open-run"
cp "$REQDIR/bin/codex" "$REQWT/bin/codex"
printf '# Run open-run\n\n- flow: feature\n- spec: docs/specs/plan.md\n\n## Phases\n\n## Open items\n\n## Rollback\n\n' \
  > "$REQWT/main/.charles/runs/open-run/RUN.md"
rm -f "$REQWT/lane-ran"
req_wt_out="$(PATH="$REQWT/bin:$PATH" CHARLES_STATE_DIR="$REQWT/state" \
  CHARLES_LANE_MARKER="$REQWT/lane-ran" bash "$RUN_SH" --lane implement --dir "$REQWT/worktree" \
  --run open-run --no-fallback --timeout 2 "scope" 2>&1)"; req_wt_rc=$?
wt_state_out="$(bash "$RS" phase "$REQWT/worktree" "worktree state phase" --run open-run 2>&1)"; wt_state_rc=$?
if [ "$req_wt_rc" -eq 2 ] && grep -qF 'docs/specs/plan.md' <<<"$req_wt_out" \
  && [ ! -s "$REQWT/worktree/.charles/dispatches.jsonl" ] && [ ! -e "$REQWT/lane-ran" ] \
  && [ "$wt_state_rc" -eq 0 ] && grep -qF 'worktree state phase' "$REQWT/main/.charles/runs/open-run/RUN.md" \
  && ! grep -qF 'worktree state phase' "$REQWT/worktree/.charles/runs/open-run/RUN.md" 2>/dev/null; then
  echo "  PASS  worktree run-state and codex-run select the main repo run"; pass=$((pass+1))
else
  echo "  FAIL  worktree selectors must honor the main repo open run (codex=$req_wt_rc state=$wt_state_rc)"; fail=$((fail+1))
fi

REQAMB="$BOX/req-ambiguous"; mkdir -p "$REQAMB/bin" "$REQAMB/docs/specs" \
  "$REQAMB/.charles/runs/run-alpha-20260821" "$REQAMB/.charles/runs/run-beta-20260821"
cp "$REQDIR/bin/codex" "$REQAMB/bin/codex"
printf '# Plan alpha\n\n## Grill verdict\n\n- Rounds: 1\n\n- [ ] **R1. alpha requirement**\n' > "$REQAMB/docs/specs/plan-alpha.md"
printf '# Plan beta\n\n## Grill verdict\n\n- Rounds: 1\n\n- [ ] **A3. beta requirement**\n' > "$REQAMB/docs/specs/plan-beta.md"
printf '# Run run-alpha-20260821\n\n- flow: feature\n- spec: docs/specs/plan-alpha.md\n\n## Phases\n\n## Open items\n\n## Rollback\n\n' \
  > "$REQAMB/.charles/runs/run-alpha-20260821/RUN.md"
printf '# Run run-beta-20260821\n\n- flow: feature\n- spec: docs/specs/plan-beta.md\n\n## Phases\n\n## Open items\n\n## Rollback\n\n' \
  > "$REQAMB/.charles/runs/run-beta-20260821/RUN.md"
req_out="$(CHARLES_RUN= PATH="$REQAMB/bin:$PATH" CHARLES_STATE_DIR="$REQAMB/state" \
  bash "$RUN_SH" --lane implement --dir "$REQAMB" --req R1 --no-fallback --timeout 2 "scope" 2>&1)"; req_rc=$?
if [ "$req_rc" -eq 2 ] && grep -qF 'run-alpha-20260821' <<<"$req_out" \
  && grep -qF 'run-beta-20260821' <<<"$req_out" \
  && grep -qF -- '--run <id>' <<<"$req_out" && grep -qF 'CHARLES_RUN' <<<"$req_out"; then
  echo "  PASS  two open runs without a selector name both runs and the selector"; pass=$((pass+1))
else
  echo "  FAIL  two open runs without a selector must name both runs and the selector (rc=$req_rc)"; fail=$((fail+1))
fi

: > "$REQAMB/.charles/dispatches.jsonl"
req_out="$(CHARLES_RUN= PATH="$REQAMB/bin:$PATH" CHARLES_STATE_DIR="$REQAMB/state" \
  bash "$RUN_SH" --lane implement --dir "$REQAMB" --run run-alpha-20260821 --req R1 \
  --no-fallback --timeout 2 "scope" 2>&1)"; req_rc=$?
wrong_out="$(CHARLES_RUN= PATH="$REQAMB/bin:$PATH" CHARLES_STATE_DIR="$REQAMB/state" \
  bash "$RUN_SH" --lane implement --dir "$REQAMB" --run run-alpha-20260821 --req A3 \
  --no-fallback --timeout 2 "scope" 2>&1)"; wrong_rc=$?
if [ "$req_rc" -eq 0 ] && [ "$wrong_rc" -eq 2 ] \
  && grep -qF 'requirement A3 is not in docs/specs/plan-alpha.md' <<<"$wrong_out" \
  && jq -e 'select(.event == "start" and .req == ["R1"])' "$REQAMB/.charles/dispatches.jsonl" >/dev/null 2>&1; then
  echo "  PASS  --run full id selects its run and validates its spec"; pass=$((pass+1))
else
  echo "  FAIL  --run full id must validate --req against its spec (rc=$req_rc wrong=$wrong_rc)"; fail=$((fail+1))
fi

: > "$REQAMB/.charles/dispatches.jsonl"
req_out="$(CHARLES_RUN=run-beta-20260821 PATH="$REQAMB/bin:$PATH" CHARLES_STATE_DIR="$REQAMB/state" \
  bash "$RUN_SH" --lane implement --dir "$REQAMB" --req A3 --no-fallback --timeout 2 "scope" 2>&1)"; req_rc=$?
if [ "$req_rc" -eq 0 ] \
  && jq -e 'select(.event == "start" and .req == ["A3"])' "$REQAMB/.charles/dispatches.jsonl" >/dev/null 2>&1; then
  echo "  PASS  CHARLES_RUN selects the right run and validates its spec"; pass=$((pass+1))
else
  echo "  FAIL  CHARLES_RUN must select and validate its run (rc=$req_rc)"; fail=$((fail+1))
fi

: > "$REQAMB/.charles/dispatches.jsonl"
req_out="$(CHARLES_RUN=run-beta-20260821 PATH="$REQAMB/bin:$PATH" CHARLES_STATE_DIR="$REQAMB/state" \
  bash "$RUN_SH" --lane implement --dir "$REQAMB" --run run-alpha-20260821 --req R1 \
  --no-fallback --timeout 2 "scope" 2>&1)"; req_rc=$?
if [ "$req_rc" -eq 0 ] \
  && jq -e 'select(.event == "start" and .req == ["R1"])' "$REQAMB/.charles/dispatches.jsonl" >/dev/null 2>&1; then
  echo "  PASS  --run takes precedence over CHARLES_RUN"; pass=$((pass+1))
else
  echo "  FAIL  --run must take precedence over CHARLES_RUN (rc=$req_rc)"; fail=$((fail+1))
fi

: > "$REQAMB/.charles/dispatches.jsonl"
req_out="$(CHARLES_RUN= PATH="$REQAMB/bin:$PATH" CHARLES_STATE_DIR="$REQAMB/state" \
  bash "$RUN_SH" --lane implement --dir "$REQAMB" --run run-al --req R1 \
  --no-fallback --timeout 2 "scope" 2>&1)"; req_rc=$?
if [ "$req_rc" -eq 0 ] \
  && jq -e 'select(.event == "start" and .req == ["R1"])' "$REQAMB/.charles/dispatches.jsonl" >/dev/null 2>&1; then
  echo "  PASS  unambiguous run prefix selects its run"; pass=$((pass+1))
else
  echo "  FAIL  unambiguous run prefix must select its run (rc=$req_rc)"; fail=$((fail+1))
fi

: > "$REQAMB/.charles/dispatches.jsonl"
req_out="$(CHARLES_RUN= PATH="$REQAMB/bin:$PATH" CHARLES_STATE_DIR="$REQAMB/state" \
  bash "$RUN_SH" --lane implement --dir "$REQAMB" --run alpha-20260821 --req R1 \
  --no-fallback --timeout 2 "scope" 2>&1)"; req_rc=$?
if [ "$req_rc" -eq 0 ] \
  && jq -e 'select(.event == "start" and .req == ["R1"])' "$REQAMB/.charles/dispatches.jsonl" >/dev/null 2>&1; then
  echo "  PASS  mid-id substring selects a unique run in codex-run"; pass=$((pass+1))
else
  echo "  FAIL  codex-run must accept a unique mid-id substring (rc=$req_rc)"; fail=$((fail+1))
fi
state_sub_out="$(CHARLES_RUN= bash "$RS" phase "$REQAMB" "mid-id phase" --run alpha-20260821 2>&1)"; state_sub_rc=$?
if [ "$state_sub_rc" -eq 0 ] && grep -qF 'mid-id phase' "$REQAMB/.charles/runs/run-alpha-20260821/RUN.md" \
  && ! grep -qF 'mid-id phase' "$REQAMB/.charles/runs/run-beta-20260821/RUN.md"; then
  echo "  PASS  mid-id substring selects a unique run in run-state"; pass=$((pass+1))
else
  echo "  FAIL  run-state must accept a unique mid-id substring (rc=$state_sub_rc)"; fail=$((fail+1))
fi

req_out="$(CHARLES_RUN= PATH="$REQAMB/bin:$PATH" CHARLES_STATE_DIR="$REQAMB/state" \
  bash "$RUN_SH" --lane implement --dir "$REQAMB" --run 20260821 --req R1 \
  --no-fallback --timeout 2 "scope" 2>&1)"; req_rc=$?
state_sub_out="$(CHARLES_RUN= bash "$RS" phase "$REQAMB" "ambiguous substring" --run 20260821 2>&1)"; state_sub_rc=$?
if [ "$req_rc" -eq 2 ] && [ "$state_sub_rc" -eq 2 ] \
  && grep -qF 'run-alpha-20260821' <<<"$req_out" && grep -qF 'run-beta-20260821' <<<"$req_out" \
  && grep -qF 'run-alpha-20260821' <<<"$state_sub_out" && grep -qF 'run-beta-20260821' <<<"$state_sub_out"; then
  echo "  PASS  ambiguous substring names both candidates in both selectors"; pass=$((pass+1))
else
  echo "  FAIL  ambiguous substring must name both candidates (codex=$req_rc run-state=$state_sub_rc)"; fail=$((fail+1))
fi

REQEXACT="$BOX/req-exact"; mkdir -p "$REQEXACT/bin" "$REQEXACT/docs/specs" \
  "$REQEXACT/.charles/runs/run-target" "$REQEXACT/.charles/runs/prefix-run-target-suffix"
cp "$REQDIR/bin/codex" "$REQEXACT/bin/codex"
printf '# Target plan\n\n## Grill verdict\n\n- Rounds: 1\n\n- [ ] **R1. target requirement**\n' > "$REQEXACT/docs/specs/target.md"
printf '# Other plan\n\n- [ ] **A3. other requirement**\n' > "$REQEXACT/docs/specs/other.md"
printf '# Run run-target\n\n- flow: feature\n- spec: docs/specs/target.md\n\n## Phases\n\n## Open items\n\n## Rollback\n\n' \
  > "$REQEXACT/.charles/runs/run-target/RUN.md"
printf '# Run prefix-run-target-suffix\n\n- flow: feature\n- spec: docs/specs/other.md\n\n## Phases\n\n## Open items\n\n## Rollback\n\n' \
  > "$REQEXACT/.charles/runs/prefix-run-target-suffix/RUN.md"
exact_state_out="$(CHARLES_RUN= bash "$RS" phase "$REQEXACT" "exact target" --run run-target 2>&1)"; exact_state_rc=$?
exact_codex_out="$(CHARLES_RUN= PATH="$REQEXACT/bin:$PATH" CHARLES_STATE_DIR="$REQEXACT/state" \
  bash "$RUN_SH" --lane implement --dir "$REQEXACT" --run run-target --req R1 \
  --no-fallback --timeout 2 "scope" 2>&1)"; exact_codex_rc=$?
if [ "$exact_state_rc" -eq 0 ] && [ "$exact_codex_rc" -eq 0 ] \
  && grep -qF 'exact target' "$REQEXACT/.charles/runs/run-target/RUN.md" \
  && ! grep -qF 'exact target' "$REQEXACT/.charles/runs/prefix-run-target-suffix/RUN.md"; then
  echo "  PASS  exact full id wins over a longer matching substring in both selectors"; pass=$((pass+1))
else
  echo "  FAIL  exact full id must win over a longer matching substring (run-state=$exact_state_rc codex=$exact_codex_rc)"; fail=$((fail+1))
fi

req_out="$(CHARLES_RUN= PATH="$REQAMB/bin:$PATH" CHARLES_STATE_DIR="$REQAMB/state" \
  bash "$RUN_SH" --lane implement --dir "$REQAMB" --run run- --req R1 \
  --no-fallback --timeout 2 "scope" 2>&1)"; req_rc=$?
if [ "$req_rc" -eq 2 ] && grep -qF "run selector 'run-' is ambiguous" <<<"$req_out" \
  && grep -qF 'run-alpha-20260821' <<<"$req_out" && grep -qF 'run-beta-20260821' <<<"$req_out"; then
  echo "  PASS  ambiguous run prefix names its candidates"; pass=$((pass+1))
else
  echo "  FAIL  ambiguous run prefix must name its candidates (rc=$req_rc)"; fail=$((fail+1))
fi

mkdir -p "$REQAMB/.charles/runs/closed-run-20260821"
printf '# Run closed-run-20260821\n\n- flow: feature\n- spec: docs/specs/plan-alpha.md\n\n## Outcome\n\nclosed\n' \
  > "$REQAMB/.charles/runs/closed-run-20260821/RUN.md"
closed_out="$(CHARLES_RUN= PATH="$REQAMB/bin:$PATH" CHARLES_STATE_DIR="$REQAMB/state" \
  bash "$RUN_SH" --lane implement --dir "$REQAMB" --run closed-run-20260821 --req R1 \
  --no-fallback --timeout 2 "scope" 2>&1)"; closed_rc=$?
unknown_out="$(CHARLES_RUN= PATH="$REQAMB/bin:$PATH" CHARLES_STATE_DIR="$REQAMB/state" \
  bash "$RUN_SH" --lane implement --dir "$REQAMB" --run missing-run-20260821 --req R1 \
  --no-fallback --timeout 2 "scope" 2>&1)"; unknown_rc=$?
if [ "$closed_rc" -eq 2 ] && [ "$unknown_rc" -eq 2 ] \
  && grep -qF "run selector 'closed-run-20260821'" <<<"$closed_out" \
  && grep -qF "run selector 'missing-run-20260821'" <<<"$unknown_out"; then
  echo "  PASS  closed and unknown run selectors are refused"; pass=$((pass+1))
else
  echo "  FAIL  closed and unknown run selectors must be refused (closed=$closed_rc unknown=$unknown_rc)"; fail=$((fail+1))
fi

mkdir -p "$REQAMB/.charles/runs/open-closed-run-20260821"
printf '# Run open-closed-run-20260821\n\n- flow: feature\n- spec: docs/specs/plan-alpha.md\n\n## Phases\n\n## Open items\n\n## Rollback\n\n' \
  > "$REQAMB/.charles/runs/open-closed-run-20260821/RUN.md"
cp "$REQAMB/.charles/runs/open-closed-run-20260821/RUN.md" "$REQAMB/open-closed.before"
closed_collision_state_out="$(bash "$RS" phase "$REQAMB" "closed collision" --run closed-run-20260821 2>&1)"; closed_collision_state_rc=$?
closed_collision_codex_out="$(CHARLES_RUN= PATH="$REQAMB/bin:$PATH" CHARLES_STATE_DIR="$REQAMB/state" \
  bash "$RUN_SH" --lane implement --dir "$REQAMB" --run closed-run-20260821 --req R1 \
  --no-fallback --timeout 2 "scope" 2>&1)"; closed_collision_codex_rc=$?
if [ "$closed_collision_state_rc" -eq 2 ] && [ "$closed_collision_codex_rc" -eq 2 ] \
  && grep -qF "names a closed run" <<<"$closed_collision_state_out" \
  && grep -qF "names a closed run" <<<"$closed_collision_codex_out" \
  && cmp -s "$REQAMB/.charles/runs/open-closed-run-20260821/RUN.md" "$REQAMB/open-closed.before"; then
  echo "  PASS  exact closed id is refused before an open substring match in both selectors"; pass=$((pass+1))
else
  echo "  FAIL  exact closed id must not select an open substring (state=$closed_collision_state_rc codex=$closed_collision_codex_rc)"; fail=$((fail+1))
fi

REQNOSPEC="$BOX/req-no-spec"; mkdir -p "$REQNOSPEC/bin" "$REQNOSPEC/.charles/runs/open-run"
cp "$REQDIR/bin/codex" "$REQNOSPEC/bin/codex"
printf '# Run open-run\n\n- flow: feature\n\n## Phases\n\n## Open items\n\n## Rollback\n\n' \
  > "$REQNOSPEC/.charles/runs/open-run/RUN.md"
req_out="$(PATH="$REQNOSPEC/bin:$PATH" CHARLES_STATE_DIR="$REQNOSPEC/state" \
  bash "$RUN_SH" --lane implement --dir "$REQNOSPEC" --req R1 --no-fallback --timeout 2 "scope" 2>&1)"; req_rc=$?
if [ "$req_rc" -eq 2 ] && grep -qF 'has no associated spec' <<<"$req_out"; then
  echo "  PASS  requirement dispatch refuses an open run with no associated spec"; pass=$((pass+1))
else
  echo "  FAIL  missing open-run spec must refuse without guessing (rc=$req_rc)"; fail=$((fail+1))
fi

REQUNREAD="$BOX/req-unreadable"; mkdir -p "$REQUNREAD/bin" "$REQUNREAD/.charles/runs"
cp "$REQDIR/bin/codex" "$REQUNREAD/bin/codex"
chmod 000 "$REQUNREAD/.charles/runs"
req_unread_out="$(PATH="$REQUNREAD/bin:$PATH" CHARLES_STATE_DIR="$REQUNREAD/state" \
  bash "$RUN_SH" --lane implement --dir "$REQUNREAD" --no-fallback --timeout 2 "scope" 2>&1)"; req_unread_rc=$?
chmod 755 "$REQUNREAD/.charles/runs"
if [ "$req_unread_rc" -eq 2 ] && grep -qF 'cannot read run directory' <<<"$req_unread_out"; then
  echo "  PASS  unreadable run state refuses implement dispatch"; pass=$((pass+1))
else
  echo "  FAIL  unreadable run state must refuse dispatch (rc=$req_unread_rc)"; fail=$((fail+1))
fi

# --- dispatcher symlink hook --------------------------------------------------
# Agents cannot rely on ${CLAUDE_PLUGIN_ROOT} expanding in their shell; when it
# did not, they hunted the filesystem and executed a live working copy. The hook
# gives them a stable `codex-run` instead.
LINK="$(cd "$(dirname "$0")/.." && pwd)/hooks/link-dispatcher.sh"
DISPATCH_ROOT="$BOX/dispatcher-worktree"; mkdir -p "$DISPATCH_ROOT/scripts" "$DISPATCH_ROOT/.claude-plugin"
env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR git init -q "$DISPATCH_ROOT"
printf '{"version":"2.34.0"}\n' > "$DISPATCH_ROOT/.claude-plugin/plugin.json"
printf '#!/usr/bin/env bash\necho dispatched\n' > "$DISPATCH_ROOT/scripts/codex-run.sh"
chmod +x "$DISPATCH_ROOT/scripts/codex-run.sh"

HOME_ORIG="$HOME"
export HOME="$BOX/fakehome"; mkdir -p "$HOME"
(
  cd "$BOX" && CLAUDE_PLUGIN_ROOT="$DISPATCH_ROOT" \
    GIT_DIR="$BOX/not-a-git-dir" GIT_WORK_TREE="$BOX" bash "$LINK" \
    >"$BOX/dispatcher-refuse.out" 2>"$BOX/dispatcher-refuse.err"
); refuse_rc=$?
if [ "$refuse_rc" -eq 0 ] \
  && [ ! -e "$HOME/.local/bin/codex-run" ] && [ ! -L "$HOME/.local/bin/codex-run" ] \
  && grep -qF 'git working tree' "$BOX/dispatcher-refuse.err"; then
  echo "  PASS  session hook refuses a working-tree target without creating the link"; pass=$((pass+1))
else
  echo "  FAIL  session hook must refuse a working-tree target without creating the link"; fail=$((fail+1))
fi

cache_target="$HOME/.claude/plugins/cache/charlesdr-dev-loop/charlesdr-dev-loop/2.34.0/scripts/codex-run.sh"
mkdir -p "$(dirname "$cache_target")"
printf '#!/usr/bin/env bash\necho cached\n' > "$cache_target"
chmod +x "$cache_target"
(
  cd "$BOX" && CLAUDE_PLUGIN_ROOT="$DISPATCH_ROOT" \
    GIT_DIR="$BOX/not-a-git-dir" GIT_WORK_TREE="$BOX" bash "$LINK"
) >/dev/null 2>&1
if [ "$(readlink "$HOME/.local/bin/codex-run" 2>/dev/null)" = "$cache_target" ]; then
  echo "  PASS  session hook falls back to the installed cache copy"; pass=$((pass+1))
else
  echo "  FAIL  session hook did not use the installed cache copy"; fail=$((fail+1))
fi

second="$(cd "$BOX" && CLAUDE_PLUGIN_ROOT="$DISPATCH_ROOT" bash "$LINK" 2>&1)"
if [ -z "$second" ]; then
  echo "  PASS  hook is idempotent on reinstall"; pass=$((pass+1))
else
  echo "  FAIL  hook should be silent when the link is already correct"; fail=$((fail+1))
fi

ln -sfn "$DISPATCH_ROOT/scripts/codex-run.sh" "$cache_target"
cache_bad_before="$(readlink "$HOME/.local/bin/codex-run")"
(
  cd "$BOX" && CLAUDE_PLUGIN_ROOT="$DISPATCH_ROOT" \
    GIT_DIR="$BOX/not-a-git-dir" GIT_WORK_TREE="$BOX" bash "$LINK"
) >/dev/null 2>"$BOX/dispatcher-cache-refuse.err"
if [ "$(readlink "$HOME/.local/bin/codex-run" 2>/dev/null)" = "$cache_bad_before" ] \
  && grep -qF 'git working tree' "$BOX/dispatcher-cache-refuse.err"; then
  echo "  PASS  hook rejects a cache target whose resolved path is a checkout"; pass=$((pass+1))
else
  echo "  FAIL  hook accepted a cache target whose resolved path is a checkout"; fail=$((fail+1))
fi

rm -f "$cache_target"
good_target="$BOX/good-codex-run.sh"
printf '#!/usr/bin/env bash\necho good\n' > "$good_target"
chmod +x "$good_target"
ln -sfn "$good_target" "$HOME/.local/bin/codex-run"
good_before="$(readlink "$HOME/.local/bin/codex-run")"
(
  cd "$BOX" && CLAUDE_PLUGIN_ROOT="$DISPATCH_ROOT" bash "$LINK"
) >/dev/null 2>"$BOX/dispatcher-existing.err"
if [ "$(readlink "$HOME/.local/bin/codex-run" 2>/dev/null)" = "$good_before" ] \
  && grep -qF 'git working tree' "$BOX/dispatcher-existing.err"; then
  echo "  PASS  hook leaves an existing link alone without an installed copy"; pass=$((pass+1))
else
  echo "  FAIL  hook repointed an existing link without an installed copy"; fail=$((fail+1))
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
# sat stuck 27 minutes on dead engines. lane-status asks the watchdog artifacts.
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
unknown_lane_out="$(CHARLES_STATE_DIR="$LD" bash "$LS" 20260101-000000-222222-explore 2>&1)"; unknown_lane_rc=$?
if [ "$unknown_lane_rc" -eq 3 ] && grep -q 'UNKNOWN: 20260101-000000-222222-explore' <<<"$unknown_lane_out" \
  && ! grep -q 'DEAD:' <<<"$unknown_lane_out"; then
  echo "  PASS  dispatch with no liveness artifacts reports UNKNOWN, not DEAD"; pass=$((pass+1))
else
  echo "  FAIL  dispatch with no liveness artifacts should report UNKNOWN (rc=$unknown_lane_rc)"; fail=$((fail+1))
fi

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
pending_out=""; pending_rc=3
for _ in $(seq 1 40); do
  pending_out="$(CHARLES_STATE_DIR="$PENDING/state" bash "$LS" --dir "$PENDING" "$pending_run" 2>&1)"; pending_rc=$?
  [ "$pending_rc" -eq 0 ] && break
  sleep 0.05
done
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

# R4: a live start with no end is RUNNING, not an orphan. The PID is this
# selftest process; no Codex lane is launched for this synthetic artifact check.
R4="$BOX/r4-liveness"; R4_STATE="$R4/state"; R4_RUN="live-r4"
mkdir -p "$R4/.charles" "$R4_STATE"
R4_PID_FILE="$R4_STATE/$R4_RUN.child.1"
printf '{"ts":"%s","event":"start","lane":"explore","engine":"luna","run":"%s","dir":"%s","task":"live"}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$R4_RUN" "$R4" > "$R4/.charles/dispatches.jsonl"
printf '1|luna|m|||%s\n' "$R4_PID_FILE" > "$R4_STATE/$R4_RUN.watchdog.state"
printf '%s\n' "$$" > "$R4_PID_FILE"
r4_flow_out="$(CHARLES_STATE_DIR="$R4_STATE" bash "$FS" "$R4" 2>&1)"; r4_flow_rc=$?
if [ "$r4_flow_rc" -eq 1 ] && grep -q 'ISSUE.*RUNNING dispatch live-r4' <<<"$r4_flow_out" \
  && ! grep -q 'orphan dispatch live-r4' <<<"$r4_flow_out"; then
  echo "  PASS  live dispatch is RUNNING and not counted as an orphan"; pass=$((pass+1))
else
  echo "  FAIL  live dispatch must be RUNNING, not orphan (rc=$r4_flow_rc)"; fail=$((fail+1))
fi

R4_DONE="$BOX/r4-done"; R4_DONE_STATE="$R4_DONE/state"; R4_DONE_RUN="done-r4"
mkdir -p "$R4_DONE/.charles" "$R4_DONE_STATE"
printf '{"ts":"%s","event":"start","lane":"explore","engine":"luna","run":"%s","dir":"%s","task":"done"}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$R4_DONE_RUN" "$R4_DONE" > "$R4_DONE/.charles/dispatches.jsonl"
printf 'result\n' > "$R4_DONE_STATE/$R4_DONE_RUN.last"
r4_done_flow_out="$(CHARLES_STATE_DIR="$R4_DONE_STATE" bash "$FS" "$R4_DONE" 2>&1)"; r4_done_flow_rc=$?
if [ "$r4_done_flow_rc" -eq 1 ] \
  && grep -q 'lane completed but its terminal dispatch record is missing' <<<"$r4_done_flow_out" \
  && ! grep -q 'killed mid-write' <<<"$r4_done_flow_out"; then
  echo "  PASS  completed dispatch without terminal record is not called killed"; pass=$((pass+1))
else
  echo "  FAIL  completed dispatch without terminal record must not be called killed (rc=$r4_done_flow_rc)"; fail=$((fail+1))
fi

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

# --- close-time flow scoping -------------------------------------------------
CS="$BOX/close-scope"; CS_STATE="$CS/state"
mkdir -p "$CS/.charles/runs/close-run" "$CS/.charles/runs/stale-run" "$CS/docs/specs" "$CS_STATE"
printf 'green = "true"\n' > "$CS/.charles.toml"
( cd "$CS" && git init -q && git config user.name tester && git config user.email tester@example.invalid && \
  printf 'base\n' > tracked && git add tracked && git commit -qm init ) >/dev/null 2>&1
CS_OLD="$(date -u -d '2 days ago' +%Y-%m-%dT%H:%M:%SZ)"
CS_CLOSE="$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
CS_IMPL="$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
CS_PLAN="$(date -u -d '4 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
CS_MID="$(date -u -d '3 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
CS_UNSOURCED="$(date -u -d '2 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
printf '# Close plan\n\n## Grill verdict\n\n- Rounds: 1\n\n## Sign-off\n\n- [x] close-scope fixture\n' > "$CS/docs/specs/close-plan.md"
printf '# Own ungrilled plan\n\n## Sign-off\n\n- [x] close-scope fixture\n' > "$CS/docs/specs/own-ungrilled.md"
printf '# Run close-run\n\n- flow: feature\n- spec: docs/specs/close-plan.md\n- started: %s\n- repo: %s\n\n## Phases\n\n- [12:00Z] verify\n\n## Open items\n\n## Rollback\n\n' \
  "$CS_CLOSE" "$CS" > "$CS/.charles/runs/close-run/RUN.md"
printf '# Run stale-run\n\n- flow: feature\n- started: %s\n- repo: %s\n\n## Phases\n\n## Open items\n\n## Rollback\n\n' \
  "$CS_OLD" "$CS" > "$CS/.charles/runs/stale-run/RUN.md"
printf '{"ts":"%s","event":"start","lane":"explore","run":"old-orphan","dir":"%s","task":"old"}\n' \
  "$CS_OLD" "$CS" > "$CS/.charles/dispatches.jsonl"

scope_status="$(CHARLES_STATE_DIR="$CS_STATE" bash "$FS" "$CS" --closing "$CS/.charles/runs/close-run" 2>&1)"; scope_status_rc=$?
if [ "$scope_status_rc" -eq 0 ] && grep -q 'repo backlog' <<<"$scope_status" \
  && grep -q 'old-orphan' <<<"$scope_status" && grep -q 'run stale-run' <<<"$scope_status" \
  && grep -q '/charlesdr-dev-loop:resolve' <<<"$scope_status" && grep -q 'runs-sweep.sh' <<<"$scope_status"; then
  echo "  PASS  closing audit reports stale findings as repo backlog"; pass=$((pass+1))
else
  echo "  FAIL  closing audit should report stale findings without blocking (rc=$scope_status_rc)"; fail=$((fail+1))
fi
scope_close="$(CHARLES_STATE_DIR="$CS_STATE" bash "$RS" close "$CS" done --run close-run 2>&1)"; scope_close_rc=$?
if [ "$scope_close_rc" -eq 0 ]; then
  echo "  PASS  close ignores stale open runs and pre-dating orphan"; pass=$((pass+1))
else
  echo "  FAIL  complete run should close despite stale repo findings (rc=$scope_close_rc)"; fail=$((fail+1))
fi

mkdir -p "$CS/.charles/runs/own-impl"
printf '# Run own-impl\n\n- flow: feature\n- spec: docs/specs/close-plan.md\n- started: %s\n- repo: %s\n\n## Phases\n\n- [12:00Z] verify\n\n## Open items\n\n## Rollback\n\n' \
  "$CS_IMPL" "$CS" > "$CS/.charles/runs/own-impl/RUN.md"
printf '{"ts":"%s","event":"end","lane":"implement","engine":"luna","model":"m","rc":0,"run":"own-impl","dir":"%s","task":"own"}\n' \
  "$CS_IMPL" "$CS" >> "$CS/.charles/dispatches.jsonl"
impl_status="$(CHARLES_STATE_DIR="$CS_STATE" bash "$FS" "$CS" --closing "$CS/.charles/runs/own-impl" 2>&1)"; impl_status_rc=$?
if [ "$impl_status_rc" -eq 1 ] && grep -q 'ISSUE.*never reviewed' <<<"$impl_status" \
  && grep -q 'NOTE.*run(s) still open' <<<"$impl_status"; then
  echo "  PASS  own ungraded implement stays blocking"; pass=$((pass+1))
else
  echo "  FAIL  own ungraded implement must be the blocking finding (rc=$impl_status_rc)"; fail=$((fail+1))
fi
impl_close="$(CHARLES_STATE_DIR="$CS_STATE" bash "$RS" close "$CS" done --run own-impl 2>&1)"; impl_close_rc=$?
if [ "$impl_close_rc" -eq 5 ] && grep -q 'never reviewed' <<<"$impl_close"; then
  echo "  PASS  close refuses on own ungraded implement"; pass=$((pass+1))
else
  echo "  FAIL  close should refuse on own ungraded implement (rc=$impl_close_rc)"; fail=$((fail+1))
fi

mkdir -p "$CS/.charles/runs/own-plan"
printf '# Run own-plan\n\n- flow: feature\n- spec: docs/specs/own-ungrilled.md\n- started: %s\n- repo: %s\n\n## Phases\n\n- [12:00Z] verify\n\n## Open items\n\n## Rollback\n\n' \
  "$CS_PLAN" "$CS" > "$CS/.charles/runs/own-plan/RUN.md"
plan_status="$(CHARLES_STATE_DIR="$CS_STATE" bash "$FS" "$CS" --closing "$CS/.charles/runs/own-plan" 2>&1)"; plan_status_rc=$?
if [ "$plan_status_rc" -eq 1 ] && grep -q 'ISSUE.*grill verdict' <<<"$plan_status" \
  && grep -q 'NOTE.*never reviewed' <<<"$plan_status" \
  && grep -q 'NOTE.*run(s) still open' <<<"$plan_status"; then
  echo "  PASS  own ungrilled plan is the blocking plan finding"; pass=$((pass+1))
else
  echo "  FAIL  only the closing run's ungrilled plan should block (rc=$plan_status_rc)"; fail=$((fail+1))
fi
plan_close="$(CHARLES_STATE_DIR="$CS_STATE" bash "$RS" close "$CS" done --run own-plan 2>&1)"; plan_close_rc=$?
if [ "$plan_close_rc" -eq 5 ] && grep -q 'grill verdict' <<<"$plan_close"; then
  echo "  PASS  close refuses on own ungrilled spec"; pass=$((pass+1))
else
  echo "  FAIL  close should refuse on own ungrilled spec (rc=$plan_close_rc)"; fail=$((fail+1))
fi

mkdir -p "$CS/.charles/runs/own-midflow"
printf '# Run own-midflow\n\n- flow: feature\n- started: %s\n- repo: %s\n\n## Phases\n\n- [12:00Z] implement-chunk-A\n\n## Open items\n\n## Rollback\n\n' \
  "$CS_MID" "$CS" > "$CS/.charles/runs/own-midflow/RUN.md"
mid_status="$(CHARLES_STATE_DIR="$CS_STATE" bash "$FS" "$CS" --closing "$CS/.charles/runs/own-midflow" 2>&1)"; mid_status_rc=$?
if [ "$mid_status_rc" -eq 1 ] && grep -q 'ISSUE.*died mid-flow' <<<"$mid_status" \
  && grep -q 'NOTE.*never reviewed' <<<"$mid_status" \
  && grep -q 'NOTE.*run(s) still open' <<<"$mid_status"; then
  echo "  PASS  own mid-flow death stays blocking"; pass=$((pass+1))
else
  echo "  FAIL  only the closing run's mid-flow death should block (rc=$mid_status_rc)"; fail=$((fail+1))
fi
mid_close="$(CHARLES_STATE_DIR="$CS_STATE" bash "$RS" close "$CS" done --run own-midflow 2>&1)"; mid_close_rc=$?
if [ "$mid_close_rc" -eq 5 ] && grep -q 'died mid-flow' <<<"$mid_close"; then
  echo "  PASS  close refuses on own mid-flow death"; pass=$((pass+1))
else
  echo "  FAIL  close should refuse on own mid-flow death (rc=$mid_close_rc)"; fail=$((fail+1))
fi

all_status="$(CHARLES_STATE_DIR="$CS_STATE" bash "$FS" "$CS" 2>&1)"; all_status_rc=$?
if [ "$all_status_rc" -eq 1 ] && grep -q 'ISSUE.*orphan' <<<"$all_status" \
  && grep -q 'ISSUE.*never reviewed' <<<"$all_status" \
  && grep -q 'ISSUE.*grill verdict' <<<"$all_status" \
  && grep -q 'ISSUE.*run(s) still open' <<<"$all_status"; then
  echo "  PASS  repo-wide flow status still reports every finding"; pass=$((pass+1))
else
  echo "  FAIL  repo-wide flow status must keep every finding (rc=$all_status_rc)"; fail=$((fail+1))
fi

UC="$BOX/unsourced-close"; mkdir -p "$UC/.charles/runs/unsourced-run"
printf 'green = "true"\n' > "$UC/.charles.toml"
( cd "$UC" && git init -q && git config user.name tester && git config user.email tester@example.invalid && \
  printf 'base\n' > tracked && git add tracked && git commit -qm init ) >/dev/null 2>&1
printf '# Run unsourced-run\n\n- flow: feature\n- started: %s\n- repo: %s\n\n## Phases\n\n- [12:00Z] verify\n\n## Open items\n\n## Rollback\n\n' \
  "$CS_UNSOURCED" "$UC" > "$UC/.charles/runs/unsourced-run/RUN.md"
printf 'unaccounted\n' > "$UC/tracked"
unsourced_status="$(bash "$FS" "$UC" --closing "$UC/.charles/runs/unsourced-run" 2>&1)"; unsourced_status_rc=$?
unsourced_issues="$(grep -c '  ISSUE ' <<<"$unsourced_status" || true)"
if [ "$unsourced_status_rc" -eq 1 ] && [ "$unsourced_issues" -eq 1 ] \
  && grep -q 'ISSUE.*working-tree changes' <<<"$unsourced_status" \
  && ! grep -q 'NOTE.*working-tree changes' <<<"$unsourced_status"; then
  echo "  PASS  unsourced changes remain a blocking close finding"; pass=$((pass+1))
else
  echo "  FAIL  unsourced changes must block even with no attributable flow issue (rc=$unsourced_status_rc)"; fail=$((fail+1))
fi
unsourced_close="$(bash "$RS" close "$UC" done --run unsourced-run 2>&1)"; unsourced_close_rc=$?
if [ "$unsourced_close_rc" -eq 5 ]; then
  echo "  PASS  close refuses on unsourced working-tree changes"; pass=$((pass+1))
else
  echo "  FAIL  close should refuse on unsourced working-tree changes (rc=$unsourced_close_rc)"; fail=$((fail+1))
fi

MISSING_START="$BOX/close-missing-start"; mkdir -p "$MISSING_START/.charles/runs/closing"
printf '# Run closing\n\n- flow: feature\n\n## Phases\n\n- [12:00Z] verify\n\n## Open items\n\n## Rollback\n\n' \
  > "$MISSING_START/.charles/runs/closing/RUN.md"
printf '{"ts":"%s","event":"end","lane":"implement","engine":"luna","model":"m","rc":0,"run":"closing","dir":"%s","task":"own"}\n' \
  "$CS_IMPL" "$MISSING_START" > "$MISSING_START/.charles/dispatches.jsonl"
missing_start_status="$(bash "$FS" "$MISSING_START" --closing "$MISSING_START/.charles/runs/closing" 2>&1)"; missing_start_rc=$?
if [ "$missing_start_rc" -eq 1 ] && grep -q 'ISSUE.*never reviewed' <<<"$missing_start_status" \
  && grep -q 'attribution degraded' <<<"$missing_start_status" \
  && ! grep -q 'NOTE.*never reviewed' <<<"$missing_start_status"; then
  echo "  PASS  missing closing start blocks attribution"; pass=$((pass+1))
else
  echo "  FAIL  missing closing start must block, not note (rc=$missing_start_rc)"; fail=$((fail+1))
fi
printf '# Run closing\n\n- flow: feature\n- started: not-an-iso-timestamp\n\n## Phases\n\n- [12:00Z] verify\n\n## Open items\n\n## Rollback\n\n' \
  > "$MISSING_START/.charles/runs/closing/RUN.md"
malformed_start_status="$(bash "$FS" "$MISSING_START" --closing "$MISSING_START/.charles/runs/closing" 2>&1)"; malformed_start_rc=$?
if [ "$malformed_start_rc" -eq 1 ] && grep -q 'ISSUE.*never reviewed' <<<"$malformed_start_status" \
  && grep -q 'attribution degraded' <<<"$malformed_start_status" \
  && ! grep -q 'NOTE.*never reviewed' <<<"$malformed_start_status"; then
  echo "  PASS  malformed closing start blocks attribution"; pass=$((pass+1))
else
  echo "  FAIL  malformed closing start must block, not note (rc=$malformed_start_rc)"; fail=$((fail+1))
fi

UNREADABLE_START="$BOX/close-unreadable-start"
mkdir -p "$UNREADABLE_START/.charles/runs/closing"
printf '# Run closing\n\n- flow: feature\n- started: %s\n\n## Phases\n\n- [12:00Z] verify\n\n## Open items\n\n## Rollback\n\n' \
  "$CS_CLOSE" > "$UNREADABLE_START/.charles/runs/closing/RUN.md"
printf '{"ts":"%s","event":"end","lane":"implement","engine":"luna","model":"m","rc":0,"run":"closing","dir":"%s","task":"own"}\n' \
  "$CS_IMPL" "$UNREADABLE_START" > "$UNREADABLE_START/.charles/dispatches.jsonl"
if [ "$(id -u)" -eq 0 ]; then
  echo "  SKIP  unreadable closing RUN.md assertion as root"
else
  chmod 000 "$UNREADABLE_START/.charles/runs/closing/RUN.md"
  unreadable_start_status="$(bash "$FS" "$UNREADABLE_START" --closing "$UNREADABLE_START/.charles/runs/closing" 2>&1)"; unreadable_start_rc=$?
  chmod 644 "$UNREADABLE_START/.charles/runs/closing/RUN.md"
  if [ "$unreadable_start_rc" -eq 1 ] && grep -q 'ISSUE.*never reviewed' <<<"$unreadable_start_status" \
    && grep -q 'attribution degraded: closing run RUN.md is missing or unreadable' <<<"$unreadable_start_status" \
    && ! grep -q 'NOTE.*never reviewed' <<<"$unreadable_start_status"; then
    echo "  PASS  unreadable closing RUN.md blocks attribution"; pass=$((pass+1))
  else
    echo "  FAIL  unreadable closing RUN.md must block, not note (rc=$unreadable_start_rc)"; fail=$((fail+1))
  fi
fi

NO_REALPATH="$BOX/close-no-realpath"; NO_REALPATH_BIN="$BOX/no-realpath-bin"
mkdir -p "$NO_REALPATH/.charles/runs/own-plan" "$NO_REALPATH/docs/specs" "$NO_REALPATH_BIN"
printf '# Own ungrilled plan\n' > "$NO_REALPATH/docs/specs/own-ungrilled.md"
printf '# Run own-plan\n\n- flow: feature\n- spec: docs/specs/../specs/own-ungrilled.md\n- started: %s\n\n## Phases\n\n- [12:00Z] implement-chunk-A\n\n## Open items\n\n## Rollback\n\n' \
  "$CS_CLOSE" > "$NO_REALPATH/.charles/runs/own-plan/RUN.md"
printf '{"ts":"%s","event":"start","lane":"explore","run":"foreign-old","dir":"%s","task":"old"}\n' \
  "$CS_OLD" "$NO_REALPATH" > "$NO_REALPATH/.charles/dispatches.jsonl"
for tool in bash dirname sed head jq sort tail grep awk basename date git wc ls; do
  ln -s "$(command -v "$tool")" "$NO_REALPATH_BIN/$tool"
done
no_realpath_status="$(PATH="$NO_REALPATH_BIN" bash "$FS" "$NO_REALPATH" --closing "$NO_REALPATH/.charles/runs/own-plan/../own-plan" 2>&1)"; no_realpath_rc=$?
if [ "$no_realpath_rc" -eq 1 ] && grep -q 'ISSUE.*grill verdict' <<<"$no_realpath_status" \
  && grep -q 'ISSUE.*died mid-flow' <<<"$no_realpath_status" \
  && grep -q 'WARN.*realpath' <<<"$no_realpath_status" \
  && ! grep -q 'NOTE.*grill verdict' <<<"$no_realpath_status" \
  && ! grep -q 'NOTE.*died mid-flow' <<<"$no_realpath_status"; then
  echo "  PASS  non-canonical early and late findings block without realpath"; pass=$((pass+1))
else
  echo "  FAIL  unavailable realpath must fail closed for own paths (rc=$no_realpath_rc)"; fail=$((fail+1))
fi
if grep -q 'ISSUE.*orphan' <<<"$no_realpath_status" \
  && ! grep -q 'NOTE.*orphan' <<<"$no_realpath_status"; then
  echo "  PASS  early unavailable-realpath finding matches later classification"; pass=$((pass+1))
else
  echo "  FAIL  unavailable realpath must classify early findings consistently"; fail=$((fail+1))
fi
if [ "$no_realpath_rc" -ne 0 ] \
  && grep -q 'WARN.*realpath is unavailable for non-identical path attribution' <<<"$no_realpath_status"; then
  echo "  PASS  degraded attribution blocks the non-canonical close"; pass=$((pass+1))
else
  echo "  FAIL  degraded attribution must block the non-canonical close (rc=$no_realpath_rc)"; fail=$((fail+1))
fi

# --- flow graph lookup -------------------------------------------------------
FG="$BOX/flow-graph"; mkdir -p "$FG"
bash "$RS" init "$FG" feature "prefix mapping" >/dev/null 2>&1
bash "$RS" phase "$FG" "implement-chunk-A" >/dev/null 2>"$FG/prefix.err"
prefix_show="$(bash "$RS" show "$FG" 2>"$FG/prefix-show.err")"
if grep -q 'next expected: review' <<<"$prefix_show"; then
  echo "  PASS  prefixed implement phase expects review"; pass=$((pass+1))
else
  echo "  FAIL  prefixed implement phase should expect review"; fail=$((fail+1))
fi

UNKNOWN="$BOX/flow-unknown"; mkdir -p "$UNKNOWN"
bash "$RS" init "$UNKNOWN" debug "unknown phase" >/dev/null 2>&1
unknown_stdout="$(bash "$RS" phase "$UNKNOWN" "mystery-step" 2>"$UNKNOWN/phase.err")"
unknown_show="$(bash "$RS" show "$UNKNOWN" 2>/dev/null)"
if grep -qi 'WARN.*unmapped' "$UNKNOWN/phase.err"; then
  echo "  PASS  unknown phase warns on stderr"; pass=$((pass+1))
else
  echo "  FAIL  unknown phase should warn on stderr"; fail=$((fail+1))
fi
if grep -q 'mystery-step' <<<"$unknown_stdout$unknown_show"; then
  echo "  PASS  unknown phase is still recorded"; pass=$((pass+1))
else
  echo "  FAIL  unknown phase should still be recorded"; fail=$((fail+1))
fi

TERMINAL="$BOX/flow-terminal"; mkdir -p "$TERMINAL"
bash "$RS" init "$TERMINAL" feature "terminal phase" >/dev/null 2>&1
bash "$RS" phase "$TERMINAL" verify >/dev/null 2>&1
terminal_show="$(bash "$RS" show "$TERMINAL" 2>/dev/null)"
if grep -q 'next expected: close' <<<"$terminal_show"; then
  echo "  PASS  terminal phase expects close"; pass=$((pass+1))
else
  echo "  FAIL  terminal phase should expect close"; fail=$((fail+1))
fi

FIRST="$BOX/flow-first"; mkdir -p "$FIRST"
bash "$RS" init "$FIRST" polish "first phase" >/dev/null 2>&1
first_show="$(bash "$RS" show "$FIRST" 2>/dev/null)"
if grep -q 'next expected: explore' <<<"$first_show"; then
  echo "  PASS  no-phase run expects the flow first phase"; pass=$((pass+1))
else
  echo "  FAIL  no-phase run should expect the flow first phase"; fail=$((fail+1))
fi

MID="$BOX/flow-mid"; mkdir -p "$MID"
bash "$RS" init "$MID" feature "mid-flow run" >/dev/null 2>&1
bash "$RS" phase "$MID" "implement-chunk-A" >/dev/null 2>&1
mid_out="$(bash "$FS" "$MID" 2>&1)"; mid_rc=$?
if [ "$mid_rc" -eq 1 ] && grep -q 'ISSUE.*died mid-flow at implement' <<<"$mid_out" \
  && grep -q 'expected next: review' <<<"$mid_out"; then
  echo "  PASS  open mapped mid-flow run is an ISSUE with its next phase"; pass=$((pass+1))
else
  echo "  FAIL  open mapped mid-flow run should be an ISSUE (rc=$mid_rc)"; fail=$((fail+1))
fi

UNKNOWN_FLOW="$BOX/flow-unknown-name"; mkdir -p "$UNKNOWN_FLOW"
bash "$RS" init "$UNKNOWN_FLOW" mystery-flow "unknown flow" >/dev/null 2>&1
unknown_flow_status="$(bash "$FS" "$UNKNOWN_FLOW" 2>&1)"; unknown_flow_rc=$?
if [ "$unknown_flow_rc" -eq 1 ] \
  && grep -q 'run .*last phase: (none) | expected next: (no guidance)' <<<"$unknown_flow_status"; then
  echo "  PASS  unknown flow still gets a no-guidance status line"; pass=$((pass+1))
else
  echo "  FAIL  unknown flow must still get a no-guidance status line (rc=$unknown_flow_rc)"; fail=$((fail+1))
fi

NOFLOW="$BOX/no-flow"; mkdir -p "$NOFLOW/scripts"
cp "$RS" "$NOFLOW/scripts/run-state.sh"
cp "$(dirname "$RS")/run-common.sh" "$NOFLOW/scripts/run-common.sh"
cp "$FS" "$NOFLOW/scripts/flow-status.sh"
chmod +x "$NOFLOW/scripts/run-state.sh" "$NOFLOW/scripts/run-common.sh" "$NOFLOW/scripts/flow-status.sh"
bash "$NOFLOW/scripts/run-state.sh" init "$NOFLOW" feature "missing graph" >/dev/null 2>&1
noflow_phase="$(bash "$NOFLOW/scripts/run-state.sh" phase "$NOFLOW" mystery 2>"$NOFLOW/phase.err")"
noflow_show="$(bash "$NOFLOW/scripts/run-state.sh" show "$NOFLOW" 2>"$NOFLOW/show.err")"
noflow_status="$(bash "$NOFLOW/scripts/flow-status.sh" "$NOFLOW" 2>"$NOFLOW/status.err")" || true
if ! grep -qi 'WARN' <<<"$noflow_phase$noflow_show$noflow_status" \
  && grep -qi 'WARN' "$NOFLOW/phase.err" \
  && grep -qi 'WARN' "$NOFLOW/show.err" \
  && grep -qi 'WARN' "$NOFLOW/status.err" \
  && grep -q 'expected next: (no guidance)' <<<"$noflow_status"; then
  echo "  PASS  absent flow graph degrades on stdout and warns on stderr"; pass=$((pass+1))
else
  echo "  FAIL  absent flow graph should warn only on stderr"; fail=$((fail+1))
fi

# --- read-only cross-repo run sweep -------------------------------------------
SWEEP="$(cd "$(dirname "$0")/.." && pwd)/scripts/runs-sweep.sh"
SW="$BOX/sweep"; mkdir -p "$SW/root/fixture-repo/.charles/runs/mapped-run" \
  "$SW/root/fixture-repo/.charles/runs/fallback-run" \
  "$SW/root/fixture-repo/.charles/runs/closed-run" \
  "$SW/root/fixture-repo/.charles/runs/unreadable-run" \
  "$SW/env-root/env-repo/.charles/runs/env-run"
printf 'green = "true"\n' > "$SW/root/fixture-repo/.charles.toml"
printf 'green = "true"\n' > "$SW/env-root/env-repo/.charles.toml"
printf '# Run env-run\n\n- flow: feature\n\n## Phases\n\n## Open items\n\n## Rollback\n\n' \
  > "$SW/env-root/env-repo/.charles/runs/env-run/RUN.md"
mapped_started="$(date -u -d '3 days ago' +%Y-%m-%dT%H:%M:%SZ)"
printf '# Run mapped-run\n\n- flow: feature\n- goal: sweep\n- started: %s\n\n## Phases\n\n- [12:00Z] implement-chunk-C\n  ```\n- [99:99Z] proof-suffix\n  ```\n\n## Open items\n\n- [ ] **FAILED** — one\n- [ ] **PENDING-DECISION** — two\n\n## Rollback\n\n' \
  "$mapped_started" > "$SW/root/fixture-repo/.charles/runs/mapped-run/RUN.md"
printf '# Run fallback-run\n\n- flow: feature\n- goal: fallback\n\n## Phases\n\n- [12:00Z] mystery-step\n\n## Open items\n\n## Rollback\n\n' \
  > "$SW/root/fixture-repo/.charles/runs/fallback-run/RUN.md"
touch -d '5 days ago' "$SW/root/fixture-repo/.charles/runs/fallback-run/RUN.md"
printf '# Run closed-run\n\n- flow: feature\n- started: %s\n\n## Outcome\n\ndone\n' \
  "$mapped_started" > "$SW/root/fixture-repo/.charles/runs/closed-run/RUN.md"
UNREADABLE_RUN="$SW/root/fixture-repo/.charles/runs/unreadable-run/RUN.md"
printf '# Run unreadable-run\n\n- flow: feature\n\n## Phases\n\n## Open items\n\n## Rollback\n\n' > "$UNREADABLE_RUN"
if [ "$(id -u)" -eq 0 ]; then
  echo "  SKIP  unreadable RUN.md assertion as root"
else
  chmod 000 "$UNREADABLE_RUN"
  unreadable_out="$(bash "$SWEEP" "$SW/root" 2>&1)"; unreadable_rc=$?
  chmod 644 "$UNREADABLE_RUN"
  if [ "$unreadable_rc" -eq 0 ] && grep -q 'unreadable:.*unreadable-run' <<<"$unreadable_out"; then
    echo "  PASS  sweep reports an unreadable RUN.md"; pass=$((pass+1))
  else
    echo "  FAIL  sweep must report an unreadable RUN.md (rc=$unreadable_rc)"; fail=$((fail+1))
  fi
fi
missing_root="$SW/missing-root"
sweep_before="$(find "$SW/root" -type f -printf '%P %T@ %s\n' | sort)"
sweep_out="$(CHARLES_SWEEP_ROOTS="$SW/env-root" bash "$SWEEP" "$missing_root" "$SW/root" 2>"$SW/args.err")"; sweep_rc=$?
sweep_after="$(find "$SW/root" -type f -printf '%P %T@ %s\n' | sort)"
if [ "$sweep_rc" -eq 0 ] && grep -qF "root not found: $missing_root" <<<"$sweep_out" \
  && ! grep -q 'env-repo' <<<"$sweep_out"; then
  echo "  PASS  sweep args override env and missing roots stay non-fatal"; pass=$((pass+1))
else
  echo "  FAIL  sweep must prefer args and report missing roots (rc=$sweep_rc)"; fail=$((fail+1))
fi
if grep -qF 'fixture-repo · mapped-run · 3 · 2 · implement-chunk-C → review' <<<"$sweep_out" \
  && grep -qF 'fixture-repo · fallback-run · 5 · 0 · mystery-step → (unmapped)' <<<"$sweep_out" \
  && ! grep -q 'closed-run' <<<"$sweep_out"; then
  echo "  PASS  sweep reports started/mtime ages, items, and expected phases"; pass=$((pass+1))
else
  echo "  FAIL  sweep format or age/phase lookup is wrong"; fail=$((fail+1))
fi
sweep_flow_out="$(bash "$FS" "$SW/root/fixture-repo" 2>&1 || true)"
if grep -q 'run mapped-run: last phase: implement-chunk-C' <<<"$sweep_flow_out" \
  && ! grep -q 'proof-suffix' <<<"$sweep_out$sweep_flow_out"; then
  echo "  PASS  flow status and sweep ignore proof content when finding the phase"; pass=$((pass+1))
else
  echo "  FAIL  proof content must not become the displayed phase"; fail=$((fail+1))
fi
if [ "$sweep_before" = "$sweep_after" ]; then
  echo "  PASS  sweep is read-only"; pass=$((pass+1))
else
  echo "  FAIL  sweep changed its fixture"; fail=$((fail+1))
fi
sweep_env_out="$(CHARLES_SWEEP_ROOTS="$SW/root:$SW/env-root" bash "$SWEEP" 2>"$SW/env.err")"
if grep -q 'fixture-repo' <<<"$sweep_env_out" && grep -q 'env-repo' <<<"$sweep_env_out"; then
  echo "  PASS  sweep accepts colon-separated roots from env"; pass=$((pass+1))
else
  echo "  FAIL  sweep must scan colon-separated env roots"; fail=$((fail+1))
fi

# --- R8 reopen and abandon ----------------------------------------------------
# These are real run-state fixtures; no Codex lane is invoked.
R8="$BOX/r8-reopen-abandon"; mkdir -p "$R8/reopen/docs/specs" "$R8/status/docs/specs"
printf 'green = "true"\n' > "$R8/reopen/.charles.toml"
printf 'green = "true"\n' > "$R8/status/.charles.toml"
printf '# R8 plan\n\n## Grill verdict\n\n- Rounds: 1\n' > "$R8/reopen/docs/specs/plan.md"
r8_reopen_id="$(bash "$RS" init "$R8/reopen" feature "reopen history" --spec docs/specs/plan.md 2>/dev/null)"
bash "$RS" close "$R8/reopen" "finished before reopen" --run "$r8_reopen_id" \
  --spec docs/specs/plan.md --force >/dev/null 2>&1
r8_reopen_md="$R8/reopen/.charles/runs/$r8_reopen_id/RUN.md"
r8_reopen_out="$(bash "$RS" reopen "$R8/reopen" --run "$r8_reopen_id" 2>&1)"; r8_reopen_rc=$?
if [ "$r8_reopen_rc" -eq 0 ] && ! grep -q '^## Outcome' "$r8_reopen_md" \
  && grep -q '^## Previous outcome' "$r8_reopen_md" \
  && grep -q 'finished before reopen' "$r8_reopen_md" \
  && grep -q '^## Run outcome' "$R8/reopen/docs/specs/plan.md" \
  && grep -q 'finished before reopen' "$R8/reopen/docs/specs/plan.md" \
  && grep -qF 'previous outcome preserved' <<<"$r8_reopen_out"; then
  echo "  PASS  reopen reopens the run and preserves RUN.md/spec history"; pass=$((pass+1))
else
  echo "  FAIL  reopen must reopen and preserve both outcome records (rc=$r8_reopen_rc)"; fail=$((fail+1))
fi
r8_open_out="$(bash "$RS" reopen "$R8/reopen" --run "$r8_reopen_id" 2>&1)"; r8_open_rc=$?
if [ "$r8_open_rc" -eq 8 ] && grep -q 'already open' <<<"$r8_open_out"; then
  echo "  PASS  reopen refuses an already-open run with exit 8"; pass=$((pass+1))
else
  echo "  FAIL  reopen must refuse an already-open run with exit 8 (rc=$r8_open_rc)"; fail=$((fail+1))
fi
r8_unknown_out="$(bash "$RS" reopen "$R8/reopen" --run no-such-r8-run 2>&1)"; r8_unknown_rc=$?
if [ "$r8_unknown_rc" -eq 7 ] && grep -q 'unknown run id' <<<"$r8_unknown_out"; then
  echo "  PASS  reopen refuses an unknown run id with exit 7"; pass=$((pass+1))
else
  echo "  FAIL  reopen must refuse an unknown run id with exit 7 (rc=$r8_unknown_rc)"; fail=$((fail+1))
fi

printf '# R8 status plan\n\n## Grill verdict\n\n- Rounds: 1\n' > "$R8/status/docs/specs/plan.md"
r8_abandon_id="$(bash "$RS" init "$R8/status" feature "abandon report" --spec docs/specs/plan.md 2>/dev/null)"
r8_abandon_out="$(bash "$RS" abandon "$R8/status" --run "$r8_abandon_id" \
  "lane died at phase 3" 2>&1)"; r8_abandon_rc=$?
r8_abandon_md="$R8/status/.charles/runs/$r8_abandon_id/RUN.md"
if [ "$r8_abandon_rc" -eq 0 ] && grep -q '^## Outcome$' "$r8_abandon_md" \
  && grep -q '^ABANDONED$' "$r8_abandon_md" \
  && grep -q '^## Abandoned$' "$r8_abandon_md" \
  && grep -q 'lane died at phase 3' "$r8_abandon_md" \
  && grep -q 'ABANDONED' "$R8/status/docs/specs/plan.md"; then
  echo "  PASS  abandon writes an ABANDONED outcome and reason"; pass=$((pass+1))
else
  echo "  FAIL  abandon must write an ABANDONED outcome (rc=$r8_abandon_rc)"; fail=$((fail+1))
fi

r8_finished_id="$(bash "$RS" init "$R8/status" feature "finished report" 2>/dev/null)"
bash "$RS" close "$R8/status" "finished" --run "$r8_finished_id" --force >/dev/null 2>&1
r8_finished_md="$R8/status/.charles/runs/$r8_finished_id/RUN.md"
cp "$r8_finished_md" "$R8/finished.before"
r8_closed_out="$(bash "$RS" abandon "$R8/status" --run "$r8_finished_id" "too late" 2>&1)"; r8_closed_rc=$?
if [ "$r8_closed_rc" -eq 9 ] && grep -q 'already closed' <<<"$r8_closed_out" \
  && cmp -s "$r8_finished_md" "$R8/finished.before"; then
  echo "  PASS  abandon refuses a closed run with exit 9"; pass=$((pass+1))
else
  echo "  FAIL  abandon must refuse a closed run with exit 9 (rc=$r8_closed_rc)"; fail=$((fail+1))
fi
r8_abandon_again_out="$(bash "$RS" abandon "$R8/status" --run "$r8_abandon_id" "again" 2>&1)"; r8_abandon_again_rc=$?
if [ "$r8_abandon_again_rc" -eq 9 ]; then
  echo "  PASS  abandon refuses an already-ABANDONED run"; pass=$((pass+1))
else
  echo "  FAIL  abandon must refuse an already-ABANDONED run (rc=$r8_abandon_again_rc)"; fail=$((fail+1))
fi

r8_show_out="$(bash "$RS" show "$R8/status" --list 2>&1)"
if grep -q "^ABANDONED $r8_abandon_id$" <<<"$r8_show_out" \
  && grep -q "^closed $r8_finished_id$" <<<"$r8_show_out" \
  && ! grep -q "^ABANDONED $r8_finished_id$" <<<"$r8_show_out"; then
  echo "  PASS  run-state show distinguishes ABANDONED from closed"; pass=$((pass+1))
else
  echo "  FAIL  run-state show must distinguish ABANDONED from closed"; fail=$((fail+1))
fi
r8_flow_out="$(bash "$FS" "$R8/status" 2>&1)"; r8_flow_rc=$?
if [ "$r8_flow_rc" -eq 0 ] && grep -q 'ABANDONED' <<<"$r8_flow_out" \
  && grep -q 'no runs left open' <<<"$r8_flow_out" \
  && ! grep -q 'still open' <<<"$r8_flow_out"; then
  echo "  PASS  flow-status reports ABANDONED and counts no open run"; pass=$((pass+1))
else
  echo "  FAIL  flow-status must report ABANDONED without an open-run issue (rc=$r8_flow_rc)"; fail=$((fail+1))
fi
r8_sweep_out="$(bash "$SWEEP" "$R8" 2>&1)"; r8_sweep_rc=$?
if [ "$r8_sweep_rc" -eq 0 ] && grep -q 'status.*ABANDONED' <<<"$r8_sweep_out"; then
  echo "  PASS  runs-sweep reports ABANDONED distinctly"; pass=$((pass+1))
else
  echo "  FAIL  runs-sweep must report ABANDONED distinctly (rc=$r8_sweep_rc)"; fail=$((fail+1))
fi

R8_PLUGIN="$R8/plugin"; R8_HOME="$R8/home"
mkdir -p "$R8_PLUGIN/.claude-plugin" "$R8_PLUGIN/scripts" "$R8_HOME"
printf '{"version":"fixture"}\n' > "$R8_PLUGIN/.claude-plugin/plugin.json"
printf '#!/usr/bin/env bash\nexit 0\n' > "$R8_PLUGIN/scripts/codex-run.sh"
chmod +x "$R8_PLUGIN/scripts/codex-run.sh"
r8_link_out="$(cd "$R8/status" && HOME="$R8_HOME" CLAUDE_PLUGIN_ROOT="$R8_PLUGIN" bash "$LINK" 2>&1)"
if grep -q 'ABANDONED' <<<"$r8_link_out" && ! grep -q 'open run(s)' <<<"$r8_link_out"; then
  echo "  PASS  SessionStart notice reports ABANDONED outside open count"; pass=$((pass+1))
else
  echo "  FAIL  SessionStart notice must distinguish ABANDONED (output: $r8_link_out)"; fail=$((fail+1))
fi
r8_warn_out="$(cd "$R8/status" && bash "$WARN" 2>&1)"
if grep -q 'ABANDONED' <<<"$r8_warn_out" && ! grep -q 'FAILED item' <<<"$r8_warn_out"; then
  echo "  PASS  Stop hook reports ABANDONED without a FAILED warning"; pass=$((pass+1))
else
  echo "  FAIL  Stop hook must distinguish ABANDONED (output: $r8_warn_out)"; fail=$((fail+1))
fi

# --- doctor drift classes -----------------------------------------------------
DOCTOR="$(cd "$(dirname "$0")/.." && pwd)/scripts/doctor.sh"
DD="$BOX/doctor-drift"; mkdir -p "$DD/bin" "$DD/repo/scripts" "$DD/repo/docs/specs" \
  "$DD/repo/.claude-plugin" "$DD/home/.codex" "$DD/home/.config/lg-cc-deepseek" \
  "$DD/home/.claude/skills/codex-deepseek/scripts"
printf 'green = "true"\n' > "$DD/repo/.charles.toml"
printf '{"version":"fixture"}\n' > "$DD/repo/.claude-plugin/plugin.json"
cp "$DOCTOR" "$DD/repo/scripts/doctor.sh"
cp "$FS" "$DD/repo/scripts/flow-status.sh"
cp "$REPO_ROOT/scripts/flow.json" "$DD/repo/scripts/flow.json"
printf '#!/usr/bin/env bash\nexit 0\n' > "$DD/repo/scripts/codex-run.sh"
chmod +x "$DD/repo/scripts/doctor.sh" "$DD/repo/scripts/flow-status.sh" "$DD/repo/scripts/codex-run.sh"
printf 'current\n' > "$DD/repo/docs/specs/plan.md"
DRIFT_CACHE="$DD/home/.claude/plugins/cache/charlesdr-dev-loop/charlesdr-dev-loop/fixture"
mkdir -p "$DRIFT_CACHE/docs/specs" "$DRIFT_CACHE/scripts"
printf 'installed\n' > "$DRIFT_CACHE/docs/specs/plan.md"
cp "$DD/repo/scripts/codex-run.sh" "$DRIFT_CACHE/scripts/codex-run.sh"
ln -s "$DRIFT_CACHE/scripts/codex-run.sh" "$DD/bin/codex-run"
for tool in codex treehouse tasks-axi; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$DD/bin/$tool"
  chmod +x "$DD/bin/$tool"
done
touch "$DD/home/.codex/luna.config.toml" "$DD/home/.codex/terra.config.toml" \
  "$DD/home/.codex/deepseek.config.toml" "$DD/home/.config/lg-cc-deepseek/key.env"
printf 'model = "gpt-5.6-sol"\n' > "$DD/home/.codex/config.toml"
printf '#!/usr/bin/env bash\nexit 0\n' > "$DD/home/.claude/skills/codex-deepseek/scripts/codex-ds.sh"
chmod +x "$DD/home/.claude/skills/codex-deepseek/scripts/codex-ds.sh"
doctor_spec_out="$(cd "$DD/repo" && HOME="$DD/home" PATH="$DD/bin:$PATH" bash scripts/doctor.sh 2>&1)"; doctor_spec_rc=$?
if [ "$doctor_spec_rc" -eq 0 ] && grep -q 'WARN.*docs/specs' <<<"$doctor_spec_out" \
  && ! grep -q '^  FAIL' <<<"$doctor_spec_out"; then
  echo "  PASS  doctor downgrades docs/specs drift to WARN"; pass=$((pass+1))
else
  echo "  FAIL  docs/specs-only drift must not fail doctor (rc=$doctor_spec_rc)"; fail=$((fail+1))
fi
printf 'current\n' > "$DD/repo/scripts/other.sh"
printf 'installed\n' > "$DRIFT_CACHE/scripts/other.sh"
doctor_other_out="$(cd "$DD/repo" && HOME="$DD/home" PATH="$DD/bin:$PATH" CHARLES_RELEASING=0 bash scripts/doctor.sh 2>&1)"; doctor_other_rc=$?
if [ "$doctor_other_rc" -ne 0 ] && grep -q '^  FAIL.*non-spec' <<<"$doctor_other_out"; then
  echo "  PASS  doctor keeps non-spec drift as FAIL"; pass=$((pass+1))
else
  echo "  FAIL  non-spec drift must fail doctor (rc=$doctor_other_rc)"; fail=$((fail+1))
fi

mkdir -p "$DD/repo/.charles/runs/open-run"
printf '# Run open-run\n\n- flow: feature\n\n## Phases\n\n## Open items\n\n## Rollback\n\n' \
  > "$DD/repo/.charles/runs/open-run/RUN.md"
printf '{"ts":"%s","lane":"implement","engine":"luna","model":"m","rc":0,"run":"open-impl","dir":"%s","task":"t"}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$DD/repo" > "$DD/repo/.charles/dispatches.jsonl"
doctor_open_out="$(cd "$DD/repo" && HOME="$DD/home" PATH="$DD/bin:$PATH" CHARLES_RELEASING=0 bash scripts/doctor.sh 2>&1)"; doctor_open_rc=$?
if [ "$doctor_open_rc" -ne 0 ] \
  && grep -q 'WARN.*non-spec' <<<"$doctor_open_out" \
  && grep -q '^  FAIL.*never reviewed' <<<"$doctor_open_out"; then
  echo "  PASS  open-run doctor warns on drift but fails on unreviewed implement"; pass=$((pass+1))
else
  echo "  FAIL  open-run doctor severity must split drift WARN and review FAIL (rc=$doctor_open_rc)"; fail=$((fail+1))
fi

rm -f "$DD/bin/codex-run"
ln -s "$DD/repo/scripts/codex-run.sh" "$DD/bin/codex-run"
doctor_target_open_out="$(cd "$DD/repo" && HOME="$DD/home" PATH="$DD/bin:$PATH" CHARLES_RELEASING=0 bash scripts/doctor.sh 2>&1)"; doctor_target_open_rc=$?
if [ "$doctor_target_open_rc" -ne 0 ] \
  && grep -q '^  FAIL.*codex-run points at' <<<"$doctor_target_open_out"; then
  echo "  PASS  open-run doctor keeps dispatcher-target drift as FAIL"; pass=$((pass+1))
else
  echo "  FAIL  dispatcher-target drift must remain FAIL while a run is open (rc=$doctor_target_open_rc)"; fail=$((fail+1))
fi

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

make_unsourced_repo() {
  local dir="$1"
  mkdir -p "$dir/.charles"
  ( cd "$dir" && git init -q && git config user.name tester && git config user.email tester@example.invalid &&
    printf 'base\n' > tracked && git add tracked && git commit -qm init ) >/dev/null 2>&1
}

US_CLEAN="$BOX/unsourced-clean-dead"; make_unsourced_repo "$US_CLEAN"
US_OLD="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","event":"start","lane":"implement","run":"dead-clean","dir":"%s","task":"t"}\n' \
  "$US_OLD" "$US_CLEAN" > "$US_CLEAN/.charles/dispatches.jsonl"
clean_orphan_out="$(CHARLES_STATE_DIR="$US_CLEAN/state" bash "$US" "$US_CLEAN" 2>&1)"; clean_orphan_rc=$?
if [ "$clean_orphan_rc" -eq 0 ] && grep -q 'ORPHAN: dead-clean' <<<"$clean_orphan_out" \
  && grep -q 'clean tree — nothing to account for' <<<"$clean_orphan_out"; then
  echo "  PASS  clean tree with dead orphan exits 0 and reports the orphan"; pass=$((pass+1))
else
  echo "  FAIL  clean dead orphan should be visible but non-blocking (rc=$clean_orphan_rc)"; fail=$((fail+1))
fi

US_FLIGHT="$BOX/unsourced-clean-inflight"; make_unsourced_repo "$US_FLIGHT"
printf '{"ts":"%s","event":"start","lane":"implement","run":"inflight-orphan","dir":"%s","task":"t"}\n' \
  "$US_OLD" "$US_FLIGHT" > "$US_FLIGHT/.charles/dispatches.jsonl"
bash -c 'while sleep 1; do :; done' inflight-orphan & flight_pid=$!
sleep 0.1
US_FLIGHT_STATE="$US_FLIGHT/state"; US_FLIGHT_PID_FILE="$US_FLIGHT_STATE/inflight-orphan.child.1"
mkdir -p "$US_FLIGHT_STATE"
printf '1|luna|m|||%s\n' "$US_FLIGHT_PID_FILE" > "$US_FLIGHT_STATE/inflight-orphan.watchdog.state"
printf '%s\n' "$flight_pid" > "$US_FLIGHT_PID_FILE"
flight_out="$(CHARLES_STATE_DIR="$US_FLIGHT/state" bash "$US" "$US_FLIGHT" 2>&1)"; flight_rc=$?
kill "$flight_pid" 2>/dev/null || true; wait "$flight_pid" 2>/dev/null || true
if [ "$flight_rc" -eq 3 ] && grep -q 'ORPHAN: inflight-orphan — lane in flight' <<<"$flight_out"; then
  echo "  PASS  clean tree with in-flight orphan exits 3"; pass=$((pass+1))
else
  echo "  FAIL  in-flight orphan must block a clean tree (rc=$flight_rc)"; fail=$((fail+1))
fi

US_DIRTY="$BOX/unsourced-dirty-dead"; make_unsourced_repo "$US_DIRTY"
printf 'changed\n' > "$US_DIRTY/tracked"
printf '{"ts":"%s","event":"start","lane":"implement","run":"dead-dirty","dir":"%s","task":"t"}\n' \
  "$US_OLD" "$US_DIRTY" > "$US_DIRTY/.charles/dispatches.jsonl"
dirty_orphan_out="$(CHARLES_STATE_DIR="$US_DIRTY/state" bash "$US" "$US_DIRTY" 2>&1)"; dirty_orphan_rc=$?
if [ "$dirty_orphan_rc" -eq 3 ] && grep -q 'ORPHAN: dead-dirty' <<<"$dirty_orphan_out"; then
  echo "  PASS  dirty tree with dead orphan still exits 3"; pass=$((pass+1))
else
  echo "  FAIL  dirty dead orphan must remain blocking (rc=$dirty_orphan_rc)"; fail=$((fail+1))
fi

US_TOCTOU="$BOX/unsourced-toctou"; make_unsourced_repo "$US_TOCTOU"
TOCTOU_BIN="$BOX/unsourced-toctou-bin"; mkdir -p "$TOCTOU_BIN"
TOCTOU_REAL_GIT="$(command -v git)"; TOCTOU_COUNT="$US_TOCTOU/.charles/status-count"
printf '%s\n' '#!/usr/bin/env bash' \
  'if [ "${1:-}" = "-C" ] && [ "${3:-}" = "status" ]; then' \
  '  n="$(cat "$TOCTOU_COUNT" 2>/dev/null || echo 0)"' \
  '  n=$((n + 1)); printf "%s\\n" "$n" > "$TOCTOU_COUNT"' \
  '  [ "$n" -eq 2 ] && printf "changed\\n" > "$TOCTOU_REPO/tracked"' \
  'fi' \
  'exec "$TOCTOU_REAL_GIT" "$@"' > "$TOCTOU_BIN/git"
chmod +x "$TOCTOU_BIN/git"
printf '{"ts":"%s","event":"start","lane":"implement","run":"dead-toctou","dir":"%s","task":"t"}\n' \
  "$US_OLD" "$US_TOCTOU" > "$US_TOCTOU/.charles/dispatches.jsonl"
toctou_out="$(TOCTOU_REPO="$US_TOCTOU" TOCTOU_COUNT="$TOCTOU_COUNT" TOCTOU_REAL_GIT="$TOCTOU_REAL_GIT" \
  PATH="$TOCTOU_BIN:$PATH" CHARLES_STATE_DIR="$US_TOCTOU/state" bash "$US" "$US_TOCTOU" 2>&1)"; toctou_rc=$?
if [ "$toctou_rc" -eq 3 ] && [ "$(cat "$US_TOCTOU/tracked")" = "changed" ] \
  && grep -q 'ORPHAN: dead-toctou' <<<"$toctou_out"; then
  echo "  PASS  changes made during orphan probing are recounted"; pass=$((pass+1))
else
  echo "  FAIL  orphan probing must recount changes made during the probe (rc=$toctou_rc)"; fail=$((fail+1))
fi

US_FRESH="$BOX/unsourced-fresh"; make_unsourced_repo "$US_FRESH"
fresh_log_out="$(CHARLES_STATE_DIR="$US_FRESH/state" bash "$US" "$US_FRESH" 2>&1)"; fresh_log_rc=$?
if [ "$fresh_log_rc" -eq 0 ] && grep -q 'clean tree — nothing to account for' <<<"$fresh_log_out" \
  && ! grep -q 'cannot read or parse' <<<"$fresh_log_out"; then
  echo "  PASS  fresh clean repo with no dispatch log exits 0"; pass=$((pass+1))
else
  echo "  FAIL  fresh clean repo with no dispatch log should exit 0 (rc=$fresh_log_rc)"; fail=$((fail+1))
fi

US_BAD="$BOX/unsourced-bad-log"; make_unsourced_repo "$US_BAD"
printf '{not json\n' > "$US_BAD/.charles/dispatches.jsonl"
bad_log_out="$(CHARLES_STATE_DIR="$US_BAD/state" bash "$US" "$US_BAD" 2>&1)"; bad_log_rc=$?
if [ "$bad_log_rc" -eq 3 ] && grep -q 'ORPHAN CENSUS IMPOSSIBLE: cannot read or parse' <<<"$bad_log_out"; then
  echo "  PASS  clean tree with unparseable dispatch log exits 3"; pass=$((pass+1))
else
  echo "  FAIL  existing unparseable dispatch log should exit 3 (rc=$bad_log_rc)"; fail=$((fail+1))
fi

mkdir -p "$US_CLEAN/.charles/runs/closing"
printf '# Run closing\n\n- flow: feature\n- started: %s\n- repo: %s\n\n## Phases\n\n## Open items\n\n## Rollback\n\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$US_CLEAN" > "$US_CLEAN/.charles/runs/closing/RUN.md"
flow_clean_out="$(CHARLES_STATE_DIR="$US_CLEAN/state" bash "$REPO_ROOT/scripts/flow-status.sh" \
  "$US_CLEAN" --closing "$US_CLEAN/.charles/runs/closing" 2>&1)"; flow_clean_rc=$?
if [ "$flow_clean_rc" -eq 0 ] && grep -q 'flow complete: nothing outstanding' <<<"$flow_clean_out" \
  && ! grep -q 'ISSUE.*working-tree changes' <<<"$flow_clean_out"; then
  echo "  PASS  closing audit does not block on a clean dead orphan"; pass=$((pass+1))
else
  echo "  FAIL  clean dead orphan must not create a closing ISSUE (rc=$flow_clean_rc)"; fail=$((fail+1))
fi

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

# R8: the local weekly quota disables fast_mode only once 20% remains.
R8="$BOX/r8-sessions"
for r8_case in 85 28; do
  mkdir -p "$R8/$r8_case/2026/08/28"
  printf '{"rate_limits":{"primary":{"used_percent":%s,"window_minutes":10080}}}\n' "$r8_case" \
    > "$R8/$r8_case/2026/08/28/rollout-$r8_case.jsonl"
done
mkdir -p "$R8/empty/2026/08/28"
for r8_case in 85 28 empty; do
  case "$r8_case" in 85) r8_expected=disable ;; *) r8_expected=enable ;; esac
  PATH="$ED/bin:$PATH" CHARLES_STATE_DIR="$ED" CHARLES_CODEX_SESSIONS_DIR="$R8/$r8_case" \
    bash "$RUN_SH" --lane implement --engine luna --dir "$ED" --timeout 5 "t" >/dev/null 2>&1
  if grep -q -- "--$r8_expected fast_mode" "$ED/args.txt" 2>/dev/null; then
    echo "  PASS  R8 luna $r8_case% used_percent selects --$r8_expected fast_mode"; pass=$((pass+1))
  else
    echo "  FAIL  R8 luna $r8_case% used_percent must select --$r8_expected fast_mode"; fail=$((fail+1))
  fi

  PATH="$ED/bin:$PATH" CHARLES_STATE_DIR="$ED" CHARLES_CODEX_SESSIONS_DIR="$R8/$r8_case" \
    bash "$RUN_SH" --lane implement --engine terra --dir "$ED" --timeout 5 "t" >/dev/null 2>&1
  if grep -q -- '--disable fast_mode' "$ED/args.txt" 2>/dev/null; then
    echo "  PASS  R8 terra $r8_case% used_percent keeps --disable fast_mode"; pass=$((pass+1))
  else
    echo "  FAIL  R8 terra must keep --disable fast_mode ($r8_case% fixture)"; fail=$((fail+1))
  fi
done

out="$(PATH="$ED/bin:$PATH" CHARLES_STATE_DIR="$ED" bash "$RUN_SH" --lane implement --engine nonsense --dir "$ED" --timeout 5 "t" 2>&1)"
if grep -q 'unknown engine' <<<"$out"; then
  echo "  PASS  an unknown engine is rejected"; pass=$((pass+1))
else
  echo "  FAIL  unknown engine should be rejected"; fail=$((fail+1))
fi

# R1: a real timeout is not rescued, but an engine that merely returns 124 is.
R1="$BOX/r1-fallback"; mkdir -p "$R1/bin" "$R1/home/.claude/skills/codex-deepseek/scripts"
printf '#!/usr/bin/env bash\ncase "${CHARLES_R1_MODE:-}" in\n  deadline) sleep 2 ;;\n  early124) exit 124 ;;\n  failure) exit 1 ;;\nesac\n' > "$R1/bin/codex"
chmod +x "$R1/bin/codex"
printf '#!/usr/bin/env bash\n: > "${CHARLES_R1_DEEPSEEK_RAN:?}"\nprintf "deepseek result\\n"\n' \
  > "$R1/home/.claude/skills/codex-deepseek/scripts/codex-ds.sh"
chmod +x "$R1/home/.claude/skills/codex-deepseek/scripts/codex-ds.sh"

R1D="$R1/deadline"; mkdir -p "$R1D/repo"
r1_dead_out="$(HOME="$R1/home" CHARLES_R1_MODE=deadline CHARLES_R1_DEEPSEEK_RAN="$R1D/deepseek-ran" \
  CHARLES_STATE_DIR="$R1D/state" PATH="$R1/bin:$PATH" \
  bash "$RUN_SH" --lane explore --dir "$R1D/repo" --timeout 1 "deadline" 2>&1)"; r1_dead_rc=$?
r1_dead_ends="$(jq -r 'select(.event == "end") | .engine' "$R1D/repo/.charles/dispatches.jsonl" 2>/dev/null | wc -l)"
if [ "$r1_dead_rc" -eq 124 ] && grep -qF 'fallback was skipped because the task timed out' <<<"$r1_dead_out" \
  && [ ! -e "$R1D/deepseek-ran" ] && [ "$r1_dead_ends" -eq 1 ]; then
  echo "  PASS  rc=124 at the timeout deadline skips deepseek fallback"; pass=$((pass+1))
else
  echo "  FAIL  rc=124 at the timeout deadline must skip fallback (rc=$r1_dead_rc, ends=$r1_dead_ends)"; fail=$((fail+1))
fi

R1F="$R1/failure"; mkdir -p "$R1F/repo"
r1_fail_out="$(HOME="$R1/home" CHARLES_R1_MODE=failure CHARLES_R1_DEEPSEEK_RAN="$R1F/deepseek-ran" \
  CHARLES_STATE_DIR="$R1F/state" PATH="$R1/bin:$PATH" \
  bash "$RUN_SH" --lane explore --dir "$R1F/repo" --timeout 1 "failure" 2>&1)"; r1_fail_rc=$?
r1_fail_ends="$(jq -r 'select(.event == "end") | .engine' "$R1F/repo/.charles/dispatches.jsonl" 2>/dev/null | wc -l)"
if [ "$r1_fail_rc" -eq 0 ] && [ -e "$R1F/deepseek-ran" ] && [ "$r1_fail_ends" -eq 2 ]; then
  echo "  PASS  rc=1 still falls back to deepseek"; pass=$((pass+1))
else
  echo "  FAIL  rc=1 must still fall back to deepseek (rc=$r1_fail_rc, ends=$r1_fail_ends)"; fail=$((fail+1))
fi

R1E="$R1/early-124"; mkdir -p "$R1E/repo"
r1_early_out="$(HOME="$R1/home" CHARLES_R1_MODE=early124 CHARLES_R1_DEEPSEEK_RAN="$R1E/deepseek-ran" \
  CHARLES_STATE_DIR="$R1E/state" PATH="$R1/bin:$PATH" \
  bash "$RUN_SH" --lane explore --dir "$R1E/repo" --timeout 1 "early 124" 2>&1)"; r1_early_rc=$?
if [ "$r1_early_rc" -eq 0 ] && [ -e "$R1E/deepseek-ran" ]; then
  echo "  PASS  early rc=124 still falls back to deepseek"; pass=$((pass+1))
else
  echo "  FAIL  early rc=124 must still fall back to deepseek (rc=$r1_early_rc)"; fail=$((fail+1))
fi

# R2: kill a live wrapper and prove its detached child group and receipt finish.
R2="$BOX/r2-watchdog"; mkdir -p "$R2/bin" "$R2/repo"
printf '%s\n' '#!/usr/bin/env bash' \
  'trap "" TERM INT HUP' \
  'printf "%s\n" "$$" > "$CHARLES_R2_READY"' \
  'while :; do sleep 1; done' > "$R2/bin/codex"
chmod +x "$R2/bin/codex"
( CHARLES_STATE_DIR="$R2/state" CHARLES_R2_READY="$R2/ready" PATH="$R2/bin:$PATH" \
  exec bash "$RUN_SH" --lane explore --dir "$R2/repo" --no-fallback --timeout 30 "watchdog" ) \
  >"$R2/wrapper.out" 2>&1 &
r2_wrapper_pid=$!
r2_run=""
for _ in $(seq 1 100); do
  r2_run="$(jq -r 'select(.event == "start") | .run' "$R2/repo/.charles/dispatches.jsonl" 2>/dev/null | head -1)"
  [ -n "$r2_run" ] && [ -s "$R2/ready" ] && break
  sleep 0.05
done
r2_fake_pid="$(cat "$R2/ready" 2>/dev/null || true)"
r2_pgid="$(ps -o pgid= -p "$r2_fake_pid" 2>/dev/null | tr -d '[:space:]')"
r2_watchdog_pid=""
r2_watchdog_cmd=""
if [[ "$r2_wrapper_pid" =~ ^[0-9]+$ ]] && [ -n "$r2_run" ]; then
  for _ in $(seq 1 100); do
    for r2_proc in /proc/[0-9]*; do
      r2_pid="${r2_proc##*/}"
      [ "$r2_pid" = "$r2_wrapper_pid" ] && continue
      r2_env="$(tr '\0' '\n' < "$r2_proc/environ" 2>/dev/null || true)"
      if grep -qF "CHARLES_WATCHDOG_RUN=$r2_run" <<<"$r2_env"; then
        r2_watchdog_pid="$r2_pid"
        r2_watchdog_cmd="$(tr '\0' ' ' < "$r2_proc/cmdline" 2>/dev/null || true)"
        break 2
      fi
    done
    sleep 0.05
  done
fi
r2_cmdline_ok=0
[ -n "$r2_watchdog_pid" ] && ! grep -qF "$r2_run" <<<"$r2_watchdog_cmd" && r2_cmdline_ok=1
if [[ "$r2_wrapper_pid" =~ ^[0-9]+$ ]]; then kill -KILL "$r2_wrapper_pid" 2>/dev/null || true; fi
wait "$r2_wrapper_pid" 2>/dev/null || true
r2_group_dead=0
r2_receipt_ready=0
for _ in $(seq 1 150); do
  [ -n "$r2_pgid" ] && ! kill -0 -- "-$r2_pgid" 2>/dev/null && r2_group_dead=1
  if [ -n "$r2_run" ] && [ -f "$R2/state/$r2_run.done" ] \
    && jq -e --arg r "$r2_run" 'select(.event == "end" and .run == $r and .rc == 143 and .wrapper_death == true)' \
      "$R2/repo/.charles/dispatches.jsonl" >/dev/null 2>&1; then
    r2_receipt_ready=1
  fi
  [ "$r2_group_dead" -eq 1 ] && [ "$r2_receipt_ready" -eq 1 ] && break
  sleep 0.1
done
r2_end_count="$(jq -r --arg r "$r2_run" 'select(.event == "end" and .run == $r) | .run' \
  "$R2/repo/.charles/dispatches.jsonl" 2>/dev/null | wc -l)"
r2_identity_omitted=0
if jq -e --arg r "$r2_run" \
  'select(.event == "end" and .run == $r and .wrapper_death == true
    and (has("flow_run_id") | not) and (has("spec_path") | not))' \
  "$R2/repo/.charles/dispatches.jsonl" >/dev/null 2>&1; then
  r2_identity_omitted=1
fi
r2_status_out="$(CHARLES_STATE_DIR="$R2/state" bash "$LS" --dir "$R2/repo" "$r2_run" 2>&1)"; r2_status_rc=$?
if [ "$r2_group_dead" -eq 1 ] && [ "$r2_receipt_ready" -eq 1 ] && [ "$r2_end_count" -eq 1 ] \
  && [ "$r2_identity_omitted" -eq 1 ] \
  && [ "$(cat "$R2/state/$r2_run.done" 2>/dev/null)" = 143 ] \
  && [ "$r2_status_rc" -eq 2 ] && grep -qF "DEAD: $r2_run" <<<"$r2_status_out" \
  && ! grep -qF "RUNNING: $r2_run" <<<"$r2_status_out"; then
  echo "  PASS  SIGKILLed wrapper leaves no child group and completes one end marker"; pass=$((pass+1))
else
  echo "  FAIL  SIGKILLed wrapper must clean its child group and receipt (group=$r2_group_dead, receipt=$r2_receipt_ready, identity_omitted=$r2_identity_omitted, ends=$r2_end_count, status=$r2_status_rc)"; fail=$((fail+1))
fi
if [ "$r2_cmdline_ok" -eq 1 ]; then
  echo "  PASS  watchdog is detached and its command line omits the run id"; pass=$((pass+1))
else
  echo "  FAIL  watchdog must be detached and omit the run id from its command line"; fail=$((fail+1))
fi

# R2I: kill a live wrapper with flow identity and prove the watchdog preserves it.
R2I="$BOX/r2i-watchdog-identity"; mkdir -p "$R2I/bin" "$R2I/repo/docs/specs"
printf '%s\n' '#!/usr/bin/env bash' \
  'trap "" TERM INT HUP' \
  'printf "%s\n" "$$" > "$CHARLES_R2I_READY"' \
  'while :; do sleep 1; done' > "$R2I/bin/codex"
chmod +x "$R2I/bin/codex"
( cd "$R2I/repo" && git init -q )
printf 'green = "true"\n' > "$R2I/repo/.charles.toml"
r2i_spec_path="$R2I/repo/docs/specs/identity.md"
printf '%s\n' '# Plan' '' '- [ ] **R1. watchdog identity**' '' '## Grill verdict' '' '- Rounds: 1' \
  > "$r2i_spec_path"
r2i_flow_run_id="$(bash "$RS" init "$R2I/repo" polish "watchdog identity" --spec docs/specs/identity.md 2>/dev/null)"
( \
  CHARLES_STATE_DIR="$R2I/state" CHARLES_R2I_READY="$R2I/ready" PATH="$R2I/bin:$PATH" \
  exec bash "$RUN_SH" --lane explore --dir "$R2I/repo" --no-fallback --timeout 30 "watchdog identity" ) \
  >"$R2I/wrapper.out" 2>&1 &
r2i_wrapper_pid=$!
r2i_run=""
for _ in $(seq 1 100); do
  r2i_run="$(jq -r 'select(.event == "start") | .run' "$R2I/repo/.charles/dispatches.jsonl" 2>/dev/null | head -1)"
  [ -n "$r2i_run" ] && [ -s "$R2I/ready" ] && break
  sleep 0.05
done
r2i_watchdog_pid=""
if [[ "$r2i_wrapper_pid" =~ ^[0-9]+$ ]] && [ -n "$r2i_run" ]; then
  for _ in $(seq 1 100); do
    for r2i_proc in /proc/[0-9]*; do
      r2i_pid="$(basename "$r2i_proc")"
      [ "$r2i_pid" = "$r2i_wrapper_pid" ] && continue
      r2i_env="$(tr '\0' '\n' < "$r2i_proc/environ" 2>/dev/null || true)"
      if grep -qF "CHARLES_WATCHDOG_RUN=$r2i_run" <<<"$r2i_env"; then
        r2i_watchdog_pid="$r2i_pid"
        break 2
      fi
    done
    sleep 0.05
  done
fi
if [[ "$r2i_wrapper_pid" =~ ^[0-9]+$ ]]; then
  kill -KILL "$r2i_wrapper_pid" 2>/dev/null || true
  for _ in $(seq 1 100); do
    kill -0 "$r2i_wrapper_pid" 2>/dev/null || break
    sleep 0.05
  done
  wait "$r2i_wrapper_pid" 2>/dev/null || true
fi
r2i_identity_ok=0
for _ in $(seq 1 150); do
  if [ -n "$r2i_run" ] && jq -e --arg r "$r2i_run" \
    --arg f "$r2i_flow_run_id" --arg s "$r2i_spec_path" \
    'select(.event == "end" and .run == $r and .wrapper_death == true
      and .flow_run_id == $f and .spec_path == $s)' \
    "$R2I/repo/.charles/dispatches.jsonl" >/dev/null 2>&1; then
    r2i_identity_ok=1
    break
  fi
  sleep 0.1
done
if [ -n "$r2i_watchdog_pid" ] && [ "$r2i_identity_ok" -eq 1 ]; then
  echo "  PASS  watchdog wrapper-death receipt preserves flow_run_id and spec_path"; pass=$((pass+1))
else
  echo "  FAIL  watchdog wrapper-death receipt must preserve identity (watchdog=$r2i_watchdog_pid, identity=$r2i_identity_ok)"; fail=$((fail+1))
fi

# R3: a real TERM reaches the wrapper and leaves its own terminal receipt.
R3="$BOX/r3-term-handler"; mkdir -p "$R3/bin" "$R3/repo"
printf '%s\n' '#!/usr/bin/env bash' \
  'trap "exit 0" TERM INT HUP' \
  'printf "%s\n" "$$" > "$CHARLES_R3_READY"' \
  'while :; do sleep 1; done' > "$R3/bin/codex"
chmod +x "$R3/bin/codex"
( CHARLES_STATE_DIR="$R3/state" CHARLES_R3_READY="$R3/ready" PATH="$R3/bin:$PATH" \
  exec bash "$RUN_SH" --lane explore --dir "$R3/repo" --no-fallback --timeout 30 "term handler" ) \
  >"$R3/wrapper.out" 2>&1 &
r3_wrapper_pid=$!
r3_run=""
for _ in $(seq 1 100); do
  r3_run="$(jq -r 'select(.event == "start") | .run' "$R3/repo/.charles/dispatches.jsonl" 2>/dev/null | head -1)"
  [ -n "$r3_run" ] && [ -s "$R3/ready" ] && break
  sleep 0.05
done
r3_fake_pid="$(cat "$R3/ready" 2>/dev/null || true)"
r3_pgid="$(ps -o pgid= -p "$r3_fake_pid" 2>/dev/null | tr -d '[:space:]')"
r3_watchdog_pid=""
if [[ "$r3_wrapper_pid" =~ ^[0-9]+$ ]] && [ -n "$r3_run" ]; then
  for _ in $(seq 1 100); do
    for r3_proc in /proc/[0-9]*; do
      r3_pid="${r3_proc##*/}"
      [ "$r3_pid" = "$r3_wrapper_pid" ] && continue
      r3_env="$(tr '\0' '\n' < "$r3_proc/environ" 2>/dev/null || true)"
      if grep -qF "CHARLES_WATCHDOG_RUN=$r3_run" <<<"$r3_env"; then
        r3_watchdog_pid="$r3_pid"
        break 2
      fi
    done
    sleep 0.05
  done
fi
r3_watchdog_killed=0
if [[ "$r3_watchdog_pid" =~ ^[1-9][0-9]*$ ]] && [ "$r3_watchdog_pid" -gt 1 ]; then
  kill -KILL "$r3_watchdog_pid" 2>/dev/null || true
  r3_watchdog_killed=1
fi
r3_term_sent=0
if [[ "$r3_wrapper_pid" =~ ^[1-9][0-9]*$ ]]; then
  kill -TERM "$r3_wrapper_pid" 2>/dev/null && r3_term_sent=1
fi
r3_wrapper_gone=0
for _ in $(seq 1 100); do
  if ! kill -0 "$r3_wrapper_pid" 2>/dev/null; then r3_wrapper_gone=1; break; fi
  sleep 0.05
done
if [ "$r3_wrapper_gone" -eq 0 ] && [[ "$r3_wrapper_pid" =~ ^[1-9][0-9]*$ ]]; then
  kill -KILL "$r3_wrapper_pid" 2>/dev/null || true
fi
wait "$r3_wrapper_pid" 2>/dev/null || true
r3_done_seen=0
r3_end_count=0
r3_nonzero_end=0
for _ in $(seq 1 100); do
  [ -e "$R3/state/$r3_run.done" ] && r3_done_seen=1
  r3_end_count="$(jq -r --arg r "$r3_run" 'select(.event == "end" and .run == $r) | .run' \
    "$R3/repo/.charles/dispatches.jsonl" 2>/dev/null | wc -l)"
  if jq -e --arg r "$r3_run" \
      'select(.event == "end" and .run == $r and (.rc | type) == "number" and .rc != 0)' \
      "$R3/repo/.charles/dispatches.jsonl" >/dev/null 2>&1; then
    r3_nonzero_end=1
  fi
  [ "$r3_done_seen" -eq 1 ] && [ "$r3_end_count" -eq 1 ] && [ "$r3_nonzero_end" -eq 1 ] && break
  sleep 0.05
done
r3_self_pgid="$(ps -o pgid= -p $$ 2>/dev/null | tr -d '[:space:]')"
if [[ "$r3_pgid" =~ ^[1-9][0-9]*$ ]] && [ "$r3_pgid" -gt 1 ] && [ "$r3_pgid" != "$r3_self_pgid" ]; then
  kill -KILL -- "-$r3_pgid" 2>/dev/null || true
fi
if [ "$r3_term_sent" -eq 1 ] && [ "$r3_wrapper_gone" -eq 1 ] \
  && [ "$r3_watchdog_killed" -eq 1 ] && [ "$r3_done_seen" -eq 1 ] \
  && [ "$r3_end_count" -eq 1 ] && [ "$r3_nonzero_end" -eq 1 ]; then
  echo "  PASS  real SIGTERM leaves one non-zero end record and .done"; pass=$((pass+1))
else
  echo "  FAIL  real SIGTERM must leave one non-zero end record and .done (sent=$r3_term_sent, gone=$r3_wrapper_gone, watchdog=$r3_watchdog_killed, done=$r3_done_seen, ends=$r3_end_count, nonzero=$r3_nonzero_end)"; fail=$((fail+1))
fi

# R3 second half: cleanup waits for a late terminal receipt and retains a
# worktree when no terminal receipt can ever arrive. Replace both dispatcher
# calls in a temporary copy so this uses stub children, not a real Codex lane.
R3P="$BOX/r3-parallel-cleanup"; mkdir -p "$R3P/bin"
PARALLEL_SCRIPTS="$(cd -- "$(dirname -- "$PARALLEL")" && pwd -P)"
cp "$PARALLEL" "$R3P/parallel-chunks.sh"
sed -i \
  -e "s|^SCRIPT_DIR=.*|SCRIPT_DIR=\"$PARALLEL_SCRIPTS\"|" \
  -e 's|"\$SCRIPTS/codex-run\.sh"|"\$CHARLES_TEST_CHILD"|g' \
  "$R3P/parallel-chunks.sh"

parallel_fixture "$R3P/late-repo" "$R3P/late-alpha" true
git -C "$R3P/late-repo" worktree add -q "$R3P/late-beta" HEAD
parallel_fixture "$R3P/expiry-repo" "$R3P/expiry-alpha" true
git -C "$R3P/expiry-repo" worktree add -q "$R3P/expiry-beta" HEAD
printf '[{"name":"alpha","files":["alpha"],"task":"late"},{"name":"beta","files":["beta"],"task":"fast"}]\n' \
  > "$R3P/late.chunks.json"
printf '[{"name":"alpha","files":["alpha"],"task":"never"},{"name":"beta","files":["beta"],"task":"fast"}]\n' \
  > "$R3P/expiry.chunks.json"
cat > "$R3P/bin/treehouse" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  get)
    case "\${PWD##*/}:\${4:-}" in
      late-repo:chunk-alpha) printf '%s\n' "$R3P/late-alpha" ;;
      late-repo:chunk-beta) printf '%s\n' "$R3P/late-beta" ;;
      expiry-repo:chunk-alpha) printf '%s\n' "$R3P/expiry-alpha" ;;
      expiry-repo:chunk-beta) printf '%s\n' "$R3P/expiry-beta" ;;
      *) exit 1 ;;
    esac
    ;;
  return)
    path="\${2:-}"
    printf '%s\n' "\$path" >> "\${CHARLES_RETURN_RECORD:?}"
    [ -z "\$path" ] || rm -rf -- "\$path"
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$R3P/bin/treehouse"
cat > "$R3P/bin/child" <<'EOF'
#!/usr/bin/env bash
child_dir=""
while [ "$#" -gt 0 ]; do
  case "${1:-}" in
    --dir) child_dir="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$child_dir" ] || exit 2
case "$child_dir" in
  */late-alpha)
    mkdir -p "$child_dir/.charles"
    receipt="$child_dir/.charles/dispatches.jsonl"
    printf '%s\n' '{"event":"start","run":"late-alpha"}' > "$receipt"
    printf 'late alpha\n' > "$child_dir/alpha"
    ( sleep 1; printf '%s\n' '{"event":"end","run":"late-alpha","rc":0}' >> "$receipt" ) &
    ;;
  */late-beta)
    mkdir -p "$child_dir/.charles"
    receipt="$child_dir/.charles/dispatches.jsonl"
    printf '%s\n' '{"event":"start","run":"late-beta"}' > "$receipt"
    printf '%s\n' '{"event":"end","run":"late-beta","rc":0}' >> "$receipt"
    printf 'late beta\n' > "$child_dir/beta"
    ;;
  */expiry-alpha)
    mkdir -p "$child_dir/.charles"
    printf '%s\n' '{"event":"end","run":"previous-lease","rc":0}' \
      '{"event":"start","run":"expiry-alpha"}' > "$child_dir/.charles/dispatches.jsonl"
    printf 'expiry alpha\n' > "$child_dir/alpha"
    ;;
  */expiry-beta)
    mkdir -p "$child_dir/.charles"
    receipt="$child_dir/.charles/dispatches.jsonl"
    printf '%s\n' '{"event":"start","run":"expiry-beta"}' > "$receipt"
    printf '%s\n' '{"event":"end","run":"expiry-beta","rc":0}' >> "$receipt"
    printf 'expiry beta\n' > "$child_dir/beta"
    ;;
  *)
    # Scope validation targets the parent repo and needs no fixture receipt.
    ;;
esac
exit 0
EOF
chmod +x "$R3P/bin/child"

: > "$R3P/late-returns"
late_cleanup_out="$(PATH="$R3P/bin:$PATH" CHARLES_TEST_CHILD="$R3P/bin/child" \
  CHARLES_PARALLEL_MIN_CHUNKS=2 CHARLES_RETURN_RECORD="$R3P/late-returns" \
  timeout 8s bash "$R3P/parallel-chunks.sh" "$R3P/late-repo" "$R3P/late.chunks.json" --no-green 2>&1)"; late_cleanup_rc=$?
if [ "$late_cleanup_rc" -eq 0 ] \
  && jq -e 'select(.run == "late-alpha" and .event == "end")' \
       "$R3P/late-repo/.charles/dispatches.jsonl" >/dev/null 2>&1 \
  && grep -Fxq "$R3P/late-alpha" "$R3P/late-returns" \
  && grep -Fxq "$R3P/late-beta" "$R3P/late-returns" \
  && [ ! -d "$R3P/late-alpha" ] && [ ! -d "$R3P/late-beta" ]; then
  echo "  PASS  cleanup waits for a late terminal receipt before aggregating and returning"; pass=$((pass+1))
else
  echo "  FAIL  cleanup must wait for a late terminal receipt (rc=$late_cleanup_rc): $late_cleanup_out"; fail=$((fail+1))
fi

: > "$R3P/expiry-returns"
expiry_cleanup_out="$(PATH="$R3P/bin:$PATH" CHARLES_TEST_CHILD="$R3P/bin/child" \
  CHARLES_PARALLEL_MIN_CHUNKS=2 CHARLES_RETURN_RECORD="$R3P/expiry-returns" \
  timeout 8s bash "$R3P/parallel-chunks.sh" "$R3P/expiry-repo" "$R3P/expiry.chunks.json" --no-green 2>&1)"; expiry_cleanup_rc=$?
if [ "$expiry_cleanup_rc" -eq 3 ] \
  && grep -qF 'no terminal record after bounded wait' <<<"$expiry_cleanup_out" \
  && grep -qF "$R3P/expiry-alpha" <<<"$expiry_cleanup_out" \
  && grep -qF 'unaggregated receipt' <<<"$expiry_cleanup_out" \
  && [ -d "$R3P/expiry-alpha" ] \
  && ! grep -Fxq "$R3P/expiry-alpha" "$R3P/expiry-returns" \
  && grep -Fxq "$R3P/expiry-beta" "$R3P/expiry-returns"; then
  echo "  PASS  cleanup expiry marks failure and retains the unaggregated receipt"; pass=$((pass+1))
else
  echo "  FAIL  cleanup expiry must retain and report its worktree (rc=$expiry_cleanup_rc): $expiry_cleanup_out"; fail=$((fail+1))
fi

# A clean one-attempt dispatch must reap its watchdog and log exactly one end.
R2C="$R2/clean"; mkdir -p "$R2C/bin" "$R2C/repo"
printf '#!/usr/bin/env bash\nexit 0\n' > "$R2C/bin/codex"
chmod +x "$R2C/bin/codex"
sleep 1
CHARLES_STATE_DIR="$R2C/state" PATH="$R2C/bin:$PATH" bash "$RUN_SH" \
  --lane explore --dir "$R2C/repo" --no-fallback --timeout 5 "clean" >/dev/null 2>&1
r2_clean_rc=$?
r2_clean_run="$(jq -r 'select(.event == "start") | .run' "$R2C/repo/.charles/dispatches.jsonl" 2>/dev/null | head -1)"
r2_clean_ends="$(jq -r --arg r "$r2_clean_run" 'select(.event == "end" and .run == $r) | .run' \
  "$R2C/repo/.charles/dispatches.jsonl" 2>/dev/null | wc -l)"
r2_clean_survivor=0
for _ in $(seq 1 30); do
  for r2_proc in /proc/[0-9]*; do
    r2_pid="${r2_proc##*/}"
    r2_env="$(tr '\0' '\n' < "$r2_proc/environ" 2>/dev/null || true)"
    if grep -qF "CHARLES_WATCHDOG_RUN=$r2_clean_run" <<<"$r2_env"; then r2_clean_survivor=1; break 2; fi
  done
  sleep 0.05
done
if [ "$r2_clean_rc" -eq 0 ] && [ "$r2_clean_ends" -eq 1 ] \
  && [ "$(cat "$R2C/state/$r2_clean_run.done" 2>/dev/null)" = 0 ] \
  && [ "$r2_clean_survivor" -eq 0 ]; then
  echo "  PASS  clean dispatch has one end per attempt and no watchdog survivor"; pass=$((pass+1))
else
  echo "  FAIL  clean dispatch must reap its watchdog and log one end (rc=$r2_clean_rc, ends=$r2_clean_ends, survivor=$r2_clean_survivor)"; fail=$((fail+1))
fi

# A clean fallback must log one end for each of its two attempts and reap the watchdog.
R2F="$R2/clean-fallback"; mkdir -p "$R2F/bin" "$R2F/home/.claude/skills/codex-deepseek/scripts" "$R2F/repo"
printf '#!/usr/bin/env bash\ncase " $* " in *" -p luna "*) exit 1;; esac\nexit 0\n' > "$R2F/bin/codex"
chmod +x "$R2F/bin/codex"
printf '#!/usr/bin/env bash\nexit 0\n' > "$R2F/home/.claude/skills/codex-deepseek/scripts/codex-ds.sh"
chmod +x "$R2F/home/.claude/skills/codex-deepseek/scripts/codex-ds.sh"
HOME="$R2F/home" CHARLES_STATE_DIR="$R2F/state" PATH="$R2F/bin:$PATH" bash "$RUN_SH" \
  --lane explore --dir "$R2F/repo" --timeout 5 "clean fallback" >/dev/null 2>&1
r2_fallback_rc=$?
r2_fallback_run="$(jq -r 'select(.event == "start") | .run' "$R2F/repo/.charles/dispatches.jsonl" 2>/dev/null | head -1)"
r2_fallback_luna_ends="$(jq -r --arg r "$r2_fallback_run" 'select(.event == "end" and .run == $r and .engine == "luna") | .run' \
  "$R2F/repo/.charles/dispatches.jsonl" 2>/dev/null | wc -l)"
r2_fallback_deepseek_ends="$(jq -r --arg r "$r2_fallback_run" 'select(.event == "end" and .run == $r and .engine == "deepseek") | .run' \
  "$R2F/repo/.charles/dispatches.jsonl" 2>/dev/null | wc -l)"
r2_fallback_survivor=0
for _ in $(seq 1 30); do
  for r2_proc in /proc/[0-9]*; do
    r2_pid="${r2_proc##*/}"
    r2_env="$(tr '\0' '\n' < "$r2_proc/environ" 2>/dev/null || true)"
    if grep -qF "CHARLES_WATCHDOG_RUN=$r2_fallback_run" <<<"$r2_env"; then r2_fallback_survivor=1; break 2; fi
  done
  sleep 0.05
done
r2_fallback_ends=$((r2_fallback_luna_ends + r2_fallback_deepseek_ends))
if [ "$r2_fallback_rc" -eq 0 ] && [ "$r2_fallback_luna_ends" -eq 1 ] \
  && [ "$r2_fallback_deepseek_ends" -eq 1 ] && [ "$r2_fallback_ends" -eq 2 ] \
  && [ "$r2_fallback_survivor" -eq 0 ]; then
  echo "  PASS  clean fallback logs one end per attempt and leaves no watchdog survivor"; pass=$((pass+1))
else
  echo "  FAIL  clean fallback must log two ends and reap its watchdog (rc=$r2_fallback_rc, luna=$r2_fallback_luna_ends, deepseek=$r2_fallback_deepseek_ends, survivor=$r2_fallback_survivor)"; fail=$((fail+1))
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
printf '#!/usr/bin/env bash\necho "$@" > %s/args.txt\ncp changes.diff %s/review-captured.diff\n' "$RD" "$BOX" > "$RD/bin/codex"
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
if grep -q -- '-c model_reasoning_effort=medium' "$RD/args.txt" 2>/dev/null; then
  echo "  PASS  sol review defaults to medium effort"; pass=$((pass+1))
else
  echo "  FAIL  sol review must default to medium effort"; fail=$((fail+1))
fi
if [ -s "$BOX/review-captured.diff" ] && grep -q '^+changed$' "$BOX/review-captured.diff"; then
  echo "  PASS  review without --base uses the working-tree diff"; pass=$((pass+1))
else
  echo "  FAIL  review without --base must use the working-tree diff"; fail=$((fail+1))
fi

# --base reviews committed work from the chosen ref, plus changes made on top.
RB="$BOX/reviewbase"; RBBIN="$BOX/reviewbase-bin"; mkdir -p "$RB/docs" "$RBBIN"
printf '#!/usr/bin/env bash\necho "$@" > %s/base-args.txt\ncp changes.diff %s/base-captured.diff\n' "$BOX" "$BOX" > "$RBBIN/codex"
chmod +x "$RBBIN/codex"
( cd "$RB" && git init -q && git config user.name tester && git config user.email tester@example.invalid
  printf 'base\n' > a.ts && git add -A && git commit -qm base ) >/dev/null 2>&1
base_ref="$(git -C "$RB" rev-parse HEAD)"
( cd "$RB" && printf 'committed\n' >> a.ts && git add -A && git commit -qm committed && printf 'working\n' >> a.ts ) >/dev/null 2>&1
printf '# Plan\n' > "$RB/docs/p.md"

PATH="$RBBIN:$PATH" CHARLES_STATE_DIR="$RB" bash "$RUN_SH" --lane review --dir "$RB" --plan "$RB/docs/p.md" --base "$base_ref" --timeout 5 "t" >/dev/null 2>&1
if [ $? -eq 0 ] && [ -s "$BOX/base-captured.diff" ] \
  && grep -q '^+committed$' "$BOX/base-captured.diff" \
  && grep -q '^+working$' "$BOX/base-captured.diff" \
  && [ -s "$BOX/base-args.txt" ]; then
  echo "  PASS  valid --base diff dispatches committed and working changes"; pass=$((pass+1))
else
  echo "  FAIL  valid --base must dispatch a non-empty committed-work diff"; fail=$((fail+1))
fi

base_out="$(PATH="$RBBIN:$PATH" CHARLES_STATE_DIR="$RB" bash "$RUN_SH" --lane review --dir "$RB" --plan "$RB/docs/p.md" --base does-not-exist --timeout 5 "t" 2>&1)"; base_rc=$?
if [ "$base_rc" -eq 2 ] && grep -q "invalid --base ref 'does-not-exist'" <<<"$base_out"; then
  echo "  PASS  nonexistent --base ref exits 2"; pass=$((pass+1))
else
  echo "  FAIL  nonexistent --base ref should exit 2 (rc=$base_rc)"; fail=$((fail+1))
fi

nonreview_out="$(PATH="$RD/bin:$PATH" CHARLES_STATE_DIR="$RD" bash "$RUN_SH" --lane implement --dir "$RD" --base HEAD --timeout 5 "t" 2>&1)"; nonreview_rc=$?
if [ "$nonreview_rc" -eq 2 ] && grep -q 'only valid with --lane review' <<<"$nonreview_out"; then
  echo "  PASS  --base is rejected outside the review lane"; pass=$((pass+1))
else
  echo "  FAIL  --base outside review should exit 2 (rc=$nonreview_rc)"; fail=$((fail+1))
fi

# --- review diff boundaries and fail-closed assembly --------------------------
RDIFF="$BOX/reviewdiff"; RDIFFBIN="$BOX/reviewdiff-bin"; mkdir -p "$RDIFF/docs" "$RDIFF/.charles" "$RDIFFBIN"
RDIFF_STATE="$BOX/reviewdiff-state"
printf '#!/usr/bin/env bash\n: > %s/review-dispatched\ncp changes.diff %s/reviewdiff-captured.diff\n' \
  "$BOX" "$BOX" > "$RDIFFBIN/codex"
chmod +x "$RDIFFBIN/codex"
( cd "$RDIFF" && git init -q && git config user.name tester && git config user.email tester@example.invalid
  printf 'base\n' > tracked.txt
  printf 'base charles\n' > .charles/state
  printf 'base config\n' > .charles.toml
  git add tracked.txt .charles.toml && git add -f .charles/state && git commit -qm base
  printf 'changed\n' > tracked.txt
  printf 'changed charles\n' > .charles/state
  printf 'changed config\n' > .charles.toml ) >/dev/null 2>&1
printf '# outside plan sentinel\n' > "$BOX/outside-review-plan.md"

rm -f "$BOX/review-dispatched" "$BOX/reviewdiff-captured.diff"
outside_review_out="$(PATH="$RDIFFBIN:$PATH" CHARLES_STATE_DIR="$RDIFF_STATE" bash "$RUN_SH" \
  --lane review --dir "$RDIFF" --plan "$BOX/outside-review-plan.md" --timeout 5 "t" 2>&1)"; outside_review_rc=$?
if [ "$outside_review_rc" -eq 0 ] && [ -s "$BOX/reviewdiff-captured.diff" ] \
  && grep -q '^+changed$' "$BOX/reviewdiff-captured.diff" \
  && ! grep -qF 'outside plan sentinel' "$BOX/reviewdiff-captured.diff" \
  && ! grep -qF 'changed charles' "$BOX/reviewdiff-captured.diff" \
  && ! grep -qF 'changed config' "$BOX/reviewdiff-captured.diff"; then
  echo "  PASS  outside plan keeps tracked review changes and excludes internal scratch"; pass=$((pass+1))
else
  echo "  FAIL  outside plan must keep tracked changes and exclude .charles files (rc=$outside_review_rc)"; fail=$((fail+1))
fi

# A failing TRACKED diff must refuse, never fall through to untracked-only.
# The incident: --plan outside --dir made the tracked halves fatal while the
# untracked enumeration (a case filter, not the exclude pathspec) still appended
# its additions, so changes.diff was PARTIAL. The reviewer graded plausible input
# and reported every tracked change as absent. Partial is worse than empty:
# empty announces itself, partial does not.
printf 'untracked\n' > "$RDIFF/untracked-sentinel.txt"
printf '#!/usr/bin/env bash\nfor a in "$@"; do [ "$a" = diff ] && { echo "fatal: simulated" >&2; exit 128; }; done\nexec %s "$@"\n' \
  "$(command -v git)" > "$RDIFFBIN/git"
chmod +x "$RDIFFBIN/git"
rm -f "$BOX/review-dispatched" "$BOX/reviewdiff-captured.diff"
trkfail_out="$(PATH="$RDIFFBIN:$PATH" CHARLES_STATE_DIR="$RDIFF_STATE" bash "$RUN_SH" \
  --lane review --dir "$RDIFF" --plan "$BOX/outside-review-plan.md" --timeout 5 "t" 2>&1)"; trkfail_rc=$?
rm -f "$RDIFFBIN/git" "$RDIFF/untracked-sentinel.txt"
if [ "$trkfail_rc" -ne 0 ] && grep -qF 'git error while assembling review diff' <<<"$trkfail_out" \
  && [ ! -f "$BOX/review-dispatched" ]; then
  echo "  PASS  a failing tracked diff refuses instead of grading untracked-only"; pass=$((pass+1))
else
  echo "  FAIL  a failing tracked diff must refuse before dispatch (rc=$trkfail_rc)"; fail=$((fail+1))
fi

# Staged changes must appear ONCE. `git diff HEAD` already covers staged and
# unstaged; a second `--cached` pass appended every staged hunk again, so the
# reviewer saw duplicates of exactly the changes most likely to be mid-commit.
printf 'staged-sentinel\n' > "$RDIFF/staged.txt"
( cd "$RDIFF" && git add staged.txt ) >/dev/null 2>&1
rm -f "$BOX/review-dispatched" "$BOX/reviewdiff-captured.diff"
staged_out="$(PATH="$RDIFFBIN:$PATH" CHARLES_STATE_DIR="$RDIFF_STATE" bash "$RUN_SH" \
  --lane review --dir "$RDIFF" --plan "$BOX/outside-review-plan.md" --timeout 5 "t" 2>&1)"; staged_rc=$?
staged_hits="$(grep -c '^+staged-sentinel$' "$BOX/reviewdiff-captured.diff" 2>/dev/null || echo 0)"
( cd "$RDIFF" && git rm -q --cached staged.txt ) >/dev/null 2>&1; rm -f "$RDIFF/staged.txt"
if [ "$staged_rc" -eq 0 ] && [ "$staged_hits" -eq 1 ]; then
  echo "  PASS  a staged change appears once in the review diff"; pass=$((pass+1))
else
  echo "  FAIL  staged change must appear exactly once (hits=$staged_hits rc=$staged_rc)"; fail=$((fail+1))
fi

printf '# inside plan sentinel\n' > "$RDIFF/docs/inside.md"
rm -f "$BOX/review-dispatched" "$BOX/reviewdiff-captured.diff"
inside_review_out="$(PATH="$RDIFFBIN:$PATH" CHARLES_STATE_DIR="$RDIFF_STATE" bash "$RUN_SH" \
  --lane review --dir "$RDIFF" --plan "$RDIFF/docs/inside.md" --timeout 5 "t" 2>&1)"; inside_review_rc=$?
if [ "$inside_review_rc" -eq 0 ] && [ -s "$BOX/reviewdiff-captured.diff" ] \
  && grep -q '^+changed$' "$BOX/reviewdiff-captured.diff" \
  && ! grep -qF 'inside plan sentinel' "$BOX/reviewdiff-captured.diff" \
  && ! grep -qF 'changed charles' "$BOX/reviewdiff-captured.diff" \
  && ! grep -qF 'changed config' "$BOX/reviewdiff-captured.diff"; then
  echo "  PASS  inside plan stays excluded with .charles files"; pass=$((pass+1))
else
  echo "  FAIL  inside plan must be excluded with .charles files (rc=$inside_review_rc)"; fail=$((fail+1))
fi

RDIFF_REAL_GIT="$(command -v git)"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'case "${CHARLES_FAIL_GIT:-}" in' \
  '  head) [ "${1:-}" = "-C" ] && [ "${3:-}" = "diff" ] && [ "${4:-}" = "HEAD" ] ;;' \
  '  untracked) [ "${1:-}" = "-C" ] && [ "${3:-}" = "ls-files" ] ;;' \
  '  *) false ;;' \
  'esac' \
  'if [ "$?" -eq 0 ]; then' \
  '  echo "fatal: synthetic git assembly failure" >&2' \
  '  exit 91' \
  'fi' \
  "exec \"$RDIFF_REAL_GIT\" \"\$@\"" > "$RDIFFBIN/git"
chmod +x "$RDIFFBIN/git"
for fail_mode in head untracked; do
  rm -f "$BOX/review-dispatched" "$BOX/reviewdiff-captured.diff"
  git_error_out="$(CHARLES_FAIL_GIT="$fail_mode" PATH="$RDIFFBIN:$PATH" CHARLES_STATE_DIR="$RDIFF_STATE" \
    bash "$RUN_SH" --lane review --dir "$RDIFF" --plan "$RDIFF/docs/inside.md" --timeout 5 "t" 2>&1)"; git_error_rc=$?
  if [ "$git_error_rc" -ne 0 ] && grep -qF 'git error while assembling review diff' <<<"$git_error_out" \
    && ! grep -qF 'nothing to review (empty diff)' <<<"$git_error_out" \
    && [ ! -e "$BOX/review-dispatched" ]; then
    echo "  PASS  git $fail_mode failure refuses review input"; pass=$((pass+1))
  else
    echo "  FAIL  git $fail_mode failure must refuse distinctly (rc=$git_error_rc)"; fail=$((fail+1))
  fi
done

RCLEAN="$BOX/reviewclean"; mkdir -p "$RCLEAN/docs"
RCLEAN_STATE="$BOX/reviewclean-state"
( cd "$RCLEAN" && git init -q && git config user.name tester && git config user.email tester@example.invalid
  printf 'clean\n' > tracked.txt
  printf '# clean plan\n' > docs/p.md
  git add -A && git commit -qm clean ) >/dev/null 2>&1
rm -f "$BOX/review-dispatched" "$BOX/reviewdiff-captured.diff"
clean_review_out="$(PATH="$RDIFFBIN:$PATH" CHARLES_STATE_DIR="$RCLEAN_STATE" bash "$RUN_SH" \
  --lane review --dir "$RCLEAN" --plan "$RCLEAN/docs/p.md" --timeout 5 "t" 2>&1)"; clean_review_rc=$?
if [ "$clean_review_rc" -eq 3 ] && grep -qF 'nothing to review (empty diff)' <<<"$clean_review_out" \
  && ! grep -qF 'git error while assembling review diff' <<<"$clean_review_out" \
  && [ ! -e "$BOX/review-dispatched" ]; then
  echo "  PASS  clean review tree keeps the empty-diff refusal"; pass=$((pass+1))
else
  echo "  FAIL  clean review tree must refuse as an empty diff (rc=$clean_review_rc)"; fail=$((fail+1))
fi

PATH="$RD/bin:$PATH" CHARLES_STATE_DIR="$RD" bash "$RUN_SH" --lane review --engine luna --dir "$RD" --plan "$RD/docs/p.md" --timeout 5 "t" >/dev/null 2>&1
if grep -q -- '-m gpt-5.6-luna' "$RD/args.txt" 2>/dev/null \
  && grep -q -- '-c model_reasoning_effort=max' "$RD/args.txt" 2>/dev/null; then
  echo "  PASS  review with --engine luna defaults to max"; pass=$((pass+1))
else
  echo "  FAIL  review with --engine luna must default to max"; fail=$((fail+1))
fi

PATH="$RD/bin:$PATH" CHARLES_STATE_DIR="$RD" bash "$RUN_SH" --lane review --engine terra --dir "$RD" --plan "$RD/docs/p.md" --timeout 5 "t" >/dev/null 2>&1
if grep -q -- '-m gpt-5.6-terra' "$RD/args.txt" 2>/dev/null \
  && grep -q -- '-c model_reasoning_effort=max' "$RD/args.txt" 2>/dev/null; then
  echo "  PASS  review with --engine terra defaults to max"; pass=$((pass+1))
else
  echo "  FAIL  review with --engine terra must default to max"; fail=$((fail+1))
fi

PATH="$RD/bin:$PATH" CHARLES_STATE_DIR="$RD" bash "$RUN_SH" --lane review --engine luna --effort medium --dir "$RD" --plan "$RD/docs/p.md" --timeout 5 "t" >/dev/null 2>&1
if grep -q -- '-m gpt-5.6-luna' "$RD/args.txt" 2>/dev/null \
  && grep -q -- '-c model_reasoning_effort=medium' "$RD/args.txt" 2>/dev/null; then
  echo "  PASS  explicit --effort medium overrides luna review default"; pass=$((pass+1))
else
  echo "  FAIL  explicit --effort medium must override luna review default"; fail=$((fail+1))
fi

# --- global engine switch -----------------------------------------------------
# Codex quota runs out; the lanes should move to another engine without a
# restart or a reinstall. The file is read at dispatch time, so they do.
printf 'deepseek\n' > "$RD/engine"
# CHARLES_PEAK_HOUR pins the clock: off-peak, so the deepseek pick stands.
PATH="$RD/bin:$PATH" CHARLES_STATE_DIR="$RD" CHARLES_PEAK_HOUR=12 bash "$RUN_SH" --lane review --dir "$RD" --plan "$RD/docs/p.md" --timeout 5 "t" >/dev/null 2>&1
if grep -q -- '-p deepseek' "$RD/args.txt" 2>/dev/null; then
  echo "  PASS  engine file switches the review lane to deepseek"; pass=$((pass+1))
else
  echo "  FAIL  engine file must switch the review lane"; fail=$((fail+1))
fi

PATH="$RD/bin:$PATH" CHARLES_STATE_DIR="$RD" bash "$RUN_SH" --lane review --engine terra --dir "$RD" --plan "$RD/docs/p.md" --timeout 5 "t" >/dev/null 2>&1
if grep -q -- '-m gpt-5.6-terra' "$RD/args.txt" 2>/dev/null; then
  echo "  PASS  --engine still beats the engine file"; pass=$((pass+1))
else
  echo "  FAIL  --engine must override the engine file"; fail=$((fail+1))
fi

PATH="$RD/bin:$PATH" CHARLES_STATE_DIR="$RD" CHARLES_ENGINE=luna bash "$RUN_SH" --lane review --dir "$RD" --plan "$RD/docs/p.md" --timeout 5 "t" >/dev/null 2>&1
if grep -q -- '-m gpt-5.6-luna' "$RD/args.txt" 2>/dev/null; then
  echo "  PASS  CHARLES_ENGINE beats the engine file"; pass=$((pass+1))
else
  echo "  FAIL  CHARLES_ENGINE must beat the engine file"; fail=$((fail+1))
fi
printf 'deepseek\n' > "$ED/engine"
# DeepSeek peak window: borrow luna on Codex quota; R8 applies luna's fast-mode
# selection to the substitution too.
PATH="$ED/bin:$PATH" CHARLES_STATE_DIR="$ED" CHARLES_CODEX_SESSIONS_DIR="$R8/empty" CHARLES_PEAK_HOUR=07 bash "$RUN_SH" --lane implement --dir "$ED" --timeout 5 "t" >/dev/null 2>&1
if grep -q -- '-p luna' "$ED/args.txt" 2>/dev/null; then
  echo "  PASS  deepseek engine swaps to luna in a peak window"; pass=$((pass+1))
else
  echo "  FAIL  peak window must swap deepseek to luna"; fail=$((fail+1))
fi
if grep -q -- '--enable fast_mode' "$ED/args.txt" 2>/dev/null; then
  echo "  PASS  the peak swap runs luna with fast_mode enabled"; pass=$((pass+1))
else
  echo "  FAIL  peak-swapped luna must use fast_mode by default"; fail=$((fail+1))
fi

# The deepseek lane runs codex-ds.sh, not codex, so it needs its own HOME —
# without one these two cases would reach the real wrapper and bill a live call.
mkdir -p "$ED/home/.claude/skills/codex-deepseek/scripts"
printf '#!/usr/bin/env bash\ntouch %s/ds-ran\nprintf "ds\\n"\n' "$ED" \
  > "$ED/home/.claude/skills/codex-deepseek/scripts/codex-ds.sh"
chmod +x "$ED/home/.claude/skills/codex-deepseek/scripts/codex-ds.sh"

rm -f "$ED/ds-ran"
HOME="$ED/home" PATH="$ED/bin:$PATH" CHARLES_STATE_DIR="$ED" CHARLES_PEAK_HOUR=12 bash "$RUN_SH" --lane implement --dir "$ED" --timeout 5 "t" >/dev/null 2>&1
if [ -e "$ED/ds-ran" ]; then
  echo "  PASS  off-peak keeps the deepseek engine"; pass=$((pass+1))
else
  echo "  FAIL  off-peak must stay on deepseek"; fail=$((fail+1))
fi

# the fallback path passes --engine deepseek explicitly; swapping it back to luna
# would send a failed luna dispatch straight back to luna.
rm -f "$ED/ds-ran"
HOME="$ED/home" PATH="$ED/bin:$PATH" CHARLES_STATE_DIR="$ED" CHARLES_PEAK_HOUR=07 bash "$RUN_SH" --lane implement --engine deepseek --dir "$ED" --timeout 5 "t" >/dev/null 2>&1
if [ -e "$ED/ds-ran" ]; then
  echo "  PASS  explicit --engine deepseek is never peak-swapped"; pass=$((pass+1))
else
  echo "  FAIL  explicit --engine deepseek must survive a peak window"; fail=$((fail+1))
fi
rm -f "$RD/engine" "$ED/engine"

# --- sign-off gate ------------------------------------------------------------
SG="$BOX/signoff"; mkdir -p "$SG/docs/specs"
printf '# Plan\n\n## Grill verdict\n\n- Rounds: 2\n' > "$SG/docs/specs/no-section.md"
sg_run="$(bash "$RS" init "$SG" feature "sign-off gate" 2>/dev/null)"
sg_run_md="$SG/.charles/runs/$sg_run/RUN.md"
cp "$sg_run_md" "$SG/no-section.run.before"
cp "$SG/docs/specs/no-section.md" "$SG/no-section.spec.before"
no_section_out="$(bash "$RS" close "$SG" done --spec docs/specs/no-section.md 2>&1)"; no_section_rc=$?
if [ "$no_section_rc" -eq 6 ] && grep -qF 'docs/specs/no-section.md' <<<"$no_section_out" \
  && grep -qF '## Sign-off' <<<"$no_section_out"; then
  echo "  PASS  close refuses spec with no Sign-off section"; pass=$((pass+1))
else
  echo "  FAIL  missing Sign-off section should refuse with exit 6 (rc=$no_section_rc)"; fail=$((fail+1))
fi
if cmp -s "$sg_run_md" "$SG/no-section.run.before" \
  && cmp -s "$SG/docs/specs/no-section.md" "$SG/no-section.spec.before"; then
  echo "  PASS  no-section refusal leaves RUN.md and spec byte-identical"; pass=$((pass+1))
else
  echo "  FAIL  no-section refusal must leave RUN.md and spec byte-identical"; fail=$((fail+1))
fi
bash "$RS" close "$SG" forced --spec docs/specs/no-section.md --force >/dev/null 2>&1
if [ $? -eq 0 ]; then
  echo "  PASS  --force overrides missing Sign-off section"; pass=$((pass+1))
else
  echo "  FAIL  --force should override missing Sign-off section"; fail=$((fail+1))
fi

printf '# Plan\n\n## Grill verdict\n\n- Rounds: 2\n\n## Sign-off\n\n- [ ] unticked requirement — no proof yet\n' \
  > "$SG/docs/specs/unticked.md"
sg_run="$(bash "$RS" init "$SG" feature "unticked sign-off" 2>/dev/null)"
sg_run_md="$SG/.charles/runs/$sg_run/RUN.md"
cp "$sg_run_md" "$SG/unticked.run.before"
cp "$SG/docs/specs/unticked.md" "$SG/unticked.spec.before"
unticked_out="$(bash "$RS" close "$SG" done --spec docs/specs/unticked.md 2>&1)"; unticked_rc=$?
if [ "$unticked_rc" -eq 6 ] && grep -qF 'docs/specs/unticked.md' <<<"$unticked_out" \
  && grep -qF 'unticked' <<<"$unticked_out"; then
  echo "  PASS  close refuses unticked sign-off requirement"; pass=$((pass+1))
else
  echo "  FAIL  unticked Sign-off should refuse with exit 6 (rc=$unticked_rc)"; fail=$((fail+1))
fi
if cmp -s "$sg_run_md" "$SG/unticked.run.before" \
  && cmp -s "$SG/docs/specs/unticked.md" "$SG/unticked.spec.before"; then
  echo "  PASS  unticked refusal leaves RUN.md and spec byte-identical"; pass=$((pass+1))
else
  echo "  FAIL  unticked refusal must leave RUN.md and spec byte-identical"; fail=$((fail+1))
fi
bash "$RS" close "$SG" forced --spec docs/specs/unticked.md --force >/dev/null 2>&1
if [ $? -eq 0 ]; then
  echo "  PASS  --force overrides unticked sign-off requirement"; pass=$((pass+1))
else
  echo "  FAIL  --force should override unticked Sign-off"; fail=$((fail+1))
fi

printf '# Plan\n\n## Grill verdict\n\n- Rounds: 2\n\n## Sign-off\n\n- [x] checked requirement — selftest output\n' \
  > "$SG/docs/specs/ticked.md"
sg_run="$(bash "$RS" init "$SG" feature "ticked sign-off" 2>/dev/null)"
bash "$RS" close "$SG" done --spec docs/specs/ticked.md >/dev/null 2>&1
if [ $? -eq 0 ] && grep -q '^## Outcome$' "$SG/.charles/runs/$sg_run/RUN.md" \
  && grep -q '^## Run outcome' "$SG/docs/specs/ticked.md"; then
  echo "  PASS  close succeeds with every Sign-off box ticked"; pass=$((pass+1))
else
  echo "  FAIL  ticked Sign-off should allow close"; fail=$((fail+1))
fi

sg_run="$(bash "$RS" init "$SG" feature "no spec close" 2>/dev/null)"
bash "$RS" close "$SG" done >/dev/null 2>&1
if [ $? -eq 0 ] && grep -q '^## Outcome$' "$SG/.charles/runs/$sg_run/RUN.md"; then
  echo "  PASS  close without --spec remains unaffected"; pass=$((pass+1))
else
  echo "  FAIL  close without --spec should remain unaffected"; fail=$((fail+1))
fi

printf '# Plan\n\n## Grill verdict\n\n- Rounds: 2\n\n## Sign-off\n' \
  > "$SG/docs/specs/empty.md"
sg_run="$(bash "$RS" init "$SG" feature "empty sign-off" 2>/dev/null)"
sg_run_md="$SG/.charles/runs/$sg_run/RUN.md"
cp "$sg_run_md" "$SG/empty.run.before"
cp "$SG/docs/specs/empty.md" "$SG/empty.spec.before"
empty_out="$(bash "$RS" close "$SG" done --spec docs/specs/empty.md 2>&1)"; empty_rc=$?
if [ "$empty_rc" -eq 6 ] && grep -qF 'section is empty' <<<"$empty_out"; then
  echo "  PASS  close refuses Sign-off section with no ticked line"; pass=$((pass+1))
else
  echo "  FAIL  empty Sign-off should refuse with exit 6 (rc=$empty_rc)"; fail=$((fail+1))
fi
if cmp -s "$sg_run_md" "$SG/empty.run.before" \
  && cmp -s "$SG/docs/specs/empty.md" "$SG/empty.spec.before"; then
  echo "  PASS  empty Sign-off refusal leaves RUN.md and spec byte-identical"; pass=$((pass+1))
else
  echo "  FAIL  empty Sign-off refusal must leave RUN.md and spec byte-identical"; fail=$((fail+1))
fi
bash "$RS" close "$SG" forced --spec docs/specs/empty.md --force >/dev/null 2>&1
if [ $? -eq 0 ] && grep -q '^## Outcome$' "$sg_run_md"; then
  echo "  PASS  --force overrides empty Sign-off refusal"; pass=$((pass+1))
else
  echo "  FAIL  --force should override empty Sign-off refusal"; fail=$((fail+1))
fi

mkdir -p "$BOX/outside"
printf '# Plan\n\n## Grill verdict\n\n- Rounds: 2\n\n## Sign-off\n\n- [x] outside target — selftest output\n' \
  > "$BOX/outside/outside.md"
sg_run="$(bash "$RS" init "$SG" feature "outside spec" 2>/dev/null)"
sg_run_md="$SG/.charles/runs/$sg_run/RUN.md"
cp "$sg_run_md" "$SG/outside.run.before"
cp "$BOX/outside/outside.md" "$SG/outside.spec.before"
outside_out="$(bash "$RS" close "$SG" done --spec ../outside/outside.md 2>&1)"; outside_rc=$?
if [ "$outside_rc" -eq 6 ] && grep -qF 'outside the repository' <<<"$outside_out"; then
  echo "  PASS  close refuses --spec outside the repository"; pass=$((pass+1))
else
  echo "  FAIL  outside --spec should refuse with exit 6 (rc=$outside_rc)"; fail=$((fail+1))
fi
if cmp -s "$sg_run_md" "$SG/outside.run.before" \
  && cmp -s "$BOX/outside/outside.md" "$SG/outside.spec.before"; then
  echo "  PASS  outside-spec refusal leaves RUN.md and spec byte-identical"; pass=$((pass+1))
else
  echo "  FAIL  outside-spec refusal must leave RUN.md and spec byte-identical"; fail=$((fail+1))
fi
# --force is a bookkeeping override, not a licence to write outside the repo.
forced_out="$(bash "$RS" close "$SG" forced --spec ../outside/outside.md --force 2>&1)"; forced_rc=$?
if [ "$forced_rc" -eq 6 ] && grep -qF 'outside the repository' <<<"$forced_out" \
  && cmp -s "$sg_run_md" "$SG/outside.run.before" \
  && cmp -s "$BOX/outside/outside.md" "$SG/outside.spec.before"; then
  echo "  PASS  --force does not override the outside-spec boundary"; pass=$((pass+1))
else
  echo "  FAIL  --force must not write outside the repo (rc=$forced_rc)"; fail=$((fail+1))
fi

# the outside-spec run is still open now that --force cannot close it past the
# boundary; retire it without a spec so the next case has exactly one open run.
bash "$RS" close "$SG" "retired" >/dev/null 2>&1

# no realpath on PATH: a final symlink out of the repo must be refused, not
# written through. PATH is stripped to a shim dir holding everything but realpath.
mkdir -p "$BOX/norp"
# mirror the whole PATH into a shim dir, minus realpath itself
while IFS= read -r tp; do
  tn="${tp##*/}"
  [ "$tn" = "realpath" ] && continue
  [ -e "$BOX/norp/$tn" ] || ln -sf "$tp" "$BOX/norp/$tn" 2>/dev/null
done < <(find ${PATH//:/ } -maxdepth 1 \( -type f -perm -u+x -o -type l \) 2>/dev/null)
ln -sf "$BOX/outside/outside.md" "$SG/docs/specs/link.md"
sg_run="$(bash "$RS" init "$SG" feature "symlink spec" 2>/dev/null)"
sg_run_md="$SG/.charles/runs/$sg_run/RUN.md"
cp "$BOX/outside/outside.md" "$SG/link.spec.before"
link_out="$(PATH="$BOX/norp" bash "$RS" close "$SG" done --spec docs/specs/link.md 2>&1)"; link_rc=$?
if [ "$link_rc" -eq 6 ] && cmp -s "$BOX/outside/outside.md" "$SG/link.spec.before"; then
  echo "  PASS  symlinked --spec is refused when realpath is unavailable"; pass=$((pass+1))
else
  echo "  FAIL  symlinked --spec must not be written through (rc=$link_rc)"; fail=$((fail+1))
fi
bash "$RS" close "$SG" "retired" >/dev/null 2>&1

printf '# Plan\n\n## Grill verdict\n\n- Rounds: 2\n\n## Sign-off\n\n- [x] in-repo target — selftest output\n' \
  > "$SG/docs/specs/inside.md"
sg_run="$(bash "$RS" init "$SG" feature "inside spec" 2>/dev/null)"
sg_run_md="$SG/.charles/runs/$sg_run/RUN.md"
bash "$RS" close "$SG" done --spec docs/specs/inside.md >/dev/null 2>&1
if [ $? -eq 0 ] && grep -q '^## Outcome$' "$sg_run_md" \
  && grep -q '^## Run outcome' "$SG/docs/specs/inside.md"; then
  echo "  PASS  ordinary in-repo --spec close still succeeds"; pass=$((pass+1))
else
  echo "  FAIL  ordinary in-repo --spec close should succeed"; fail=$((fail+1))
fi

# --- documentation contracts: background dispatch and UI router ---------------
# Keep this list documentation-only: executable `&` in dispatcher scripts is
# legitimate and is intentionally outside this assertion.
DOCS=(
  "$REPO_ROOT/skills/charles-flow/SKILL.md"
  "$REPO_ROOT/README.md"
  "$REPO_ROOT/agents/codex-reviewer.md"
  "$REPO_ROOT/commands/debug.md"
  "$REPO_ROOT/commands/polish.md"
  "$REPO_ROOT/commands/ui.md"
  "$REPO_ROOT/commands/status.md"
)
doc_background_bad="$(grep -nE 'nohup|codex-run.*[^&]&[[:space:]]*$|\$RUN.*[^&]&[[:space:]]*$' "${DOCS[@]}" 2>/dev/null || true)"
if [ -z "$doc_background_bad" ]; then
  echo "  PASS  instructional docs use no shell backgrounding"; pass=$((pass+1))
else
  echo "  FAIL  instructional docs contain shell backgrounding"; echo "        $doc_background_bad"; fail=$((fail+1))
fi

background_marker_missing=""
for doc in "${DOCS[@]}"; do
  case "$doc" in
    */skills/charles-flow/SKILL.md|*/README.md|*/agents/codex-reviewer.md|*/commands/debug.md|*/commands/polish.md|*/commands/ui.md) \
      grep -qF 'run_in_background: true' "$doc" || background_marker_missing="$background_marker_missing ${doc#"$REPO_ROOT"/}" ;;
  esac
done
if [ -z "$background_marker_missing" ]; then
  echo "  PASS  explore/implement background docs name run_in_background"; pass=$((pass+1))
else
  echo "  FAIL  background docs missing run_in_background: true:$background_marker_missing"; fail=$((fail+1))
fi

review_doc="$REPO_ROOT/agents/codex-reviewer.md"
if grep -qF 'outer Bash' "$review_doc" \
  && grep -qF 'timeout: 600' "$review_doc" \
  && grep -qF '600s is the ceiling' "$review_doc" \
  && grep -qF 'defaults to' "$review_doc" \
  && grep -qF '120s' "$review_doc"; then
  echo "  PASS  foreground review documents the outer timeout limits"; pass=$((pass+1))
else
  echo "  FAIL  foreground review must document timeout: 600, the 600s ceiling, and 120s default"; fail=$((fail+1))
fi

ui_doc="$REPO_ROOT/commands/ui.md"
ui_green_line="$(grep -nF '"$SCRIPTS/green.sh" "$(pwd)"' "$ui_doc" | head -1 | cut -d: -f1)"
ui_init_line="$(grep -nF '"$SCRIPTS/run-state.sh" init' "$ui_doc" | head -1 | cut -d: -f1)"
if [ -n "$ui_green_line" ] && [ -n "$ui_init_line" ] && [ "$ui_green_line" -lt "$ui_init_line" ]; then
  echo "  PASS  UI runs baseline green before opening the run"; pass=$((pass+1))
else
  echo "  FAIL  UI baseline green must precede run-state init"; fail=$((fail+1))
fi
if grep -qF '"$SCRIPTS/run-state.sh" spec "$(pwd)" docs/specs/<plan>.md' "$ui_doc"; then
  echo "  PASS  UI binds the written plan with run-state spec"; pass=$((pass+1))
else
  echo "  FAIL  UI must bind the written plan with run-state spec"; fail=$((fail+1))
fi
ui_signoff_line="$(grep -nF '## Sign-off' "$ui_doc" | head -1 | cut -d: -f1)"
ui_close_line="$(grep -nF '"$SCRIPTS/run-state.sh" close' "$ui_doc" | head -1 | cut -d: -f1)"
if grep -qF 'run-state.sh" item "$(pwd)" FAILED' "$ui_doc" \
  && [ -n "$ui_signoff_line" ] && [ -n "$ui_close_line" ] \
  && [ "$ui_signoff_line" -lt "$ui_close_line" ] \
  && grep -qF 'unsourced working-tree changes' "$REPO_ROOT/commands/status.md"; then
  echo "  PASS  UI records failed receipts, signs off before close, and status names unsourced changes"; pass=$((pass+1))
else
  echo "  FAIL  UI/status lifecycle wording is incomplete"; fail=$((fail+1))
fi

flow_skill="$REPO_ROOT/skills/charles-flow/SKILL.md"
if grep -qF '## Select by work-kind' "$flow_skill" \
  && grep -qF '| Work-kind | Destination |' "$flow_skill" \
  && grep -qF '| UI/UX work — router, not a flow |' "$flow_skill" \
  && grep -qF 'This one is a **router, not a flow**' "$flow_skill"; then
  echo "  PASS  flow selector table keeps UI as a router"; pass=$((pass+1))
else
  echo "  FAIL  flow selector table must keep UI as a router"; fail=$((fail+1))
fi
if grep -qE 'top-level bullets.*optional.*\[ \].*\[x\].*\[X\]' "$flow_skill" \
  && grep -qF '`**ID`' "$flow_skill" \
  && grep -qE 'terminated by.*\*\*.*whitespace.*dot' "$flow_skill" \
  && grep -qE 'non-digit.*end of line' "$flow_skill" \
  && grep -qF -- 'Example: `- [ ] **R1**' "$flow_skill" \
  && grep -qF 'IDs below `## Sign-off`' "$flow_skill" \
  && grep -qF 'do not count for dispatch' "$flow_skill"; then
  echo "  PASS  flow docs spell out dispatchable requirement bullets"; pass=$((pass+1))
else
  echo "  FAIL  flow docs must spell out dispatchable requirement bullets"; fail=$((fail+1))
fi

# --- R5 grill gate ------------------------------------------------------------
R5DIR="$BOX/r5-grill"; mkdir -p "$R5DIR/bin" "$R5DIR/docs/specs" "$R5DIR/.charles/runs/open-run"
cp "$REQDIR/bin/codex" "$R5DIR/bin/codex"
r5_run_md="$R5DIR/.charles/runs/open-run/RUN.md"
r5_log="$R5DIR/.charles/dispatches.jsonl"

printf '# Plan\n\n- [ ] **R1. ungrilled**\n' > "$R5DIR/docs/specs/ungrilled.md"
printf '# Run open-run\n\n- flow: feature\n- spec: docs/specs/ungrilled.md\n\n## Phases\n\n## Open items\n\n## Rollback\n\n' > "$r5_run_md"
r5_out="$(PATH="$R5DIR/bin:$PATH" CHARLES_STATE_DIR="$R5DIR/state" \
  CHARLES_LANE_MARKER="$R5DIR/lane-ran" \
  bash "$RUN_SH" --lane implement --dir "$R5DIR" --req R1 --no-fallback --timeout 2 "r5 ungrilled" 2>&1)"; r5_rc=$?
if [ "$r5_rc" -eq 5 ] \
  && grep -qF 'docs/specs/ungrilled.md' <<<"$r5_out" \
  && grep -qF "missing '- Rounds:' or 'Grill waived: <reason>'" <<<"$r5_out"; then
  echo "  PASS  R5 refuses an ungrilled spec with the missing marker"; pass=$((pass+1))
else
  echo "  FAIL  R5 must refuse an ungrilled spec (rc=$r5_rc): $r5_out"; fail=$((fail+1))
fi
if [ ! -s "$r5_log" ] && [ ! -e "$R5DIR/lane-ran" ]; then
  echo "  PASS  R5 refusal writes no dispatch event or lane marker"; pass=$((pass+1))
else
  echo "  FAIL  R5 refusal must write no dispatch event or lane marker"; fail=$((fail+1))
fi

printf '# Plan\n\n## Grill verdict\n\n- Reviewer note: first section has no marker.\n\n## Grill verdict\n\n- Rounds: 2\n\n- [ ] **R1. duplicate heading**\n' > "$R5DIR/docs/specs/duplicate.md"
printf '# Run open-run\n\n- flow: feature\n- spec: docs/specs/duplicate.md\n\n## Phases\n\n## Open items\n\n## Rollback\n\n' > "$r5_run_md"
r5_duplicate_out="$(PATH="$R5DIR/bin:$PATH" CHARLES_STATE_DIR="$R5DIR/state" \
  bash "$RUN_SH" --lane implement --dir "$R5DIR" --req R1 --validate-only --no-fallback --timeout 2 \
  "r5 duplicate verdict" 2>&1)"; r5_duplicate_rc=$?
if [ "$r5_duplicate_rc" -eq 5 ] \
  && grep -qF 'docs/specs/duplicate.md' <<<"$r5_duplicate_out" \
  && grep -qF "missing '- Rounds:' or 'Grill waived: <reason>'" <<<"$r5_duplicate_out"; then
  echo "  PASS  R5 uses only the first duplicate Grill verdict section"; pass=$((pass+1))
else
  echo "  FAIL  R5 must refuse a marker found only in a duplicate verdict section (rc=$r5_duplicate_rc): $r5_duplicate_out"; fail=$((fail+1))
fi

printf '# Plan\n\n## Grill verdict\n\n- Rounds: 2\n\n- [ ] **R1. rounds acceptance**\n' > "$R5DIR/docs/specs/rounds.md"
printf '# Run open-run\n\n- flow: feature\n- spec: docs/specs/rounds.md\n\n## Phases\n\n## Open items\n\n## Rollback\n\n' > "$r5_run_md"
r5_out="$(PATH="$R5DIR/bin:$PATH" CHARLES_STATE_DIR="$R5DIR/state" \
  bash "$RUN_SH" --lane implement --dir "$R5DIR" --req R1 --no-fallback --timeout 2 "r5 rounds" 2>&1)"; r5_rc=$?
if [ "$r5_rc" -eq 0 ] \
  && jq -e 'select(.event == "start" and .grill == "rounds")' "$r5_log" >/dev/null 2>&1 \
  && jq -e 'select(.event == "end" and .grill == "rounds")' "$r5_log" >/dev/null 2>&1; then
  echo "  PASS  R5 accepts a Rounds verdict and records it on both events"; pass=$((pass+1))
else
  echo "  FAIL  R5 must accept and record a Rounds verdict (rc=$r5_rc): $r5_out"; fail=$((fail+1))
fi

: > "$r5_log"
printf '# Plan\n\n## Grill verdict\n\nGrill waived: UI router has no grill step by design.\n\n- [ ] **R1. waiver acceptance**\n' > "$R5DIR/docs/specs/waiver.md"
printf '# Run open-run\n\n- flow: ui\n- spec: docs/specs/waiver.md\n\n## Phases\n\n## Open items\n\n## Rollback\n\n' > "$r5_run_md"
r5_out="$(PATH="$R5DIR/bin:$PATH" CHARLES_STATE_DIR="$R5DIR/state" \
  bash "$RUN_SH" --lane implement --dir "$R5DIR" --req R1 --no-fallback --timeout 2 "r5 waiver" 2>&1)"; r5_rc=$?
if [ "$r5_rc" -eq 0 ] \
  && jq -e 'select(.event == "start" and .grill == "waived")' "$r5_log" >/dev/null 2>&1 \
  && jq -e 'select(.event == "end" and .grill == "waived")' "$r5_log" >/dev/null 2>&1; then
  echo "  PASS  R5 accepts a non-empty waiver and records it on both events"; pass=$((pass+1))
else
  echo "  FAIL  R5 must accept and record a waiver (rc=$r5_rc): $r5_out"; fail=$((fail+1))
fi

printf '# Plan\n\n## Grill verdict\n\n_(pending)_\n\n- [ ] **R1. pending verdict**\n' > "$R5DIR/docs/specs/pending.md"
printf '# Run open-run\n\n- flow: feature\n- spec: docs/specs/pending.md\n\n## Phases\n\n## Open items\n\n## Rollback\n\n' > "$r5_run_md"
r5_out="$(PATH="$R5DIR/bin:$PATH" CHARLES_STATE_DIR="$R5DIR/state" \
  bash "$RUN_SH" --lane implement --dir "$R5DIR" --req R1 --validate-only --no-fallback --timeout 2 "r5 pending" 2>&1)"; r5_rc=$?
if [ "$r5_rc" -eq 5 ] \
  && grep -qF 'docs/specs/pending.md' <<<"$r5_out" \
  && grep -qF "missing '- Rounds:' or 'Grill waived: <reason>'" <<<"$r5_out"; then
  echo "  PASS  R5 refuses a placeholder pending verdict"; pass=$((pass+1))
else
  echo "  FAIL  R5 must refuse a placeholder pending verdict (rc=$r5_rc): $r5_out"; fail=$((fail+1))
fi

printf '# Plan\n\n- [ ] **R1. parallel ungrilled**\n' > "$PD/r10-repo/docs/specs/parallel-ungrilled.md"
printf '[{"name":"alpha","files":["r5-parallel-alpha"],"task":"x","req":["R1"]},{"name":"beta","files":["r5-parallel-beta"],"task":"x","req":["R1"]}]\n' \
  > "$PD/r10-repo/docs/specs/parallel-ungrilled.chunks.json"
mkdir -p "$PD/r10-repo/.charles/runs/r5-parallel"
printf '# Run r5-parallel\n\n- flow: feature\n- spec: docs/specs/parallel-ungrilled.md\n\n## Phases\n\n## Open items\n\n## Rollback\n\n' \
  > "$PD/r10-repo/.charles/runs/r5-parallel/RUN.md"
r5_parallel_out="$(PATH="$PD/bin:$PATH" CHARLES_STATE_DIR="$PD/state" \
  bash "$PARALLEL" "$PD/r10-repo" "$PD/r10-repo/docs/specs/parallel-ungrilled.chunks.json" \
  --run r5-parallel --no-green 2>&1)"; r5_parallel_rc=$?
if [ "$r5_parallel_rc" -eq 1 ] \
  && grep -qF 'invalid manifest: chunk alpha requirement scope was refused' <<<"$r5_parallel_out" \
  && grep -qF "missing '- Rounds:' or 'Grill waived: <reason>'" <<<"$r5_parallel_out"; then
  echo "  PASS  parallel preflight refuses an ungrilled spec"; pass=$((pass+1))
else
  echo "  FAIL  parallel preflight must refuse an ungrilled spec (rc=$r5_parallel_rc): $r5_parallel_out"; fail=$((fail+1))
fi

# --- R6 review coverage -------------------------------------------------------
# Use the real dispatcher and status scripts with the existing fake codex lane;
# reviews are receipt fixtures, never live model calls.
R6DIR="$BOX/r6-review-scope"; mkdir -p "$R6DIR/bin" "$R6DIR/docs/specs" "$R6DIR/.charles/runs/run-a"
cp "$REQDIR/bin/codex" "$R6DIR/bin/codex"
printf 'green = "true"\n' > "$R6DIR/.charles.toml"
printf '# Plan\n\n## Grill verdict\n\n- Rounds: 1\n\n- [ ] **R1. review scope**\n' > "$R6DIR/docs/specs/plan.md"
printf '# Run run-a\n\n- flow: feature\n- spec: docs/specs/plan.md\n\n## Phases\n\n## Open items\n\n## Rollback\n\n' \
  > "$R6DIR/.charles/runs/run-a/RUN.md"
( cd "$R6DIR" && git init -q && git config user.name tester && git config user.email tester@example.invalid && \
  printf 'base\n' > tracked && git add .charles.toml docs/specs/plan.md tracked && git commit -qm init ) >/dev/null 2>&1
r6_impl_out="$(PATH="$R6DIR/bin:$PATH" CHARLES_STATE_DIR="$R6DIR/state" \
  bash "$RUN_SH" --lane implement --allow-main-tree --dir "$R6DIR" --req R1 --no-fallback --timeout 2 "r6 implement" 2>&1)"; r6_impl_rc=$?
r6_spec_path="$(realpath "$R6DIR/docs/specs/plan.md")"
r6_impl_ts="$(jq -r 'select(.event == "end" and .lane == "implement") | .ts' \
  "$R6DIR/.charles/dispatches.jsonl" 2>/dev/null | tail -1)"
r6_identity_ok=0
if jq -e -s --arg f run-a --arg s "$r6_spec_path" \
  'length > 0 and all(.[]; (.flow_run_id == $f and .spec_path == $s))' \
  "$R6DIR/.charles/dispatches.jsonl" >/dev/null 2>&1; then
  r6_identity_ok=1
fi
printf '\n## Outcome\n\nfixture closed\n' >> "$R6DIR/.charles/runs/run-a/RUN.md"
r6_review_b_ts="$(date -u -d "${r6_impl_ts:-1970-01-01T00:00:00Z} + 1 second" +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","event":"end","lane":"review","engine":"review","model":"m","rc":0,"run":"dispatch-b","dir":"%s","task":"run B","flow_run_id":"run-b","spec_path":"%s/other.md"}\n' \
  "$r6_review_b_ts" "$R6DIR" "$R6DIR/docs/specs" >> "$R6DIR/.charles/dispatches.jsonl"
r6_cross_out="$(CHARLES_STATE_DIR="$R6DIR/state" bash "$FS" "$R6DIR" 2>&1)"; r6_cross_rc=$?
if [ "$r6_impl_rc" -eq 0 ] && [ "$r6_identity_ok" -eq 1 ] && [ "$r6_cross_rc" -eq 1 ] \
  && grep -q 'ISSUE.*1 implement dispatch(es) never reviewed' <<<"$r6_cross_out"; then
  echo "  PASS  R6 run B review does not clear run A implement (fields recorded)"; pass=$((pass+1))
else
  echo "  FAIL  R6 review coverage must stay within its run (rc=$r6_cross_rc, implement rc=$r6_impl_rc): $r6_cross_out"; fail=$((fail+1))
fi

r6_legacy_review_ts="$(date -u -d "${r6_impl_ts:-1970-01-01T00:00:00Z} + 3 seconds" +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","event":"end","lane":"review","engine":"review","model":"m","rc":0,"run":"dispatch-legacy","dir":"%s","task":"legacy review"}\n' \
  "$r6_legacy_review_ts" "$R6DIR" >> "$R6DIR/.charles/dispatches.jsonl"
r6_legacy_out="$(CHARLES_STATE_DIR="$R6DIR/state" bash "$FS" "$R6DIR" 2>&1)"; r6_legacy_rc=$?
if [ "$r6_legacy_rc" -eq 0 ] && ! grep -q 'never reviewed' <<<"$r6_legacy_out"; then
  echo "  PASS  R6 legacy review clears an identity-bearing implement"; pass=$((pass+1))
else
  echo "  FAIL  R6 legacy review must clear an identity-bearing implement (rc=$r6_legacy_rc): $r6_legacy_out"; fail=$((fail+1))
fi

r6_review_a_ts="$(date -u -d "${r6_impl_ts:-1970-01-01T00:00:00Z} + 2 seconds" +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","event":"end","lane":"review","engine":"review","model":"m","rc":0,"run":"dispatch-c","dir":"%s","task":"same run","flow_run_id":"run-a","spec_path":"%s"}\n' \
  "$r6_review_a_ts" "$R6DIR" "$r6_spec_path" >> "$R6DIR/.charles/dispatches.jsonl"
r6_same_out="$(CHARLES_STATE_DIR="$R6DIR/state" bash "$FS" "$R6DIR" 2>&1)"; r6_same_rc=$?
if [ "$r6_same_rc" -eq 0 ] && ! grep -q 'never reviewed' <<<"$r6_same_out"; then
  echo "  PASS  R6 same-run review clears the implement"; pass=$((pass+1))
else
  echo "  FAIL  R6 same-run review must clear the implement (rc=$r6_same_rc): $r6_same_out"; fail=$((fail+1))
fi

: > "$R6DIR/.charles/dispatches.jsonl"
r6_old_i1="$(date -u -d '3 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
r6_old_review="$(date -u -d '2 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
r6_old_i2="$(date -u -d '1 minute ago' +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","event":"end","lane":"implement","engine":"luna","model":"m","rc":0,"run":"old-implement-a","dir":"%s","task":"old A"}\n' \
  "$r6_old_i1" "$R6DIR" > "$R6DIR/.charles/dispatches.jsonl"
printf '{"ts":"%s","event":"end","lane":"review","engine":"review","model":"m","rc":0,"run":"old-review-b","dir":"%s","task":"old B"}\n' \
  "$r6_old_review" "$R6DIR" >> "$R6DIR/.charles/dispatches.jsonl"
printf '{"ts":"%s","event":"end","lane":"implement","engine":"luna","model":"m","rc":0,"run":"old-implement-c","dir":"%s","task":"old C"}\n' \
  "$r6_old_i2" "$R6DIR" >> "$R6DIR/.charles/dispatches.jsonl"
r6_old_out="$(CHARLES_STATE_DIR="$R6DIR/state" bash "$FS" "$R6DIR" 2>&1)"; r6_old_rc=$?
if [ "$r6_old_rc" -eq 1 ] && grep -q 'ISSUE.*1 implement dispatch(es) never reviewed' <<<"$r6_old_out" \
  && grep -q 'repo total: 2 implements, 1 reviews' <<<"$r6_old_out" \
  && jq -e -s 'all(.[]; (has("flow_run_id") | not) and (has("spec_path") | not))' "$R6DIR/.charles/dispatches.jsonl" >/dev/null 2>&1; then
  echo "  PASS  R6 old-format records retain global review behavior"; pass=$((pass+1))
else
  echo "  FAIL  R6 old-format records must match the prior global result (rc=$r6_old_rc): $r6_old_out"; fail=$((fail+1))
fi

# --- release flow coverage ----------------------------------------------------
FLOW_JSON="$REPO_ROOT/scripts/flow.json"
if jq -e '
  def strings: type == "array" and all(.[]; type == "string");
  . as $root |
  ($root | type == "object") and
  all(["feature", "debug", "polish", "ui", "release"][];
    . as $flow |
    ($root[$flow] | type == "object") and
    ($root[$flow].phases | type == "object") and
    ($root[$flow].first | type == "string") and
    ($root[$flow].terminal | strings) and
    ([$root[$flow].phases[] | type == "object" and (.next | strings) and (.proof | type == "string")] | all)
  ) and
  ($root.release.first == "guard") and
  ($root.release.terminal == ["ship"]) and
  ($root.release.phases.guard.next == ["green"]) and
  ($root.release.phases.green.next == ["version"]) and
  ($root.release.phases.version.next == ["ship"]) and
  ($root.release.phases.ship.next == ["close"])
' "$FLOW_JSON" >/dev/null 2>&1; then
  echo "  PASS  flow.json validates all five flows, including release"; pass=$((pass+1))
else
  echo "  FAIL  flow.json must structurally validate the release flow"; fail=$((fail+1))
fi

RELEASE_FLOW="$BOX/flow-release"; mkdir -p "$RELEASE_FLOW"
release_init="$(bash "$RS" init "$RELEASE_FLOW" release "release fixture" 2>"$RELEASE_FLOW/init.err")"; release_init_rc=$?
release_run="$RELEASE_FLOW/.charles/runs/$release_init/RUN.md"
release_guard_out="$(bash "$RS" phase "$RELEASE_FLOW" guard "clean .claude-plugin/" 2>"$RELEASE_FLOW/guard.err")"; release_guard_rc=$?
release_status="$(bash "$FS" "$RELEASE_FLOW" 2>&1)"; release_status_rc=$?
if [ "$release_status_rc" -eq 1 ] && [ "$release_guard_rc" -eq 0 ] \
  && grep -q 'expected next: green' <<<"$release_status" \
  && ! grep -qi 'not in flow.json' <<<"$release_status"; then
  echo "  PASS  release flow-status gives phase guidance"; pass=$((pass+1))
else
  echo "  FAIL  release flow-status must guide the next phase (rc=$release_status_rc): $release_status"; fail=$((fail+1))
fi

release_phase_rc="$release_guard_rc"
bash "$RS" phase "$RELEASE_FLOW" green "green command passed" >/dev/null 2>&1 || release_phase_rc=1
bash "$RS" phase "$RELEASE_FLOW" version "version fields written" >/dev/null 2>&1 || release_phase_rc=1
bash "$RS" phase "$RELEASE_FLOW" ship "installed cache verified" >/dev/null 2>&1 || release_phase_rc=1
release_close_out="$(bash "$RS" close "$RELEASE_FLOW" "release fixture complete" 2>&1)"; release_close_rc=$?
if [ "$release_init_rc" -eq 0 ] && [ "$release_phase_rc" -eq 0 ] \
  && [ "$release_close_rc" -eq 0 ] && [ -f "$release_run" ] \
  && grep -q ' guard$' "$release_run" \
  && grep -q ' green$' "$release_run" \
  && grep -q ' version$' "$release_run" \
  && grep -q ' ship$' "$release_run" \
  && grep -q '^## Outcome$' "$release_run"; then
  echo "  PASS  release run opens, records phases, and closes normally"; pass=$((pass+1))
else
  echo "  FAIL  release run must use init, phase, and normal close (init rc=$release_init_rc, phase rc=$release_phase_rc, close rc=$release_close_rc): $release_close_out"; fail=$((fail+1))
fi

# --- ops flow coverage --------------------------------------------------------
if jq -e '
  def strings: type == "array" and all(.[]; type == "string");
  . as $root |
  ($root | type == "object") and
  ($root.ops | type == "object") and
  ($root.ops.phases | type == "object") and
  ($root.ops.first == "survey") and
  ($root.ops.terminal == ["report"]) and
  ([$root.ops.phases[] | type == "object" and (.next | strings) and (.proof | type == "string")] | all) and
  ($root.ops.phases.survey.next == ["select"]) and
  ($root.ops.phases.select.next == ["recover"]) and
  ($root.ops.phases.recover.next == ["report"]) and
  ($root.ops.phases.report.next == ["close"])
' "$FLOW_JSON" >/dev/null 2>&1; then
  echo "  PASS  flow.json structurally validates the ops flow"; pass=$((pass+1))
else
  echo "  FAIL  flow.json must structurally validate the ops flow"; fail=$((fail+1))
fi

OPS_FLOW="$BOX/flow-ops"; mkdir -p "$OPS_FLOW"
ops_init="$(bash "$RS" init "$OPS_FLOW" ops "ops fixture" 2>"$OPS_FLOW/init.err")"; ops_init_rc=$?
ops_status="$(bash "$FS" "$OPS_FLOW" 2>&1)"; ops_status_rc=$?
if [ "$ops_init_rc" -eq 0 ] && [ "$ops_status_rc" -eq 1 ] \
  && grep -q 'expected next: survey' <<<"$ops_status" \
  && ! grep -q "flow 'ops' is not in flow.json" <<<"$ops_status"; then
  echo "  PASS  ops flow-status gives phase guidance"; pass=$((pass+1))
else
  echo "  FAIL  ops flow-status must guide the first phase (init rc=$ops_init_rc, status rc=$ops_status_rc): $ops_status"; fail=$((fail+1))
fi

ops_run="$OPS_FLOW/.charles/runs/$ops_init/RUN.md"
ops_phase_rc=0
for ops_phase in survey select recover report; do
  bash "$RS" phase "$OPS_FLOW" "$ops_phase" "ops fixture $ops_phase" >/dev/null 2>"$OPS_FLOW/$ops_phase.err" || ops_phase_rc=1
done
ops_close_out="$(bash "$RS" close "$OPS_FLOW" "ops fixture complete" 2>&1)"; ops_close_rc=$?
if [ "$ops_init_rc" -eq 0 ] && [ "$ops_phase_rc" -eq 0 ] \
  && [ "$ops_close_rc" -eq 0 ] && [ -f "$ops_run" ] \
  && grep -q ' survey$' "$ops_run" \
  && grep -q ' select$' "$ops_run" \
  && grep -q ' recover$' "$ops_run" \
  && grep -q ' report$' "$ops_run" \
  && grep -q '^## Outcome$' "$ops_run"; then
  echo "  PASS  ops run opens, records phases, and closes normally"; pass=$((pass+1))
else
  echo "  FAIL  ops run must use init, phase, and normal close (init rc=$ops_init_rc, phase rc=$ops_phase_rc, close rc=$ops_close_rc): $ops_close_out"; fail=$((fail+1))
fi

OPS_SWEEP_ROOT="$BOX/ops-sweep-root"
OPS_SWEEP_REPO="$OPS_SWEEP_ROOT/fixture-repo"
OPS_SWEEP_RUN="$OPS_SWEEP_REPO/.charles/runs/open-run/RUN.md"
mkdir -p "$(dirname "$OPS_SWEEP_RUN")"
printf 'green = "true"\n' > "$OPS_SWEEP_REPO/.charles.toml"
printf '# Run open-run\n\n- flow: feature\n- goal: read-only sweep\n\n## Phases\n\n## Open items\n\n## Rollback\n\n' \
  > "$OPS_SWEEP_RUN"
ops_sweep_paths_before="$(find "$OPS_SWEEP_ROOT" -print | sort)"
ops_sweep_content_before="$(sha256sum "$OPS_SWEEP_RUN")"
ops_sweep_out="$(bash "$SWEEP" "$OPS_SWEEP_ROOT" 2>&1)"; ops_sweep_rc=$?
ops_sweep_paths_after="$(find "$OPS_SWEEP_ROOT" -print | sort)"
ops_sweep_content_after="$(sha256sum "$OPS_SWEEP_RUN")"
if [ "$ops_sweep_rc" -eq 0 ] \
  && grep -qF 'fixture-repo · open-run' <<<"$ops_sweep_out" \
  && [ -f "$OPS_SWEEP_RUN" ] \
  && ! grep -q '^## Outcome$' "$OPS_SWEEP_RUN" \
  && ! grep -q '^## Abandoned$' "$OPS_SWEEP_RUN" \
  && [ "$ops_sweep_paths_before" = "$ops_sweep_paths_after" ] \
  && [ "$ops_sweep_content_before" = "$ops_sweep_content_after" ]; then
  echo "  PASS  ops sweep leaves a temporary open run untouched"; pass=$((pass+1))
else
  echo "  FAIL  ops sweep must leave its temporary open run open and unchanged (rc=$ops_sweep_rc): $ops_sweep_out"; fail=$((fail+1))
fi

# Documentation assertion only; this does not exercise recovery behavior.
if grep -qF "HARD RULE: NEVER close, abandon, or delete another repository's run without" \
  "$REPO_ROOT/commands/ops.md" \
  && grep -qF 'EXPLICIT human confirmation' "$REPO_ROOT/commands/ops.md"; then
  echo "  PASS  ops docs require explicit confirmation before cross-repo recovery"; pass=$((pass+1))
else
  echo "  FAIL  ops docs must require explicit human confirmation before cross-repo recovery"; fail=$((fail+1))
fi

# --- A3 resolve and A4 run selection -------------------------------------------
A3="$BOX/a3-resolve"; A3_RUN="$A3/.charles/runs/a3-run"; mkdir -p "$A3_RUN"
printf '# Run a3-run\n\n- flow: feature\n\n## Phases\n\n## Open items\n\n- [ ] **PENDING-DECISION** — unique alpha\n- [ ] **DEFERRED** — duplicate alpha\n- [ ] **FAILED** — duplicate alpha\n\n## Rollback\n\n' \
  > "$A3_RUN/RUN.md"
a3_resolve_out="$(bash "$RS" resolve "$A3" "unique alpha" "closed by selftest" 2>&1)"; a3_resolve_rc=$?
if [ "$a3_resolve_rc" -eq 0 ] \
  && grep -qF -- '- [x] **PENDING-DECISION** — unique alpha — resolved: closed by selftest' "$A3_RUN/RUN.md" \
  && grep -qF -- '- [ ] **DEFERRED** — duplicate alpha' "$A3_RUN/RUN.md" \
  && grep -qF -- '- [ ] **FAILED** — duplicate alpha' "$A3_RUN/RUN.md"; then
  echo "  PASS  resolve ticks one item and appends its note"; pass=$((pass+1))
else
  echo "  FAIL  resolve must tick one item and append its note (rc=$a3_resolve_rc): $a3_resolve_out"; fail=$((fail+1))
fi
a3_ambig_out="$(bash "$RS" resolve "$A3" "duplicate alpha" "should not apply" 2>&1)"; a3_ambig_rc=$?
if [ "$a3_ambig_rc" -eq 2 ] \
  && grep -qF "selector 'duplicate alpha' is ambiguous" <<<"$a3_ambig_out" \
  && grep -qF -- '- [ ] **DEFERRED** — duplicate alpha' <<<"$a3_ambig_out" \
  && grep -qF -- '- [ ] **FAILED** — duplicate alpha' <<<"$a3_ambig_out"; then
  echo "  PASS  resolve refuses an ambiguous selector and names every candidate"; pass=$((pass+1))
else
  echo "  FAIL  ambiguous resolve must name every candidate (rc=$a3_ambig_rc): $a3_ambig_out"; fail=$((fail+1))
fi
a3_missing_out="$(bash "$RS" resolve "$A3" "not present" "should not apply" 2>&1)"; a3_missing_rc=$?
if [ "$a3_missing_rc" -eq 2 ] && grep -qF "selector 'not present' matches no open item" <<<"$a3_missing_out"; then
  echo "  PASS  resolve refuses a selector with no match"; pass=$((pass+1))
else
  echo "  FAIL  resolve must refuse a selector with no match (rc=$a3_missing_rc): $a3_missing_out"; fail=$((fail+1))
fi

A4="$BOX/a4-run-selection"; mkdir -p "$A4/.charles/runs/run-a" "$A4/.charles/runs/run-b"
for a4_run in run-a run-b; do
  printf '# Run %s\n\n- flow: feature\n\n## Phases\n\n## Open items\n\n## Rollback\n\n' "$a4_run" \
    > "$A4/.charles/runs/$a4_run/RUN.md"
done
a4_multi_out="$(bash "$RS" phase "$A4" "ambiguous phase" 2>&1)"; a4_multi_rc=$?
if [ "$a4_multi_rc" -eq 2 ] \
  && grep -qF 'multiple open runs' <<<"$a4_multi_out" \
  && grep -qF 'run-a' <<<"$a4_multi_out" && grep -qF 'run-b' <<<"$a4_multi_out"; then
  echo "  PASS  mutating run-state verb refuses two open runs without --run"; pass=$((pass+1))
else
  echo "  FAIL  mutating run-state verb must name both ambiguous runs (rc=$a4_multi_rc): $a4_multi_out"; fail=$((fail+1))
fi
a4_selected_out="$(bash "$RS" phase "$A4" "selected phase" --run run-a 2>&1)"; a4_selected_rc=$?
if [ "$a4_selected_rc" -eq 0 ] \
  && grep -qF 'selected phase' "$A4/.charles/runs/run-a/RUN.md" \
  && ! grep -qF 'selected phase' "$A4/.charles/runs/run-b/RUN.md"; then
  echo "  PASS  mutating run-state verb succeeds with --run"; pass=$((pass+1))
else
  echo "  FAIL  --run must select only the requested run (rc=$a4_selected_rc): $a4_selected_out"; fail=$((fail+1))
fi
A4_SINGLE="$BOX/a4-single"; mkdir -p "$A4_SINGLE/.charles/runs/only-run"
printf '# Run only-run\n\n- flow: feature\n\n## Phases\n\n## Open items\n\n## Rollback\n\n' \
  > "$A4_SINGLE/.charles/runs/only-run/RUN.md"
a4_single_out="$(bash "$RS" phase "$A4_SINGLE" "single open phase" 2>&1)"; a4_single_rc=$?
if [ "$a4_single_rc" -eq 0 ] && grep -qF 'single open phase' "$A4_SINGLE/.charles/runs/only-run/RUN.md"; then
  echo "  PASS  mutating run-state verb keeps the single-open-run behavior"; pass=$((pass+1))
else
  echo "  FAIL  one open run must still accept the mutating verb (rc=$a4_single_rc): $a4_single_out"; fail=$((fail+1))
fi

# --- A5 recorded-spec close gates ----------------------------------------------
A5_UNTICKED="$BOX/a5-unticked"; mkdir -p "$A5_UNTICKED/docs/specs" "$A5_UNTICKED/.charles/runs/unticked"
printf '# Unticked plan\n\n## Grill verdict\n\n- Rounds: 1\n\n## Sign-off\n\n- [x] shipped\n- [ ] pending\n' \
  > "$A5_UNTICKED/docs/specs/plan.md"
printf '# Run unticked\n\n- flow: feature\n- spec: docs/specs/plan.md\n- started: 2026-09-03T00:00:00Z\n\n## Phases\n\n## Open items\n\n## Rollback\n\n' \
  > "$A5_UNTICKED/.charles/runs/unticked/RUN.md"
a5_unticked_out="$(bash "$RS" close "$A5_UNTICKED" "unticked close" 2>&1)"; a5_unticked_rc=$?
if [ "$a5_unticked_rc" -eq 6 ] \
  && grep -qF 'unticked sign-off requirements' <<<"$a5_unticked_out" \
  && grep -qF 'docs/specs/plan.md' <<<"$a5_unticked_out"; then
  echo "  PASS  bare close applies the recorded spec sign-off gate"; pass=$((pass+1))
else
  echo "  FAIL  bare close must refuse an unticked recorded sign-off (rc=$a5_unticked_rc): $a5_unticked_out"; fail=$((fail+1))
fi

A5_EMPTY="$BOX/a5-empty-signoff"; mkdir -p "$A5_EMPTY/docs/specs" "$A5_EMPTY/.charles/runs/empty"
printf '# Empty sign-off plan\n\n## Grill verdict\n\n- Rounds: 1\n\n## Sign-off\n\n_(pending)_\n' \
  > "$A5_EMPTY/docs/specs/plan.md"
printf '# Run empty\n\n- flow: feature\n- spec: docs/specs/plan.md\n- started: 2026-09-03T00:00:00Z\n\n## Phases\n\n## Open items\n\n## Rollback\n\n' \
  > "$A5_EMPTY/.charles/runs/empty/RUN.md"
a5_empty_out="$(bash "$RS" close "$A5_EMPTY" "empty close" 2>&1)"; a5_empty_rc=$?
if [ "$a5_empty_rc" -eq 6 ] \
  && grep -qF 'has no ticked requirements' <<<"$a5_empty_out" \
  && grep -qF 'docs/specs/plan.md' <<<"$a5_empty_out"; then
  echo "  PASS  bare close refuses a sign-off section with no ticked line"; pass=$((pass+1))
else
  echo "  FAIL  bare close must refuse an empty recorded sign-off (rc=$a5_empty_rc): $a5_empty_out"; fail=$((fail+1))
fi
a5_force_out="$(bash "$RS" close "$A5_EMPTY" "forced empty close" --force 2>&1)"; a5_force_rc=$?
if [ "$a5_force_rc" -eq 0 ] \
  && grep -q '^## Outcome$' "$A5_EMPTY/.charles/runs/empty/RUN.md" \
  && grep -qF 'forced empty close' "$A5_EMPTY/docs/specs/plan.md"; then
  echo "  PASS  --force still overrides the recorded-spec close gate"; pass=$((pass+1))
else
  echo "  FAIL  --force must still close a gated recorded-spec run (rc=$a5_force_rc): $a5_force_out"; fail=$((fail+1))
fi

A5_NONE="$BOX/a5-no-spec"; mkdir -p "$A5_NONE/.charles/runs/no-spec"
printf '# Run no-spec\n\n- flow: feature\n- started: 2026-09-03T00:00:00Z\n\n## Phases\n\n## Open items\n\n## Rollback\n\n' \
  > "$A5_NONE/.charles/runs/no-spec/RUN.md"
a5_none_out="$(bash "$RS" close "$A5_NONE" "no recorded spec" 2>&1)"; a5_none_rc=$?
if [ "$a5_none_rc" -eq 0 ] \
  && grep -q '^## Outcome$' "$A5_NONE/.charles/runs/no-spec/RUN.md" \
  && ! grep -qF 'Run outcome' "$A5_NONE/.charles/runs/no-spec/RUN.md"; then
  echo "  PASS  bare close without a recorded spec keeps the old behavior"; pass=$((pass+1))
else
  echo "  FAIL  a run with no recorded spec must close as before (rc=$a5_none_rc): $a5_none_out"; fail=$((fail+1))
fi

# --- A1 close attribution ------------------------------------------------------
# One close-time fixture covers foreign, closing-run, legacy, and watchdog end
# records together; no real lane is needed for the receipt census.
A1="$BOX/a1-close-attribution"; A1_STATE="$A1/state"; A1_SPEC="$A1/docs/specs/plan.md"
mkdir -p "$A1/.charles/runs/a1-close" "$(dirname "$A1_SPEC")" "$A1_STATE"
printf 'green = "true"\n' > "$A1/.charles.toml"
printf '# Plan\n\n## Grill verdict\n\n- Rounds: 1\n' > "$A1_SPEC"
printf '# Run a1-close\n\n- flow: feature\n- spec: docs/specs/plan.md\n- started: 2026-09-03T00:00:00Z\n\n## Phases\n\n- [00:00Z] verify\n\n## Open items\n\n## Rollback\n\n' \
  > "$A1/.charles/runs/a1-close/RUN.md"
printf '%s\n' \
  "$(jq -nc --arg ts 2026-09-03T00:01:00Z --arg dir "$A1" --arg r a1-foreign-orphan --arg f foreign-flow \
    '{ts:$ts,event:"start",lane:"explore",engine:"luna",run:$r,dir:$dir,task:"foreign orphan",flow_run_id:$f}')" \
  "$(jq -nc --arg ts 2026-09-03T00:02:00Z --arg dir "$A1" --arg r a1-closing-orphan --arg f a1-close \
    '{ts:$ts,event:"start",lane:"explore",engine:"luna",run:$r,dir:$dir,task:"closing orphan",flow_run_id:$f}')" \
  "$(jq -nc --arg ts 2026-09-03T00:03:00Z --arg dir "$A1" --arg r a1-legacy-orphan \
    '{ts:$ts,event:"start",lane:"explore",engine:"luna",run:$r,dir:$dir,task:"legacy orphan"}')" \
  "$(jq -nc --arg ts 2026-09-03T00:04:00Z --arg dir "$A1" --arg r a1-watchdog-end --arg f a1-close --arg s "$A1_SPEC" \
    '{ts:$ts,event:"start",lane:"implement",engine:"luna",run:$r,dir:$dir,task:"watchdog end",flow_run_id:$f,spec_path:$s}')" \
  "$(jq -nc --arg ts 2026-09-03T00:05:00Z --arg dir "$A1" --arg r a1-watchdog-end --arg f a1-close --arg s "$A1_SPEC" \
    '{ts:$ts,event:"end",lane:"implement",engine:"luna",model:"m",rc:143,run:$r,dir:$dir,task:"watchdog end",wrapper_death:true,flow_run_id:$f,spec_path:$s}')" \
  "$(jq -nc --arg ts 2026-09-03T00:06:00Z --arg dir "$A1" --arg r a1-foreign-implement --arg f foreign-flow \
    '{ts:$ts,event:"end",lane:"implement",engine:"luna",model:"m",rc:0,run:$r,dir:$dir,task:"foreign implement",flow_run_id:$f}')" \
  > "$A1/.charles/dispatches.jsonl"
a1_status_out="$(CHARLES_STATE_DIR="$A1_STATE" bash "$FS" "$A1" --closing "$A1/.charles/runs/a1-close" 2>&1)"; a1_status_rc=$?
if [ "$a1_status_rc" -eq 1 ] \
  && grep -qF 'NOTE   repo backlog (not this close): orphan dispatch a1-foreign-orphan' <<<"$a1_status_out" \
  && grep -qF 'ISSUE  orphan dispatch a1-closing-orphan' <<<"$a1_status_out" \
  && grep -qF 'ISSUE  orphan dispatch a1-legacy-orphan' <<<"$a1_status_out" \
  && grep -qF 'NOTE   repo backlog (not this close): 1 implement dispatch(es) never reviewed' <<<"$a1_status_out" \
  && ! grep -qF 'ISSUE  orphan dispatch a1-foreign-orphan' <<<"$a1_status_out" \
  && ! grep -qF 'NOTE   repo backlog (not this close): orphan dispatch a1-closing-orphan' <<<"$a1_status_out" \
  && ! grep -qF 'orphan dispatch a1-watchdog-end' <<<"$a1_status_out" \
  && [ "$(grep -cF 'orphan dispatch' <<<"$a1_status_out")" -eq 3 ]; then
  echo "  PASS  A1 close attribution keeps foreign, closing, legacy, and watchdog records distinct"; pass=$((pass+1))
else
  echo "  FAIL  A1 close attribution must classify all four records (rc=$a1_status_rc): $a1_status_out"; fail=$((fail+1))
fi
if [ "$a1_status_rc" -eq 1 ] \
  && jq -e --arg f a1-close --arg s "$A1_SPEC" \
    'select(.event == "end" and .run == "a1-watchdog-end" and .wrapper_death == true
      and .flow_run_id == $f and .spec_path == $s)' \
    "$A1/.charles/dispatches.jsonl" >/dev/null 2>&1; then
  echo "  PASS  A1 watchdog end keeps identity while the close stays blocked"; pass=$((pass+1))
else
  echo "  FAIL  A1 watchdog end must keep identity and the blocking exit (rc=$a1_status_rc)"; fail=$((fail+1))
fi

# --- A6 requirement dispatch needs a run or plan ------------------------------
A6="$BOX/a6-req-validation"; mkdir -p "$A6/bin" "$A6/docs/specs"
cp "$REQDIR/bin/codex" "$A6/bin/codex"
printf '# Plan\n\n## Grill verdict\n\n- Rounds: 1\n\n- [ ] **R1. requirement**\n' \
  > "$A6/docs/specs/plan.md"
a6_no_run_out="$(PATH="$A6/bin:$PATH" CHARLES_STATE_DIR="$A6/state" \
  bash "$RUN_SH" --lane implement --dir "$A6" \
  --req R1 --no-fallback --timeout 2 "scope" 2>&1)"; a6_no_run_rc=$?
if [ "$a6_no_run_rc" -eq 2 ] \
  && grep -qF 'no open run or resolvable plan' <<<"$a6_no_run_out" \
  && [ ! -s "$A6/.charles/dispatches.jsonl" ]; then
  echo "  PASS  --req refuses without an open run or resolvable plan"; pass=$((pass+1))
else
  echo "  FAIL  --req must refuse without an open run or resolvable plan (rc=$a6_no_run_rc): $a6_no_run_out"; fail=$((fail+1))
fi

mkdir -p "$A6/.charles/runs/only-run"
printf '# Run only-run\n\n- flow: feature\n- spec: docs/specs/plan.md\n\n## Phases\n\n## Open items\n\n## Rollback\n\n' \
  > "$A6/.charles/runs/only-run/RUN.md"
rm -f "$A6/.charles/dispatches.jsonl"
a6_single_out="$(PATH="$A6/bin:$PATH" CHARLES_STATE_DIR="$A6/state" \
  bash "$RUN_SH" --lane implement --dir "$A6" \
  --req R1 --no-fallback --timeout 2 "scope" 2>&1)"; a6_single_rc=$?
if [ "$a6_single_rc" -eq 0 ] \
  && jq -e 'select(.event == "start" and .req == ["R1"])' \
    "$A6/.charles/dispatches.jsonl" >/dev/null 2>&1; then
  echo "  PASS  --req still succeeds with exactly one open run"; pass=$((pass+1))
else
  echo "  FAIL  --req must still succeed with exactly one open run (rc=$a6_single_rc): $a6_single_out"; fail=$((fail+1))
fi

mkdir -p "$A6/.charles/runs/selected-run"
printf '# Run selected-run\n\n- flow: feature\n- spec: docs/specs/plan.md\n\n## Phases\n\n## Open items\n\n## Rollback\n\n' \
  > "$A6/.charles/runs/selected-run/RUN.md"
rm -f "$A6/.charles/dispatches.jsonl"
a6_selected_out="$(PATH="$A6/bin:$PATH" CHARLES_STATE_DIR="$A6/state" \
  bash "$RUN_SH" --lane implement --dir "$A6" \
  --run selected-run --req R1 --no-fallback --timeout 2 "scope" 2>&1)"; a6_selected_rc=$?
if [ "$a6_selected_rc" -eq 0 ] \
  && jq -e 'select(.event == "start" and .req == ["R1"])' \
    "$A6/.charles/dispatches.jsonl" >/dev/null 2>&1; then
  echo "  PASS  --req still succeeds with an explicit --run"; pass=$((pass+1))
else
  echo "  FAIL  --req must still succeed with an explicit --run (rc=$a6_selected_rc): $a6_selected_out"; fail=$((fail+1))
fi

# --- A7 metadata-aware untracked review additions -----------------------------
A7="$BOX/a7-untracked"; A7BIN="$BOX/a7-bin"; A7_CAPTURE="$BOX/a7-captured.diff"
A7_TARGET="$BOX/a7-symlink-target.txt"; mkdir -p "$A7/docs/specs" "$A7BIN"
( cd "$A7" && git init -q && git config user.name tester && git config user.email tester@example.invalid
  printf '# A7 plan\n' > docs/specs/plan.md
  git add docs/specs/plan.md && git commit -qm base ) >/dev/null 2>&1
printf '#!/usr/bin/env bash\n: > "$A7_DISPATCHED"\ncp changes.diff "$A7_CAPTURE"\n' > "$A7BIN/codex"
chmod +x "$A7BIN/codex"
printf '#!/usr/bin/env bash\nprintf a7-hook\n' > "$A7/a7-executable.sh"; chmod +x "$A7/a7-executable.sh"
printf 'plain-text-A7\n' > "$A7/a7-plain.txt"
printf 'target-payload-A7\n' > "$A7_TARGET"; ln -s "$A7_TARGET" "$A7/a7-link"
printf '\000BINARY-A7\001\377\n' > "$A7/a7-binary.bin"
rm -f "$A7_CAPTURE" "$BOX/a7-dispatched"
a7_out="$(A7_CAPTURE="$A7_CAPTURE" A7_DISPATCHED="$BOX/a7-dispatched" \
  PATH="$A7BIN:$PATH" CHARLES_STATE_DIR="$BOX/a7-state" bash "$RUN_SH" \
  --lane review --dir "$A7" --plan "$A7/docs/specs/plan.md" --timeout 5 "t" 2>&1)"; a7_rc=$?
if [ "$a7_rc" -eq 0 ] && grep -qF 'new file mode 100755' "$A7_CAPTURE" \
  && grep -qF '+++ b/a7-executable.sh' "$A7_CAPTURE" \
  && grep -qF '+#!/usr/bin/env bash' "$A7_CAPTURE"; then
  echo "  PASS  untracked executable keeps its 100755 mode"; pass=$((pass+1))
else
  echo "  FAIL  untracked executable must keep its mode (rc=$a7_rc): $a7_out"; fail=$((fail+1))
fi
if [ "$a7_rc" -eq 0 ] && grep -qF 'new file mode 120000' "$A7_CAPTURE" \
  && grep -qF '+++ b/a7-link' "$A7_CAPTURE" \
  && grep -qF "+$A7_TARGET" "$A7_CAPTURE" \
  && ! grep -qF '+target-payload-A7' "$A7_CAPTURE"; then
  echo "  PASS  untracked symlink keeps mode and target text"; pass=$((pass+1))
else
  echo "  FAIL  untracked symlink must not inline its target (rc=$a7_rc): $a7_out"; fail=$((fail+1))
fi
if [ "$a7_rc" -eq 0 ] && grep -qF 'Binary files /dev/null and b/a7-binary.bin differ' "$A7_CAPTURE" \
  && ! grep -qF 'BINARY-A7' "$A7_CAPTURE"; then
  echo "  PASS  untracked binary is reported as binary"; pass=$((pass+1))
else
  echo "  FAIL  untracked binary must not be mangled as text (rc=$a7_rc): $a7_out"; fail=$((fail+1))
fi
a7_plain_hits="$(grep -cF '+plain-text-A7' "$A7_CAPTURE" 2>/dev/null || true)"
if [ "$a7_rc" -eq 0 ] && grep -qF 'new file mode 100644' "$A7_CAPTURE" \
  && [ "$a7_plain_hits" -eq 1 ]; then
  echo "  PASS  untracked plain text remains an added line with mode 100644"; pass=$((pass+1))
else
  echo "  FAIL  untracked plain text must remain an added line (hits=$a7_plain_hits rc=$a7_rc): $a7_out"; fail=$((fail+1))
fi

# --- A10 provider errors fail fast; quiet work still reaches normal completion -
A10="$BOX/a10-provider"; A10_UNREACHABLE="$A10/unreachable"; A10_SLOW="$A10/slow"
mkdir -p "$A10_UNREACHABLE/bin" "$A10_SLOW/bin"
printf '%s\n' '#!/usr/bin/env bash' \
  'for _ in 1 2 3 4; do' \
  '  printf "%s\n" "failed to lookup address information: Try again" >&2' \
  '  sleep 0.1' \
  'done' \
  'while :; do sleep 1; done' > "$A10_UNREACHABLE/bin/codex"
chmod +x "$A10_UNREACHABLE/bin/codex"
a10_unreachable_out="$(CHARLES_STATE_DIR="$A10_UNREACHABLE/state" PATH="$A10_UNREACHABLE/bin:$PATH" \
  timeout 5 bash "$RUN_SH" --lane explore --dir "$A10_UNREACHABLE" \
  --no-fallback --timeout 3 "provider unavailable" 2>&1)"; a10_unreachable_rc=$?
a10_unreachable_ends="$(jq -r 'select(.event == "end") | .rc' \
  "$A10_UNREACHABLE/.charles/dispatches.jsonl" 2>/dev/null | wc -l)"
if [ "$a10_unreachable_rc" -eq 125 ] \
  && grep -qF 'provider unreachable' <<<"$a10_unreachable_out" \
  && [ "$a10_unreachable_ends" -eq 1 ] \
  && jq -e 'select(.event == "end" and .rc == 125)' \
    "$A10_UNREACHABLE/.charles/dispatches.jsonl" >/dev/null 2>&1; then
  echo "  PASS  A10 repeated provider errors fail fast with one terminal record"; pass=$((pass+1))
else
  echo "  FAIL  A10 repeated provider errors must fail fast once (rc=$a10_unreachable_rc, ends=$a10_unreachable_ends): $a10_unreachable_out"; fail=$((fail+1))
fi

printf '%s\n' '#!/usr/bin/env bash' \
  'sleep 1' \
  'touch "${CHARLES_A10_SLOW_DONE:?}"' > "$A10_SLOW/bin/codex"
chmod +x "$A10_SLOW/bin/codex"
a10_slow_out="$(CHARLES_A10_SLOW_DONE="$A10_SLOW/finished" \
  CHARLES_STATE_DIR="$A10_SLOW/state" PATH="$A10_SLOW/bin:$PATH" \
  timeout 5 bash "$RUN_SH" --lane explore --dir "$A10_SLOW" \
  --no-fallback --timeout 3 "slow quiet" 2>&1)"; a10_slow_rc=$?
if [ "$a10_slow_rc" -eq 0 ] \
  && [ -e "$A10_SLOW/finished" ] \
  && jq -e 'select(.event == "end" and .rc == 0)' \
    "$A10_SLOW/.charles/dispatches.jsonl" >/dev/null 2>&1 \
  && ! grep -qF 'provider unreachable' <<<"$a10_slow_out"; then
  echo "  PASS  A10 quiet slow lane reaches normal completion"; pass=$((pass+1))
else
  echo "  FAIL  A10 quiet slow lane must not be terminated early (rc=$a10_slow_rc): $a10_slow_out"; fail=$((fail+1))
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]

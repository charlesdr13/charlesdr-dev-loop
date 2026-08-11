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

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]

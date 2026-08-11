#!/usr/bin/env bash
# init-repo.sh — opt a repo into the charlesdr-dev-loop flow.
# Seeds .charles.toml (green command inferred), gitignores .charles/.
set -euo pipefail

DIR="${1:-$PWD}"
DIR="$(cd "$DIR" && pwd)"
CFG="$DIR/.charles.toml"

if [ -f "$CFG" ]; then
  echo "already opted in: $CFG"
  cat "$CFG"
  exit 0
fi

# --- infer the green command --------------------------------------------------
green=""
if [ -f "$DIR/package.json" ] && command -v jq >/dev/null; then
  has() { jq -e --arg s "$1" '.scripts[$s] // empty' "$DIR/package.json" >/dev/null 2>&1; }
  runner="npm run"
  [ -f "$DIR/bun.lockb" ] || [ -f "$DIR/bun.lock" ] && runner="bun run"
  [ -f "$DIR/pnpm-lock.yaml" ] && runner="pnpm run"
  parts=()
  has test && parts+=("$runner test")
  has typecheck && parts+=("$runner typecheck")
  [ ${#parts[@]} -eq 0 ] && has build && parts+=("$runner build")
  green="$(IFS=' && '; echo "${parts[*]}")"
  green="$(printf '%s' "${parts[0]:-}"; for p in "${parts[@]:1}"; do printf ' && %s' "$p"; done)"
elif [ -f "$DIR/pyproject.toml" ] || [ -f "$DIR/pytest.ini" ]; then
  green="pytest -q"
elif [ -f "$DIR/Cargo.toml" ]; then
  green="cargo test"
elif [ -f "$DIR/go.mod" ]; then
  green="go test ./..."
fi

cat > "$CFG" <<EOF
# charlesdr-dev-loop — per-repo flow config. Committed on purpose: the green command is
# a fact about this repo, not a preference of yours.

# What "all green" means. The debug loop runs this and stops when it passes.
# Empty means the flow will ask you to set it before it will start a debug loop.
green = "${green}"

# Inline-edit thresholds. Over either one, the hook asks you to dispatch codex
# instead. Bypass a session with CHARLES_INLINE_OK=1.
inline_lines = 40
inline_files = 3
EOF

# --- gitignore .charles/ ------------------------------------------------------
if [ -d "$DIR/.git" ] || git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
  if ! grep -qxF '.charles/' "$DIR/.gitignore" 2>/dev/null; then
    printf '\n# charlesdr-dev-loop scratch (transcripts, gate output, hook state)\n.charles/\n' >> "$DIR/.gitignore"
    echo "gitignored .charles/"
  fi
else
  echo "note: $DIR is not a git repo — the review lane will need --files instead of a diff"
fi

mkdir -p "$DIR/.charles" "$DIR/docs/specs"
echo "opted in: $CFG"
[ -z "$green" ] && echo "WARNING: could not infer a green command — set 'green' in $CFG before running a debug loop"
cat "$CFG"

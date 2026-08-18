---
description: Switch the codex engine used by every lane (luna | terra | deepseek), or show the current one
---

```bash
D="${CHARLES_STATE_DIR:-$HOME/.cache/charlesdr-dev-loop}"; mkdir -p "$D"
case "$ARGUMENTS" in
  luna|terra|deepseek) printf '%s\n' "$ARGUMENTS" > "$D/engine" ;;
  default|clear|reset) rm -f "$D/engine" ;;
  "") ;;
  *) echo "unknown engine '$ARGUMENTS' (luna|terra|deepseek|default)" ;;
esac
echo "engine: $(cat "$D/engine" 2>/dev/null || echo 'default (luna; review on sol)')"
```

Report the engine line back. Takes effect on the next dispatch — no restart, no
reinstall. It applies to explore, implement AND review; a `--engine` flag on an
individual `codex-run` call still overrides it, and so does `CHARLES_ENGINE` in
the environment.

`deepseek` is the free-of-codex-quota lane (deepseek-v4-flash @ max, via
`~/.codex/deepseek.config.toml`). `default` restores luna-primary with
deepseek as fallback.

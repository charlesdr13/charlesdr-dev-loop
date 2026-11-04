---
description: Opt this repo into the cstack flow — seeds .charles.toml, gitignores .charles/
---

Run:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/init-repo.sh "$(pwd)"
```

Then show the user the seeded config. If the green command came out empty, ask
what "all green" means for this repo and write it into `.charles.toml`; the debug
loop will not start without it.

This is the single switch for flow routing in this repo; nothing else on the
machine is affected.

---
description: Opt this repo into the charlesdr13 flow — seeds .charles.toml, gitignores .charles/
---

Run:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/init-repo.sh "$(pwd)"
```

Then show the user the seeded config. If the green command came out empty, ask
them what "all green" means for this repo and write it into `.charles.toml` —
the debug loop will not start without it.

This is the single switch: it turns on the edit-routing hook AND the flow
routing for this repo, and nothing else on the machine is affected.

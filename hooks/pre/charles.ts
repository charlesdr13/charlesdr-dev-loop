// charles.ts — omp (oh-my-pi) bridge for the Claude Code hooks in hooks.json.
//
// omp installs this plugin from .claude-plugin/marketplace.json and loads its
// skills, commands and agents natively, but ignores hooks.json. It does load
// hooks/pre/*.ts as extension modules, so this file feeds Claude-shaped payloads
// to the same shell hooks. One gate, two hosts; the shell scripts stay the truth.
//
// Bridged: route-to-codex + mark-inline-ok (edit gate), warn-open-runs (stop),
// link-dispatcher (session start). Not bridged: the Agent|Task hooks — they
// drive Claude Code's own subagent tool, which omp does not have.
import { spawnSync } from "node:child_process";
import { resolve } from "node:path";

const root = resolve(import.meta.dir, "../..");

function hook(name: string, payload: object, cwd: string): string {
  const r = spawnSync(`${root}/hooks/${name}`, {
    input: JSON.stringify({ ...payload, cwd }),
    cwd,
    env: { ...process.env, CLAUDE_PLUGIN_ROOT: root },
    encoding: "utf8",
    timeout: 10_000,
  });
  return (r.stdout ?? "").trim();
}

export default function (pi: any) {
  pi.on("session_start", (_e: any, ctx: any) => {
    hook("link-dispatcher.sh", {}, ctx?.cwd ?? process.cwd());
  });

  pi.on("tool_call", async (e: any, ctx: any) => {
    if (e.toolName !== "write" && e.toolName !== "edit") return;
    const cwd = ctx?.cwd ?? process.cwd();
    const paths: string[] = e.input.paths ?? [e.input.path];
    for (const p of paths.filter(Boolean)) {
      const file_path = resolve(cwd, p);
      // ponytail: an omp edit is a patch DSL, so its whole text (headers included)
      // stands in for new_string. Overcounts by a few lines; the gate errs toward asking.
      const payload =
        e.toolName === "write"
          ? { tool_name: "Write", tool_input: { file_path, content: e.input.content } }
          : { tool_name: "Edit", tool_input: { file_path, old_string: "", new_string: e.input.input } };
      const out = hook("route-to-codex.sh", payload, cwd);
      if (!out) continue;
      const reason = JSON.parse(out).hookSpecificOutput?.permissionDecisionReason ?? out;
      // Headless omp (-p) answers confirm with false, so the gate blocks there.
      if (!(await ctx.ui.confirm("charlesdr-dev-loop", reason))) return { block: true, reason };
      // ponytail: grants on approval, not on landing — omp has no per-call post hook here.
      hook("mark-inline-ok.sh", payload, cwd);
    }
  });

  pi.on("session_stop", (_e: any, ctx: any) => {
    const out = hook("warn-open-runs.sh", {}, ctx?.cwd ?? process.cwd());
    if (out) ctx.ui.notify(out, "warning");
  });
}

// charles.ts — omp (oh-my-pi) bridge for the Claude Code hooks in hooks.json.
//
// omp installs this plugin from .claude-plugin/marketplace.json and loads its
// skills, commands and agents natively, but ignores hooks.json. It does load
// hooks/pre/*.ts as extension modules, so this file feeds Claude-shaped payloads
// to the same shell hooks. One gate, two hosts; the shell scripts stay the truth.
//
// Bridged: route-to-codex + mark-inline-ok (edit gate), warn-open-runs (stop),
// link-dispatcher (session start), and the Agent|Task hooks on omp's task tool:
// route-subagents (subagent gate), claude-lane-dispatch (lane dispatch),
// claude-review-box (reviewer confinement), claude-lane-receipt (end receipt).
// omp re-runs this factory inside every subagent, and ctx.agent says which one.
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, isAbsolute, resolve } from "node:path";

const root = resolve(import.meta.dir ?? import.meta.dirname, "../..");

// The claude-<lane> agents' frontmatter models (haiku/sonnet/opus) are Claude
// Code names. Under omp each lane runs on its own provider instead, the same
// defaults as codex-run.sh's omp_default_model, at the effort that lane needs.
const LANES: Record<string, { lane: string; model: string }> = {
  "claude-explorer": { lane: "explore", model: "cursor/composer-2.5-fast" },
  "claude-implementer": { lane: "implement", model: "cursor/composer-2.5" },
  "claude-reviewer": { lane: "review", model: "openai-codex/gpt-6.1-sol:medium" },
};

// Plugin agents may arrive namespaced (charlesdr-dev-loop:claude-explorer).
export function laneAgent(agent?: string): string | undefined {
  const base = String(agent ?? "").split(":").pop()!.toLowerCase();
  return base in LANES ? base : undefined;
}

// A user's task.agentModelOverrides entry for the agent wins over the lane default.
export function laneModel(agent: string | undefined, overrides: Record<string, unknown> = {}): string | undefined {
  const base = laneAgent(agent);
  if (!base) return undefined;
  if (Object.hasOwn(overrides, base) || (agent && Object.hasOwn(overrides, agent))) return undefined;
  return LANES[base].model;
}

// omp read paths carry line selectors (a.txt:1, a.txt:10-20); Claude's Read does not.
export function stripSelector(p: string): string {
  return p.replace(/:[0-9][0-9,+-]*$/, "");
}

// omp glob takes one path that is also the pattern; Claude's Glob splits it
// into a directory and a pattern relative to it.
export function splitGlob(p: string, cwd: string): { path: string; pattern?: string } {
  const parts = p.split("/");
  const i = parts.findIndex((s) => /[*?[{]/.test(s));
  if (i < 0) return { path: resolve(cwd, p) };
  const dir = parts.slice(0, i).join("/") || (isAbsolute(p) ? "/" : ".");
  return { path: resolve(cwd, dir), pattern: parts.slice(i).join("/") };
}

function optedIn(cwd: string): boolean {
  for (let d = resolve(cwd); ; d = dirname(d)) {
    if (existsSync(`${d}/.charles.toml`)) return true;
    if (dirname(d) === d) return false;
  }
}

function hook(name: string, payload: object, cwd: string, env: Record<string, string> = {}, timeout = 10_000): string {
  const r = spawnSync(`${root}/hooks/${name}`, {
    input: JSON.stringify({ ...payload, cwd }),
    cwd,
    env: { ...process.env, CLAUDE_PLUGIN_ROOT: root, ...env },
    encoding: "utf8",
    timeout,
  });
  return (r.stdout ?? "").trim();
}

type Verdict = { decision?: string; reason: string; updatedInput?: any };
function verdict(out: string): Verdict | undefined {
  if (!out) return undefined;
  try {
    const h = JSON.parse(out).hookSpecificOutput ?? {};
    return { decision: h.permissionDecision, reason: h.permissionDecisionReason ?? out, updatedInput: h.updatedInput };
  } catch {
    return { reason: out };
  }
}

async function modelOverrides(pi: any): Promise<Record<string, unknown>> {
  try {
    const { lookup } = await import("@oh-my-pi/pi-coding-agent/config/registry");
    return lookup("task.agentModelOverrides")?.get(pi.pi.settings) ?? {};
  } catch {
    return {};
  }
}

function modelName(m: any): string | undefined {
  if (!m) return undefined;
  return typeof m === "string" ? m : m.provider && m.id ? `${m.provider}/${m.id}` : m.id;
}

// Every task item passes the subagent gate, then the lane dispatcher, which
// logs the start receipt and rewrites a lane's brief to carry charles-run:.
async function gateTask(e: any, ctx: any, cwd: string) {
  const input = e.input ?? {};
  const batch = Array.isArray(input.tasks);
  const items = (batch ? input.tasks : [input]).map((it: any) => ({ ...it }));
  let changed = false;
  for (const it of items) {
    const payload = { tool_name: "Task", tool_input: { subagent_type: it.agent || "task", prompt: it.task ?? "" } };
    const gate = verdict(hook("route-subagents.sh", payload, cwd));
    if (gate?.decision === "deny") return { block: true, reason: gate.reason };
    if (gate) {
      // Headless omp (-p) and subagents answer confirm with false, so the gate blocks there.
      if (!(await ctx.ui.confirm("charlesdr-dev-loop", gate.reason))) return { block: true, reason: gate.reason };
      hook("mark-inline-ok.sh", payload, cwd);
    }
    const d = verdict(hook("claude-lane-dispatch.sh", payload, cwd, {}, 60_000));
    if (d?.decision === "deny") return { block: true, reason: d.reason };
    if (d?.updatedInput?.prompt) {
      it.task = d.updatedInput.prompt;
      changed = true;
    }
  }
  if (!changed) return;
  return { input: batch ? { ...input, tasks: items } : items[0] };
}

// claude-reviewer sees only its review box. Map omp's read/grep/glob onto the
// Claude tool shapes claude-review-box.sh already checks; everything else it denies.
function reviewBox(e: any, cwd: string, agent: string) {
  if (e.toolName === "yield") return;
  const i = e.input ?? {};
  let tool_name = e.toolName;
  let tool_input: object = i;
  if (e.toolName === "read") {
    tool_name = "Read";
    tool_input = { file_path: resolve(cwd, stripSelector(String(i.path ?? ""))) };
  } else if (e.toolName === "grep") {
    tool_name = "Grep";
    tool_input = { path: resolve(cwd, String(i.path ?? ".")) };
  } else if (e.toolName === "glob") {
    tool_name = "Glob";
    tool_input = splitGlob(String(i.path ?? "."), cwd);
  }
  const v = verdict(hook("claude-review-box.sh", { agent_type: agent, tool_name, tool_input }, cwd));
  if (v?.decision === "deny") return { block: true, reason: v.reason };
}

export default function (pi: any) {
  // Per-session lane state: the brief a lane subagent started with, and
  // whether its end receipt is written. Keyed by agent id, since subagents
  // may share this module.
  const lanes = new Map<string, { agent: string; brief: string; done: boolean }>();
  const laneOf = (ctx: any) =>
    ctx?.agent?.kind === "sub" && laneAgent(ctx.agent.name) ? String(ctx.agent.id ?? ctx.agent.name) : undefined;

  function receipt(ctx: any, rc = 0) {
    const key = laneOf(ctx);
    const s = key ? lanes.get(key) : undefined;
    if (!s || s.done || !s.brief) return;
    s.done = true;
    const env: Record<string, string> = {};
    const model = modelName(ctx.model);
    if (model) env.CHARLES_LANE_MODEL = model;
    if (rc) env.CHARLES_LANE_RC = String(rc);
    const payload = {
      hook_event_name: "PostToolUse",
      tool_name: "Task",
      tool_input: { subagent_type: s.agent, prompt: s.brief },
    };
    hook("claude-lane-receipt.sh", payload, ctx?.cwd ?? process.cwd(), env);
  }

  pi.on("session_start", (_e: any, ctx: any) => {
    if (ctx?.agent?.kind === "sub") return;
    hook("link-dispatcher.sh", {}, ctx?.cwd ?? process.cwd());
  });

  pi.on("before_subagent_spawn", async (e: any, ctx: any) => {
    if (!laneAgent(e.agent) || !optedIn(ctx?.cwd ?? process.cwd())) return;
    const model = laneModel(e.agent, await modelOverrides(pi));
    if (model) return { model, note: `charlesdr-dev-loop ${LANES[laneAgent(e.agent)!].lane} lane` };
  });

  pi.on("before_agent_start", (e: any, ctx: any) => {
    const key = laneOf(ctx);
    if (!key || lanes.has(key)) return;
    const prompt = String(e.prompt ?? "");
    if (/(^|\n)charles-run: /.test(prompt)) lanes.set(key, { agent: laneAgent(ctx.agent.name)!, brief: prompt, done: false });
  });

  pi.on("tool_call", async (e: any, ctx: any) => {
    const cwd = ctx?.cwd ?? process.cwd();
    const lane = ctx?.agent?.kind === "sub" ? laneAgent(ctx.agent.name) : undefined;
    if (lane === "claude-reviewer") return reviewBox(e, cwd, lane);
    if (e.toolName === "task") return gateTask(e, ctx, cwd);
    if (e.toolName !== "write" && e.toolName !== "edit") return;
    // The implement lane is the dispatch this gate asks for, like CHARLES_INLINE_OK=1 on a codex-run lane.
    if (lane === "claude-implementer") return;
    const paths: string[] = e.input.paths ?? [e.input.path];
    for (const p of paths.filter(Boolean)) {
      const file_path = resolve(cwd, p);
      // ponytail: an omp edit is a patch DSL, so its whole text (headers included)
      // stands in for new_string. Overcounts by a few lines; the gate errs toward asking.
      const payload =
        e.toolName === "write"
          ? { tool_name: "Write", tool_input: { file_path, content: e.input.content } }
          : { tool_name: "Edit", tool_input: { file_path, old_string: "", new_string: e.input.input } };
      const v = verdict(hook("route-to-codex.sh", payload, cwd));
      if (!v) continue;
      const reason = v.reason;
      if (v.decision === "deny") return { block: true, reason };
      // Headless omp (-p) answers confirm with false, so the gate blocks there.
      if (!(await ctx.ui.confirm("charlesdr-dev-loop", reason))) return { block: true, reason };
      // ponytail: grants on approval, not on landing — omp has no per-call post hook here.
      hook("mark-inline-ok.sh", payload, cwd);
    }
  });

  // A lane is done when it yields its final result (a section yield carries a
  // type); session shutdown is the backstop for a lane that never yields, and
  // records rc 130: a lane killed or crashed before its final yield did not finish.
  pi.on("tool_result", (e: any, ctx: any) => {
    if (e.toolName === "yield" && !e.isError && !(e.details?.type ?? e.input?.type)) receipt(ctx);
  });
  pi.on("session_shutdown", (_e: any, ctx: any) => receipt(ctx, 130));

  pi.on("session_stop", (_e: any, ctx: any) => {
    const out = hook("warn-open-runs.sh", {}, ctx?.cwd ?? process.cwd());
    if (out) ctx.ui.notify(out, "warning");
  });
}

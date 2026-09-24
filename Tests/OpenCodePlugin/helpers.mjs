import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import { ChauffeurOpenCode } from "../../Sources/ChauffeurCore/Resources/Plugins/chauffeur-opencode.js";

export const createChauffeurPlugin = ChauffeurOpenCode.createChauffeurPlugin;
export const ROOT = "ses_0d09000000001rootAAAAAAAAA";
export const CHILD = "ses_0d09000000002childBBBBBBBB";
export const env = { CHAUFFEUR_SESSION_ID: "6F1B6C9E-1D4B-4C3A-9E57-2D0A5B7E1C11", CHAUFFEUR_CTL: "/fake/chauffeurctl" };

export const tick = (ms = 0) => new Promise((r) => setTimeout(r, ms));

/**
 * A fake `spawn` for chauffeurctl. `reply(args, stdin)` returns `{ stdout, hang }`; a hanging child only exits when
 * killed or when the test calls `finish(stdout)` on the recorded call.
 */
export function fakeCtl(reply = () => ({})) {
  const calls = [];
  const spawn = (cmd, args) => {
    const child = new EventEmitter();
    child.stdin = new PassThrough();
    child.stdout = new PassThrough();
    const call = { cmd, args, stdin: "", payload: null, killed: null, child };
    calls.push(call);
    let closed = false;
    const close = (stdout = "", code = 0, signal = null) => {
      if (closed) return;
      closed = true;
      if (stdout) child.stdout.write(stdout);
      child.stdout.end();
      setImmediate(() => child.emit("close", code, signal));
    };
    call.finish = (stdout) => close(stdout);
    // `killStdout` lets a test make a killed child still print, as `wait-for-work` does on SIGTERM.
    child.kill = (signal) => { call.killed = signal; close(call.killStdout ?? "", null, signal); return true; };
    child.stdin.on("data", (d) => { call.stdin += d; });
    const respond = () => {
      try { call.payload = call.stdin ? JSON.parse(call.stdin) : null; } catch {}
      const r = reply(args, call.payload) ?? {};
      if (!r.hang) setTimeout(() => close(r.stdout ?? ""), r.delayMs ?? 0);
    };
    if (args[0] === "wait-for-work") setImmediate(respond);
    else child.stdin.on("end", respond);
    return child;
  };
  return { spawn, calls };
}

export function fakeClient() {
  const prompts = [];
  return { prompts, session: { promptAsync: async (req) => { prompts.push(req); return { response: { status: 204 } }; } } };
}

/** Builds a plugin with fakes; `emit(type, properties)` delivers an OpenCode bus event and lets queued ctl calls run. */
export async function harness({ reply, options = {}, client = fakeClient() } = {}) {
  const ctl = fakeCtl(reply);
  const exits = [];
  const hooks = createChauffeurPlugin({ client, env: { ...env }, spawn: ctl.spawn, onExit: (fn) => exits.push(fn), attentionDelayMs: 30, ...options });
  const emit = async (type, properties) => { await hooks.event({ event: { type, properties } }); await tick(5); };
  const statuses = () => ctl.calls.filter((c) => c.args[0] === "event").map((c) => c.args[3]);
  const stops = () => ctl.calls.filter((c) => c.args[0] === "inbox-hook" && c.args.includes("--report-stop"));
  const waiters = () => ctl.calls.filter((c) => c.args[0] === "wait-for-work");
  return { hooks, ctl, client, exits, emit, statuses, stops, waiters };
}

export const created = (id, parentID) => ["session.created", { sessionID: id, info: { id, ...(parentID && { parentID }), title: "t", agent: "build" } }];
export const busy = (id = ROOT) => ["session.status", { sessionID: id, status: { type: "busy" } }];
export const idle = (id = ROOT) => ["session.idle", { sessionID: id }];

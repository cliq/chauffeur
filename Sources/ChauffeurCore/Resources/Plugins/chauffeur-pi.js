// Chauffeur's Pi extension. Coordinated launches load this file explicitly; it reports lifecycle state,
// exposes the runtime's authenticated MCP tools, delivers inbox reminders, and wakes idle coordinators.
import { spawn as nodeSpawn } from "node:child_process";

const defaults = { ctlTimeoutMs: 5000, toolHookTimeoutMs: 3000, discoveryTimeoutMs: 5000, mcpTimeoutMs: 360000 };
const identityChangingSources = new Set(["startup", "new", "resume", "fork"]);

/** Build and register the extension. Dependencies are injectable so the behavior can be tested without Pi. */
export function createChauffeurPiExtension(pi, {
  env = process.env,
  spawn = nodeSpawn,
  fetch = globalThis.fetch,
  setTimeout: setTimer = setTimeout,
  clearTimeout: clearTimer = clearTimeout,
  pid = process.pid,
  ...options
} = {}) {
  const ctl = env.CHAUFFEUR_CTL;
  const chauffeurSession = env.CHAUFFEUR_SESSION_ID;
  const token = env.CHAUFFEUR_SESSION_TOKEN;
  const endpoint = validEndpoint(env.CHAUFFEUR_PI_ENDPOINT);
  if (!ctl || !chauffeurSession || !token || !endpoint || typeof fetch !== "function") return;

  // A Pi started from a tool inherits the launch environment. Only the process Chauffeur launched owns the session.
  const owner = String(pid);
  if (env.CHAUFFEUR_PI_OWNER && env.CHAUFFEUR_PI_OWNER !== owner) return;
  env.CHAUFFEUR_PI_OWNER = owner;

  const cfg = { ...defaults, ...options };
  const state = {
    conversation: null,
    reported: null,
    registeredTools: new Set(),
    waiter: null,
    pendingWait: false,
    stopActive: false,
    turn: 0,
  };
  let queue = Promise.resolve();
  let requestID = 0;

  function run(args, payload, timeoutMs) {
    return new Promise((resolve) => {
      let child, timer, output = "", done = false;
      const finish = (value) => {
        if (done) return;
        done = true;
        clearTimer(timer);
        resolve(value);
      };
      try {
        child = spawn(ctl, args, { env, stdio: ["pipe", "pipe", "ignore"] });
        child.on("error", () => finish(null));
        child.on("close", () => finish(output));
        child.stdout?.on("data", (data) => { output += data; });
        child.stdin?.on("error", () => {});
        child.stdin?.end(payload ? JSON.stringify(payload) + "\n" : "");
        timer = setTimer(() => {
          try { child.kill("SIGKILL"); } catch {}
          finish(null);
        }, timeoutMs);
      } catch { finish(null); }
    });
  }

  const enqueue = (task) => {
    queue = queue.then(task).catch(() => {});
    return queue;
  };
  const payload = (hookEventName, extra = {}) => ({
    session_id: state.conversation,
    ...(hookEventName && { hook_event_name: hookEventName }),
    ...extra,
  });

  function report(status, body = payload()) {
    if (state.reported === status) return queue;
    state.reported = status;
    return enqueue(() => run(["event", "--session", chauffeurSession, status], body, cfg.ctlTimeoutMs));
  }

  async function mcp(method, params, signal, timeoutMs = cfg.mcpTimeoutMs) {
    const id = ++requestID;
    const controller = new AbortController();
    const abort = () => controller.abort(signal?.reason);
    if (signal?.aborted) abort();
    else signal?.addEventListener("abort", abort, { once: true });
    const timer = setTimer(() => controller.abort(new Error("Chauffeur MCP request timed out")), timeoutMs);
    let reply;
    try {
      const response = await fetch(endpoint, {
        method: "POST",
        redirect: "error",
        signal: controller.signal,
        headers: {
          "Authorization": `Bearer ${token}`,
          "Content-Type": "application/json",
          "Accept": "application/json, text/event-stream",
          "MCP-Protocol-Version": "2025-11-25",
        },
        body: JSON.stringify({ jsonrpc: "2.0", id, method, ...(params && { params }) }),
      });
      if (!response?.ok) throw new Error("Chauffeur MCP request failed");
      reply = await response.json();
    } finally {
      clearTimer(timer);
      signal?.removeEventListener("abort", abort);
    }
    if (!reply || reply.jsonrpc !== "2.0" || reply.id !== id || reply.error || !reply.result) {
      throw new Error(safeMessage(reply?.error?.message, "Chauffeur MCP request failed", token));
    }
    return reply.result;
  }

  async function discoverTools() {
    const result = await mcp("tools/list", undefined, undefined, cfg.discoveryTimeoutMs);
    if (!Array.isArray(result.tools)) throw new Error("Chauffeur MCP tool discovery failed");
    for (const tool of result.tools) {
      if (!tool || typeof tool.name !== "string" || !tool.name || state.registeredTools.has(tool.name)) continue;
      state.registeredTools.add(tool.name);
      const name = tool.name;
      pi.registerTool({
        name,
        label: typeof tool.title === "string" && tool.title ? tool.title : name,
        description: typeof tool.description === "string" ? tool.description : name,
        parameters: tool.inputSchema && typeof tool.inputSchema === "object"
          ? tool.inputSchema
          : { type: "object", properties: {} },
        async execute(toolCallId, params, signal) {
          const result = await mcp("tools/call", { name, arguments: params ?? {} }, signal);
          const content = Array.isArray(result.content) ? result.content : [];
          if (result.isError === true) throw new Error(safeMessage(firstText(content), "Chauffeur tool failed", token));
          return { content, details: {} };
        },
      });
    }
  }

  function turnFinished() { report("turn-finished"); }

  function killWaiter() {
    state.pendingWait = false;
    const waiter = state.waiter;
    if (!waiter) return;
    state.waiter = null;
    waiter.killed = true;
    try { waiter.child.kill("SIGTERM"); } catch {}
  }

  function startWaiter(ctx) {
    if (state.waiter) return;
    let child;
    try {
      child = spawn(ctl, ["wait-for-work", "--json"], { env, stdio: ["ignore", "pipe", "ignore"] });
    } catch { turnFinished(); return; }
    const waiter = { child, killed: false, done: false, output: "" };
    const turn = state.turn;
    state.waiter = waiter;
    const exited = () => {
      if (waiter.done) return;
      waiter.done = true;
      if (state.waiter === waiter) state.waiter = null;
      if (waiter.killed) return;
      if (state.turn !== turn || !ctx.isIdle()) return;
      const result = parseLine(waiter.output);
      if (result?.reason === "replaced") return;
      if (result?.reason === "work" && typeof result.text === "string" && result.text) {
        try { pi.sendUserMessage(result.text); return; } catch {}
      }
      turnFinished();
    };
    child.on("error", exited);
    child.stdout?.on("data", (data) => { waiter.output += data; });
    child.on("close", exited);
  }

  pi.on("session_start", async (event, ctx) => {
    try {
      state.conversation = ctx.sessionManager.getSessionId();
      state.turn++;
      state.reported = null;
      state.stopActive = false;
      killWaiter();
      if (identityChangingSources.has(event.reason)) {
        await report("session-start", payload("SessionStart", { source: event.reason }));
      } else {
        await queue;
      }
      await discoverTools();
    } catch { report("needs-attention"); }
  });

  pi.on("turn_start", () => {
    state.turn++;
    killWaiter();
    report("running");
  });

  pi.on("agent_before_settle", async (event) => {
    if (event.outcome === "error") { state.stopActive = false; report("needs-attention"); return; }
    if (event.outcome === "aborted") { state.stopActive = false; turnFinished(); return; }
    const turn = state.turn;
    const result = parseLine(await run(
      ["inbox-hook", "--provider", "pi", "--report-stop"],
      payload("Stop", { stop_hook_active: state.stopActive }),
      cfg.ctlTimeoutMs,
    ));
    if (state.turn !== turn) return;
    if (result?.block === true && typeof result.text === "string" && result.text) {
      state.stopActive = true;
      return {
        entries: [
          ...(Array.isArray(event.entries) ? event.entries : []),
          { type: "custom_message", customType: "chauffeur-inbox", content: result.text, display: true },
        ],
        continue: true,
      };
    }
    state.stopActive = false;
    if (result?.waitForWorkers === true) {
      // inbox-hook already moved the runtime to turn-finished; mirror it so the woken turn reports running again.
      state.reported = "turn-finished";
      state.pendingWait = true;
    }
    else turnFinished();
  });

  pi.on("agent_settled", (_event, ctx) => {
    if (!state.pendingWait) return;
    state.pendingWait = false;
    if (ctx.isIdle()) startWaiter(ctx);
    else turnFinished();
  });

  pi.on("tool_result", async (event) => {
    try {
      const result = parseLine(await run(
        ["inbox-hook", "--provider", "pi"],
        payload("PostToolUse"),
        cfg.toolHookTimeoutMs,
      ));
      if (typeof result?.text !== "string" || !result.text) return;
      return { content: [...event.content, { type: "text", text: result.text }] };
    } catch {}
  });

  pi.on("input", (event) => {
    state.turn++;
    if (event.source !== "extension") state.stopActive = false;
    killWaiter();
  });
  pi.on("session_before_switch", () => { state.turn++; killWaiter(); });
  pi.on("session_before_fork", () => { state.turn++; killWaiter(); });
  pi.on("session_shutdown", () => { state.turn++; killWaiter(); });
}

function validEndpoint(value) {
  try {
    const url = new URL(value);
    return url.protocol === "http:" && url.hostname === "127.0.0.1" && url.pathname === "/mcp"
      && !url.username && !url.password && !url.search && !url.hash ? url.href : null;
  } catch { return null; }
}

function parseLine(output) {
  if (typeof output !== "string") return null;
  const line = output.trim().split("\n").pop();
  if (!line) return null;
  try {
    const value = JSON.parse(line);
    return value && typeof value === "object" ? value : null;
  } catch { return null; }
}

function firstText(content) {
  return content.find((item) => item?.type === "text" && typeof item.text === "string")?.text;
}

function safeMessage(value, fallback, secret) {
  return typeof value === "string" && value && !value.includes(secret) ? value : fallback;
}

export default function ChauffeurPi(pi) {
  return createChauffeurPiExtension(pi);
}

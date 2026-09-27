import { test } from "node:test";
import assert from "node:assert/strict";
import { createChauffeurPiExtension } from "../../Sources/ChauffeurCore/Resources/Plugins/chauffeur-pi.js";
import { fakeCtl, tick } from "../OpenCodePlugin/helpers.mjs";

const SESSION = "6f1b6c9e-1d4b-4c3a-9e57-2d0a5b7e1c11";
const CONVERSATION = "3d8681b1-7090-4751-88bf-0cd0763d6ca6";
const baseEnv = {
  CHAUFFEUR_CTL: "/fake/chauffeurctl",
  CHAUFFEUR_SESSION_ID: SESSION,
  CHAUFFEUR_SESSION_TOKEN: "secret-token",
  CHAUFFEUR_PI_ENDPOINT: "http://127.0.0.1:8123/mcp",
};

function fakePi() {
  const handlers = new Map();
  const tools = [];
  const messages = [];
  return {
    handlers,
    tools,
    messages,
    on(name, handler) { handlers.set(name, handler); return () => handlers.delete(name); },
    registerTool(tool) { tools.push(tool); },
    sendUserMessage(text, options) { messages.push({ text, options }); },
  };
}

function context(id = CONVERSATION) {
  return {
    sessionManager: { getSessionId: () => id },
    isIdle: () => true,
  };
}

function jsonResponse(value, ok = true) {
  return { ok, status: ok ? 200 : 500, json: async () => value };
}

function fakeFetch(tools = []) {
  const calls = [];
  const fetch = async (url, init) => {
    const body = JSON.parse(init.body);
    calls.push({ url, init, body });
    if (body.method === "tools/list") return jsonResponse({ jsonrpc: "2.0", id: body.id, result: { tools } });
    return jsonResponse({ jsonrpc: "2.0", id: body.id, result: { content: [{ type: "text", text: "called" }], isError: false } });
  };
  fetch.calls = calls;
  return fetch;
}

async function harness({ env = baseEnv, reply, fetch = fakeFetch(), pid = 42, options = {} } = {}) {
  const pi = fakePi();
  const ctl = fakeCtl(reply);
  createChauffeurPiExtension(pi, { env: { ...env }, spawn: ctl.spawn, fetch, pid, ctlTimeoutMs: 100, toolHookTimeoutMs: 100, ...options });
  const emit = async (name, event = {}, ctx = context()) => {
    const result = await pi.handlers.get(name)?.({ type: name, ...event }, ctx);
    await tick(5);
    return result;
  };
  const statuses = () => ctl.calls.filter((call) => call.args[0] === "event").map((call) => call.args[3]);
  return { pi, ctl, fetch, emit, statuses };
}

test("exports a default Pi extension and a named test factory", async () => {
  const module = await import("../../Sources/ChauffeurCore/Resources/Plugins/chauffeur-pi.js");
  assert.equal(typeof module.default, "function");
  assert.equal(typeof module.createChauffeurPiExtension, "function");
});

test("does nothing outside a complete Chauffeur launch or in a nested Pi process", () => {
  for (const missing of Object.keys(baseEnv)) {
    const pi = fakePi();
    const env = { ...baseEnv };
    delete env[missing];
    createChauffeurPiExtension(pi, { env, spawn: fakeCtl().spawn, fetch: fakeFetch(), pid: 42 });
    assert.equal(pi.handlers.size, 0, missing);
  }
  const pi = fakePi();
  createChauffeurPiExtension(pi, { env: { ...baseEnv, CHAUFFEUR_PI_OWNER: "41" }, spawn: fakeCtl().spawn, fetch: fakeFetch(), pid: 42 });
  assert.equal(pi.handlers.size, 0);
});

test("session start reports Pi's conversation identity and discovers authenticated MCP tools", async () => {
  const fetch = fakeFetch([{ name: "chauffeur_inbox", description: "Read messages", inputSchema: { type: "object", properties: { wait: { type: "boolean" } } } }]);
  const h = await harness({ fetch });
  await h.emit("session_start", { reason: "startup" });

  assert.deepEqual(h.statuses(), ["session-start"]);
  assert.deepEqual(h.ctl.calls[0].args, ["event", "--session", SESSION, "session-start"]);
  assert.deepEqual(h.ctl.calls[0].payload, { session_id: CONVERSATION, hook_event_name: "SessionStart", source: "startup" });
  assert.equal(fetch.calls[0].url, baseEnv.CHAUFFEUR_PI_ENDPOINT);
  assert.equal(fetch.calls[0].init.headers.Authorization, "Bearer secret-token");
  assert.equal(fetch.calls[0].body.method, "tools/list");
  assert.equal(h.pi.tools.length, 1);
  assert.equal(h.pi.tools[0].name, "chauffeur_inbox");
  assert.deepEqual(h.pi.tools[0].parameters, { type: "object", properties: { wait: { type: "boolean" } } });
});

test("new, resume, and fork starts report their new session IDs while reload only refreshes local identity", async () => {
  const h = await harness();
  for (const [reason, id] of [["startup", "one"], ["new", "two"], ["resume", "three"], ["fork", "four"], ["reload", "five"]]) {
    await h.emit("session_start", { reason }, context(id));
  }
  assert.deepEqual(h.ctl.calls.filter((c) => c.args[3] === "session-start").map((c) => [c.payload.source, c.payload.session_id]), [
    ["startup", "one"], ["new", "two"], ["resume", "three"], ["fork", "four"],
  ]);
});

test("registered tools forward calls to MCP and preserve content", async () => {
  const fetch = fakeFetch([{ name: "chauffeur_send", description: "Send", inputSchema: { type: "object" } }]);
  const h = await harness({ fetch });
  await h.emit("session_start", { reason: "startup" });
  const result = await h.pi.tools[0].execute("call-1", { recipient: "Ada", text: "Hi" }, undefined);
  assert.deepEqual(fetch.calls[1].body, { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "chauffeur_send", arguments: { recipient: "Ada", text: "Hi" } } });
  assert.deepEqual(result, { content: [{ type: "text", text: "called" }], details: {} });
});

test("MCP failures become tool errors without exposing credentials", async () => {
  const fetch = async (_url, init) => {
    const body = JSON.parse(init.body);
    if (body.method === "tools/list") return jsonResponse({ jsonrpc: "2.0", id: body.id, result: { tools: [{ name: "chauffeur_send", description: "Send", inputSchema: { type: "object" } }] } });
    return jsonResponse({ jsonrpc: "2.0", id: body.id, result: { content: [{ type: "text", text: "Denied secret-token" }], isError: true } });
  };
  const h = await harness({ fetch });
  await h.emit("session_start", { reason: "startup" });
  await assert.rejects(h.pi.tools[0].execute("call-2", {}, undefined), /^Error: Chauffeur tool failed$/);
});

test("tool discovery is bounded when the MCP endpoint hangs", async () => {
  let sawSignal = false;
  const fetch = (_url, init) => new Promise((_resolve, reject) => {
    sawSignal = init.signal instanceof AbortSignal;
    init.signal.addEventListener("abort", () => reject(init.signal.reason), { once: true });
  });
  const h = await harness({ fetch, options: { discoveryTimeoutMs: 20 } });
  const started = Date.now();
  await h.emit("session_start", { reason: "startup" });
  assert.equal(sawSignal, true);
  assert.ok(Date.now() - started >= 15);
  assert.deepEqual(h.statuses(), ["session-start", "needs-attention"]);
});

test("MCP tool calls honor Pi's cancellation signal", async () => {
  let calls = 0;
  const fetch = async (_url, init) => {
    calls++;
    const body = JSON.parse(init.body);
    if (calls === 1) return jsonResponse({ jsonrpc: "2.0", id: body.id, result: { tools: [{ name: "chauffeur_wait", inputSchema: { type: "object" } }] } });
    return new Promise((_resolve, reject) => init.signal.addEventListener("abort", () => reject(init.signal.reason), { once: true }));
  };
  const h = await harness({ fetch });
  await h.emit("session_start", { reason: "startup" });
  const controller = new AbortController();
  const call = h.pi.tools[0].execute("cancelled", {}, controller.signal);
  controller.abort(new Error("cancelled by Pi"));
  await assert.rejects(call, /cancelled by Pi/);
});

test("MCP tool calls have a maximum request duration", async () => {
  let calls = 0;
  const fetch = async (_url, init) => {
    calls++;
    const body = JSON.parse(init.body);
    if (calls === 1) return jsonResponse({ jsonrpc: "2.0", id: body.id, result: { tools: [{ name: "chauffeur_wait", inputSchema: { type: "object" } }] } });
    return new Promise((_resolve, reject) => init.signal.addEventListener("abort", () => reject(init.signal.reason), { once: true }));
  };
  const h = await harness({ fetch, options: { mcpTimeoutMs: 20 } });
  await h.emit("session_start", { reason: "startup" });
  await assert.rejects(h.pi.tools[0].execute("timed-out", {}, undefined), /timed out/);
});

test("the MCP timeout also bounds reading the response body", async () => {
  let calls = 0;
  const fetch = async (_url, init) => {
    calls++;
    const body = JSON.parse(init.body);
    if (calls === 1) return jsonResponse({ jsonrpc: "2.0", id: body.id, result: { tools: [{ name: "chauffeur_wait", inputSchema: { type: "object" } }] } });
    return {
      ok: true,
      json: () => new Promise((_resolve, reject) => init.signal.addEventListener("abort", () => reject(init.signal.reason), { once: true })),
    };
  };
  const h = await harness({ fetch, options: { mcpTimeoutMs: 20 } });
  await h.emit("session_start", { reason: "startup" });
  const outcome = await Promise.race([
    h.pi.tools[0].execute("body-timeout", {}, undefined).then(() => "resolved", (error) => error.message),
    tick(80).then(() => "still pending"),
  ]);
  assert.match(outcome, /timed out/);
});

test("session start is committed before MCP discovery begins", async () => {
  const started = Date.now();
  let discoveryDelay = 0;
  const fetch = async (_url, init) => {
    discoveryDelay = Date.now() - started;
    const body = JSON.parse(init.body);
    return jsonResponse({ jsonrpc: "2.0", id: body.id, result: { tools: [] } });
  };
  const h = await harness({ fetch, reply: (args) => args[0] === "event" ? { delayMs: 25 } : {} });
  await h.emit("session_start", { reason: "startup" });
  assert.ok(discoveryDelay >= 20, `discovery began after ${discoveryDelay} ms`);
});

test("turn lifecycle reports running and a completed stop can continue from inbox mail", async () => {
  const h = await harness({ reply: (args) => args.includes("--report-stop") ? { stdout: '{"block":true,"text":"New instructions"}\n' } : {} });
  await h.emit("session_start", { reason: "startup" });
  await h.emit("turn_start");
  const result = await h.emit("agent_before_settle", { outcome: "completed" });
  assert.deepEqual(h.statuses(), ["session-start", "running"]);
  const stop = h.ctl.calls.find((c) => c.args.includes("--report-stop"));
  assert.deepEqual(stop.args, ["inbox-hook", "--provider", "pi", "--report-stop"]);
  assert.equal(stop.payload.session_id, CONVERSATION);
  assert.deepEqual(result, {
    entries: [{ type: "custom_message", customType: "chauffeur-inbox", content: "New instructions", display: true }],
    continue: true,
  });
});

test("inbox continuation preserves boundary entries proposed by earlier extensions", async () => {
  const h = await harness({ reply: (args) => args.includes("--report-stop") ? { stdout: '{"block":true,"text":"New instructions"}\n' } : {} });
  const prior = { type: "custom", customType: "another-extension", data: { kept: true } };
  await h.emit("session_start", { reason: "startup" });
  await h.emit("turn_start");
  const result = await h.emit("agent_before_settle", { outcome: "completed", entries: [prior] });
  assert.deepEqual(result.entries, [
    prior,
    { type: "custom_message", customType: "chauffeur-inbox", content: "New instructions", display: true },
  ]);
});

test("a continuation marks its next stop active so the same inbox item is not delivered twice", async () => {
  const stopPayloads = [];
  const h = await harness({ reply: (args, payload) => {
    if (!args.includes("--report-stop")) return {};
    stopPayloads.push(payload);
    return { stdout: JSON.stringify(payload.stop_hook_active
      ? { block: false, waitForWorkers: false }
      : { block: true, text: "Continue once" }) + "\n" };
  } });
  await h.emit("session_start", { reason: "startup" });
  await h.emit("turn_start");
  const first = await h.emit("agent_before_settle", { outcome: "completed" });
  await h.emit("turn_start");
  const second = await h.emit("agent_before_settle", { outcome: "completed" });
  assert.equal(first.continue, true);
  assert.equal(second, undefined);
  assert.deepEqual(stopPayloads.map((payload) => payload.stop_hook_active), [false, true]);
  assert.equal(h.statuses().at(-1), "turn-finished");
});

test("completed and errored runs report their terminal status", async () => {
  const completed = await harness({ reply: (args) => args.includes("--report-stop") ? { stdout: '{"block":false,"waitForWorkers":false}\n' } : {} });
  await completed.emit("session_start", { reason: "startup" });
  await completed.emit("turn_start");
  await completed.emit("agent_before_settle", { outcome: "completed" });
  assert.deepEqual(completed.statuses(), ["session-start", "running", "turn-finished"]);

  const errored = await harness();
  await errored.emit("session_start", { reason: "startup" });
  await errored.emit("turn_start");
  await errored.emit("agent_before_settle", { outcome: "error" });
  assert.deepEqual(errored.statuses(), ["session-start", "running", "needs-attention"]);
  assert.equal(errored.ctl.calls.some((c) => c.args[0] === "inbox-hook"), false);
});

test("tool results append unread inbox reminders", async () => {
  const h = await harness({ reply: (args) => args[0] === "inbox-hook" && !args.includes("--report-stop") ? { stdout: '{"block":false,"text":"You have mail"}\n' } : {} });
  await h.emit("session_start", { reason: "startup" });
  const result = await h.emit("tool_result", { toolName: "bash", content: [{ type: "text", text: "ok" }], details: {}, isError: false });
  assert.deepEqual(result.content, [{ type: "text", text: "ok" }, { type: "text", text: "You have mail" }]);
  assert.deepEqual(h.ctl.calls.find((c) => c.args[0] === "inbox-hook").args, ["inbox-hook", "--provider", "pi"]);
});

test("the coordinator waiter wakes an idle Pi session with work", async () => {
  const h = await harness({ reply: (args) => args.includes("--report-stop")
    ? { stdout: '{"block":false,"waitForWorkers":true}\n' }
    : args[0] === "wait-for-work" ? { stdout: '{"reason":"work","text":"Worker finished"}\n' } : {} });
  await h.emit("session_start", { reason: "startup" });
  await h.emit("turn_start");
  await h.emit("agent_before_settle", { outcome: "completed" });
  await h.emit("agent_settled");
  await tick(20);
  assert.deepEqual(h.ctl.calls.find((c) => c.args[0] === "wait-for-work").args, ["wait-for-work", "--json"]);
  assert.deepEqual(h.pi.messages, [{ text: "Worker finished", options: undefined }]);
  await h.emit("turn_start");
  assert.deepEqual(h.statuses(), ["session-start", "running", "running"], "the woken turn becomes running after Stop marked it finished");
});

test("a waiter result does not inject work after Pi stopped being idle", async () => {
  let idle = true;
  const ctx = { sessionManager: { getSessionId: () => CONVERSATION }, isIdle: () => idle };
  const h = await harness({ reply: (args) => args.includes("--report-stop")
    ? { stdout: '{"block":false,"waitForWorkers":true}\n' }
    : args[0] === "wait-for-work" ? { hang: true } : {} });
  await h.emit("session_start", { reason: "startup" }, ctx);
  await h.emit("turn_start", {}, ctx);
  await h.emit("agent_before_settle", { outcome: "completed" }, ctx);
  await h.emit("agent_settled", {}, ctx);
  const waiter = h.ctl.calls.find((c) => c.args[0] === "wait-for-work");
  idle = false;
  waiter.finish('{"reason":"work","text":"Stale work"}\n');
  await tick(10);
  assert.deepEqual(h.pi.messages, []);
});

test("input, session switching, and shutdown cancel a coordinator waiter", async () => {
  for (const event of ["input", "session_before_switch", "session_before_fork", "session_shutdown"]) {
    const h = await harness({ reply: (args) => args.includes("--report-stop")
      ? { stdout: '{"block":false,"waitForWorkers":true}\n' }
      : args[0] === "wait-for-work" ? { hang: true } : {} });
    await h.emit("session_start", { reason: "startup" });
    await h.emit("turn_start");
    await h.emit("agent_before_settle", { outcome: "completed" });
    await h.emit("agent_settled");
    const waiter = h.ctl.calls.find((c) => c.args[0] === "wait-for-work");
    assert.ok(waiter, event);
    await h.emit(event, event === "input" ? { text: "hello", source: "interactive" } : {});
    assert.equal(waiter.killed, "SIGTERM", event);
  }
});

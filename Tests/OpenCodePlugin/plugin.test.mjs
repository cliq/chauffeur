import { test } from "node:test";
import assert from "node:assert/strict";
import { ChauffeurOpenCode } from "../../Sources/ChauffeurCore/Resources/Plugins/chauffeur-opencode.js";
import { harness, createChauffeurPlugin, fakeCtl, fakeClient, env, tick, ROOT, CHILD, created, busy, idle } from "./helpers.mjs";

const stopReply = (json) => (args) => (args.includes("--report-stop") ? { stdout: JSON.stringify(json) + "\n" } : {});

test("is a no-op without the Chauffeur environment", async () => {
  for (const partial of [{}, { CHAUFFEUR_CTL: "/x" }, { CHAUFFEUR_SESSION_ID: "id" }]) {
    const ctl = fakeCtl();
    assert.deepEqual(createChauffeurPlugin({ env: partial, spawn: ctl.spawn, client: fakeClient() }), {});
    assert.equal(ctl.calls.length, 0);
  }
});

test("exports only the plugin function", async () => {
  const mod = await import("../../Sources/ChauffeurCore/Resources/Plugins/chauffeur-opencode.js");
  assert.deepEqual(Object.keys(mod), ["ChauffeurOpenCode"]);
  assert.equal(typeof ChauffeurOpenCode, "function");
});

test("session.created adopts the root and reports session-start with source startup", async () => {
  const h = await harness();
  await h.emit(...created(ROOT));
  const [call] = h.ctl.calls;
  assert.equal(call.cmd, env.CHAUFFEUR_CTL);
  assert.deepEqual(call.args, ["event", "--session", env.CHAUFFEUR_SESSION_ID, "session-start"]);
  assert.deepEqual(call.payload, { session_id: ROOT, hook_event_name: "SessionStart", source: "startup" });
});

test("a resumed session is adopted from its first event with source resume", async () => {
  const h = await harness();
  await h.emit("message.updated", { sessionID: ROOT, info: { id: "msg_1", sessionID: ROOT } });
  await h.emit(...busy());
  assert.deepEqual(h.statuses(), ["session-start", "running"]);
  assert.deepEqual(h.ctl.calls[0].payload, { session_id: ROOT, hook_event_name: "SessionStart", source: "resume" });
  assert.deepEqual(h.ctl.calls[1].payload, { session_id: ROOT });
});

test("status is reported on transitions only", async () => {
  const h = await harness();
  await h.emit(...created(ROOT));
  for (let i = 0; i < 5; i++) await h.emit(...busy());
  await h.emit("session.status", { sessionID: ROOT, status: { type: "retry", attempt: 1 } });
  await h.emit(...busy());
  assert.deepEqual(h.statuses(), ["session-start", "running"]);
});

test("child sessions are ignored, including their bare session.idle", async () => {
  const h = await harness({ reply: stopReply({ block: false }) });
  await h.emit(...created(ROOT));
  await h.emit(...busy());
  await h.emit(...created(CHILD, ROOT));
  await h.emit(...busy(CHILD));
  await h.emit("session.error", { sessionID: CHILD, error: { name: "APIError", data: { message: "x" } } });
  await h.emit(...idle(CHILD));
  await tick(50);
  assert.deepEqual(h.statuses(), ["session-start", "running"]);
  assert.equal(h.stops().length, 0);
  const r = await harness();
  await r.emit(...created(ROOT));
  await r.hooks["tool.execute.after"]({ tool: "bash", sessionID: CHILD, callID: "c" }, { title: "", output: "x", metadata: {} });
  assert.equal(r.ctl.calls.filter((c) => c.args[0] === "inbox-hook").length, 0);
});

test("a subagent's open dialog needs attention like the root's own", async () => {
  const h = await harness();
  await h.emit(...created(ROOT));
  await h.emit(...busy());
  await h.emit(...created(CHILD, ROOT));
  await h.emit("permission.asked", { id: "per_c", sessionID: CHILD, permission: "bash" });
  await tick(60);
  assert.deepEqual(h.statuses(), ["session-start", "running", "needs-attention"]);
  await h.emit("permission.replied", { sessionID: CHILD, requestID: "per_c", reply: "once" });
  assert.deepEqual(h.statuses(), ["session-start", "running", "needs-attention", "running"]);
});

test("another root session is ignored once one is adopted", async () => {
  const h = await harness({ reply: stopReply({ block: false }) });
  await h.emit(...created(ROOT));
  await h.emit(...created("ses_other"));
  await h.emit(...busy("ses_other"));
  await h.emit(...idle("ses_other"));
  assert.deepEqual(h.statuses(), ["session-start"]);
  assert.equal(h.stops().length, 0);
});

test("a permission answered within the debounce (--auto) never reports attention", async () => {
  const h = await harness();
  await h.emit(...created(ROOT));
  await h.emit(...busy());
  await h.emit("permission.asked", { id: "per_1", sessionID: ROOT, permission: "bash" });
  await h.emit("permission.replied", { sessionID: ROOT, requestID: "per_1", reply: "once" });
  await tick(60);
  assert.deepEqual(h.statuses(), ["session-start", "running"]);
});

test("a permission left open reports needs-attention, and its reply reports running", async () => {
  const h = await harness();
  await h.emit(...created(ROOT));
  await h.emit(...busy());
  await h.emit("permission.asked", { id: "per_1", sessionID: ROOT, permission: "bash" });
  await tick(60);
  await h.emit(...busy()); // OpenCode keeps sending busy while the dialog is open
  assert.deepEqual(h.statuses(), ["session-start", "running", "needs-attention"]);
  await h.emit("permission.replied", { sessionID: ROOT, requestID: "per_1", reply: "once" });
  assert.deepEqual(h.statuses(), ["session-start", "running", "needs-attention", "running"]);
});

test("questions follow the same attention rules, resolved by reply or rejection", async () => {
  const h = await harness();
  await h.emit(...created(ROOT));
  await h.emit(...busy());
  await h.emit("question.asked", { id: "que_1", sessionID: ROOT, questions: [] });
  await tick(60);
  await h.emit("question.replied", { sessionID: ROOT, requestID: "que_1", answers: [["Red"]] });
  await h.emit("question.asked", { id: "que_2", sessionID: ROOT, questions: [] });
  await tick(60);
  await h.emit("question.rejected", { sessionID: ROOT, requestID: "que_2" });
  assert.deepEqual(h.statuses(), ["session-start", "running", "needs-attention", "running", "needs-attention", "running"]);
});

test("an error reports needs-attention and the idles that follow do not run the Stop hook", async () => {
  const h = await harness({ reply: stopReply({ block: false }) });
  await h.emit(...created(ROOT));
  await h.emit(...busy());
  await h.emit("session.error", { sessionID: ROOT, error: { name: "APIError", data: { message: "Cannot connect" } } });
  await h.emit("session.status", { sessionID: ROOT, status: { type: "idle" } });
  await h.emit(...idle());
  await h.emit(...idle());
  assert.deepEqual(h.statuses(), ["session-start", "running", "needs-attention"]);
  assert.equal(h.stops().length, 0);
  await h.emit(...busy());
  await h.emit(...idle());
  assert.deepEqual(h.statuses(), ["session-start", "running", "needs-attention", "running"]);
  assert.equal(h.stops().length, 1);
});

test("an aborted message is not an attention state and the turn ends normally", async () => {
  const h = await harness({ reply: stopReply({ block: false }) });
  await h.emit(...created(ROOT));
  await h.emit(...busy());
  await h.emit("session.error", { sessionID: ROOT, error: { name: "MessageAbortedError", data: { message: "Aborted" } } });
  await h.emit(...idle());
  assert.deepEqual(h.statuses(), ["session-start", "running"]);
  assert.equal(h.stops().length, 1);
});

test("repeated session.idle runs the Stop hook once", async () => {
  const h = await harness({ reply: stopReply({ block: false }) });
  await h.emit(...created(ROOT));
  await h.emit(...busy());
  await h.emit(...idle());
  await h.emit(...idle());
  await h.emit(...idle());
  const [stop] = h.stops();
  assert.equal(h.stops().length, 1);
  assert.deepEqual(stop.args, ["inbox-hook", "--provider", "opencode", "--report-stop"]);
  assert.deepEqual(stop.payload, { session_id: ROOT, hook_event_name: "Stop", stop_hook_active: false });
  await h.emit(...busy());
  assert.deepEqual(h.statuses(), ["session-start", "running", "running"]); // the idle ended the turn
});

test("a blocking Stop continues the turn, and the next Stop is marked stop_hook_active", async () => {
  let n = 0;
  const h = await harness({
    reply: (args) => args.includes("--report-stop")
      ? { stdout: JSON.stringify(n++ === 0 ? { block: true, text: "New mail from Ada.", waitForWorkers: true } : { block: false }) }
      : {},
  });
  await h.emit(...created(ROOT));
  await h.emit(...busy());
  await h.emit(...idle());
  assert.deepEqual(h.client.prompts, [{ path: { id: ROOT }, body: { parts: [{ type: "text", text: "New mail from Ada." }] } }]);
  assert.equal(h.waiters().length, 0, "a blocked Stop never starts the waiter");
  await h.emit(...busy());
  await h.emit(...idle());
  assert.deepEqual(h.stops().map((c) => c.payload.stop_hook_active), [false, true]);
  await h.emit(...busy());
  await h.emit(...idle());
  assert.equal(h.stops()[2].payload.stop_hook_active, false);
  assert.equal(h.client.prompts.length, 1);
});

test("unparseable or empty Stop output counts as not blocking", async () => {
  for (const stdout of ["", "garbage\n", '{"block": true}\n']) {
    const h = await harness({ reply: (args) => (args.includes("--report-stop") ? { stdout } : {}) });
    await h.emit(...created(ROOT));
    await h.emit(...busy());
    await h.emit(...idle());
    assert.equal(h.client.prompts.length, 0);
    assert.equal(h.waiters().length, 0);
  }
});

test("a Stop reply that lands after the user started a new turn is dropped", async () => {
  const h = await harness({ reply: (args) => (args.includes("--report-stop") ? { stdout: '{"block":true,"text":"mail"}', delayMs: 40 } : {}) });
  await h.emit(...created(ROOT));
  await h.emit(...busy());
  await h.emit(...idle());
  await h.emit(...busy());
  await tick(80);
  assert.equal(h.client.prompts.length, 0);
});

test("PostToolUse appends the hint to built-in tool output", async () => {
  const h = await harness({ reply: (args) => (args[0] === "inbox-hook" ? { stdout: '{"block":false,"text":"You have 1 unread message.","waitForWorkers":true}\n' } : {}) });
  await h.emit(...created(ROOT));
  const output = { title: "echo hi", output: "hi\n", metadata: {} };
  await h.hooks["tool.execute.after"]({ tool: "bash", sessionID: ROOT, callID: "c1", args: {} }, output);
  assert.equal(output.output, "hi\n\n\nYou have 1 unread message.");
  const call = h.ctl.calls.find((c) => c.args[0] === "inbox-hook");
  assert.deepEqual(call.args, ["inbox-hook", "--provider", "opencode"]);
  assert.deepEqual(call.payload, { session_id: ROOT, hook_event_name: "PostToolUse" });
  assert.equal(h.waiters().length, 0, "waitForWorkers is ignored for PostToolUse");
});

test("PostToolUse pushes the hint onto MCP tool content", async () => {
  const h = await harness({ reply: (args) => (args[0] === "inbox-hook" ? { stdout: '{"block":false,"text":"hint"}' } : {}) });
  await h.emit(...created(ROOT));
  const output = { content: [{ type: "text", text: "slept 1" }] };
  await h.hooks["tool.execute.after"]({ tool: "chauffeur_sleep", sessionID: ROOT, callID: "c2" }, output);
  assert.deepEqual(output.content, [{ type: "text", text: "slept 1" }, { type: "text", text: "hint" }]);
  assert.equal(output.output, undefined);
});

test("PostToolUse leaves output alone without a hint, and is bounded when ctl hangs", async () => {
  const h = await harness({ reply: (args) => (args[0] === "inbox-hook" ? { hang: true } : {}), options: { toolHookTimeoutMs: 30 } });
  await h.emit(...created(ROOT));
  const output = { title: "", output: "x", metadata: {} };
  const t0 = Date.now();
  await h.hooks["tool.execute.after"]({ tool: "bash", sessionID: ROOT, callID: "c3" }, output);
  assert.ok(Date.now() - t0 < 500);
  assert.equal(output.output, "x");
  assert.equal(h.ctl.calls.find((c) => c.args[0] === "inbox-hook").killed, "SIGKILL");
});

test("hooks never throw, even when spawn and promptAsync do", async () => {
  const client = { session: { promptAsync: async () => { throw new Error("boom"); } } };
  const hooks = createChauffeurPlugin({ env: { ...env }, client, onExit: () => {}, spawn: () => { throw new Error("spawn failed"); } });
  await hooks.event({ event: { type: "session.created", properties: { info: { id: ROOT } } } });
  await hooks.event({ event: null });
  await hooks.event({});
  await hooks["tool.execute.after"]({ sessionID: ROOT }, { output: "x" });
  await hooks["tool.execute.after"](undefined, undefined);
  await hooks.dispose();
});

test("waiter starts on waitForWorkers, and work wakes the session", async () => {
  const h = await harness({ reply: (args) => (args.includes("--report-stop") ? { stdout: '{"block":false,"waitForWorkers":true}' } : args[0] === "wait-for-work" ? { hang: true } : {}) });
  await h.emit(...created(ROOT));
  await h.emit(...busy());
  await h.emit(...idle());
  const [w] = h.waiters();
  assert.deepEqual(w.args, ["wait-for-work", "--json"]);
  w.finish('{"reason":"work","text":"Worker Ada reported a milestone."}\n');
  await tick(10);
  assert.deepEqual(h.client.prompts, [{ path: { id: ROOT }, body: { parts: [{ type: "text", text: "Worker Ada reported a milestone." }] } }]);
});

test("a waiter that stops without work ends the turn as finished, unless another wait replaced it", async () => {
  for (const [stdout, finished] of [['{"reason":"timeout","text":"x"}', true], ['{"reason":"ended","text":"x"}', true], ["", true], ["garbage", true], ['{"reason":"replaced","text":"x"}', false]]) {
    const h = await harness({ reply: (args) => (args.includes("--report-stop") ? { stdout: '{"block":false,"waitForWorkers":true}' } : args[0] === "wait-for-work" ? { stdout } : {}) });
    await h.emit(...created(ROOT));
    await h.emit(...busy());
    await h.emit(...idle());
    await tick(10);
    assert.equal(h.waiters().length, 1);
    assert.equal(h.client.prompts.length, 0);
    assert.deepEqual(h.statuses(), ["session-start", "running", ...(finished ? ["turn-finished"] : [])], stdout);
    if (finished) {
      const call = h.ctl.calls.find((c) => c.args[3] === "turn-finished");
      assert.deepEqual(call.args, ["event", "--session", env.CHAUFFEUR_SESSION_ID, "turn-finished"]);
      assert.deepEqual(call.payload, { session_id: ROOT });
    }
  }
});

test("a waiter that cannot start ends the turn as finished", async () => {
  for (const how of ["throw", "error"]) {
    const ctl = fakeCtl((args) => (args.includes("--report-stop") ? { stdout: '{"block":false,"waitForWorkers":true}' } : {}));
    const spawn = (cmd, args, opts) => {
      if (args[0] !== "wait-for-work") return ctl.spawn(cmd, args, opts);
      if (how === "throw") throw new Error("EMFILE");
      const child = ctl.spawn(cmd, ["wait-for-work-hang"], opts); // never answers by itself
      setImmediate(() => { child.emit("error", new Error("ENOENT")); child.emit("close", -2, null); });
      return child;
    };
    const hooks = createChauffeurPlugin({ client: fakeClient(), env: { ...env }, spawn, onExit: () => {} });
    for (const [type, properties] of [created(ROOT), busy(), idle()]) { await hooks.event({ event: { type, properties } }); await tick(5); }
    await tick(20);
    const statuses = ctl.calls.filter((c) => c.args[0] === "event").map((c) => c.args[3]);
    assert.deepEqual(statuses, ["session-start", "running", "turn-finished"], how);
  }
});

test("a failed wake prompt from the waiter ends the turn as finished", async () => {
  for (const promptAsync of [async () => { throw new Error("server gone"); }, async () => ({ error: { name: "NotFound" } })]) {
    const h = await harness({
      client: { session: { promptAsync } },
      reply: (args) => (args.includes("--report-stop") ? { stdout: '{"block":false,"waitForWorkers":true}' } : args[0] === "wait-for-work" ? { stdout: '{"reason":"work","text":"Worker Ada reported."}' } : {}),
    });
    await h.emit(...created(ROOT));
    await h.emit(...busy());
    await h.emit(...idle());
    await tick(10);
    assert.deepEqual(h.statuses(), ["session-start", "running", "turn-finished"]);
  }
});

test("a failed continuation after a blocking Stop ends the turn instead of leaving it running", async () => {
  let fail = true;
  const h = await harness({
    client: { session: { promptAsync: async () => { if (fail) throw new Error("server gone"); return {}; } } },
    reply: (args) => (args.includes("--report-stop") ? { stdout: '{"block":true,"text":"New mail from Ada."}' } : {}),
  });
  await h.emit(...created(ROOT));
  await h.emit(...busy());
  await h.emit(...idle());
  await tick(10);
  assert.deepEqual(h.statuses(), ["session-start", "running", "turn-finished"]);
  // The continuation never happened, so the next Stop is a fresh one.
  fail = false;
  await h.emit(...busy());
  await h.emit(...idle());
  await tick(10);
  assert.deepEqual(h.stops().map((c) => c.payload.stop_hook_active), [false, false]);
  assert.deepEqual(h.statuses(), ["session-start", "running", "turn-finished", "running"], "a continuation that started reports nothing more");
});

test("no waiter without waitForWorkers", async () => {
  const h = await harness({ reply: stopReply({ block: false, waitForWorkers: false }) });
  await h.emit(...created(ROOT));
  await h.emit(...busy());
  await h.emit(...idle());
  assert.equal(h.waiters().length, 0);
});

test("busy kills the waiter, output from a waiter we killed is ignored, and the next idle starts a new one", async () => {
  const h = await harness({ reply: (args) => (args.includes("--report-stop") ? { stdout: '{"block":false,"waitForWorkers":true}' } : args[0] === "wait-for-work" ? { hang: true } : {}) });
  await h.emit(...created(ROOT));
  await h.emit(...busy());
  await h.emit(...idle());
  await h.emit(...idle());
  const [w] = h.waiters();
  assert.equal(h.waiters().length, 1, "at most one waiter");
  w.killStdout = '{"reason":"ended","text":"x"}\n{"reason":"work","text":"late"}\n';
  await h.emit(...busy());
  assert.equal(w.killed, "SIGTERM");
  await tick(10);
  assert.equal(h.client.prompts.length, 0);
  await h.emit(...idle());
  assert.equal(h.waiters().length, 2);
  assert.equal(h.waiters()[1].killed, null);
});

test("dispose and process exit kill the waiter", async () => {
  for (const how of ["dispose", "exit"]) {
    const h = await harness({ reply: (args) => (args.includes("--report-stop") ? { stdout: '{"block":false,"waitForWorkers":true}' } : args[0] === "wait-for-work" ? { hang: true } : {}) });
    await h.emit(...created(ROOT));
    await h.emit(...busy());
    await h.emit(...idle());
    if (how === "dispose") await h.hooks.dispose();
    else h.exits.forEach((fn) => fn());
    assert.equal(h.waiters()[0].killed, "SIGTERM");
  }
});

test("status and Stop calls reach chauffeurctl in event order", async () => {
  const h = await harness({ reply: (args) => (args[0] === "event" && args[3] === "session-start" ? { delayMs: 30 } : args.includes("--report-stop") ? { stdout: "{}" } : {}) });
  await h.hooks.event({ event: { type: "session.created", properties: { info: { id: ROOT } } } });
  await h.hooks.event({ event: { type: "session.status", properties: { sessionID: ROOT, status: { type: "busy" } } } });
  await h.hooks.event({ event: { type: "session.idle", properties: { sessionID: ROOT } } });
  assert.equal(h.ctl.calls.length, 1, "later calls wait for the earlier ones");
  await tick(80);
  assert.deepEqual(h.ctl.calls.map((c) => (c.args[0] === "event" ? c.args[3] : c.args[0])), ["session-start", "running", "inbox-hook"]);
});

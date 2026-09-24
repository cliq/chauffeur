// Drives the plugin through the real child_process path against a tiny shell stand-in for chauffeurctl.
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createChauffeurPlugin, fakeClient, tick, ROOT } from "./helpers.mjs";

const script = `#!/bin/sh
input=$(cat)
printf '%s|%s|%s\\n' "$*" "$input" "$CHAUFFEUR_SESSION_TOKEN" >> "$CTL_LOG"
case "$*" in
  "inbox-hook --provider opencode --report-stop") echo '{"block":false,"text":null,"waitForWorkers":true}' ;;
  "inbox-hook --provider opencode")
    [ -n "$CTL_HANG" ] && exec sleep 10
    echo "ignored first line"; echo '{"block":false,"text":"1 unread message","waitForWorkers":false}' ;;
  "wait-for-work --json") sleep 0.1; echo '{"reason":"work","text":"wake up"}' ;;
esac
`;

function setup(extraEnv = {}, options = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "chauffeur-opencode-"));
  const ctl = path.join(dir, "chauffeurctl");
  fs.writeFileSync(ctl, script, { mode: 0o755 });
  const log = path.join(dir, "ctl.log");
  const env = { PATH: process.env.PATH, CHAUFFEUR_CTL: ctl, CHAUFFEUR_SESSION_ID: "SID", CHAUFFEUR_SESSION_TOKEN: "tok", CTL_LOG: log, ...extraEnv };
  const client = fakeClient();
  const hooks = createChauffeurPlugin({ env, client, onExit: () => {}, ...options });
  const lines = () => (fs.existsSync(log) ? fs.readFileSync(log, "utf8").trim().split("\n") : []);
  const until = async (pred, ms = 3000) => { const end = Date.now() + ms; while (!pred() && Date.now() < end) await tick(20); };
  return { hooks, client, lines, until, cleanup: () => fs.rmSync(dir, { recursive: true, force: true }) };
}

test("real spawn: payloads reach ctl on stdin and replies drive the waiter and tool output", async () => {
  const t = setup();
  try {
    const ev = (type, properties) => t.hooks.event({ event: { type, properties } });
    await ev("session.created", { sessionID: ROOT, info: { id: ROOT } });
    await ev("session.status", { sessionID: ROOT, status: { type: "busy" } });
    const output = { title: "", output: "ok", metadata: {} };
    await t.hooks["tool.execute.after"]({ tool: "bash", sessionID: ROOT, callID: "c" }, output);
    assert.equal(output.output, "ok\n\n1 unread message");
    await ev("session.idle", { sessionID: ROOT });
    await t.until(() => t.client.prompts.length > 0);
    assert.deepEqual(t.client.prompts, [{ path: { id: ROOT }, body: { parts: [{ type: "text", text: "wake up" }] } }]);
    const lines = t.lines();
    const find = (prefix) => lines.find((l) => l.startsWith(prefix + "|"));
    assert.equal(find("event --session SID session-start"), `event --session SID session-start|{"session_id":"${ROOT}","hook_event_name":"SessionStart","source":"startup"}|tok`);
    assert.equal(find("event --session SID running"), `event --session SID running|{"session_id":"${ROOT}"}|tok`);
    assert.equal(find("inbox-hook --provider opencode"), `inbox-hook --provider opencode|{"session_id":"${ROOT}","hook_event_name":"PostToolUse"}|tok`);
    assert.equal(find("inbox-hook --provider opencode --report-stop"), `inbox-hook --provider opencode --report-stop|{"session_id":"${ROOT}","hook_event_name":"Stop","stop_hook_active":false}|tok`);
    assert.equal(find("wait-for-work --json"), "wait-for-work --json||tok");
  } finally { t.cleanup(); }
});

test("real spawn: a hanging ctl is killed at the tool-hook bound", async () => {
  const t = setup({ CTL_HANG: "1" }, { toolHookTimeoutMs: 200 });
  try {
    await t.hooks.event({ event: { type: "session.created", properties: { info: { id: ROOT } } } });
    const output = { title: "", output: "ok", metadata: {} };
    const t0 = Date.now();
    await t.hooks["tool.execute.after"]({ tool: "bash", sessionID: ROOT, callID: "c" }, output);
    assert.ok(Date.now() - t0 < 1500, "bounded");
    assert.equal(output.output, "ok");
  } finally { t.cleanup(); }
});

test("real spawn: a missing ctl binary is swallowed", async () => {
  const hooks = createChauffeurPlugin({ env: { CHAUFFEUR_CTL: "/nonexistent/chauffeurctl", CHAUFFEUR_SESSION_ID: "SID" }, client: fakeClient(), onExit: () => {} });
  await hooks.event({ event: { type: "session.created", properties: { info: { id: ROOT } } } });
  const output = { output: "ok" };
  await hooks["tool.execute.after"]({ sessionID: ROOT }, output);
  assert.equal(output.output, "ok");
});

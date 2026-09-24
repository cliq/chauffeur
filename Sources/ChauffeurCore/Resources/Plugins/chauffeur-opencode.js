// Chauffeur's OpenCode plugin. It reports the root session's status through chauffeurctl, continues turns for new mail,
// appends mid-turn mail hints to tool output and runs the coordinator waiter. The contract with chauffeurctl is in
// docs/chauffeur/plans/opencode-provider.md ("Plugin ↔ runtime contract"). No dependencies beyond node built-ins.
import { spawn as nodeSpawn } from "node:child_process";

const defaults = {
  ctlTimeoutMs: 5000,
  toolHookTimeoutMs: 3000,
  // Under --auto OpenCode answers permissions in ~13 ms; only a request still open after this is worth reporting.
  attentionDelayMs: 250,
};

/** Builds the plugin hooks. Every dependency is injectable so tests can drive it without OpenCode or chauffeurctl. */
function createChauffeurPlugin({
  client,
  env = process.env,
  spawn = nodeSpawn,
  setTimeout: setTimer = setTimeout,
  clearTimeout: clearTimer = clearTimeout,
  onExit = (fn) => process.once("exit", fn),
  ...options
} = {}) {
  const ctl = env.CHAUFFEUR_CTL;
  const chauffeurSession = env.CHAUFFEUR_SESSION_ID;
  if (!ctl || !chauffeurSession) return {};
  const cfg = { ...defaults, ...options };

  const s = {
    root: null,
    children: new Set(),
    reported: null, // last status sent, so only transitions reach chauffeurctl
    idle: false, // dedupes repeated session.idle
    errored: false, // a non-abort session.error owns the status until the next busy
    pending: new Map(), // permission/question id -> attention timer
    attention: false, // needs-attention was reported for a pending request
    stopActive: false, // the previous Stop blocked and the plugin continued the turn
    turn: 0, // bumped on busy, so late ctl replies for an earlier idle are dropped
    waiter: null,
  };
  let queue = Promise.resolve(); // status and Stop calls run in order

  function run(args, payload, timeoutMs) {
    return new Promise((resolve) => {
      let child, timer, out = "", done = false;
      const finish = (value) => { if (!done) { done = true; clearTimer(timer); resolve(value); } };
      try {
        child = spawn(ctl, args, { env, stdio: ["pipe", "pipe", "ignore"] });
        child.on("error", () => finish(null));
        child.on("close", () => finish(out));
        child.stdout?.on("data", (d) => { out += d; });
        child.stdin?.on("error", () => {});
        child.stdin?.end(payload ? JSON.stringify(payload) + "\n" : "");
        timer = setTimer(() => { try { child.kill("SIGKILL"); } catch {} finish(null); }, timeoutMs);
      } catch { finish(null); }
    });
  }
  const enqueue = (task) => { queue = queue.then(task).catch(() => {}); return queue; };
  const payload = (hook_event_name, extra = {}) => ({ session_id: s.root, ...(hook_event_name && { hook_event_name }), ...extra });

  function report(status, body = payload()) {
    if (s.reported === status) return;
    s.reported = status;
    enqueue(() => run(["event", "--session", chauffeurSession, status], body, cfg.ctlTimeoutMs));
  }

  /** Resolves whether OpenCode accepted the prompt; the SDK reports most failures as `{error}` rather than throwing. */
  async function prompt(text) {
    try {
      const r = await client.session.promptAsync({ path: { id: s.root }, body: { parts: [{ type: "text", text }] } });
      return !r?.error;
    } catch { return false; }
  }

  // Nothing continues the turn (a prompt failed, or no waiter is waiting), so it ends as finished work: the runtime
  // marks the session unread and notifies, which a Stop that blocked or started a waiter left out.
  function turnFinished() {
    s.stopActive = false;
    report("turn-finished");
  }

  function adopt(id, source) {
    s.root = id;
    enqueue(() => run(["event", "--session", chauffeurSession, "session-start"], payload("SessionStart", { source }), cfg.ctlTimeoutMs));
  }

  function startWaiter() {
    if (s.waiter) return;
    let child;
    try { child = spawn(ctl, ["wait-for-work", "--json"], { env, stdio: ["ignore", "pipe", "ignore"] }); } catch { turnFinished(); return; }
    const waiter = { child, killed: false, done: false, out: "" };
    s.waiter = waiter;
    // `error` (the ctl didn't start) and `close` can both arrive; only the first counts.
    const exited = async () => {
      if (waiter.done) return;
      waiter.done = true;
      if (s.waiter === waiter) s.waiter = null;
      if (waiter.killed) return; // a new turn started, or OpenCode is exiting
      const turn = s.turn;
      const r = parseLine(waiter.out);
      if (r?.reason === "replaced") return; // another wait of this session carries on
      if (r?.reason === "work" && typeof r.text === "string" && r.text && await prompt(r.text)) return;
      if (s.turn === turn) turnFinished();
    };
    child.on("error", exited);
    child.stdout?.on("data", (d) => { waiter.out += d; });
    child.on("close", exited);
  }
  function killWaiter() {
    const w = s.waiter;
    if (!w) return;
    s.waiter = null;
    w.killed = true;
    try { w.child.kill("SIGTERM"); } catch {}
  }

  function clearPending() {
    for (const t of s.pending.values()) clearTimer(t);
    s.pending.clear();
    s.attention = false;
  }

  function onBusy() {
    s.turn++;
    s.idle = false;
    s.errored = false;
    killWaiter();
    if (!s.attention) report("running"); // the status stays busy while a dialog is open
  }

  function onIdle() {
    if (s.idle) return;
    s.idle = true;
    clearPending();
    // After an error OpenCode sends one or two idles; the Stop hook would report turn-finished over needs-attention.
    if (s.errored) return;
    // Either the ctl reports turn-finished or the plugin continues the turn; the next busy reports running again.
    s.reported = "idle";
    const turn = s.turn;
    const body = payload("Stop", { stop_hook_active: s.stopActive });
    enqueue(async () => {
      const r = parseLine(await run(["inbox-hook", "--provider", "opencode", "--report-stop"], body, cfg.ctlTimeoutMs));
      if (s.turn !== turn) return; // the user started a turn meanwhile; the mail stays in the inbox
      if (r?.block === true && typeof r.text === "string" && r.text) {
        s.stopActive = true;
        // The ctl left the turn running for this continuation; without it nothing would ever end the turn.
        if (!(await prompt(r.text)) && s.turn === turn) turnFinished();
      } else {
        s.stopActive = false;
        if (r?.waitForWorkers === true) startWaiter();
      }
    });
  }

  function onError(error) {
    if (error?.name === "MessageAbortedError") return; // the user pressed Esc
    s.errored = true;
    s.stopActive = false;
    report("needs-attention");
  }

  function onAsked(id) {
    if (!id || s.pending.has(id)) return;
    s.pending.set(id, setTimer(() => {
      if (!s.pending.has(id) || s.attention) return;
      s.attention = true;
      report("needs-attention");
    }, cfg.attentionDelayMs));
  }

  function onReplied(id) {
    if (!s.pending.has(id)) return;
    clearTimer(s.pending.get(id));
    s.pending.delete(id);
    if (s.attention && s.pending.size === 0) {
      s.attention = false;
      report("running");
    }
  }

  function onEvent(event) {
    const type = event?.type;
    const p = event?.properties ?? {};
    if (type === "session.created" || type === "session.updated") {
      const info = p.info ?? {};
      if (info.parentID) { s.children.add(info.id); return; }
      if (type === "session.created" && info.id && !s.root) { adopt(info.id, "startup"); return; }
    }
    const sid = p.sessionID ?? p.info?.id;
    if (typeof sid !== "string") return;
    if (s.children.has(sid)) {
      // A subagent's dialog blocks the whole TUI, so it needs attention like the root's own.
      if (type === "permission.asked" || type === "question.asked") onAsked(p.id);
      else if (type === "permission.replied" || type === "question.replied" || type === "question.rejected") onReplied(p.requestID);
      return;
    }
    if (!s.root) adopt(sid, "resume"); // `-s <id>` emits no session.created
    if (sid !== s.root) return;
    switch (type) {
      case "session.status": if (p.status?.type === "busy") onBusy(); break;
      case "session.idle": onIdle(); break;
      case "session.error": onError(p.error); break;
      case "permission.asked": case "question.asked": onAsked(p.id); break;
      case "permission.replied": case "question.replied": case "question.rejected": onReplied(p.requestID); break;
    }
  }

  function dispose() { killWaiter(); clearPending(); }
  try { onExit(dispose); } catch {}

  return {
    event: async ({ event } = {}) => { try { onEvent(event); } catch {} },
    // OpenCode awaits this hook, so the ctl call is bounded well below the tool's own budget.
    "tool.execute.after": async (input, output) => {
      try {
        if (!s.root || input?.sessionID !== s.root || !output) return;
        const r = parseLine(await run(["inbox-hook", "--provider", "opencode"], payload("PostToolUse"), cfg.toolHookTimeoutMs));
        const text = r?.text;
        if (typeof text !== "string" || !text) return;
        if (typeof output.output === "string") output.output += "\n\n" + text;
        else if (Array.isArray(output.content)) output.content.push({ type: "text", text });
        else output.output = text;
      } catch {}
    },
    dispose: async () => { try { dispose(); } catch {} },
  };
}

function parseLine(out) {
  if (typeof out !== "string") return null;
  const line = out.trim().split("\n").pop();
  if (!line) return null;
  try { const v = JSON.parse(line); return v && typeof v === "object" ? v : null; } catch { return null; }
}

// The only export OpenCode sees: its loader calls every exported function as a plugin. Tests reach the factory
// through the property.
export const ChauffeurOpenCode = async ({ client } = {}) => createChauffeurPlugin({ client });
ChauffeurOpenCode.createChauffeurPlugin = createChauffeurPlugin;

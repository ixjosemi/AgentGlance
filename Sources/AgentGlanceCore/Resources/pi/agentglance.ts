// AgentGlance session-status extension for Pi (https://github.com/badlogic/pi-mono).
// Installed by `agentglance install` into ~/.pi/agent/extensions/. Mirrors the
// OpenCode plugin: every lifecycle event is persisted as a versioned state
// document under ~/.agentglance/state for the notch app to observe.
import { chmod, mkdir, rename, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, join } from "node:path";
import { spawn } from "node:child_process";

const stateDirectory = join(
  process.env.AGENTGLANCE_HOME || join(homedir(), ".agentglance"),
  "state",
);
const sessions = new Map();

function timestamp() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
}

function sessionID(ctx) {
  return ctx?.sessionManager?.getSessionId?.() || `pid-${process.pid}`;
}

function createState(id, cwd) {
  const now = timestamp();
  return {
    schema_version: 1,
    tool: "pi",
    session_id: id,
    pid: process.pid,
    status: "working",
    attention_reason: null,
    cwd,
    started_at: now,
    updated_at: now,
    terminal: {
      term_program: process.env.TERM_PROGRAM || null,
      iterm_session_id: process.env.ITERM_SESSION_ID || null,
      tmux_pane: process.env.TMUX_PANE || null,
      tty: null,
      window_title_hint: `${basename(cwd)} — pi`,
    },
  };
}

async function writeState(state) {
  const encoded = Buffer.from(state.session_id, "utf8");
  if (encoded.length > 128) throw new Error("AgentGlance session ID exceeds 128 bytes");
  const safeID = encoded.toString("base64url");
  const destination = join(stateDirectory, `pi-${safeID}.json`);
  const temporary = join(stateDirectory, `.${safeID}-${process.pid}.tmp`);
  await mkdir(stateDirectory, { recursive: true, mode: 0o700 });
  await chmod(stateDirectory, 0o700);
  await writeFile(temporary, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
  await rename(temporary, destination);
  // Spawn failures surface as asynchronous "error" events; without a
  // listener they would crash the host process. A missed notification is
  // harmless — the app also observes the state directory directly.
  const notifier = spawn("/usr/bin/notifyutil", ["-p", "com.agentglance.stateChanged"], {
    stdio: "ignore",
  });
  notifier.on("error", () => {});
  notifier.unref();
}

async function transition(ctx, status, attentionReason) {
  const id = sessionID(ctx);
  const state = sessions.get(id) || createState(id, ctx?.cwd || process.cwd());
  state.status = status;
  state.attention_reason = attentionReason ?? null;
  state.updated_at = timestamp();
  sessions.set(id, state);
  await writeState(state);
}

let warnedOnce = false;

function guarded(handler) {
  return async (event, ctx) => {
    try {
      await handler(event, ctx);
    } catch (error) {
      if (!warnedOnce) {
        warnedOnce = true;
        console.error(`agentglance: state update failed: ${String(error)}`);
      }
    }
  };
}

export default function agentGlance(pi) {
  pi.on("session_start", guarded(async (_event, ctx) => transition(ctx, "working")));
  pi.on("input", guarded(async (_event, ctx) => transition(ctx, "working")));
  pi.on("agent_start", guarded(async (_event, ctx) => transition(ctx, "working")));
  pi.on(
    "agent_end",
    guarded(async (_event, ctx) => transition(ctx, "idle", "turn_complete")),
  );
  pi.on("session_before_switch", guarded(async (_event, ctx) => transition(ctx, "ended")));
  pi.on("session_shutdown", guarded(async (_event, ctx) => transition(ctx, "ended")));
}

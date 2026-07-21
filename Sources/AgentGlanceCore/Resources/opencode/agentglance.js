// AgentGlance-managed integration; reinstalls replace this file.
import { chmod, mkdir, rename, writeFile } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { homedir } from "node:os";
import { basename, join } from "node:path";
import { spawn } from "node:child_process";

const stateDirectory = join(
  process.env.AGENTGLANCE_HOME || join(homedir(), ".agentglance"),
  "state",
);
const sessions = new Map();
const childSessionIDs = new Set();
const updateQueues = new Map();

function timestamp() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
}

function createState(session, directory) {
  const now = timestamp();
  return {
    schema_version: 1,
    tool: "opencode",
    session_id: session.id,
    pid: process.pid,
    status: "working",
    attention_reason: null,
    cwd: session.directory || directory,
    started_at: now,
    updated_at: now,
    terminal: {
      term_program: process.env.TERM_PROGRAM || null,
      iterm_session_id: process.env.ITERM_SESSION_ID || null,
      tmux_pane: process.env.TMUX_PANE || null,
      tty: null,
      window_title_hint: `${basename(session.directory || directory)} — opencode`,
    },
  };
}

async function writeState(state) {
  const sessionID = Buffer.from(state.session_id, "utf8");
  if (sessionID.length > 128) throw new Error("AgentGlance session ID exceeds 128 bytes");
  const safeID = sessionID.toString("base64url");
  const destination = join(stateDirectory, `opencode-${safeID}.json`);
  // OpenCode does not serialize event delivery: a burst of events for the
  // same session can call writeState concurrently. A temp name fixed per
  // session+pid let one call's rename consume another's temp file first,
  // failing the loser's rename with ENOENT and silently dropping that
  // status transition. A unique name per call removes the collision.
  const temporary = join(stateDirectory, `.${safeID}-${process.pid}-${randomUUID()}.tmp`);
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

function eventSessionID(event) {
  return event.properties.sessionID
    || event.properties.session_id
    || event.properties.info?.id;
}

async function isRootSession(client, sessionID) {
  try {
    const response = await client.session.get({ path: { id: sessionID } });
    return !response.data?.parentID;
  } catch {
    // Fail open: a lookup hiccup must not blind the app to a real root
    // session, and the app's reaper prunes any duplicate that slips through.
    return true;
  }
}

async function updateState(client, event, directory) {
  const sessionID = eventSessionID(event);
  if (!sessionID || childSessionIDs.has(sessionID)) return;
  if (event.type === "session.created") {
    // Child sessions (subagents, title generation) run inside a root
    // session's terminal; tracking them would list phantom sessions.
    if (event.properties.info?.parentID) {
      childSessionIDs.add(sessionID);
      return;
    }
    const state = createState(event.properties.info, directory);
    sessions.set(sessionID, state);
    await writeState(state);
    return;
  }
  let state = sessions.get(sessionID);
  if (!state) {
    // Unknown mid-stream session: the plugin instance is younger than the
    // session (daemon restart). Ask the server whether it is a root
    // session before fabricating a document for it.
    if (!(await isRootSession(client, sessionID))) {
      childSessionIDs.add(sessionID);
      return;
    }
    state = createState({ id: sessionID }, directory);
  }
  const transitions = {
    "permission.asked": ["needs_attention", "permission"],
    "permission.replied": ["working", null],
    "session.idle": ["idle", null],
    "session.deleted": ["ended", null],
  };
  // session.status carries its own idle signal (properties.status.type ===
  // "idle") alongside the dedicated session.idle event below — OpenCode
  // 1.18 emits this one, not the dedicated event, when a turn ends. Treating
  // only busy/retry as meaningful and falling through to transitions[] (which
  // has no "session.status" key) silently dropped every idle transition,
  // leaving the spinner stuck on "working" forever.
  const statusTransition = event.type === "session.status"
    ? ["busy", "retry"].includes(event.properties.status?.type)
      ? ["working", null]
      : event.properties.status?.type === "idle"
        ? ["idle", null]
        : null
    : null;
  const transition = statusTransition ?? transitions[event.type];
  if (!transition) return;
  // While a permission is pending, OpenCode keeps emitting session.status
  // "busy" noise for the paused turn. Only an explicit
  // permission.replied may end the wait — anything else must not downgrade
  // the red light back to "working".
  if (state.status === "needs_attention" && transition[0] === "working" && event.type !== "permission.replied") {
    return;
  }
  state.status = transition[0];
  state.attention_reason = transition[1];
  state.updated_at = timestamp();
  sessions.set(sessionID, state);
  await writeState(state);
}

export const AgentGlancePlugin = async ({ client, directory }) => ({
  event: async ({ event }) => {
    const sessionID = eventSessionID(event);
    const previous = sessionID ? updateQueues.get(sessionID) : undefined;
    const update = (previous ?? Promise.resolve()).catch(() => {}).then(
      () => updateState(client, event, directory),
    );
    if (sessionID) updateQueues.set(sessionID, update);
    try {
      await update;
    } catch (error) {
      await client.app.log({
        body: {
          service: "agentglance",
          level: "warn",
          message: `State update failed: ${String(error)}`,
        },
      });
    } finally {
      if (sessionID && updateQueues.get(sessionID) === update) {
        updateQueues.delete(sessionID);
      }
    }
  },
});

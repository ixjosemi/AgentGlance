import { chmod, mkdir, rename, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, join } from "node:path";
import { spawn } from "node:child_process";

const stateDirectory = join(
  process.env.AGENTGLANCE_HOME || join(homedir(), ".agentglance"),
  "state",
);
const sessions = new Map();

function createState(session, directory) {
  const now = new Date().toISOString();
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
  const temporary = join(stateDirectory, `.${safeID}-${process.pid}.tmp`);
  await mkdir(stateDirectory, { recursive: true, mode: 0o700 });
  await chmod(stateDirectory, 0o700);
  await writeFile(temporary, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
  await rename(temporary, destination);
  try {
    spawn("/usr/bin/notifyutil", ["-p", "com.agentglance.stateChanged"], {
      stdio: "ignore",
    }).unref();
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
}

function eventSessionID(event) {
  return event.properties.sessionID
    || event.properties.session_id
    || event.properties.info?.id;
}

async function updateState(event, directory) {
  const sessionID = eventSessionID(event);
  if (!sessionID) return;
  if (event.type === "session.created") {
    const state = createState(event.properties.info, directory);
    sessions.set(sessionID, state);
    await writeState(state);
    return;
  }
  const state = sessions.get(sessionID) || createState({ id: sessionID }, directory);
  const transitions = {
    "permission.asked": ["needs_attention", "permission"],
    "permission.replied": ["working", null],
    "session.idle": ["idle", null],
    "session.deleted": ["ended", null],
    "message.updated": ["working", null],
  };
  const transition = event.type === "session.status"
    && ["busy", "working", "retry"].includes(event.properties.status?.type)
    ? ["working", null]
    : transitions[event.type];
  if (!transition) return;
  state.status = transition[0];
  state.attention_reason = transition[1];
  state.updated_at = new Date().toISOString();
  sessions.set(sessionID, state);
  await writeState(state);
}

export const AgentGlancePlugin = async ({ client, directory }) => ({
  event: async ({ event }) => {
    try {
      await updateState(event, directory);
    } catch (error) {
      await client.app.log({
        body: {
          service: "agentglance",
          level: "warn",
          message: `State update failed: ${String(error)}`,
        },
      });
    }
  },
});

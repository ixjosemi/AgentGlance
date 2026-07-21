import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const home = await mkdtemp(join(tmpdir(), "agentglance-opencode-"));
process.env.AGENTGLANCE_HOME = home;

try {
  const { AgentGlancePlugin } = await import(
    "../../Sources/AgentGlanceCore/Resources/opencode/agentglance.js"
  );
  const plugin = await AgentGlancePlugin({
    directory: "/tmp/project",
    client: {
      session: { get: async () => ({ data: {} }) },
      app: { log: async ({ body }) => { throw new Error(body.message); } },
    },
  });
  const event = (type, properties) => plugin.event({ event: { type, properties } });
  await event("session.created", {
    info: { id: "regression", directory: "/tmp/project" },
  });

  // OpenCode can deliver a burst without awaiting previous plugin handlers.
  // message.updated describes persisted message data, not active generation,
  // and must never resurrect a turn after the authoritative idle signal.
  await Promise.all([
    event("session.status", { sessionID: "regression", status: { type: "busy" } }),
    event("session.status", { sessionID: "regression", status: { type: "idle" } }),
    event("message.updated", { sessionID: "regression" }),
  ]);

  const state = JSON.parse(await readFile(
    join(home, "state", "opencode-cmVncmVzc2lvbg.json"),
    "utf8",
  ));
  assert.equal(state.status, "idle", "busy -> idle -> message.updated must remain idle");
  console.log("OpenCode plugin regression tests passed");
} finally {
  await rm(home, { recursive: true, force: true });
}

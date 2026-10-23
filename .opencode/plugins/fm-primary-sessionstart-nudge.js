import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { createSessionScope } from "./lib/fm-session-scope.js";

// Session-start nudge for OpenCode 2.x primary sessions: on a session.created
// at this plugin's own location, run bin/fm-sessionstart-nudge.sh and deliver
// its one-line instruction into the session through ctx.session.prompt (the
// 2.x form of V1's client.session.promptAsync; both admit a user prompt that
// the session processes as its own turn). OpenCode 2.1.4 publishes
// session.created as { type, data: { sessionID, location: { directory }, ... } }
// and never the legacy session.idle/session.status bus events (verified live,
// 2.1.4; see .agents/skills/harness-adapters/references/harness/opencode.md).
// One 2.x server hosts sessions from many directories and every location
// plugin receives every hosted session's created event, so the nudge acts
// only on sessions created at this plugin's own root and only on top-level
// sessions (lib/fm-session-scope.js). The owner script is itself inert
// outside a genuine firstmate primary, so a crewmate/scout worktree never
// nudges.

const handledSessions = new Set();

function rememberSession(sessionID) {
  if (handledSessions.size >= 512) handledSessions.clear();
  handledSessions.add(sessionID);
}

function runProcess(command, args) {
  return new Promise((resolveResult) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "ignore"] });
    let stdout = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.on("error", () => resolveResult({ code: 0, stdout: "" }));
    child.on("close", (code) => resolveResult({ code: code ?? 0, stdout }));
  });
}

function resolvePath(anchor) {
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

async function resolveRoot(anchor) {
  if (!anchor) return "";
  const result = await runProcess("git", ["-C", anchor, "rev-parse", "--show-toplevel"]);
  const root = result.stdout.trim();
  if (result.code === 0 && root) return root;
  return resolvePath(anchor);
}

export default {
  id: "fm-primary-sessionstart-nudge",
  async setup(ctx) {
    const root = await resolveRoot(ctx.location?.directory);
    const scope = createSessionScope(root);
    const stop = new AbortController();

    void (async () => {
      try {
        for await (const event of ctx.event.subscribe({ signal: stop.signal })) {
          try {
            if (event.type !== "session.created") continue;
            const data = event.data ?? {};
            const sessionID = data.sessionID;
            if (!sessionID || handledSessions.has(sessionID) || !root) continue;
            if (data.parentID || !(await scope.ownsDirectory(data.location?.directory))) {
              rememberSession(sessionID);
              continue;
            }
            rememberSession(sessionID);

            const result = await runProcess(`${root}/bin/fm-sessionstart-nudge.sh`, []);
            const nudge = result.code === 0 ? result.stdout.trim() : "";
            if (!nudge) continue;

            try {
              await ctx.session.prompt({ sessionID, text: nudge });
            } catch {
              // OpenCode owns delivery errors; the once-per-session guard above stands.
            }
          } catch {
            // One unreadable event never ends the subscription.
          }
        }
      } catch {
        // The event stream closes at shutdown.
      }
    })();

    return () => stop.abort();
  },
};

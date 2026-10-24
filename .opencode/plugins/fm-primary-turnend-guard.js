import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { createSessionScope } from "./lib/fm-session-scope.js";
import { encodeFirstmateOperationalInput } from "./lib/fm-operational-input.js";

const COORDINATOR_KEY = "__firstmateOpenCodeWatchArm";

// Turn-end guard for OpenCode 2.x primary sessions. OpenCode 2.x never
// publishes the legacy session.idle bus event (verified live on 2.1.4; it
// exists only in the API schema), so a turn ends with exactly one of
// session.execution.succeeded, session.execution.failed, or
// session.execution.interrupted - the same close set the busy-state plugin
// settles on - and this guard runs at that boundary. The one-follow-up
// skipNextIdle flag from the 1.x single-session form becomes a per-session
// set: one plugin instance now serves every session at this root, and each
// session's guard follow-up must be skipped exactly once (its own follow-up
// turn's close), never another session's. The follow-up itself is delivered
// with ctx.session.prompt (2.x form of V1's client.session.promptAsync;
// verified live on 2.1.4: an admitted plugin prompt drives a follow-up
// execution in the same session). One 2.x server hosts sessions from many
// directories and every location plugin receives every hosted session's
// execution events, so the guard acts only on top-level sessions at this
// plugin's own root (lib/fm-session-scope.js); the owner script is itself
// inert outside a real primary checkout, so a crewmate/scout worktree stays
// silent.

const TURN_END_EVENTS = new Set([
  "session.execution.succeeded",
  "session.execution.failed",
  "session.execution.interrupted",
]);
const skipNextTurnEnd = new Set();

function markSkipNextTurnEnd(sessionID) {
  if (skipNextTurnEnd.size >= 512) skipNextTurnEnd.clear();
  skipNextTurnEnd.add(sessionID);
}

function runProcess(command, args, input = "") {
  return new Promise((resolve) => {
    const child = spawn(command, args, {
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolve({ code: 0, stdout: "", stderr: "" }));
    child.on("close", (code) => resolve({ code: code ?? 0, stdout, stderr }));
    // A guard that exits before reading its payload (a fast deny, or a shell
    // that fails to exec) closes the pipe mid-write; EPIPE on stdin is that
    // expected close, never a plugin crash.
    child.stdin.on("error", () => {});
    child.stdin.end(input);
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

function runGuard(root) {
  if (!root) return Promise.resolve({ code: 0, stderr: "" });
  return runProcess(`${root}/bin/fm-turnend-guard.sh`, [], '{"stop_hook_active":false}');
}

async function letWatchArmRun(root, sessionID, ctx) {
  const coordinator = globalThis[COORDINATOR_KEY + root];
  if (!coordinator?.ensureArmed) return false;
  const status = await coordinator.ensureArmed(sessionID, ctx);
  return status === "armed" || status === "wake" || status === "failed";
}

export default {
  id: "fm-primary-turnend-guard",
  async setup(ctx) {
    const root = await resolveRoot(ctx.location?.directory);
    const scope = createSessionScope(root);
    const stop = new AbortController();

    void (async () => {
      try {
        for await (const event of ctx.event.subscribe({ signal: stop.signal })) {
          if (!TURN_END_EVENTS.has(event.type)) continue;
          try {
            const sessionID = event.data?.sessionID;
            if (!sessionID || !root) continue;
            if (!(await scope.ownsSession(ctx, sessionID))) continue;

            if (skipNextTurnEnd.has(sessionID)) {
              skipNextTurnEnd.delete(sessionID);
              continue;
            }

            if (await letWatchArmRun(root, sessionID, ctx)) continue;

            const result = await runGuard(root);
            if (result.code !== 2) continue;

            try {
              const text = await encodeFirstmateOperationalInput(
                root,
                "turn-end-guard",
                "TURN WOULD END BLIND - supervision is off. " +
                  "The watcher cycle is missing, failed, or unhealthy. Follow the harness recovery instruction below before ending the turn.\n\n" +
                  result.stderr,
              );
              await ctx.session.prompt({ sessionID, text });
              markSkipNextTurnEnd(sessionID);
            } catch {
              skipNextTurnEnd.delete(sessionID);
            }
          } catch {
            // One failed event never ends the subscription.
          }
        }
      } catch {
        // The event stream closes at shutdown.
      }
    })();

    return () => stop.abort();
  },
};

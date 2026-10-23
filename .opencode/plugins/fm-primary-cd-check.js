import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { spawn } from "node:child_process";
import { createSessionScope } from "./lib/fm-session-scope.js";

// PreToolUse seatbelt for OpenCode 2.x: block a stray persistent top-level `cd`
// in the primary firstmate checkout before the agent's shell tool relocates
// the shell out of the home (see bin/fm-cd-pretool-check.sh and docs/cd-guard.md).
// This mirrors fm-primary-pretool-check.js, calling the cd-guard owner instead
// of the watcher-arm one. The 2.x tool hook (ctx.tool.hook "execute.before")
// blocks by throwing and the thrown message surfaces as the failed tool
// result (verified 2026-10-23 against OpenCode 2.1.4; the same mechanism was
// first verified 2026-07-09 against OpenCode 1.17.15 for the watcher-arm
// plugin). The shell tool is named "shell" on 2.x (verified 2.1.4) and its
// input carries the command as event.input.command; V1's bash tool named it
// output.args.command. One 2.x server hosts sessions from many directories
// and every location plugin receives every session's tool calls, so the
// guard acts only on top-level sessions at this plugin's own root
// (lib/fm-session-scope.js). The owner script is itself inert outside the
// real primary checkout, so a crewmate/scout worktree is never affected.

function runProcess(command, args) {
  return new Promise((resolvePromise) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolvePromise({ code: 0, stdout: "", stderr: "" }));
    child.on("close", (code) => resolvePromise({ code: code ?? 0, stdout, stderr }));
  });
}

async function resolveRoot(anchor) {
  if (!anchor) return "";
  const result = await runProcess("git", ["-C", anchor, "rev-parse", "--show-toplevel"]);
  const root = result.stdout.trim();
  if (result.code === 0 && root) return root;
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

export default {
  id: "fm-primary-cd-check",
  async setup(ctx) {
    const root = await resolveRoot(ctx.location?.directory);
    if (!root) return;
    const scope = createSessionScope(root);

    await ctx.tool.hook("execute.before", async (event) => {
      if (event?.tool !== "shell") return;
      const command = event.input && typeof event.input === "object"
        && typeof event.input.command === "string" ? event.input.command : undefined;
      if (!command) return;
      if (!(await scope.ownsSession(ctx, event.sessionID))) return;

      const result = await runProcess(`${root}/bin/fm-cd-pretool-check.sh`, ["--command", command]);
      if (result.code !== 2) return;

      const reason = result.stderr.trim() || "denied by the cd-guard PreToolUse seatbelt";
      throw new Error(reason);
    });
  },
};

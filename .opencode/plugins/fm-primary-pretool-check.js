import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { spawn } from "node:child_process";
import { createSessionScope } from "./lib/fm-session-scope.js";

// PreToolUse seatbelt for OpenCode 2.x: the arm mechanism itself lives entirely in
// fm-primary-watch-arm.js (a plugin-owned child process, never a model tool
// call), so the residual risk here is the AGENT shelling `bin/fm-watch-arm.sh`
// wrong through its own shell tool - the anti-pattern bin/fm-arm-pretool-check.sh
// guards against (see that script's header and docs/arm-pretool-check.md).
// The 2.x tool hook (ctx.tool.hook "execute.before") can block by throwing
// and the thrown message surfaces as the failed tool result (verified
// 2026-10-23 against OpenCode 2.1.4, and first verified 2026-07-09 against
// OpenCode 1.17.15 for the same seatbelt class: throwing here prevents the
// command from running and surfaces the thrown message). The shell tool is
// named "shell" on 2.x (verified 2.1.4) and its input carries the command as
// event.input.command; V1's bash tool named it output.args.command. One 2.x
// server hosts sessions from many directories and every location plugin
// receives every session's tool calls, so the guard acts only on sessions at
// this plugin's own root, subagent child sessions at that root included - V1
// guarded every bash tool call in the checkout regardless of session
// (lib/fm-session-scope.js).

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
  id: "fm-primary-pretool-check",
  async setup(ctx) {
    const root = await resolveRoot(ctx.location?.directory);
    if (!root) return;
    const scope = createSessionScope(root);

    await ctx.tool.hook("execute.before", async (event) => {
      if (event?.tool !== "shell") return;
      const command = event.input && typeof event.input === "object" ? event.input.command : undefined;
      if (!command || typeof command !== "string") return;
      if (!(await scope.ownsSessionAtRoot(ctx, event.sessionID))) return;

      const result = await runProcess(`${root}/bin/fm-arm-pretool-check.sh`, ["--command", command]);
      if (result.code !== 2) return;

      const reason = result.stderr.trim() || "denied by the watcher-arm PreToolUse seatbelt";
      throw new Error(reason);
    });
  },
};

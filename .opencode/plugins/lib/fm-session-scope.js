import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { spawn } from "node:child_process";

// Session-to-location scoping for Firstmate's OpenCode 2.x primary plugins.
// A 2.x server can host sessions from many directories, and every location
// plugin loaded in that server receives every hosted session's events, so a
// primary plugin that acted on every event would act for strangers: a foreign
// session's turn end would fire the guard's follow-up into that stranger's
// session. Every plugin therefore acts only on sessions whose own location
// directory resolves (git toplevel, matching the plugin's resolveRoot of
// ctx.location.directory) to the plugin's root, preserving the V1
// single-directory gating: active in the primary checkout and a secondmate
// home, silent for foreign sessions and crewmate/scout worktrees where the
// owner scripts are themselves inert. The event plugins (nudge, turn-end
// guard, watch arm) additionally act only on top-level sessions (no
// parentID); the PreToolUse seatbelts instead keep V1's guard-every-bash-
// tool-call semantics and cover child sessions at their own root too
// (ownsSessionAtRoot). The execution events carry no location on the bus
// and one server hosts every session, so the session's directory is read
// through ctx.session.get()
// (verified live, opencode 2.1.4); a session that cannot be read is not ours
// to act on. Lookups are cached per session id and per directory with a
// bounded clear so a long-lived shared server cannot grow them without end.

function runProcess(command, args) {
  return new Promise((resolvePromise) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.on("error", () => resolvePromise({ code: 1, stdout: "" }));
    child.on("close", (code) => resolvePromise({ code: code ?? 1, stdout }));
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

export function createSessionScope(root) {
  const sessionRecords = new Map();
  const resolvedRoots = new Map();

  async function resolveRootCached(directory) {
    if (resolvedRoots.has(directory)) return resolvedRoots.get(directory);
    const resolved = await resolveRoot(directory);
    if (resolvedRoots.size >= 512) resolvedRoots.clear();
    resolvedRoots.set(directory, resolved);
    return resolved;
  }

  async function sessionRecord(ctx, sessionID) {
    if (!sessionID) return { directory: "", parented: false };
    if (sessionRecords.has(sessionID)) return sessionRecords.get(sessionID);
    let directory = "";
    let parented = false;
    try {
      const session = await ctx.session.get({ sessionID });
      directory = session?.location?.directory ?? "";
      parented = Boolean(session?.parentID);
    } catch {
      // A session that cannot be read is not ours to act on.
    }
    if (sessionRecords.size >= 512) sessionRecords.clear();
    sessionRecords.set(sessionID, { directory, parented });
    return sessionRecords.get(sessionID);
  }

  return {
    // Whether a directory (e.g. session.created's data.location.directory)
    // belongs to this plugin's location root.
    async ownsDirectory(directory) {
      if (!directory || !root) return false;
      return (await resolveRootCached(directory)) === root;
    },
    // Whether a live session on this server belongs to this plugin's
    // location root as a top-level session; child sessions (subagents)
    // never do. The event plugins (nudge, turn-end guard, watch arm) use
    // this scope.
    async ownsSession(ctx, sessionID) {
      const { directory, parented } = await sessionRecord(ctx, sessionID);
      if (parented || !directory || !root) return false;
      return (await resolveRootCached(directory)) === root;
    },
    // Whether a live session's own directory resolves to this plugin's
    // location root regardless of parentID; the PreToolUse seatbelts use
    // this scope because V1 guarded every bash tool call in the checkout,
    // subagent child sessions included.
    async ownsSessionAtRoot(ctx, sessionID) {
      const { directory } = await sessionRecord(ctx, sessionID);
      if (!directory || !root) return false;
      return (await resolveRootCached(directory)) === root;
    },
  };
}

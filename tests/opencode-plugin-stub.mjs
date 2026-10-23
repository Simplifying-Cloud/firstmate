import { pathToFileURL } from "node:url";

// Shared in-process driver for the OpenCode 2.x plugins under
// .opencode/plugins/ (V2 plugin API): loads a plugin's default export, runs
// setup() against a minimal stub of the OpenCode 2.x plugin context, and
// feeds bus events to the plugin's event subscription. The subscription stub
// hands the plugin one event at a time; emit() resolves only after the
// plugin's loop asks for the event AFTER the emitted one, so an awaited
// emit covers everything one awaited hooks.event() call covered under the
// V1 entrypoint (every ported plugin awaits its whole per-event handler
// inside the loop, and wraps it so one failure never ends the stream).
// Tool-hook plugins get their registrations captured in toolHooks for
// direct calls. The V2 shapes here - events as { type, data }, prompts as
// ctx.session.prompt({ sessionID, text }) - are the ones verified live
// against opencode 2.1.4 (see .agents/skills/harness-adapters/references/
// harness/opencode.md "OpenCode 2.x").

export async function loadOpencodePlugin(pluginPath, options = {}) {
  let {
    directory,
    sessionDirectory,
    sessionParentID,
    prompt,
  } = options;
  const mod = await import(pathToFileURL(pluginPath).href);
  if (!mod.default?.id || typeof mod.default.setup !== "function") {
    throw new Error(`${pluginPath} has no V2 default plugin definition`);
  }
  // sessionDirectory may be a string or a (sessionID) => string function so a
  // test can place individual sessions at foreign directories.
  const directoryFor = (sessionID) =>
    (typeof sessionDirectory === "function" ? sessionDirectory(sessionID) : sessionDirectory) ?? directory;
  const prompts = [];
  const toolHooks = {};
  const queue = [];
  let waiting = null;
  let drainedResolvers = [];
  const ctx = {
    location: { directory },
    session: {
      prompt: prompt ?? (async ({ text }) => {
        prompts.push(text);
      }),
      get: async ({ sessionID }) => ({
        id: sessionID,
        parentID: typeof sessionParentID === "function" ? sessionParentID(sessionID) : sessionParentID,
        location: { directory: directoryFor(sessionID) },
      }),
    },
    tool: {
      hook: async (name, callback) => {
        (toolHooks[name] ??= []).push(callback);
      },
    },
    event: {
      subscribe: () => ({
        [Symbol.asyncIterator]: () => ({
          next: () => {
            if (queue.length > 0) {
              return Promise.resolve({ value: queue.shift(), done: false });
            }
            const release = drainedResolvers;
            drainedResolvers = [];
            for (const resolve of release) resolve();
            return new Promise((resolve) => {
              waiting = resolve;
            });
          },
        }),
      }),
    },
  };
  const cleanup = await mod.default.setup(ctx);
  const emit = (event) => {
    const done = new Promise((resolve) => {
      drainedResolvers.push(resolve);
    });
    queue.push(event);
    if (waiting) {
      const release = waiting;
      waiting = null;
      release({ value: queue.shift(), done: false });
    }
    return done;
  };
  return { ctx, cleanup, emit, prompts, toolHooks };
}

export function turnEndEvent(sessionID, type = "session.execution.succeeded") {
  return { type, data: { sessionID } };
}

export function sessionCreatedEvent(sessionID, directory, extra = {}) {
  return {
    type: "session.created",
    data: { sessionID, location: { directory }, ...extra },
  };
}

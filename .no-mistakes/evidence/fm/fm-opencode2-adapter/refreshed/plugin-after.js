// Firstmate semantic busy-state events + turn-end notification; written by
// fm-spawn under the contract owned by bin/fm-busy-lib.sh.
// OpenCode 2.x plugin form: the module's DEFAULT export must be { id, setup }
// and setup must return - a setup that never returns blocks the whole location,
// after which every API call fails with "Location plugins did not finish
// activating" after five seconds (verified live, opencode 2.0.32). Events
// arrive as { type, data } through ctx.event.subscribe(); they are consumed in
// a detached loop that the returned cleanup aborts. Semantic state comes from
// the session.execution events: started is active, and succeeded, failed, and
// interrupted (including a manual double-Escape cancel) all close a turn, so an
// abnormal end can never leave a stale busy record. Scoping latches the first
// session that starts an execution (the
// worker's main session - a subagent child session can only start while the
// main session is already busy) and ignores other sessions' events until the
// latched session settles, so a child's completion can never clear the
// worker's busy state. The latched settle touch stays the watcher's wake
// NOTIFICATION, never current-state truth.
import { execFile } from "node:child_process";
const busyEvent = (state, event) =>
  new Promise((resolve) => {
    execFile("/home/dscott/.no-mistakes/worktrees/a1211da81307/01M54WH36WR8NGK9EHZG3DDNGF/bin/fm-busy-event.sh", [
      "apply", "/home/dscott/.no-mistakes/worktrees/a1211da81307/01M54WH36WR8NGK9EHZG3DDNGF/.oc2-refreshed/lab/state", "oc2-recheck", state,
      "--gen", "g1792255059.1971309.19407", "--source", "opencode-plugin", "--event", event,
    ], () => resolve());
  });
const touchTurnend = () =>
  new Promise((resolve) => {
    execFile("touch", ["/home/dscott/.no-mistakes/worktrees/a1211da81307/01M54WH36WR8NGK9EHZG3DDNGF/.oc2-refreshed/lab/state/oc2-recheck.turn-ended"], () => resolve());
  });
export default {
  id: "fm-busy-state",
  setup: async (ctx) => {
    let activeSession = null;
    const stop = new AbortController();
    (async () => {
      try {
        for await (const event of ctx.event.subscribe({ signal: stop.signal })) {
          const data = event.data || {};
          const sessionID = data.sessionID;
          if (event.type === "session.execution.started") {
            if (activeSession === null) activeSession = sessionID;
            if (sessionID === activeSession) await busyEvent("busy", "execution-started");
          } else if (event.type === "session.execution.succeeded" || event.type === "session.execution.failed" || event.type === "session.execution.interrupted") {
            if (sessionID === activeSession) {
              activeSession = null;
              await busyEvent("idle", "execution-" + event.type.split(".").pop());
              await touchTurnend();
            }
          }
        }
      } catch {
        /* the event stream closes at shutdown */
      }
    })();
    return () => stop.abort();
  },
};

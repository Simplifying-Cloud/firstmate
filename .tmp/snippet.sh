for plugin in fm-primary-cd-check.js fm-primary-pretool-check.js; do
  out=$(PLUGIN="$ROOT/.opencode/plugins/$plugin" STUB="$STUB" WORKTREE="$REPO" FOREIGN="$FOREIGN" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const { loadOpencodePlugin } = await import(pathToFileURL(process.env.STUB).href);

const driver = await loadOpencodePlugin(process.env.PLUGIN, {
  directory: process.env.WORKTREE,
  sessionDirectory: (sessionID) => (sessionID === "session-foreign" ? process.env.FOREIGN : process.env.WORKTREE),
  sessionParentID: (sessionID) => (sessionID === "session-child" ? "session-parent" : undefined),
});
const hook = driver.toolHooks["execute.before"]?.[0];
if (typeof hook !== "function") throw new Error("plugin registered no execute.before hook");

const denied = async (event) => {
  try {
    await hook(event);
    return null;
  } catch (error) {
    return error.message;
  }
};

// The 2.x shell tool (named "shell" on 2.1.4) is guarded on its own session.
const own = { tool: "shell", sessionID: "session-own", input: { command: "cd somewhere && echo deny-me" } };
const reason = await denied(own);
if (!reason || !reason.includes("fixture denial")) throw new Error(`expected the fixture denial, got ${reason}`);

// A benign command passes through untouched.
if (await denied({ ...own, input: { command: "echo fine" } }) !== null) throw new Error("benign command was denied");

// The retired 1.x bash tool name no longer names the shell tool.
if (await denied({ tool: "bash", sessionID: "session-own", input: { command: "echo deny-me" } }) !== null) {
  throw new Error("the 1.x bash tool name must be ignored on 2.x");
}

// A foreign session on the same server is never this location's to guard,
// while a subagent child session at this root stays guarded: V1 ran the
// seatbelt on every bash tool call in the checkout regardless of session.
if (await denied({ ...own, sessionID: "session-foreign" }) !== null) throw new Error("foreign session was guarded");
const childReason = await denied({ ...own, sessionID: "session-child" });
if (!childReason || !childReason.includes("fixture denial")) {
  throw new Error(`expected the child session at this root to be guarded, got ${childReason}`);
}
EOF
  ) || fail "$plugin portable behavior: $out"

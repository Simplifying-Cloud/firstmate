#!/usr/bin/env bash
# Portable coverage for the OpenCode 2.x primary tool-hook plugins
# (.opencode/plugins/fm-primary-cd-check.js and fm-primary-pretool-check.js):
# V2 default-export shape, the shell-tool deny contract (exit 2 plus stderr
# surfaced by throwing from ctx.tool.hook("execute.before")), and the
# session-at-own-root scope that keeps a shared 2.x server's foreign sessions
# unguarded while subagent child sessions at the same root stay guarded -
# V1 ran the seatbelts on every bash tool call in the checkout regardless of
# session. The deny-by-throw mechanism itself is
# verified live against opencode 2.1.4 (see
# .agents/skills/harness-adapters/references/harness/opencode.md "OpenCode 2.x");
# this suite pins the plugin logic with real fixture scripts and no harness.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STUB="$ROOT/tests/opencode-plugin-stub.mjs"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

expect_code 0 0 "suite arithmetics"

TMP_ROOT=$(fm_test_tmproot opencode-plugins)
mkdir -p "$TMP_ROOT"
REPO="$TMP_ROOT/repo"
FOREIGN="$TMP_ROOT/foreign"
mkdir -p "$REPO/bin" "$FOREIGN"
git init -q "$REPO"
: > "$REPO/AGENTS.md"
cat > "$REPO/bin/fm-cd-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
case "$2" in
  *deny-me*) printf 'cd-guard fixture denial\n' >&2; exit 2 ;;
esac
exit 0
SH
cat > "$REPO/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
case "$2" in
  *deny-me*) printf 'arm-guard fixture denial\n' >&2; exit 2 ;;
esac
exit 0
SH
chmod +x "$REPO/bin/fm-cd-pretool-check.sh" "$REPO/bin/fm-arm-pretool-check.sh"

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
  [ -z "$out" ] || fail "$plugin portable behavior printed output: $out"
  pass "$plugin: V2 hook denies sessions at this root, child sessions included, with the script's reason"
done

# The plugins load beneath the explicit ESM package boundary with their lib.
out=$(cd "$ROOT" && node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
for (const name of ["fm-primary-cd-check.js", "fm-primary-pretool-check.js"]) {
  const mod = await import(pathToFileURL(`${process.cwd()}/.opencode/plugins/${name}`).href);
  if (!mod.default?.id || typeof mod.default.setup !== "function") throw new Error(`${name} has no V2 default definition`);
}
EOF
) || fail "V2 default exports: $out"
[ -z "$out" ] || fail "V2 default exports printed output: $out"
pass "both tool-hook plugins default-export V2 definitions"

printf 'ok - opencode primary tool-hook plugins: deny, passthrough, and session scope\n'

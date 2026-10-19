#!/usr/bin/env bash
# Token-free live guard for the OpenCode 2.x crewmate adapter's config
# isolation: with the real 2.x binary and the per-task config dir the real
# fm-spawn writes, OpenCode commands in the worker's environment answer from a
# private server that sees neither the operator's global config nor its MCP
# servers, while the launch's own config and MCP server still load. A stand-in
# operator under XDG_CONFIG_HOME, XDG_DATA_HOME, XDG_STATE_HOME, and
# XDG_CACHE_HOME keeps the guard off the real operator's config, credential
# store, and shared background server, and no model is called. Each isolated
# verdict is paired with the same probe run without the per-task dir, which
# must see the stand-in operator's config, so a probe that sees nothing cannot
# pass.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_OPENCODE2_ISOLATION_LIVE opencode2 python3

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-opencode2-lib.sh
. "$ROOT/bin/fm-opencode2-lib.sh"

PYTHON_BIN_DIR=$(dirname "$(command -v python3)")
BASE_PATH=${FM_TEST_BASE_PATH:-$PYTHON_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin}
OC2_BIN=$(fm_opencode2_resolve_binary) || fail "no proven OpenCode 2.x executable"
OC2_VERSION=$("$OC2_BIN" --version | head -n1)
case "$OC2_VERSION" in
'opencode v2.'*) ;;
*) fail "resolved binary did not answer a 2.x version: $OC2_VERSION" ;;
esac

TMP_ROOT=$(fm_test_tmproot fm-opencode2-isolation-live)
LAB="$TMP_ROOT/lab"
OPERATOR="$LAB/operator"
MARK="fm-oc2-isolation-$$-$RANDOM"
mkdir -p "$OPERATOR/config/opencode" "$OPERATOR/data" "$OPERATOR/state" "$OPERATOR/cache"

# Every OpenCode process this guard starts carries MARK, so cleanup can stop
# exactly those and nothing that belongs to anyone else.
cleanup() {
  local env_file pid
  exec 9>&- 2>/dev/null || true
  for env_file in /proc/[0-9]*/environ; do
    pid=${env_file#/proc/}
    pid=${pid%/environ}
    tr '\0' '\n' <"$env_file" 2>/dev/null | grep -Fqx "FM_OC2_ISOLATION_MARK=$MARK" || continue
    kill -TERM "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup EXIT

# The stand-in operator's own global config carries an MCP server that must
# never reach the worker.
cat >"$OPERATOR/config/opencode/opencode.json" <<'JSON'
{"$schema":"https://opencode.ai/config.json","mcp":{"servers":{"fm-operator-sentinel":{"type":"local","command":["true"]}}}}
JSON
LAUNCH_CONTENT='{"permission":{"*":"allow"},"mcp":{"servers":{"fm-launch-sentinel":{"type":"local","command":["true"]}}}}'

# --- the real per-task config dir from the real fm-spawn ----------------------
home="$LAB/home"
proj="$LAB/project"
wt="$LAB/wt"
fakebin=$(fm_fakebin "$LAB/fake")
fm_test_fake_tmux_spawn "$fakebin"
cat >"$LAB/debug-config.json" <<'JSON'
[{"type":"document","info":{"providers":{"mockz":{"settings":{"baseURL":"https://ai.simplifying.cloud/models/mock/v1","apiKey":"***"}}}}}]
JSON
cat >"$fakebin/opencode2" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
--version) printf '%s\n' 'opencode v2.0.32-fixture' ;;
debug) cat "${FM_FAKE_OC2_DEBUG_CONFIG:?fixture path missing}" ;;
*) exit 0 ;;
esac
SH
chmod +x "$fakebin/opencode2"
id=oc2-live-isolation
mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$LAB/user-home"
cat >"$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Prepare the OpenCode 2.x isolated config dir.

## Firstmate spec
Fixture brief for live isolation verification.
EOF
fm_git_worktree "$proj" "$wt" wt-oc2-isolation
touch "$home/state/.last-watcher-beat"
HOME="$LAB/user-home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
  FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
  FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
  FM_FAKE_OC2_DEBUG_CONFIG="$LAB/debug-config.json" \
  PATH="$fakebin:$BASE_PATH" \
  "$ROOT/bin/fm-spawn.sh" "$id" "$proj" --mode local-only --yolo off --harness opencode2 \
  >"$LAB/spawn.log" 2>&1 \
  || fail "fixture spawn failed: $(cat "$LAB/spawn.log")"
cfgdir="$home/state/$id.opencode-config"
[ -d "$cfgdir" ] || fail "fixture spawn wrote no isolated config dir"

# oc2 [VAR=value...] <args...>: run the real 2.x binary from the worktree as
# the stand-in operator, offline. The worker posture adds OPENCODE_CONFIG_DIR.
oc2() {
  (cd "$wt" && env FM_OC2_ISOLATION_MARK="$MARK" \
    XDG_CONFIG_HOME="$OPERATOR/config" XDG_DATA_HOME="$OPERATOR/data" \
    XDG_STATE_HOME="$OPERATOR/state" XDG_CACHE_HOME="$OPERATOR/cache" \
    OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_MODELS_FETCH=1 \
    OPENCODE_CONFIG_CONTENT="$LAUNCH_CONTENT" "$@")
}

# sources <json-file>: one line per config source, "<type> <path-or-pathless>
# <mcp server names>", from a config.get or debug config document list.
sources() {
  python3 - "$1" <<'PY'
import json, sys
for doc in json.load(open(sys.argv[1])):
    names = ",".join(sorted(((doc.get("info") or {}).get("mcp") or {}).get("servers") or {}))
    print(doc.get("type"), doc.get("path") or "pathless", names or "-")
PY
}

# mcp_names [VAR=value...]: start a private server exactly as --standalone
# does, poll its MCP list until the launch's own server has registered (a
# fresh server answers before MCP servers register, so an immediate list is
# vacuous), print the registered names, and stop the server.
mcp_names() {
  local pw url out fifo spid i names=
  pw=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
  out="$LAB/serve.$RANDOM.out"
  fifo="$LAB/serve.$RANDOM.fifo"
  mkfifo "$fifo"
  oc2 "$@" OPENCODE_PASSWORD="$pw" "$OC2_BIN" serve --stdio --port 0 <"$fifo" >"$out" 2>/dev/null &
  spid=$!
  exec 9>"$fifo"
  for ((i = 0; i < 120; i++)); do
    url=$(python3 -c 'import json, sys
for line in open(sys.argv[1]):
    if line.startswith("{"):
        print(json.loads(line)["url"]); break' "$out" 2>/dev/null)
    [ -n "$url" ] && break
    sleep 0.5
  done
  case "$url" in
  http://127.0.0.1:*) ;;
  *) fail "opencode2 $OC2_VERSION private server reported no localhost url: $(cat "$out")" ;;
  esac
  for ((i = 0; i < 60; i++)); do
    names=$(oc2 "$@" OPENCODE_PASSWORD="$pw" "$OC2_BIN" api --server "$url" mcp.list 2>/dev/null \
      | python3 -c 'import json, sys
print(",".join(sorted(m["name"] for m in json.load(sys.stdin)["data"])))' 2>/dev/null)
    case ",$names," in *,fm-launch-sentinel,*) break ;; esac
    sleep 0.5
  done
  # Closing stdin is the private server's own shutdown signal.
  exec 9>&-
  for ((i = 0; i < 40; i++)); do
    kill -0 "$spid" 2>/dev/null || break
    sleep 0.25
  done
  kill -TERM "$spid" 2>/dev/null || true
  wait "$spid" 2>/dev/null
  rm -f "$fifo" "$out"
  printf '%s\n' "$names"
}

# --- the vendor reads the per-task service setting ----------------------------
got=$(oc2 OPENCODE_CONFIG_DIR="$cfgdir" "$OC2_BIN" service get disabled) \
  || fail "opencode2 $OC2_VERSION could not read the service setting"
[ "$got" = true ] \
  || fail "opencode2 $OC2_VERSION no longer reads the per-task service.json as disabled (got '$got'); OpenCode commands in the worker would attach to the operator's shared background server"
got=$(oc2 "$OC2_BIN" service get disabled) || fail "opencode2 $OC2_VERSION could not read the service setting"
[ "$got" = false ] || fail "control: the stand-in operator's own service setting must not be disabled, got '$got'"

# --- debug config answers from a private server without the operator config ---
oc2 "$OC2_BIN" api --standalone config.get >"$LAB/control.json" 2>"$LAB/control.err" \
  || fail "control config.get failed: $(cat "$LAB/control.err")"
control=$(sources "$LAB/control.json") || fail "control config.get was not a source list"
grep -Fq "$OPERATOR/config/opencode/opencode.json fm-operator-sentinel" <<<"$control" \
  || fail "control: without the per-task dir the stand-in operator config must load, got: $control"
oc2 OPENCODE_CONFIG_DIR="$cfgdir" "$OC2_BIN" debug config >"$LAB/isolated.json" 2>"$LAB/isolated.err" \
  || fail "opencode2 $OC2_VERSION debug config failed in the worker environment: $(cat "$LAB/isolated.err")"
isolated=$(sources "$LAB/isolated.json") || fail "debug config was not a source list"
if grep -Fq "$OPERATOR/config" <<<"$isolated"; then
  fail "opencode2 $OC2_VERSION debug config in the worker environment lists the operator's global config: $isolated"
fi
grep -Fqx "directory $(cd -P "$cfgdir" && pwd) -" <<<"$isolated" \
  || grep -Fqx "directory $cfgdir -" <<<"$isolated" \
  || fail "debug config in the worker environment must load the per-task config dir, got: $isolated"
grep -Fqx "document pathless fm-launch-sentinel" <<<"$isolated" \
  || fail "debug config must answer with the launch's own config, which only a private server has: $isolated"

# --- the worker's MCP servers come only from the launch -----------------------
control=$(mcp_names)
[ "$control" = "fm-launch-sentinel,fm-operator-sentinel" ] \
  || fail "control: without the per-task dir both MCP servers must register, got '$control'"
isolated=$(mcp_names OPENCODE_CONFIG_DIR="$cfgdir")
[ "$isolated" = fm-launch-sentinel ] \
  || fail "opencode2 $OC2_VERSION worker environment must register only the launch's MCP server, got '$isolated'"

# A shared background server registers itself in the state dir; none may exist.
[ ! -e "$OPERATOR/state/opencode/service.json" ] \
  || fail "opencode2 $OC2_VERSION started a shared background server from the worker environment"

printf 'ok - opencode2 %s live: the per-task config dir disables the shared server, so debug config answers privately without the operator global config, and only the launch MCP server registers\n' "$OC2_VERSION"

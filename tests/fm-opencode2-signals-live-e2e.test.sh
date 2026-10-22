#!/usr/bin/env bash
# Token-free live guard for the OpenCode 2.x crewmate adapter: launches the
# real 2.x TUI standalone against a localhost mock provider and proves the
# harness-dependent signals a stub cannot - the launch reaches the TUI, the
# launch prompt auto-submits a turn, the fm-spawn-generated busy-state plugin
# records busy and idle from the real event stream and touches the turn-end
# notification, and /exit leaves the pane. The mock answers one short turn and
# spends no model tokens; the platform-traffic tier stays opt-in because it
# spends real platform quota.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_OPENCODE2_SIGNALS_LIVE opencode2 tmux python3 node curl

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-opencode2-lib.sh
. "$ROOT/bin/fm-opencode2-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"

NODE_BIN=$(command -v node) || fail "test needs node"
NODE_BIN_DIR=$(dirname "$NODE_BIN")
BASE_PATH=${FM_TEST_BASE_PATH:-$NODE_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin}
OC2_BIN=$(fm_opencode2_resolve_binary) || fail "no proven OpenCode 2.x executable"
OC2_VERSION=$("$OC2_BIN" --version | head -n1)
case "$OC2_VERSION" in
'opencode v2.'*) ;;
*) fail "resolved binary did not answer a 2.x version: $OC2_VERSION" ;;
esac

TMP_ROOT=$(fm_test_tmproot fm-opencode2-signals-live)
SOCKET="fm-oc2-live-$$"
SESSION=oc2-live
LAB="$TMP_ROOT/lab"
mkdir -p "$LAB"

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  [ -z "${MOCK_PID:-}" ] || kill -TERM "$MOCK_PID" 2>/dev/null || true
  # The shared-server section's stand-in background server belongs to this test
  # (isolated HOME, XDG dirs, and port). Stop it through its own env, then kill
  # exactly the processes carrying this run's mark, the same /proc discipline
  # the isolation guard uses, so no test process survives a failed step.
  if [ -n "${SG:-}" ]; then
    env HOME="$LAB/user-home" XDG_CONFIG_HOME="$SG/xdg/config" XDG_DATA_HOME="$SG/xdg/data" \
      XDG_STATE_HOME="$SG/xdg/state" XDG_CACHE_HOME="$SG/xdg/cache" \
      "$OC2_BIN" service stop >/dev/null 2>&1 || true
  fi
  if [ -n "${SHARED_MARK:-}" ]; then
    for env_file in /proc/[0-9]*/environ; do
      pid=${env_file#/proc/}
      pid=${pid%/environ}
      tr '\0' '\n' <"$env_file" 2>/dev/null | grep -Fqx "FM_OC2_SHARED_MARK=$SHARED_MARK" || continue
      kill -TERM "$pid" 2>/dev/null || true
    done
  fi
  fm_test_cleanup
}
trap cleanup EXIT

# --- localhost Anthropic-compatible mock: one short streamed turn ------------
MOCK_PORT=$((20000 + RANDOM % 20000))
python3 - "$MOCK_PORT" >"$LAB/mock.log" 2>&1 <<'PYEOF' &
import json, socketserver, sys, time

port = int(sys.argv[1])
sse = b"".join(
    b"event: " + ev.encode() + b"\ndata: " + json.dumps(p).encode() + b"\n\n"
    for ev, p in [
        ("message_start", {"type": "message_start", "message": {"id": "msg_mock", "type": "message", "role": "assistant", "content": [], "model": "mock-1", "stop_reason": None, "usage": {"input_tokens": 5, "output_tokens": 1}}}),
        ("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}),
        ("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "OK"}}),
        ("content_block_stop", {"type": "content_block_stop", "index": 0}),
        ("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn"}, "usage": {"output_tokens": 1}}),
        ("message_stop", {"type": "message_stop"}),
        ("ping", {"type": "ping"}),
    ]
)

class H(socketserver.BaseRequestHandler):
    def handle(self):
        data = self.request.recv(65536)
        # Hold the turn open long enough for the busy poll to observe it.
        time.sleep(6)
        self.request.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n" + sse)

class Srv(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

Srv(("127.0.0.1", port), H).serve_forever()
PYEOF
MOCK_PID=$!
sleep 1
# The mock holds every response open for six seconds so busy is observable,
# so the readiness probe must outlast that hold.
curl -s -m 15 -X POST "http://127.0.0.1:$MOCK_PORT/v1/messages" -d '{}' -o /dev/null \
  || fail "the localhost mock provider did not come up"

# --- real generated plugin + armed busy record through the real fm-spawn ----
home="$LAB/home"
proj="$LAB/project"
wt="$LAB/wt"
fakebin=$(fm_fakebin "$LAB/fake")
fm_test_fake_tmux_spawn "$fakebin"
cat >"$LAB/debug-config.json" <<'JSON'
[
  {
    "type": "document",
    "info": {
      "providers": {
        "mockz": {
          "name": "Mock Z via organization gateway",
          "settings": { "baseURL": "https://ai.simplifying.cloud/models/mock/v1", "apiKey": "***" }
        }
      }
    }
  }
]
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
id=oc2-live-signals
mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$LAB/user-home"
cat >"$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Arm the OpenCode 2.x busy wiring.

## Firstmate spec
Fixture brief for live signal verification.
EOF
fm_git_worktree "$proj" "$wt" wt-oc2-live
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
plugin="$wt/.opencode/plugins/fm-busy-state.js"
[ -f "$plugin" ] || fail "fixture spawn wrote no busy-state plugin"
gen=$(cat "$home/state/$id.busy-gen")
turnend="$home/state/$id.turn-ended"
rm -f "$turnend"

# --- launch the real 2.x TUI in tmux with the worker posture ----------------
cfgdir="$home/state/$id.opencode-config"
cfg='{"permission":{"*":"allow"},"model":"mockz/mock-1","providers":{"mockz":{"name":"Mock Z","package":"@opencode/ai/providers/anthropic-compatible","settings":{"baseURL":"http://127.0.0.1:'"$MOCK_PORT"'","apiKey":"mock"},"models":{"mock-1":{"name":"Mock 1","capabilities":{"tools":true},"limit":{"context":100000,"output":4096}}}}},"policies":[{"action":"provider.use","resource":"*","effect":"deny"},{"action":"provider.use","resource":"mockz","effect":"allow"}]}'
tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 100 -y 30 -c "$wt" \
  "env OPENCODE_CONFIG_DIR='$cfgdir' OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_CONFIG_CONTENT='$cfg' '$OC2_BIN' --standalone --auto --prompt 'Reply with exactly OK.'; rc=\$?; printf 'OC2_EXIT=%s\\n' \"\$rc\"; sleep 300"

capture() { tmux -L "$SOCKET" capture-pane -p -t "$SESSION" 2>/dev/null || true; }

wait_for() {  # <marker> <attempts>
  local i=0
  while [ "$i" -lt "${2:-120}" ]; do
    grep -Fq "$1" <(capture) && return 0
    sleep 0.5
    i=$((i + 1))
  done
  capture >&2
  return 1
}

wait_busy_state() {  # <wanted-state> <attempts>
  local i=0 current
  while [ "$i" -lt "${2:-120}" ]; do
    current=$(fm_busy_classify tmux "fake:w" opencode2 "$id" "$home/state")
    [ "$current" = "$1 opencode-plugin" ] && return 0
    sleep 0.5
    i=$((i + 1))
  done
  fm_busy_classify tmux "fake:w" opencode2 "$id" "$home/state" >&2
  cat "$home/state/$id.busy-state" >&2 2>/dev/null || true
  return 1
}

wait_for "Reply with exactly OK." 120 || fail "the 2.x TUI never rendered the launch prompt"
wait_busy_state busy 120 || fail "the real event stream never recorded busy"
wait_busy_state idle 120 || fail "the real event stream never settled idle"
# The notification is a separate asynchronous write after the idle record.
# Observing idle does not prove that the notification has finished yet.
for ((attempt = 0; attempt < 120; attempt++)); do
  [ -f "$turnend" ] && break
  sleep 0.5
done
[ -f "$turnend" ] || fail "the settle never touched the turn-end notification"
grep -Fq "event=execution-succeeded" <(cat "$home/state/$id.busy-state") \
  || fail "the idle event was not an execution settle: $(cat "$home/state/$id.busy-state")"

composer=$(TMUX="$(tmux -L "$SOCKET" display-message -p '#{socket_path},#{pid},0')" \
  fm_tmux_composer_state "$SESSION")
[ "$composer" = empty ] || fail "the real --auto composer must allow lifecycle exit, got '$composer'"

# The same proven-idle pane read the way every cursorless backend reads it
# (herdr, zellij, cmux, orca: no cursor anchor, so the bottom-most shape
# wins). OpenCode 2.x draws its own status row directly below the composer
# floor, and before the shared classifier learned it as furniture that row
# made every idle 2.x pane read `unknown` - the live defect that refused
# fm-control exit on every cursorless backend (2026-10-17).
oc2_caps=$(printf 'styled=1\ncursor=0\nidentity=1\nrows=0')
oc2_pane=$(tmux -L "$SOCKET" capture-pane -e -p -t "$SESSION")
oc2_cursorless=$(fm_composer_classify_screen "$oc2_caps" "$oc2_pane")
[ "$oc2_cursorless" = empty ] \
  || fail "the real --auto composer must also read empty cursorless (the herdr posture), got '$oc2_cursorless'"

tmux -L "$SOCKET" send-keys -t "$SESSION" -l "/exit"
tmux -L "$SOCKET" send-keys -t "$SESSION" Enter
wait_for "OC2_EXIT=0" 60 || fail "/exit did not leave the real 2.x TUI"

printf 'ok - opencode2 %s live: standalone TUI turn drove the generated plugin busy->idle with the notification touch, and /exit left the pane\n' "$OC2_VERSION"

# --- two workers on one shared background server ------------------------------
# The 2026-10-19 cross-task defect: session.execution events carry no location
# on the bus, and every location plugin loaded in the per-user background
# server receives every session's execution events, so one worker's settle
# latched ANOTHER task's plugin from a stranger's session and touched that
# task's turn-ended notification mid-turn - for every loaded opencode2 task at
# once. The entry path is a bare `opencode` command that overrides the launch's
# per-task config dir (a worker's own tool call), loading the worktree's plugin
# into the shared server, which outlives the task. Two fixture workers attach
# to one stand-in per-user background server; the victim task's records must
# survive the foreign settle byte-for-byte while the same plugin still serves
# its own worktree's next session in the same server.
# The managed service port is machine-global (a real instance can hold the
# default 49374 at any moment, including another lane's), so the stand-in gets
# its own port and never depends on or disturbs it.
SG="$LAB/shared"
SHARED_PORT=$((20000 + RANDOM % 20000))
# Every process this section starts carries the mark, so cleanup can stop
# exactly those and nothing that belongs to anyone else (the sibling isolation
# guard owns the /proc pattern).
SHARED_MARK="fm-oc2-shared-$$-$RANDOM"
mkdir -p "$SG/xdg/config" "$SG/xdg/data" "$SG/xdg/state" "$SG/xdg/cache" "$SG/cfg"
env HOME="$LAB/user-home" FM_OC2_SHARED_MARK="$SHARED_MARK" \
  XDG_CONFIG_HOME="$SG/xdg/config" XDG_DATA_HOME="$SG/xdg/data" \
  XDG_STATE_HOME="$SG/xdg/state" XDG_CACHE_HOME="$SG/xdg/cache" \
  OPENCODE_CONFIG_DIR="$SG/cfg" OPENCODE_DISABLE_AUTOUPDATE=1 \
  "$OC2_BIN" service set port "$SHARED_PORT" >/dev/null 2>&1 \
  || fail "could not give the stand-in background server its own port"

idA=oc2-shared-a
idB=oc2-shared-b
mkdir -p "$home/data/$idA" "$home/data/$idB"
for id in "$idA" "$idB"; do
  cat >"$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Arm the OpenCode 2.x busy wiring.

## Firstmate spec
Fixture brief for shared-server confinement verification.
EOF
done
fm_git_worktree "$proj" "$LAB/wtA" wt-oc2-shared-a
fm_git_worktree "$proj" "$LAB/wtB" wt-oc2-shared-b
for pair in "$idA:$LAB/wtA" "$idB:$LAB/wtB"; do
  id=${pair%%:*}
  wtshared=${pair#*:}
  HOME="$LAB/user-home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wtshared" TMUX="fake,1,0" \
    FM_FAKE_OC2_DEBUG_CONFIG="$LAB/debug-config.json" \
    PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" --mode local-only --yolo off --harness opencode2 \
    >>"$LAB/shared-spawn.log" 2>&1 \
    || fail "fixture spawn failed for $id: $(cat "$LAB/shared-spawn.log")"
done

oc2_shared_run() {  # <worktree>
  (
    cd "$1" &&
      env HOME="$LAB/user-home" FM_OC2_SHARED_MARK="$SHARED_MARK" \
        XDG_CONFIG_HOME="$SG/xdg/config" XDG_DATA_HOME="$SG/xdg/data" \
        XDG_STATE_HOME="$SG/xdg/state" XDG_CACHE_HOME="$SG/xdg/cache" \
        OPENCODE_CONFIG_DIR="$SG/cfg" OPENCODE_DISABLE_AUTOUPDATE=1 \
        OPENCODE_CONFIG_CONTENT="$cfg" \
        timeout 120 "$OC2_BIN" run 'Reply with exactly OK.' </dev/null \
        >"$LAB/shared-run-$(basename "$1").log" 2>&1
  )
}

wait_shared_idle() {  # <id>
  local i=0 current
  while [ "$i" -lt 120 ]; do
    current=$(fm_busy_classify tmux "fake:w" opencode2 "$1" "$home/state")
    [ "$current" = "idle opencode-plugin" ] && return 0
    sleep 0.5
    i=$((i + 1))
  done
  fm_busy_classify tmux "fake:w" opencode2 "$1" "$home/state" >&2
  cat "$home/state/$1.busy-state" >&2 2>/dev/null || true
  return 1
}

# Worker A's own turn settles on the shared server first.
oc2_shared_run "$LAB/wtA" || fail "shared-server run A failed: $(cat "$LAB/shared-run-wtA.log")"
wait_shared_idle "$idA" || fail "worker A never settled on the shared server"
[ -f "$home/state/$idA.turn-ended" ] || fail "worker A's own settle must touch its notification"
a_rec=$(cat "$home/state/$idA.busy-state")
: >"$LAB/a-marker"

# Worker B's full cycle in a foreign worktree must leave A's records untouched.
oc2_shared_run "$LAB/wtB" || fail "shared-server run B failed: $(cat "$LAB/shared-run-wtB.log")"
wait_shared_idle "$idB" || fail "worker B never settled on the shared server"
[ -f "$home/state/$idB.turn-ended" ] || fail "worker B's own settle must touch its notification"
[ "$(cat "$home/state/$idA.busy-state")" = "$a_rec" ] \
  || fail "a foreign worktree's settle rewrote worker A's busy record: $(cat "$home/state/$idA.busy-state")"
[ "$home/state/$idA.turn-ended" -nt "$LAB/a-marker" ] \
  && fail "a foreign worktree's settle re-touched worker A's turn-ended notification"

# Non-vacuity: A's plugin must still be alive in that server and reacting to
# its OWN directory, or the untouched records above would prove nothing. A
# second session in A's worktree must advance A's busy record through a full
# cycle - wait for the settle, not the intermediate busy write, because only
# the accepted settle carries the notification touch.
oc2_shared_run "$LAB/wtA" || fail "shared-server run A2 failed: $(cat "$LAB/shared-run-wtA.log")"
i=0
while [ "$i" -lt 120 ]; do
  cur=$(cat "$home/state/$idA.busy-state" 2>/dev/null)
  if [ "$cur" != "$a_rec" ] \
    && [ "$(fm_busy_classify tmux "fake:w" opencode2 "$idA" "$home/state")" = "idle opencode-plugin" ]; then
    break
  fi
  sleep 0.5
  i=$((i + 1))
done
[ "$(cat "$home/state/$idA.busy-state")" != "$a_rec" ] \
  || fail "worker A's own second session must advance its busy record (plugin looked dead in the shared server): $(cat "$home/state/$idA.busy-state")"
[ "$(cat "$home/state/$idA.busy-state")" != "$a_rec" ] \
  && [ "$(fm_busy_classify tmux "fake:w" opencode2 "$idA" "$home/state")" = "idle opencode-plugin" ] \
  || fail "worker A's own second session never settled: $(cat "$home/state/$idA.busy-state")"
[ "$home/state/$idA.turn-ended" -nt "$LAB/a-marker" ] \
  || fail "worker A's own second session must re-touch its notification"

# The stand-in server must have been really shared by the two worktrees, not
# two private servers: exactly one managed-service process carries this run's
# mark after all three runs.
shared_instances=0
for env_file in /proc/[0-9]*/environ; do
  pid=${env_file#/proc/}
  pid=${pid%/environ}
  tr '\0' '\n' <"$env_file" 2>/dev/null | grep -Fqx "FM_OC2_SHARED_MARK=$SHARED_MARK" || continue
  shared_instances=$((shared_instances + 1))
done
[ "$shared_instances" -eq 1 ] \
  || fail "expected one stand-in service process after the runs, saw $shared_instances (posture not shared)"

# Stop the stand-in here rather than only in the EXIT trap, and prove it went
# down, so a failed later step can never orphan a test service on a live port.
env HOME="$LAB/user-home" XDG_CONFIG_HOME="$SG/xdg/config" XDG_DATA_HOME="$SG/xdg/data" \
  XDG_STATE_HOME="$SG/xdg/state" XDG_CACHE_HOME="$SG/xdg/cache" \
  "$OC2_BIN" service stop >/dev/null 2>&1 \
  || fail "could not stop the stand-in background server"
sleep 1
shared_instances=0
for env_file in /proc/[0-9]*/environ; do
  pid=${env_file#/proc/}
  pid=${pid%/environ}
  tr '\0' '\n' <"$env_file" 2>/dev/null | grep -Fqx "FM_OC2_SHARED_MARK=$SHARED_MARK" || continue
  shared_instances=$((shared_instances + 1))
done
[ "$shared_instances" -eq 0 ] \
  || fail "the stand-in background server did not stop ($shared_instances marked processes remain)"

printf 'ok - opencode2 %s live: two workers on one shared background server kept each task busy record and turn-ended notification confined to its own worktree\n' "$OC2_VERSION"

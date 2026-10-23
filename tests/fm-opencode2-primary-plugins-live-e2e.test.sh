#!/usr/bin/env bash
# Token-free live guard for the OpenCode 2.x PRIMARY plugins: launches the
# real 2.x TUI standalone against a localhost mock provider in a fixture
# checkout that carries the five ported .opencode/plugins/ plugins and the
# tracked bin/ scripts, and proves the harness-dependent transports a stub
# cannot: every plugin loads with no "failed to load plugin" line, the real
# bin/fm-arm-pretool-check.sh deny blocks the shell tool with its reason
# surfaced as the failed tool result, a benign shell command passes, and a
# guard exit 2 delivers exactly one typed follow-up prompt whose own turn
# close is then skipped - the turn-end boundary riding the session.execution
# close set because 2.x never publishes session.idle (verified live, 2.1.4).
# bin/fm-turnend-guard.sh alone is a deterministic stub whose deny is counted:
# its real predicate (supervision-needed versus a healthy watcher) is owned by
# tests/fm-turnend-guard.test.sh, and wiring that predicate live would arm a
# real watcher and silence the very follow-up under test. The mock answers
# short scripted turns and spends no model tokens, so this guard runs by
# default wherever its tools are installed; rerun it after every OpenCode
# upgrade before trusting the plugin evidence in
# .agents/skills/harness-adapters/references/harness/opencode.md.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_OPENCODE2_PLUGINS_LIVE opencode2 tmux python3 curl

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=bin/fm-opencode2-lib.sh
. "$ROOT/bin/fm-opencode2-lib.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

OC2_BIN=$(fm_opencode2_resolve_binary) || fail "no proven OpenCode 2.x executable"
OC2_VERSION=$(OPENCODE_DISABLE_AUTOUPDATE=1 timeout 30 "$OC2_BIN" --version | head -n1)
case "$OC2_VERSION" in
'opencode v2.'*) ;;
*) fail "resolved binary did not answer a 2.x version: $OC2_VERSION" ;;
esac

TMP_ROOT=$(fm_test_tmproot fm-opencode2-plugins-live)
SOCKET="fm-oc2-plugins-$$"
SESSION=oc2-plugins-live
LAB="$TMP_ROOT/lab"
PROJ="$LAB/primary"
STATE="$PROJ/state"
LOG="${OPENCODE_LOG:-$HOME/.local/share/opencode/log/opencode.log}"
mkdir -p "$LAB"

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  [ -z "${MOCK_PID:-}" ] || kill -TERM "$MOCK_PID" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

# --- localhost Anthropic-compatible mock with scripted shell tool use -------
# Every model request body is appended to the request log so assertions key
# off what the real session actually sent (tool results, the guard's
# follow-up text), never off request counts: OpenCode also issues title
# requests against the same mock, and those replay conversation history.
MOCK_PORT=$((20000 + RANDOM % 20000))
MOCK_REQ_LOG="$LAB/mock-requests.log"
: >"$MOCK_REQ_LOG"
python3 - "$MOCK_PORT" "$MOCK_REQ_LOG" >"$LAB/mock.log" 2>&1 <<'PYEOF' &
import json, socketserver, sys, time

port = int(sys.argv[1])
request_log = sys.argv[2]

def sse(events):
    return b"".join(
        b"event: " + ev.encode() + b"\ndata: " + json.dumps(part).encode() + b"\n\n"
        for ev, part in events
    )

def text_turn(text):
    return sse([
        ("message_start", {"type": "message_start", "message": {"id": "msg_mock", "type": "message", "role": "assistant", "content": [], "model": "mock-1", "stop_reason": None, "usage": {"input_tokens": 5, "output_tokens": 1}}}),
        ("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}),
        ("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": text}}),
        ("content_block_stop", {"type": "content_block_stop", "index": 0}),
        ("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn"}, "usage": {"output_tokens": 1}}),
        ("message_stop", {"type": "message_stop"}),
    ])

def shell_tool_turn(command):
    # The tool input must arrive as more than one input_json_delta fragment:
    # a single complete-JSON delta is dropped by the client and the tool call
    # lands with empty arguments (verified live, opencode 2.1.4).
    payload = json.dumps({"command": command})
    half = len(payload) // 2
    return sse([
        ("message_start", {"type": "message_start", "message": {"id": "msg_mock", "type": "message", "role": "assistant", "content": [], "model": "mock-1", "stop_reason": None, "usage": {"input_tokens": 5, "output_tokens": 1}}}),
        ("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "tool_use", "id": "toolu_mock", "name": "shell", "input": {}}}),
        ("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": payload[:half]}}),
        ("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": payload[half:]}}),
        ("content_block_stop", {"type": "content_block_stop", "index": 0}),
        ("message_delta", {"type": "message_delta", "delta": {"stop_reason": "tool_use"}, "usage": {"output_tokens": 1}}),
        ("message_stop", {"type": "message_stop"}),
    ])

class H(socketserver.BaseRequestHandler):
    def handle(self):
        # One buffered read: clients send complete request bodies in one
        # burst, and answering closes the connection for them.
        body = self.request.recv(262144)
        time.sleep(0.2)
        with open(request_log, "ab") as log:
            log.write(b"---REQUEST-START---\n" + body + b"\n---REQUEST-END---\n")
        if b"FMPROBE_BLIND_" in body:
            # The guard follow-up turn: close it so the loop can end cleanly.
            reply = text_turn("FMPROBE_LIVE_FOLLOWED")
        elif b"watcher-background" in body:
            # The denied tool result came back: finish the turn with text.
            reply = text_turn("FMPROBE_LIVE_DONE")
        elif b"FMPROBE_LIVE_OK" in body:
            # The benign tool result came back: now ask for the denied call.
            reply = shell_tool_turn("bin/fm-watch-arm.sh &")
        else:
            # First request: ask for the benign shell command.
            reply = shell_tool_turn("echo FMPROBE_LIVE_OK")
        time.sleep(0.5)
        self.request.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n" + reply)

class Srv(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

Srv(("127.0.0.1", port), H).serve_forever()
PYEOF
MOCK_PID=$!
sleep 1
curl -s -m 10 -X POST "http://127.0.0.1:$MOCK_PORT/v1/messages" -d 'probe' -o /dev/null \
  || fail "the localhost mock provider did not come up"
: >"$MOCK_REQ_LOG"

# --- fixture primary: the ported plugins, the real scripts, no watcher ------
# A plain git checkout with AGENTS.md, bin/, and a state dir is a genuine
# primary scope to the tracked scripts, so the REAL seatbelt and nudge gates
# run exactly as in a primary home. No task marker exists, so the watch
# plugin's shouldArm gate stays closed and no watcher is armed; the pane
# shell writes its own pid into the session lock before exec'ing the TUI, so
# the nudge's lock-ancestry check reads this session as already run and stays
# silent. Only fm-turnend-guard.sh is a stub: each run denies once with a
# fresh counter value, so exactly one follow-up turn is provable however many
# times the conversation is replayed to the mock by title requests.
mkdir -p "$PROJ/.opencode/plugins/lib" "$STATE"
git init -q "$PROJ"
: > "$PROJ/AGENTS.md"
cp "$ROOT/.opencode/plugins/package.json" "$PROJ/.opencode/plugins/package.json"
for plugin in fm-primary-cd-check.js fm-primary-pretool-check.js fm-primary-sessionstart-nudge.js fm-primary-turnend-guard.js fm-primary-watch-arm.js; do
  cp "$ROOT/.opencode/plugins/$plugin" "$PROJ/.opencode/plugins/$plugin"
done
cp "$ROOT/.opencode/plugins/lib/fm-operational-input.js" "$PROJ/.opencode/plugins/lib/fm-operational-input.js"
cp "$ROOT/.opencode/plugins/lib/fm-session-scope.js" "$PROJ/.opencode/plugins/lib/fm-session-scope.js"
cp -r "$ROOT/bin" "$PROJ/bin"
cat > "$PROJ/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
count_file="${FM_GUARD_COUNT_FILE:?}"
n=1
[ ! -f "$count_file" ] || n=$(( $(cat "$count_file") + 1 ))
printf '%s\n' "$n" > "$count_file"
printf 'FMPROBE_BLIND_%s: fixture blind turn\n' "$n" >&2
exit 2
SH
chmod +x "$PROJ/bin/fm-turnend-guard.sh"
printf '0\n' > "$LAB/guard-count"
git -C "$PROJ" add -A 2>/dev/null || true
git -C "$PROJ" -c user.email=fixture@local -c user.name=fixture commit -qm "fixture primary" 2>/dev/null || true

# --- launch the real 2.x TUI standalone with the plugins ---------------------
CFGDIR="$LAB/oc2-config"
mkdir -p "$CFGDIR"
printf '{"disabled":true}\n' > "$CFGDIR/service.json"
CFG='{"permission":{"*":"allow"},"model":"mockz/mock-1","providers":{"mockz":{"name":"Mock Z","package":"@opencode/ai/providers/anthropic-compatible","settings":{"baseURL":"http://127.0.0.1:'"$MOCK_PORT"'/v1","apiKey":"mock"},"models":{"mock-1":{"name":"Mock 1","capabilities":{"tools":true},"limit":{"context":100000,"output":4096}}}}},"policies":[{"action":"provider.use","resource":"*","effect":"deny"},{"action":"provider.use","resource":"mockz","effect":"allow"}]}'
LOG_LINES_BEFORE=0
[ -f "$LOG" ] && LOG_LINES_BEFORE=$(wc -l <"$LOG")
tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 140 -y 40 -c "$PROJ" \
  "printf '%s\\n' \"\$\$\" > '$STATE/.lock'; exec env OPENCODE_CONFIG_DIR='$CFGDIR' OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_CONFIG_CONTENT='$CFG' FM_GUARD_COUNT_FILE='$LAB/guard-count' '$OC2_BIN' --standalone --auto --prompt 'Use the shell tool to run the commands the assistant instructions require.'; rc=\$?; printf 'OC2_EXIT=%s\\n' \"\$rc\"; sleep 600"

capture() { tmux -L "$SOCKET" capture-pane -p -t "$SESSION" -S -2000 2>/dev/null || true; }

wait_for() {  # <text>
  local i=0
  while [ "$i" -lt 240 ]; do
    grep -Fq "$1" <(capture) && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

request_contains() { awk "/^---REQUEST-START---\$/,/^---REQUEST-END---\$/" "$MOCK_REQ_LOG" | grep -Fq "$1"; }

# Turn 1: benign shell call, denied shell call, final text; then the guard's
# single follow-up turn.
wait_for "FMPROBE_LIVE_DONE" || { capture >&2; fail "the scripted turn never completed in the TUI"; }
wait_for "FMPROBE_LIVE_FOLLOWED" || { capture >&2; fail "the guard follow-up turn never completed"; }
request_contains "FMPROBE_LIVE_OK" || fail "the benign shell command never reached the model result"
request_contains "watcher-background" || fail "the seatbelt denial reason never surfaced to the model"
request_contains "FMPROBE_BLIND_1" || fail "the guard follow-up prompt never reached the model"

# The follow-up's own turn close is skipped: after a settle window the stub
# guard has still denied exactly once (a second denial would re-prompt).
sleep 6
GUARD_RUNS=$(cat "$LAB/guard-count")
[ "$GUARD_RUNS" -eq 1 ] || fail "the guard ran $GUARD_RUNS times; the follow-up close must be skipped"

# No primary plugin failed to load in the server log for this run.
if [ -f "$LOG" ]; then
  if tail -n +"$((LOG_LINES_BEFORE + 1))" "$LOG" | grep -F "failed to load plugin" | grep -F "$PROJ" | grep -Eq "fm-primary"; then
    tail -n +"$((LOG_LINES_BEFORE + 1))" "$LOG" | grep -F "failed to load plugin" | grep -F "$PROJ" >&2
    fail "a primary plugin failed to load in the live server log"
  fi
fi

tmux -L "$SOCKET" kill-server 2>/dev/null || true

printf 'ok - OpenCode %s live plugins: load, seatbelt deny with surfaced reason, benign passthrough, one guard follow-up\n' "$OC2_VERSION"

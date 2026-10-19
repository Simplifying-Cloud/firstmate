#!/usr/bin/env bash
# Behavior tests for the verified OpenCode 2.x crewmate/scout adapter.
#
# The facts pinned here are the ones a wrong guess would make dangerous:
#   1. The 2.x binary is selected without PATH-order dependence: detection
#      never falls through to a 1.x `opencode` that shares the name.
#   2. The launch is standalone with an isolated config dir, disables
#      self-update, carries the platform-only provider policies and the model
#      inside OPENCODE_CONFIG_CONTENT, and passes no --model flag the 2.x TUI
#      does not have. The worker process receives the per-task config dir as
#      OPENCODE_CONFIG_DIR, and that dir holds only the service setting that
#      keeps every OpenCode command off the operator's shared background
#      server.
#   3. Platform discovery keeps only providers whose baseURL routes through
#      the platform origin; a personal provider in the same org document is
#      denied, and a model outside the discovered set refuses the spawn.
#   4. The busy-state plugin is the 2.x default-export form and classifies
#      from session.execution events with the same latch scoping as 1.x: a
#      child session's completion never clears the worker, an interrupt
#      closes the turn, and the settle touch stays a notification.
#   5. opencode2 is a crewmate/scout adapter only: a secondmate launch is
#      refused.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-opencode2-harness)

# Carry the directory the invoking environment resolves node from, plus the
# system bins, so the fake bin dir can shadow only the tools it fakes.
NODE_BIN=$(command -v node) || fail "test needs node"
NODE_BIN_DIR=$(dirname "$NODE_BIN")
BASE_PATH=${FM_TEST_BASE_PATH:-$NODE_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin}

# The fake 2.x binary answers the two probes fm-spawn makes: --version must
# print the 2.x-prefixed form, and debug config serves the fixture document
# set (an org document whose providers mix platform and personal origins, plus
# a pathed user document whose provider must stay out of the allowlist).
make_oc2_fakebin() {  # <dir>
  local fakebin
  fakebin=$(fm_test_make_spawn_fakebin "$1")
  cat >"$fakebin/opencode2" <<'SH'
#!/usr/bin/env bash
set -u
case "$1" in
--version)
  printf '%s\n' "${FM_FAKE_OC2_VERSION:-opencode v2.0.32-fixture}"
  ;;
debug)
  cat "${FM_FAKE_OC2_DEBUG_CONFIG:?fixture path missing}"
  ;;
*)
  # The worker launch itself: record the config dir the worker process got.
  if [ -n "${FM_FAKE_OC2_ENV_LOG:-}" ]; then
    printf 'OPENCODE_CONFIG_DIR=%s\n' "${OPENCODE_CONFIG_DIR-<unset>}" >"$FM_FAKE_OC2_ENV_LOG"
  fi
  exit 0
  ;;
esac
SH
  chmod +x "$fakebin/opencode2"
  # A same-named 1.x binary on PATH proves selection never depends on it.
  cat >"$fakebin/opencode" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1:-}" = --version ] && printf '%s\n' "1.18.31"
exit 0
SH
  chmod +x "$fakebin/opencode"
  printf '%s\n' "$fakebin"
}

write_oc2_debug_fixture() {  # <file>
  cat >"$1" <<'JSON'
[
  {
    "type": "document",
    "info": {
      "$schema": "https://opencode.ai/config.json",
      "model": { "providerID": "zai", "model": "glm-5.3" },
      "providers": {
        "minimax": {
          "name": "MiniMax via organization gateway",
          "settings": { "baseURL": "https://ai.simplifying.cloud/models/minimax/anthropic/v1", "apiKey": "***" },
          "headers": { "cf-access-token": "***" }
        },
        "zai": {
          "name": "GLM via organization gateway",
          "settings": { "baseURL": "https://ai.simplifying.cloud/models/glm/v4", "apiKey": "***" },
          "headers": { "cf-access-token": "***" }
        },
        "personal-openai": {
          "name": "OpenAI personal credential",
          "settings": { "baseURL": "https://api.openai.com/v1", "apiKey": "***" }
        }
      }
    }
  },
  {
    "type": "document",
    "path": "/home/someone/.config/opencode/opencode.json",
    "info": {
      "providers": {
        "zai-lookalike": {
          "settings": { "baseURL": "https://ai.simplifying.cloud/models/lookalike", "apiKey": "***" }
        }
      }
    }
  }
]
JSON
}

make_oc2_spawn_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_oc2_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  cat >"$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise OpenCode 2.x dispatch.

## Firstmate spec
Verify launch and delivery behavior.
EOF
  printf 'opencode2\n' >"$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  write_oc2_debug_fixture "$case_dir/debug-config.json"
  mkdir -p "$case_dir/user-home"
  : >"$case_dir/launch.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_oc2_spawn_record() {
  # shellcheck disable=SC2034 # record shape shared by every spawn suite
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_oc2_spawn() {  # <case-dir> <home> <fakebin> <id> [fm-spawn args...]
  local case_dir=$1 home=$2 fakebin=$3 id=$4
  shift 4
  HOME="$home/user-home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    FM_FAKE_OC2_DEBUG_CONFIG="$case_dir/debug-config.json" \
    PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off "$@" 2>&1
}

classify() {  # <id> <state-dir>
  fm_busy_classify tmux fake:w opencode2 "$1" "$2"
}

test_oc2_binary_resolution_refuses_without_2x() {
  local out
  out=$(HOME="$TMP_ROOT/no-home" PATH="$BASE_PATH" \
    bash -c '. "$1/bin/fm-opencode2-lib.sh"; fm_opencode2_resolve_binary' \
    _ "$ROOT" 2>&1 </dev/null)
  case "$out" in
  *"no OpenCode 2.x executable found"*) ;;
  *) fail "absent install should refuse loudly, got: $out" ;;
  esac
  pass "opencode2 binary resolution refuses without a proven 2.x executable"
}

test_oc2_spawn_launches_platform_only_and_standalone() {
  local rec id=oc2-launch-1 out status launch state cfgdir
  rec=$(make_oc2_spawn_case launch "$id")
  read_oc2_spawn_record "$rec"
  out=$(run_oc2_spawn "$CASE_DIR" "$HOME_DIR" "$FAKEBIN_DIR" "$id" --model zai/glm-5.3)
  status=$?
  expect_code 0 "$status" "opencode2 spawn should succeed: $out"
  launch=$(grep -F OPENCODE_CONFIG_CONTENT "$CASE_DIR/launch.log" | tail -1)
  [ -n "$launch" ] || fail "no launch line recorded for the opencode2 spawn"
  assert_contains "$launch" "--standalone" "opencode2 launch must run a private server"
  assert_contains "$launch" "--auto" "opencode2 launch must auto-approve permissions"
  assert_contains "$launch" "OPENCODE_DISABLE_AUTOUPDATE=1" "opencode2 launch must disable self-upgrade"
  assert_contains "$launch" "OPENCODE_CONFIG_DIR=" "opencode2 launch must isolate the config dir"
  assert_contains "$launch" \
    ',"policies":[{"action":"provider.use","resource":"*","effect":"deny"},{"action":"provider.use","resource":"minimax","effect":"allow"},{"action":"provider.use","resource":"zai","effect":"allow"}],"model":"zai/glm-5.3"}' \
    "opencode2 launch must deny every provider except the platform's and carry the model"
  assert_not_contains "$launch" "personal-openai" "a personal provider must never be allowed"
  assert_not_contains "$launch" "zai-lookalike" "a pathed document's provider must never be allowed"
  assert_not_contains "$launch" " --model" "the 2.x TUI has no --model flag"
  assert_not_contains "$launch" "OPENCODE_CONFIG_CONTENT=' opencode" "the launch must name the resolved binary path, not a PATH lookup"
  case "$launch" in
  *" '$FAKEBIN_DIR/opencode2' "*) ;;
  *) fail "launch did not resolve the fake 2.x binary path: $launch" ;;
  esac
  state="$HOME_DIR/state"
  cfgdir="$state/$id.opencode-config"
  [ -d "$cfgdir" ] || fail "opencode2 spawn did not create the isolated config dir $cfgdir"
  [ -e "$state/$id.busy-gen" ] || fail "opencode2 spawn did not arm busy wiring"
  out=$(classify "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "seed after spawn must be 'busy fm-spawn', got '$out'"
  local meta_harness
  meta_harness=$(sed -n 's/^harness=//p' "$state/$id.meta")
  [ "$meta_harness" = opencode2 ] || fail "meta must record harness=opencode2, got '$meta_harness'"
  pass "opencode2 launch is standalone, config-isolated, and platform-only"
}

test_oc2_worker_environment_isolates_the_operator_setup() {
  local rec id=oc2-env-1 out launch cfgdir want
  rec=$(make_oc2_spawn_case env "$id")
  read_oc2_spawn_record "$rec"
  out=$(run_oc2_spawn "$CASE_DIR" "$HOME_DIR" "$FAKEBIN_DIR" "$id" --model zai/glm-5.3)
  expect_code 0 "$?" "opencode2 spawn should succeed: $out"
  launch=$(grep -F OPENCODE_CONFIG_CONTENT "$CASE_DIR/launch.log" | tail -1)
  [ -n "$launch" ] || fail "no launch line recorded for the opencode2 spawn"
  # Run the staged launch exactly as the worker pane would; the fake 2.x
  # binary records the environment the worker process actually receives.
  (cd "$WT_DIR" && FM_FAKE_OC2_ENV_LOG="$CASE_DIR/worker-env" PATH="$FAKEBIN_DIR:$BASE_PATH" \
    bash -c "$launch") >"$CASE_DIR/launch-run.log" 2>&1 \
    || fail "the staged opencode2 launch did not run: $(cat "$CASE_DIR/launch-run.log")"
  cfgdir=$(sed -n 's/^OPENCODE_CONFIG_DIR=//p' "$CASE_DIR/worker-env" 2>/dev/null)
  want="$(cd -P "$HOME_DIR/state" && pwd)/$id.opencode-config"
  [ "$cfgdir" = "$want" ] \
    || fail "the worker must get its per-task config dir '$want' as OPENCODE_CONFIG_DIR, got '$cfgdir'"
  # OpenCode 2.x reads its service setting from the active config dir; disabled
  # makes every OpenCode command in the worker's environment start a private
  # server instead of attaching to the operator's background server.
  node -e '
const fs = require("fs");
const setting = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
process.exit(setting.disabled === true ? 0 : 1);
' "$cfgdir/service.json" \
    || fail "the per-task config dir must turn the shared background server off: $(cat "$cfgdir/service.json" 2>&1)"
  [ "$(ls -A "$cfgdir")" = service.json ] \
    || fail "the per-task config dir must hold only the service setting, got: $(ls -A "$cfgdir")"
  pass "opencode2 worker gets a per-task OPENCODE_CONFIG_DIR that keeps OpenCode off the operator's shared background server"
}

test_oc2_model_outside_the_platform_refuses() {
  local rec id=oc2-model-bad out
  rec=$(make_oc2_spawn_case model-bad "$id")
  read_oc2_spawn_record "$rec"
  out=$(run_oc2_spawn "$CASE_DIR" "$HOME_DIR" "$FAKEBIN_DIR" "$id" --model personal-openai/gpt-5.5)
  expect_code 1 "$?" "a model outside the platform providers must refuse the spawn"
  assert_contains "$out" "does not name one of the platform providers" "refusal must name the platform constraint"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused spawn must leave no task record"
  pass "opencode2 refuses a model outside the discovered platform providers"
}

test_oc2_secondmate_is_refused() {
  local rec id=oc2-secondmate out home fakebin
  rec=$(make_oc2_spawn_case secondmate "$id")
  read_oc2_spawn_record "$rec"
  out=$(HOME="$HOME_DIR/user-home" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_OC2_DEBUG_CONFIG="$CASE_DIR/debug-config.json" \
    PATH="$FAKEBIN_DIR:$BASE_PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$HOME_DIR" --secondmate 2>&1)
  expect_code 1 "$?" "an opencode2 secondmate must refuse"
  assert_contains "$out" "cannot run a secondmate" "refusal must state the crewmate-only boundary"
  pass "opencode2 refuses secondmate launches"
}

# drive_oc2_plugin <plugin-path> <state-dir> <id> <events-json...>: load the
# generated 2.x plugin and push {type,data} events through a fake ctx.
drive_oc2_plugin() {
  local plugin=$1 state=$2 id=$3
  shift 3
  PLUGIN_PATH="$plugin" STATE_DIR="$state" TASK_ID="$id" node --input-type=module - "$@" 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.PLUGIN_PATH).href);
const events = process.argv.slice(2).map((arg) => JSON.parse(arg));
for (const setup of [1, 2]) {
  const cleanup = await mod.default.setup({
    event: {
      subscribe: () => ({
        [Symbol.asyncIterator]: async function* () {
          for (const event of events) yield event;
        },
      }),
    },
  });
  await new Promise((resolve) => setTimeout(resolve, 250));
  cleanup();
  if (setup === 1) break;
}
EOF
}

oc2_event() {  # <type> <sessionID> [extra-json]
  printf '{"type":"%s","data":{"sessionID":"%s"%s}}' "$1" "$2" "${3:+,$3}"
}

test_oc2_plugin_classifies_from_execution_events() {
  local rec id=oc2-plugin-1 out state plugin
  rec=$(make_oc2_spawn_case plugin "$id")
  read_oc2_spawn_record "$rec"
  out=$(run_oc2_spawn "$CASE_DIR" "$HOME_DIR" "$FAKEBIN_DIR" "$id" --model zai/glm-5.3)
  expect_code 0 "$?" "opencode2 spawn should succeed: $out"
  state="$HOME_DIR/state"
  plugin="$WT_DIR/.opencode/plugins/fm-busy-state.js"
  assert_present "$plugin" "opencode2 spawn did not write the busy-state plugin"

  out=$(drive_oc2_plugin "$plugin" "$state" "$id" \
    "$(oc2_event session.execution.started ses_main)") || fail "busy drive failed: $out"
  out=$(classify "$id" "$state")
  [ "$out" = "busy opencode-plugin" ] || fail "execution start must classify busy, got '$out'"

  out=$(drive_oc2_plugin "$plugin" "$state" "$id" \
    "$(oc2_event session.execution.started ses_main)" \
    "$(oc2_event session.execution.started ses_child)" \
    "$(oc2_event session.execution.succeeded ses_child)") || fail "child drive failed: $out"
  out=$(classify "$id" "$state")
  [ "$out" = "busy opencode-plugin" ] || fail "a child session's completion must not clear the worker, got '$out'"

  rm -f "$state/$id.turn-ended"
  out=$(drive_oc2_plugin "$plugin" "$state" "$id" \
    "$(oc2_event session.execution.started ses_main)" \
    "$(oc2_event session.retry.scheduled ses_main '"attempt":1')" \
    "$(oc2_event session.execution.interrupted ses_main '"reason":"user"')") || fail "interrupt drive failed: $out"
  out=$(classify "$id" "$state")
  [ "$out" = "idle opencode-plugin" ] || fail "an interrupted turn must close the busy record, got '$out'"
  [ -f "$state/$id.turn-ended" ] || fail "the settle must touch the notification marker"

  rm -f "$state/$id.turn-ended"
  out=$(drive_oc2_plugin "$plugin" "$state" "$id" \
    "$(oc2_event session.execution.started ses_other)" \
    "$(oc2_event session.execution.succeeded ses_other)") || fail "other-session drive failed: $out"
  [ -f "$state/$id.turn-ended" ] || fail "another session's settle must not touch the marker"
  out=$(classify "$id" "$state")
  [ "$out" = "idle opencode-plugin" ] || fail "another session's settle must not change state, got '$out'"
  pass "opencode2 plugin classifies from session.execution events, scoped to the latched worker session"
}

# Regression for the 2026-10-17 post-teardown signal: TUI exit fired a final
# busy-plugin settle that raced teardown's record removal and recreated
# state/<id>.turn-ended for a task whose records teardown had already deleted.
# Teardown retires the busy contract before removing the notification, so the
# plugin's settle must ride the same gen-guarded writer call and be refused
# whole once the task is torn down.
test_oc2_plugin_cannot_resurrect_records_after_retire() {
  local rec id=oc2-plugin-retire out state plugin
  rec=$(make_oc2_spawn_case plugin-retire "$id")
  read_oc2_spawn_record "$rec"
  out=$(run_oc2_spawn "$CASE_DIR" "$HOME_DIR" "$FAKEBIN_DIR" "$id" --model zai/glm-5.3)
  expect_code 0 "$?" "opencode2 spawn should succeed: $out"
  state="$HOME_DIR/state"
  plugin="$WT_DIR/.opencode/plugins/fm-busy-state.js"
  assert_present "$plugin" "opencode2 spawn did not write the busy-state plugin"
  # Teardown's ordering for a live task: retire the busy contract (the meta's
  # exact gen), then remove the turn-ended notification and its seen marker.
  "$ROOT/bin/fm-busy-event.sh" retire "$state" "$id" --current-gen \
    || fail "retire failed"
  rm -f "$state/$id.turn-ended"
  # The racing final settle: TUI exit can run one last execution cycle, so the
  # latch catches a started before the settle that must be refused whole.
  out=$(drive_oc2_plugin "$plugin" "$state" "$id" \
    "$(oc2_event session.execution.started ses_main)" \
    "$(oc2_event session.execution.succeeded ses_main)") || fail "post-retire drive failed: $out"
  [ ! -e "$state/$id.turn-ended" ] || fail "a post-retire settle recreated the turn-ended notification"
  [ ! -e "$state/$id.busy-state" ] || fail "a post-retire settle recreated the busy record"
  out=$(classify "$id" "$state")
  [ "$out" = "unknown missing" ] || fail "post-retire settle changed classification, got '$out'"
  pass "an opencode2 settle racing teardown cannot resurrect task records"
}

test_oc2_control_mechanics_are_the_verified_ones() {
  local out
  [ "$(fm_control_harness_family opencode2)" = opencode2 ] || fail "opencode2 must be its own control family"
  fm_control_harness_supported opencode2 || fail "opencode2 must be a supported control adapter"
  [ "$(fm_control_exit_command opencode2)" = "/exit" ] || fail "exit command must stay /exit"
  [ "$(fm_control_interrupt_key opencode2)" = Escape ] || fail "interrupt key must be Escape"
  [ "$(fm_control_interrupt_repeat opencode2)" = 2 ] || fail "interrupt must be a double press"
  [ "$(fm_control_interrupt_arm_signal opencode2)" = "esc again to interrupt" ] \
    || fail "interrupt must arm on the rendered hint"
  [ "$(fm_control_interrupt_press_gap opencode2)" = 0.5 ] || fail "armed presses must keep the verified gap"
  fm_control_harness_supports_kind opencode2 ship || fail "ship must be supported"
  fm_control_harness_supports_kind opencode2 scout || fail "scout must be supported"
  fm_control_harness_supports_kind opencode2 secondmate && fail "secondmate must be refused" || true
  out=$(fm_control_harness_wiring_paths opencode2 /wt /state task1)
  printf '%s\n' "$out" | grep -Fqx '/wt/.opencode/plugins/fm-busy-state.js' || fail "wiring must include the plugin"
  printf '%s\n' "$out" | grep -Fqx '/state/task1.opencode-config' || fail "wiring must include the isolated config dir"
  pass "opencode2 control mechanics match the verified 2.x facts"
}

test_oc2_binary_resolution_refuses_without_2x \
  &&
  test_oc2_spawn_launches_platform_only_and_standalone \
  &&
  test_oc2_worker_environment_isolates_the_operator_setup \
  &&
  test_oc2_model_outside_the_platform_refuses \
  &&
  test_oc2_secondmate_is_refused \
  &&
  test_oc2_plugin_classifies_from_execution_events \
  &&
  test_oc2_plugin_cannot_resurrect_records_after_retire \
  &&
  test_oc2_control_mechanics_are_the_verified_ones

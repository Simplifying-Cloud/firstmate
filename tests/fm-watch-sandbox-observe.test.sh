#!/usr/bin/env bash
# tests/fm-watch-sandbox-observe.test.sh - the watcher's supervision of a
# sandbox task through its host's observe verb (bin/fm-watch.sh's
# sandbox_observe_check).
#
# A real fm-watch.sh runs against a home holding one sandbox task record. Its
# transport is the real bin/fm-on.sh, whose FM_SSH_BIN seam is a fake ssh that
# answers the host's observe, ring, and crew-state verbs from files the test
# writes, or fails with SSH exit 255 while the case's ssh-down file exists. A
# logging tmux on PATH records any local endpoint read, which a sandbox task
# must never get. The cases pin:
#   - remote calls ride the observe cadence, never the ordinary poll;
#   - an unchanging observed pane surfaces as an ordinary stale wake;
#   - a VM-side dead or missing agent is reported once per incarnation, and the
#     report names the reboot-proven relaunch only when the host has rebooted;
#   - no observation runs while a spawn still placing the task or a control
#     action holds it;
#   - an unreachable host is unknown: one keyed check wake per failure streak,
#     never a stale or dead wake;
#   - the steering re-ring ladder rings through the host's ring verb, waits on a
#     busy worker, and escalates a spent budget or a gone agent;
#   - the wedge timer's worktree-write deferral reads the host's write field.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-sandbox-observe)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

ack_stopped_cycle() {  # <state>
  local state=$1 err sequence generation
  err="$state/.test-cycle-drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation" >/dev/null 2>&1
}

# new_case <name>: a home holding sandbox task sbx-<name> and the fakes. Sets
# CASE, HOME_DIR, STATE, FAKEBIN, ID, WINDOW, KEY, and SPAWN_EPOCH.
new_case() {
  local name=$1
  CASE=$(make_case "$name")
  HOME_DIR="$CASE/home"
  STATE="$CASE/state"
  FAKEBIN="$CASE/fakebin"
  ID="sbx-$name"
  WINDOW="remote:$ID"
  KEY="remote_$ID"
  SPAWN_EPOCH=$(( $(date +%s) - 3600 ))
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/config" "$CASE/host"
  cat > "$FAKEBIN/tmux" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CASE/local-tmux.log"
exit 1
SH
  chmod +x "$FAKEBIN/tmux"
  cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
set -u
d=${FM_FAKE_SANDBOX_DIR:?}
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
host=$1
args=()
while IFS= read -r -d '' arg; do args+=("$arg"); done < <(printf '%s' "$6" | base64 --decode)
printf '%s %s\n' "${args[0]}" "${args[1]:-}" >> "$d/ssh.log"
[ ! -e "$d/down" ] || { echo "ssh: connect to host $host port 22: Connection refused" >&2; exit 255; }
case "${args[1]:-}" in
  observe)
    if [ -e "$d/lock-during-observe" ]; then
      mkdir -p "$FM_STATE_OVERRIDE/.control-${args[2]}.lock"
      cat "$d/lock-during-observe" > "$FM_STATE_OVERRIDE/.control-${args[2]}.lock/pid"
    fi
    n=$(( $(cat "$d/observe-count" 2>/dev/null || echo 0) + 1 ))
    printf '%s\n' "$n" > "$d/observe-count"
    if [ -e "$d/generation-during-observe" ]; then
      sed -i.bak "s/^spawn_gen=.*/spawn_gen=s9999999999.$n.1/" "$FM_STATE_OVERRIDE/${args[2]}.meta"
    fi
    hash=$(cat "$d/hash" 2>/dev/null || printf 'aaaa')
    [ ! -e "$d/churn" ] || hash="$hash$n"
    sed -e "s/@NOW@/$(date +%s)/g" -e "s/@HASH@/$hash/g" "$d/observe"
    ;;
  ring)
    printf '%s\n' "${args[3]:-}" >> "$d/rings"
    printf 'schema=fm-remote-task-control.v1\nring=%s\n' "$(cat "$d/ring-result" 2>/dev/null || printf rang)"
    ;;
  *) echo "error: unexpected verb ${args[1]:-}" >&2; exit 1 ;;
esac
SH
  chmod +x "$FAKEBIN/fake-ssh"
  fm_write_meta "$STATE/$ID.meta" "window=$WINDOW" "endpoint_task_id=$ID" \
    "worktree=/home/agent/fm-home/projects/alpha-wt" "project=$HOME_DIR/projects/alpha" \
    "harness=pi" "kind=ship" "mode=direct-PR" "yolo=off" "spawn_gen=s$SPAWN_EPOCH.11.22" \
    "placement=sandbox" "remote_kind=task" "remote_host=alias-$ID" "remote_root=$ROOT" \
    "remote_home=/home/agent/fm-home" "remote_backend=tmux" "remote_target=firstmate:fm-$ID" \
    "sandbox_provider=pve-sandbox" "sandbox_name=sbx-home-$ID" "sandbox_profile=default"
  observe_as alive idle
}

# observe_as <agent> <busy> [boot] [inbox-oldest] [inbox-oldest-at] [worktree-write]:
# the observation the host returns next; @NOW@ and @HASH@ are filled per call.
observe_as() {
  {
    printf 'schema=fm-remote-task-control.v1\n'
    printf 'now=@NOW@\n'
    printf 'boot=%s\n' "${3:-$(( SPAWN_EPOCH - 600 ))}"
    printf 'agent=%s\n' "$1"
    printf 'busy=%s\n' "$2"
    printf 'busy_source=pi-ext\n'
    printf 'pane_hash=@HASH@\n'
    printf 'worktree_write=%s\n' "${6:-none}"
    printf 'inbox_oldest=%s\n' "${4:-none}"
    printf 'inbox_oldest_at=%s\n' "${5:-none}"
    printf 'turn_at=@NOW@\n'
  } > "$CASE/host/observe"
}

# watch_start: one watcher process against this case, its pid in WATCH_PID and
# its output in $CASE/watch.out.
watch_start() {
  : > "$CASE/watch.out"
  # bin/fm-on.sh runs only commands this checkout tracks, so the watcher keeps
  # its own code root rather than the wake helpers' inert tangle root.
  env -u FM_ROOT_OVERRIDE PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_SSH_BIN="$FAKEBIN/fake-ssh" FM_FAKE_SANDBOX_DIR="$CASE/host" \
    FM_CREW_STATE_BIN="${FM_TEST_CREW_STATE_BIN:-$FAKEBIN/fm-crew-state.sh}" FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 FM_REMOTE_OBSERVE_SECS="${FM_TEST_OBSERVE_SECS:-1}" \
    FM_REMOTE_UNREACHABLE_COUNT="${FM_TEST_UNREACHABLE_COUNT:-2}" \
    FM_STALE_ESCALATE_SECS="${FM_TEST_STALE_ESCALATE:-240}" FM_PAUSE_RESURFACE_SECS=999999 \
    FM_TASK_INBOX_GRACE_SECS="${FM_TEST_INBOX_GRACE:-90}" FM_TASK_INBOX_RING_MAX=2 \
    "$WATCH" >> "$CASE/watch.out" 2>> "$CASE/watch.err" &
  WATCH_PID=$!
}

watch_stop() {
  kill "$WATCH_PID" 2>/dev/null || true
  wait_for_exit "$WATCH_PID" 100 >/dev/null 2>&1 || true
}

# watch_round <exit|run> [seconds]: exit waits for the watcher to wake; run lets
# it poll for <seconds>, fails if it woke meanwhile, and stops it.
watch_round() {
  local mode=$1 seconds=${2:-6} rc=0
  watch_start
  if [ "$mode" = exit ]; then
    wait_for_exit "$WATCH_PID" 300 || rc=$?
    [ "$rc" -ne 124 ] || return 1
    return 0
  fi
  sleep "$seconds"
  if ! kill -0 "$WATCH_PID" 2>/dev/null; then
    wait "$WATCH_PID" 2>/dev/null || true
    return 1
  fi
  watch_stop
  return 0
}

# watch_observes <n>: let the watcher observe the host <n> more times without
# waking, then stop it; fails if it woke or the observations never came.
watch_observes() {
  local want=$(( $(host_calls observe) + $1 )) i=0
  watch_start
  while [ "$(host_calls observe)" -lt "$want" ]; do
    if ! kill -0 "$WATCH_PID" 2>/dev/null; then
      wait "$WATCH_PID" 2>/dev/null || true
      return 1
    fi
    [ "$i" -lt 600 ] || { watch_stop; return 1; }
    sleep 0.1
    i=$((i + 1))
  done
  # Let the poll that made the last observation finish classifying it.
  sleep 1
  if ! kill -0 "$WATCH_PID" 2>/dev/null; then
    wait "$WATCH_PID" 2>/dev/null || true
    return 1
  fi
  watch_stop
  return 0
}

stale_wakes() {
  awk -F '\t' -v w="$WINDOW" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$STATE/.wake-queue" 2>/dev/null || echo 0
}

check_wakes() { # <key-prefix>
  awk -F '\t' -v k="$1" '$3 == "check" && index($4, k) == 1 { n++ } END { print n + 0 }' "$STATE/.wake-queue" 2>/dev/null || echo 0
}

host_calls() { # <verb>
  awk -v v="$1" '$1 == "fm-remote-task-control.sh" && $2 == v { n++ } END { print n + 0 }' "$CASE/host/ssh.log" 2>/dev/null || echo 0
}

assert_no_local_reads() { # <label>
  if [ -s "$CASE/local-tmux.log" ] && grep -q -- "$ID" "$CASE/local-tmux.log"; then
    fail "$1 read the sandbox task's endpoint locally:"$'\n'"$(cat "$CASE/local-tmux.log")"
  fi
}

# --- remote calls ride the observe cadence --------------------------------------

test_observation_rides_its_own_cadence() {
  local observes
  new_case cadence
  observe_as alive busy
  : > "$CASE/host/churn"
  FM_TEST_OBSERVE_SECS=4 watch_round run 7 || fail "a busy sandbox worker woke the watcher: $(cat "$CASE/watch.out")"
  observes=$(host_calls observe)
  [ "$observes" -ge 1 ] && [ "$observes" -le 2 ] \
    || fail "seven one-second polls made $observes observations at a four-second cadence"
  [ "$(wc -l < "$CASE/host/ssh.log")" -eq "$observes" ] \
    || fail "the poll reached the host for more than its observations: $(cat "$CASE/host/ssh.log")"
  assert_present "$STATE/.sandbox-observe-$ID/last" "the observation is recorded for the fleet view"
  assert_grep "agent=alive" "$STATE/.sandbox-observe-$ID/last" "the recorded observation names the agent"
  grep -q '^observed_at=[0-9][0-9]*$' "$STATE/.sandbox-observe-$ID/last" \
    || fail "the recorded observation carries no observed_at"
  [ "$(stale_wakes)" -eq 0 ] || fail "a busy observation queued a stale wake"
  assert_no_local_reads "the observe cadence"
  pass "a sandbox task is observed once per cadence, never on every poll, and a busy one stays quiet"
}

# --- an unchanging observed pane is stale --------------------------------------

test_an_unchanging_observed_pane_surfaces_as_stale() {
  new_case stale
  observe_as alive idle
  FM_TEST_CREW_STATE_BIN="$ROOT/bin/fm-crew-state.sh" watch_round exit || fail "an idle, unchanging sandbox pane never surfaced: $(cat "$CASE/watch.out")"
  assert_contains "$(cat "$CASE/watch.out")" "stale: $WINDOW" "the wake names the sandbox window"
  [ "$(stale_wakes)" -eq 1 ] || fail "the stale pane queued $(stale_wakes) wakes instead of one"
  [ "$(host_calls observe)" -ge 3 ] || fail "staleness was decided on fewer than three observations"
  [ "$(wc -l < "$CASE/host/ssh.log")" -eq "$(host_calls observe)" ] \
    || fail "stale classification made extra remote calls: $(cat "$CASE/host/ssh.log")"
  assert_equals aaaa "$(cat "$STATE/.hash-$KEY")" "the observed pane hash is what the stale loop tracks"
  assert_no_local_reads "the stale path"
  pass "an idle sandbox worker whose observed pane stops changing surfaces as an ordinary stale wake"
}

# --- a VM-side dead or missing agent --------------------------------------------

test_a_gone_agent_is_reported_once_per_incarnation() {
  local out
  new_case gone
  observe_as missing dead $(( SPAWN_EPOCH + 120 ))
  watch_round exit || fail "a missing sandbox endpoint was never reported: $(cat "$CASE/watch.out")"
  out=$(cat "$CASE/watch.out")
  assert_contains "$out" "stale: $WINDOW (agent missing on sandbox host alias-$ID" "the report names the VM-side verdict"
  assert_contains "$out" "the sandbox booted after this worker launched" "the report names the reboot that proves it gone"
  assert_contains "$out" "bin/fm-control.sh $ID relaunch" "the report names the recovery"
  assert_not_contains "$out" "possible wedge" "a gone agent is never a wedge"
  [ "$(stale_wakes)" -eq 1 ] || fail "the gone agent queued $(stale_wakes) wakes instead of one"
  ack_stopped_cycle "$STATE" || fail "could not acknowledge the report"

  # The same incarnation stays gone: nothing more is reported.
  watch_observes 2 || fail "an already-reported gone agent woke the watcher again: $(cat "$CASE/watch.out")"
  [ "$(stale_wakes)" -eq 0 ] || fail "an already-reported gone agent queued another wake"

  # A relaunch republishes the record with a new incarnation; its own death is
  # reported again, and without a reboot the report says the host cannot prove it.
  sed -i.bak "s/^spawn_gen=.*/spawn_gen=s$(( SPAWN_EPOCH + 300 )).33.44/" "$STATE/$ID.meta" && rm -f "$STATE/$ID.meta.bak"
  watch_round exit || fail "a later incarnation's death was never reported: $(cat "$CASE/watch.out")"
  out=$(cat "$CASE/watch.out")
  assert_contains "$out" "agent missing on sandbox host alias-$ID" "the later death is reported"
  assert_contains "$out" "cannot prove that endpoint absent" "without a later reboot the report asks for inspection"
  ack_stopped_cycle "$STATE" || fail "could not acknowledge the second report"

  observe_as dead dead
  sed -i.bak "s/^spawn_gen=.*/spawn_gen=s$(( SPAWN_EPOCH + 600 )).55.66/" "$STATE/$ID.meta" && rm -f "$STATE/$ID.meta.bak"
  watch_round exit || fail "a dead agent was never reported: $(cat "$CASE/watch.out")"
  assert_contains "$(cat "$CASE/watch.out")" "agent dead on sandbox host alias-$ID - its endpoint is still there with no agent running in it" \
    "a dead agent's report names the surviving endpoint"
  assert_contains "$(cat "$CASE/watch.out")" "relaunch it in place" "a dead endpoint relaunches in place"
  assert_no_local_reads "the dead-record report"
  pass "a VM-side dead or missing agent is reported once per incarnation, naming the recovery the host can perform"
}

# --- a lifecycle action in flight is never observed -------------------------------

test_no_observation_while_a_lifecycle_action_holds_the_task() {
  local lock
  new_case locked
  observe_as missing dead
  for lock in "$STATE/.spawn-$ID.lock" "$STATE/.control-$ID.lock"; do
    mkdir "$lock" && printf '%s\n' "$$" > "$lock/pid"
    watch_round run 4 || fail "a task held by $(basename "$lock") woke the watcher: $(cat "$CASE/watch.out")"
    assert_equals 0 "$(host_calls observe)" "a task held by $(basename "$lock") was observed"
    [ ! -e "$STATE/.sandbox-observe-$ID" ] \
      || fail "a deferred observation of a task held by $(basename "$lock") left bookkeeping behind"
    rm -rf "$lock"
  done
  watch_round exit || fail "the released task was never observed: $(cat "$CASE/watch.out")"
  assert_contains "$(cat "$CASE/watch.out")" "agent missing on sandbox host alias-$ID" "the released task's observation is reported"
  pass "a spawn still placing a task or a control action holding it defers its observation and leaves no bookkeeping"
}

# --- an unreachable host is unknown --------------------------------------------

test_observation_discarded_when_lifecycle_changes() {
  local change
  for change in lock generation; do
    new_case "racing-$change"
    observe_as missing dead
    printf '%s\n' "$$" > "$CASE/host/$change-during-observe"
    FM_TEST_OBSERVE_SECS=60 watch_round run 4 \
      || fail "an observation crossing a lifecycle change woke the watcher"
    [ "$(host_calls observe)" -ge 1 ] || fail "the lifecycle race never observed the host"
    assert_absent "$STATE/.sandbox-observe-$ID/last" "discarded observation was published"
    assert_absent "$STATE/.sandbox-observe-$ID/failures" "discarded observation changed failures"
    assert_absent "$STATE/.dead-reported-$KEY" "discarded observation reported death"
    assert_equals 0 "$(stale_wakes)" "discarded observation queued a stale wake"
    assert_absent "$STATE/.sandbox-observe-$ID/tick" "discarded observation advanced cadence"
  done
  pass "observations crossing lifecycle locks or incarnation changes are discarded"
}

test_an_unreachable_host_is_reported_once_per_streak() {
  local out first_key calls
  new_case unreachable
  observe_as alive busy
  : > "$CASE/host/down"
  watch_round exit || fail "an unreachable host was never reported: $(cat "$CASE/watch.out")"
  out=$(cat "$CASE/watch.out")
  assert_contains "$out" "check: sandbox $ID unreachable: 2 consecutive observations of its host alias-$ID failed" \
    "the wake counts the failed observations"
  assert_contains "$out" "SSH exit 255" "the wake names the transport failure"
  assert_contains "$out" "unknown, not dead" "an unreachable host is never called dead"
  [ "$(check_wakes "sandbox-unreachable-$ID-")" -eq 1 ] || fail "the streak queued more than one wake"
  [ "$(stale_wakes)" -eq 0 ] || fail "an unreachable host produced a stale wake"
  assert_absent "$STATE/.dead-reported-$KEY" "an unreachable host was reported dead"
  first_key=$(awk -F '\t' '$3 == "check" { print $4 }' "$STATE/.wake-queue")
  ack_stopped_cycle "$STATE" || fail "could not acknowledge the unreachable wake"

  # The same streak never alerts again, though its host is still observed.
  calls=$(host_calls observe)
  fm_touch_epoch "$(( $(date +%s) - 120 ))" "$STATE/.sandbox-observe-$ID/tick"
  FM_TEST_OBSERVE_SECS=60 watch_observes 1 || fail "a continuing streak woke the watcher again: $(cat "$CASE/watch.out")"
  [ "$(check_wakes "sandbox-unreachable-$ID-")" -eq 0 ] || fail "a continuing streak queued another wake"

  [ "$(host_calls observe)" -eq "$(( calls + 1 ))" ] || fail "the outage slowed the configured cadence"

  # A good observation ends the streak; a later outage is a new one.
  rm -f "$CASE/host/down" "$STATE/.sandbox-observe-$ID/tick"
  watch_observes 1 || fail "a recovered host woke the watcher: $(cat "$CASE/watch.out")"
  assert_absent "$STATE/.sandbox-observe-$ID/failures" "a good observation did not end the streak"
  : > "$CASE/host/down"
  watch_round exit || fail "a new outage was never reported: $(cat "$CASE/watch.out")"
  out=$(awk -F '\t' '$3 == "check" { print $4 }' "$STATE/.wake-queue")
  [ -n "$out" ] && [ "$out" != "$first_key" ] || fail "a new outage reused the old streak's key: $out"
  [ "$(stale_wakes)" -eq 0 ] || fail "a new outage produced a stale wake"
  assert_no_local_reads "the unreachable path"
  pass "an unreachable host is unknown: one keyed check wake per failure streak, never stale or dead"
}

# --- the minted GitHub token's refresh -------------------------------------------

test_a_failed_credential_refresh_wakes_once() {
  local out expires_at expires
  new_case cred-refresh
  observe_as alive busy
  : > "$CASE/host/churn"
  printf '#!/usr/bin/env bash\nprintf "called\\n" >> "%s/curl.log"\nexit 7\n' "$CASE" > "$FAKEBIN/curl"
  chmod +x "$FAKEBIN/curl"
  # The current token expires within the refresh lead, and this home has no
  # config/github-app, so the refresh fails before any request.
  expires_at=$(( $(date +%s) + 300 ))
  expires=$(date -u -r "$expires_at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$expires_at" +%Y-%m-%dT%H:%M:%SZ)
  printf '%s mint github task=%s repo=acme/alpha access=write expires=%s fp=0123456789ab purpose=launch\n' \
    "$(date +%s)" "$ID" "$expires" > "$STATE/cred-ledger"
  watch_round exit || fail "a failed credential refresh never woke the watcher: $(cat "$CASE/watch.out")"
  out=$(cat "$CASE/watch.out")
  assert_contains "$out" "check: sandbox $ID credential refresh failed: the GitHub App configuration" \
    "the wake names the task and why its refresh failed"
  assert_contains "$out" "its current GitHub token expires at $expires" "the wake names the expiry"
  [ "$(check_wakes "cred-refresh-$ID-0123456789ab")" -eq 1 ] || fail "the failed refresh did not queue exactly one keyed wake"
  grep -q " refresh github task=$ID result=failed reason=mint alerted=yes$" "$STATE/cred-ledger" \
    || fail "the failure is not recorded in the ledger: $(cat "$STATE/cred-ledger")"
  assert_absent "$CASE/curl.log" "a refresh without a GitHub App configuration made a request"
  ack_stopped_cycle "$STATE" || fail "could not acknowledge the refresh wake"

  # The same token's failure never wakes again while its retry waits.
  watch_round run 4 || fail "a repeated refresh failure woke the watcher again: $(cat "$CASE/watch.out")"
  [ "$(check_wakes "cred-refresh-$ID-")" -eq 0 ] || fail "a repeated refresh failure queued another wake"
  assert_no_local_reads "the credential refresh"
  pass "a sandbox task's failed GitHub token refresh wakes the watcher once per token"
}

# --- the steering re-ring ladder ------------------------------------------------

test_the_ladder_rings_through_the_host_and_escalates() {
  local out
  new_case ladder
  : > "$CASE/host/churn"
  observe_as alive busy '' 001.msg $(( $(date +%s) - 600 ))
  FM_TEST_INBOX_GRACE=1 watch_observes 3 || fail "a busy worker's waiting steer woke the watcher: $(cat "$CASE/watch.out")"
  assert_equals 0 "$(host_calls ring)" "a busy worker's doorbell was rung"

  observe_as alive idle '' 001.msg $(( $(date +%s) - 600 ))
  FM_TEST_INBOX_GRACE=1 watch_round exit || fail "a spent ring budget never escalated: $(cat "$CASE/watch.out")"
  out=$(cat "$CASE/watch.out")
  assert_equals 2 "$(host_calls ring)" "the ladder rang the host's doorbell its whole budget"
  assert_grep "001.msg" "$CASE/host/rings" "the ring names the oldest unacknowledged record"
  assert_contains "$out" "stale: $WINDOW (unread firstmate instruction: 001.msg in its sandbox inbox on alias-$ID still unhandled after 2 doorbell delivery attempts" \
    "a spent budget escalates through the ordinary stale reason"
  ack_stopped_cycle "$STATE" || fail "could not acknowledge the escalation"
  FM_TEST_INBOX_GRACE=1 watch_observes 2 || fail "an escalated record escalated again: $(cat "$CASE/watch.out")"
  [ "$(stale_wakes)" -eq 0 ] || fail "an escalated record queued another wake"

  # A newer oldest record with a gone agent escalates at once, untyped.
  observe_as missing dead '' 002.msg $(( $(date +%s) - 600 ))
  FM_TEST_INBOX_GRACE=1 watch_round exit || fail "a steer to a gone agent never escalated: $(cat "$CASE/watch.out")"
  assert_contains "$(cat "$CASE/watch.out")" "002.msg in its sandbox inbox on alias-$ID is unhandled and the worker's agent has exited or its endpoint is missing" \
    "a gone agent's steer escalates without a ring"
  assert_equals 2 "$(host_calls ring)" "a gone agent's doorbell was rung"
  assert_no_local_reads "the ladder"
  pass "the re-ring ladder rings through the host, waits on a busy worker, and escalates a spent budget or a gone agent"
}

# --- the wedge timer reads the host's worktree writes -----------------------------

test_the_wedge_timer_reads_the_hosts_worktree_writes() {
  local out
  new_case wedge
  observe_as alive idle '' none none @NOW@
  FM_FAKE_CREW_STATE='state: working · source: run-step · ci running' FM_TEST_STALE_ESCALATE=1 \
    watch_observes 5 || fail "a provably working pane writing its worktree escalated: $(cat "$CASE/watch.out")"
  [ "$(stale_wakes)" -eq 0 ] || fail "a pane writing its worktree on its host queued a wake"
  assert_present "$STATE/.writing-since-$KEY" "the deferral did not read the host's worktree write"

  observe_as alive idle '' none none none
  FM_FAKE_CREW_STATE='state: working · source: run-step · ci running' FM_TEST_STALE_ESCALATE=1 \
    watch_round exit || fail "a provably working pane that writes nothing never escalated: $(cat "$CASE/watch.out")"
  out=$(cat "$CASE/watch.out")
  assert_contains "$out" "stale: $WINDOW (idle" "the escalation names the sandbox window"
  assert_contains "$out" "possible wedge" "a quiet provably working pane is a wedge suspect"
  assert_no_local_reads "the wedge timer"
  pass "the wedge timer defers on the host's worktree writes and escalates a pane that writes nothing"
}

test_observation_rides_its_own_cadence
test_an_unchanging_observed_pane_surfaces_as_stale
test_a_gone_agent_is_reported_once_per_incarnation
test_no_observation_while_a_lifecycle_action_holds_the_task
test_observation_discarded_when_lifecycle_changes
test_an_unreachable_host_is_reported_once_per_streak
test_the_ladder_rings_through_the_host_and_escalates
test_the_wedge_timer_reads_the_hosts_worktree_writes
test_a_failed_credential_refresh_wakes_once
echo "ALL TESTS PASSED"

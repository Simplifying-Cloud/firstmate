#!/usr/bin/env bash
# tests/fm-teardown-remote-task.test.sh - bin/fm-teardown.sh's sandbox task
# branch: a placed ship or scout torn down from its primary home, where
# destroying the sandbox is the teardown and the landed-work gate stands in
# front of that destroy.
#
# The harness is the placement suite's (tests/fm-remote-task-spawn.test.sh): a
# real supervising home with a markdown backlog, a registered project with a
# file:// origin, a brief rendered by the real fm-brief.sh for the sandbox
# home, and spawn and teardown run from a committed copy of this checkout. The
# fake provider keeps its sandboxes as small state files, answers create,
# status, list, extend, exec, and destroy with their labels, enforces destroy's
# label confirmation, records whether the task record still existed when a
# destroy ran, and takes per-case failure switches. The fake ssh is
# bin/fm-on.sh's FM_SSH_BIN seam: it runs the named command from the code root
# against the sandbox home under an empty environment, with fake tmux,
# treehouse, Pi, gh, and no-mistakes first on PATH, so the host's retire is the
# real bin/fm-remote-task-control.sh running the host's real fm-teardown.sh and
# its landed-work test. FM_FAKE_SSH_MODE makes the retire unreachable (exit 255
# before it runs) or lost (exit 255 after it ran). A tripwire tmux on the
# supervising side records any local call.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
unset TASKS_AXI_BACKEND || :

TMP_ROOT=$(fm_test_tmproot fm-teardown-remote-task)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
RUN_ID=$$

# Host-side spawns stage per-task temp roots at /tmp/fm-<id>, outside every
# fixture, so task ids carry this run's id and the roots are removed here.
cleanup() {
  rm -rf /tmp/fm-rtt-*-"$RUN_ID" /tmp/fm-rtt-*-"$RUN_ID"+* 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

# --- shared fixtures -----------------------------------------------------------

CODE_ROOT="$TMP_ROOT/code-root"
mkdir -p "$CODE_ROOT"
(cd "$ROOT" && tar --exclude=.git --exclude=.no-mistakes --exclude=data --exclude=state \
  --exclude=config --exclude=projects -cf - .) | (cd "$CODE_ROOT" && tar -xf -)
git -C "$CODE_ROOT" init -q -b main
git -C "$CODE_ROOT" add -A
git -C "$CODE_ROOT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'code root fixture'
SPAWN="$CODE_ROOT/bin/fm-spawn.sh"
BRIEF="$CODE_ROOT/bin/fm-brief.sh"
TEARDOWN="$CODE_ROOT/bin/fm-teardown.sh"

ORIGIN="$TMP_ROOT/alpha.git"
fm_git_init_commit "$TMP_ROOT/alpha-seed"
git init -q --bare "$ORIGIN"
git -C "$TMP_ROOT/alpha-seed" push -q "$ORIGIN" HEAD:refs/heads/main
git --git-dir="$ORIGIN" symbolic-ref HEAD refs/heads/main

CREDS="$TMP_ROOT/creds"
mkdir -p "$CREDS"
(umask 077; printf 'sk-TEARDOWNPISECRET%sx' "$RUN_ID" > "$CREDS/minimax.key")

LOCAL_BIN="$TMP_ROOT/local-bin"
mkdir -p "$LOCAL_BIN"
cat > "$LOCAL_BIN/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_LOCAL_TMUX_LOG:?}"
exit 1
SH
# The supervising home's tasks-axi, whose `done` fails while the case's switch
# file exists, so a backlog close and its replay can fail on demand.
REAL_TASKS_AXI=$(command -v tasks-axi)
export REAL_TASKS_AXI
cat > "$LOCAL_BIN/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = done ] && [ -f "${FM_FAKE_TASKS_AXI_FAIL:-/nonexistent}" ]; then
  echo "error: the backlog file could not be written" >&2
  exit 1
fi
exec "$REAL_TASKS_AXI" "$@"
SH
chmod +x "$LOCAL_BIN/tmux" "$LOCAL_BIN/tasks-axi"

PROVIDER_DIR="$TMP_ROOT/provider"
mkdir -p "$PROVIDER_DIR"
PROVIDER="$PROVIDER_DIR/pve-sandbox"
cat > "$PROVIDER" <<'SH'
#!/usr/bin/env bash
set -u
d=${FM_FAKE_PROVIDER_STATE:?}
printf '%s\n' "$*" >> "$d/argv.log"
record() { # <name>
  local id home
  read -r id home < "$d/vm.$1"
  printf 'name=%s state=running fm_task=%s fm_home=%s hold=yes\n' "$1" "$id" "$home"
}
case "${1:-}" in
  create)
    id=$2
    shift 2
    home= profile=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --home) home=$2; shift 2 ;;
        --profile) profile=$2; shift 2 ;;
        --ttl) shift 2 ;;
        *) exit 64 ;;
      esac
    done
    printf '%s %s\n' "$id" "$home" > "$d/vm.sbx-$id"
    printf 'name=sbx-%s vmid=101 node=pve1 ssh_alias=alias-%s user=agent profile=%s ttl_expires=2026-10-05T12:00:00Z hostkey=pinned\n' \
      "$id" "$id" "$profile"
    ;;
  status)
    [ ! -f "$d/fail-status" ] || { echo "the cluster API is unreachable" >&2; exit 1; }
    [ ! -f "$d/invalid-status" ] || { printf 'state=unknown\n'; exit 0; }
    if [ -f "$d/vm.$2" ]; then
      record "$2"
    else
      printf 'name=%s state=absent\n' "$2"
    fi
    ;;
  list)
    [ ! -f "$d/fail-list" ] || { echo "the cluster API is unreachable" >&2; exit 1; }
    for vm in "$d"/vm.*; do
      [ -f "$vm" ] || continue
      record "${vm##*/vm.}"
    done
    ;;
  extend)
    [ ! -f "$d/fail-extend" ] || { echo "the cluster API refused the extension" >&2; exit 1; }
    ;;
  exec)
    shift 3
    case "$*" in *' pull '*) exit 0 ;; esac
    exec "$@"
    ;;
  destroy)
    name=$2 expect=$4 home=$6
    if [ -e "${FM_FAKE_PRIMARY_META:?}" ]; then echo present; else echo absent; fi >> "$d/destroy-saw-record.log"
    [ ! -f "$d/fail-destroy" ] || { echo "the cluster API timed out" >&2; exit 1; }
    if [ -f "$d/vm.$name" ]; then
      read -r id vmhome < "$d/vm.$name"
      [ "$id" = "$expect" ] && [ "$vmhome" = "$home" ] \
        || { echo "label mismatch: $name is fm_task=$id" >&2; exit 1; }
      rm -f "$d/vm.$name"
    fi
    printf '%s\n' "$name" >> "$d/destroyed.log"
    ;;
  *) exit 64 ;;
esac
SH
chmod +x "$PROVIDER"

HOST_BIN="$TMP_ROOT/host-bin"
mkdir -p "$HOST_BIN"
fm_fake_exit0 "$HOST_BIN" treehouse
cat > "$HOST_BIN/pi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --help) printf '%s\n' '--approve' ;;
  --version) printf 'fake-pi\n' ;;
esac
SH
cat > "$HOST_BIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
# No forge on the sandbox host: a PR lookup fails rather than reaching a network.
# gh only stores a provisioned token, reads it back, and answers the
# installation-token revoke retire makes, which it records in ../gh.revokes.
printf '#!/usr/bin/env bash\nexit 1\n' > "$HOST_BIN/gh-axi"
cat > "$HOST_BIN/gh" <<'SH'
#!/usr/bin/env bash
store="$HOME/.config/gh"
case "$*" in
  "auth login --hostname github.com --git-protocol https --insecure-storage --with-token")
    mkdir -p "$store" && cat > "$store/hosts.yml" ;;
  "auth token --hostname github.com") cat "$store/hosts.yml" 2>/dev/null ;;
  "api --method DELETE /installation/token --include")
    printf 'revoke\n' >> "$HOME/../gh.revokes"
    code=$(cat "$HOME/../gh-revoke-status" 2>/dev/null || echo 204)
    printf 'HTTP/2.0 %s Response\r\n\r\n' "$code"
    [ "$code" = 204 ] || exit 1
    ;;
  *) exit 1 ;;
esac
SH
cat > "$HOST_BIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
d=${FM_FAKE_TMUX_DIR:?}
printf '%s\n' "$*" >> "$d/log"
case "$*" in
  *"#{pane_current_path}"*) cat "$d/pane-path" 2>/dev/null; exit 0 ;;
  *"#{pane_tty}"*) printf '\n'; exit 0 ;;
  *"#{pane_current_command}"*) cat "$d/pane-command" 2>/dev/null || printf 'claude\n'; exit 0 ;;
  *"#{pane_id}"*) printf '%%1\n'; exit 0 ;;
  *"#{cursor_y}"*) printf '0\n'; exit 0 ;;
esac
case "${1:-}" in
  list-sessions)
    [ -f "$d/server" ] || { echo "no server running on $d/socket" >&2; exit 1; }
    printf 'firstmate: 1 windows\n'
    ;;
  has-session) [ -f "$d/server" ] ;;
  new-session) : > "$d/server" ;;
  show-environment)
    [ -f "$d/env.${3:-}" ] || { echo "unknown variable: ${3:-}" >&2; exit 1; }
    printf '%s=%s\n' "$3" "$(cat "$d/env.$3")"
    ;;
  list-windows)
    [ -f "$d/server" ] || { echo "no server running on $d/socket" >&2; exit 1; }
    [ -f "$d/window" ] || exit 0
    case "$*" in
      *'#{session_name}:#{window_name}'*) printf 'firstmate:%s\n' "$(cat "$d/window")" ;;
      *) cat "$d/window" ;;
    esac
    ;;
  new-window)
    : > "$d/server"
    while [ "$#" -gt 0 ]; do
      case "$1" in -n) shift; printf '%s\n' "$1" > "$d/window" ;; esac
      shift
    done
    printf '@1\n'
    ;;
  kill-window) rm -f "$d/window" ;;
  capture-pane) cat "$d/pane" 2>/dev/null || printf 'fake pane line\n' ;;
  display-message) printf 'firstmate\n' ;;
  send-keys)
    case "$*" in
      *"/launch."*)
        printf 'pi\n' > "$d/pane-command"
        if [[ "$*" =~ (/tmp/fm-[^\'[:space:]]+)/launch\.([^\'[:space:]]+)\.sh ]]; then
          printf 'agent-start\n' > "${BASH_REMATCH[1]}/pi-start.${BASH_REMATCH[2]}.ready"
        fi
        ;;
    esac
    ;;
esac
exit 0
SH
chmod +x "$HOST_BIN/pi" "$HOST_BIN/no-mistakes" "$HOST_BIN/gh" "$HOST_BIN/gh-axi" "$HOST_BIN/tmux"

cat > "$LOCAL_BIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
set -u
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
host=$1 entry=$2
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
root=$(printf '%s' "$4" | base64 --decode)
home=$(printf '%s' "$5" | base64 --decode)
args=()
while IFS= read -r -d '' arg; do args+=("$arg"); done < <(printf '%s' "$6" | base64 --decode)
cmd=${args[0]}
verb=${args[1]:-}
printf '%s %s %s\n' "$host" "$cmd" "$verb" >> "$FM_FAKE_SSH_LOG"
[ "$host" = "$FM_FAKE_SSH_HOST" ] || { echo "ssh: Could not resolve hostname $host" >&2; exit 255; }
if [ "$cmd" = fm-remote-doctor.sh ]; then
  printf 'check harness=ok: pi\nok: task readiness confirmed on this host\n'
  exit 0
fi
mode=${FM_FAKE_SSH_MODE:-normal}
if [ "$mode:$verb" = retire-unreachable:retire ]; then
  echo "ssh: connect to host $host port 22: Connection timed out" >&2
  exit 255
fi
if [ "$cmd" = fm-remote-task-control.sh ] && [ "$verb" = launch ] && [ ! -d "$FM_FAKE_HOST_DIR/wt" ]; then
  # Stand in for treehouse: the slot the host's spawn adopts from the pane.
  git -C "$home/projects/alpha" worktree add -q --detach "$FM_FAKE_HOST_DIR/wt" >/dev/null 2>&1 || exit 93
  printf '%s\n' "$FM_FAKE_HOST_DIR/wt" > "$FM_FAKE_HOST_DIR/tmux/pane-path"
fi
env -i PATH="$FM_FAKE_HOST_BIN:$PATH" HOME="$FM_FAKE_HOST_DIR/account" \
  TMPDIR="$FM_FAKE_HOST_DIR/tmp" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" CLAUDE_CONFIG_DIR= \
  FM_FAKE_TMUX_DIR="$FM_FAKE_HOST_DIR/tmux" FM_GATE_REFUSE_BYPASS=1 FM_TEST_SEAM=1 \
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  "$root/bin/$cmd" "${args[@]:1}"
rc=$?
[ "$mode:$verb" != retire-lost:retire ] || exit 255
exit "$rc"
SH
chmod +x "$LOCAL_BIN/fake-ssh"

# --- per-case homes --------------------------------------------------------------

# new_case <name> [kind]: a supervising home with one registered project, a
# configured provider whose sandbox home is this case's, a markdown backlog
# holding the task, and a fresh sandbox host. Sets CASE, ID, PRIMARY, HOST_DIR,
# HOST_HOME, CLAIMS, SID, and NAME.
new_case() {
  local name=$1 kind=${2:-ship}
  CASE="$TMP_ROOT/$name"
  ID="rtt-$name-$RUN_ID"
  PRIMARY="$CASE/primary"
  HOST_DIR="$CASE/host"
  HOST_HOME="$HOST_DIR/fm-home"
  CLAIMS="$CASE/claims"
  SID="remote-reply-$ID"
  NAME="sbx-$ID"
  mkdir -p "$PRIMARY/data" "$PRIMARY/state" "$PRIMARY/config" "$PRIMARY/projects" \
    "$HOST_DIR/tmp" "$HOST_DIR/tmux" "$HOST_DIR/account" "$CASE/provider" "$CLAIMS"
  git clone -q "file://$ORIGIN" "$PRIMARY/projects/alpha"
  printf '%s\n' '- alpha [direct-PR] - alpha fixture (added 2026-10-01)' > "$PRIMARY/data/projects.md"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$PRIMARY/data/backlog.md"
  printf '%s\n' 'backend = "markdown"' '' '[markdown]' 'path = "data/backlog.md"' > "$PRIMARY/.tasks.toml"
  tasks-axi add "$ID" "sandbox teardown fixture $name" --kind "$kind" --file "$PRIMARY/data/backlog.md" >/dev/null \
    || fail "could not file the backlog item for $ID"
  printf '%s\n' "$PROVIDER" default_profile=default ttl=4h "ssh_include=$TMP_ROOT/ssh-include" \
    > "$PRIMARY/config/sandbox-provider"
  printf 'minimax  pi:minimax  %s\n' "$CREDS/minimax.key" > "$PRIMARY/config/sandbox-credentials"
  fm_test_track_procevent_home "$PRIMARY" "$CLAIMS"
}

sandbox_brief() { # [fm-brief args...]
  local file content
  FM_HOME="$PRIMARY" "$BRIEF" "$ID" alpha "$@" --for-home "$HOST_HOME" --for-root "$CODE_ROOT" >/dev/null \
    || fail "fm-brief.sh could not render the brief for $ID"
  file="$PRIMARY/data/$ID/brief.md"
  content=$(cat "$file")
  content=${content//'{TASK}'/Make the sandbox change.}
  content=${content//'{FIRSTMATE_SPEC}'/Build only what the intent asks.}
  printf '%s\n' "$content" > "$file"
}

primary_env() {
  env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    -u FM_BACKEND -u FM_ROOT_OVERRIDE -u TRACEPARENT -u TMUX -u TMUX_PANE \
    FM_HOME="$PRIMARY" FM_SPAWN_NO_GUARD=1 FM_TEARDOWN_GUARD_DONE=1 FM_TEST_SEAM=1 \
    FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
    FM_TEST_SANDBOX_ROOT="$CODE_ROOT" FM_TEST_SANDBOX_HOME="$HOST_HOME" PATH="$LOCAL_BIN:$PATH" \
    FM_SSH_BIN="$LOCAL_BIN/fake-ssh" FM_FAKE_SSH_HOST="alias-$ID" FM_FAKE_SSH_LOG="$CASE/ssh.log" \
    FM_FAKE_SSH_MODE="${SSH_MODE:-normal}" FM_FAKE_HOST_DIR="$HOST_DIR" FM_FAKE_HOST_BIN="$HOST_BIN" \
    FM_FAKE_PROVIDER_STATE="$CASE/provider" FM_FAKE_PRIMARY_META="$PRIMARY/state/$ID.meta" \
    FM_FAKE_LOCAL_TMUX_LOG="$CASE/local-tmux.log" FM_REMOTE_REPLY_WAIT_SECONDS=5 \
    FM_FAKE_TASKS_AXI_FAIL="$CASE/fail-tasks-axi-done" \
    "$@"
}

run_spawn() { # <spawn args...>; sets OUT and RC
  OUT=$(primary_env "$SPAWN" "$@" 2>&1)
  RC=$?
}

# place_ship / place_scout: a launched sandbox task with its mirror armed.
place_ship() {
  new_case "$1"
  sandbox_brief --mode direct-PR
  run_spawn "$ID" "$PRIMARY/projects/alpha" --mode direct-PR --yolo off --harness pi --model minimax/m2 --placement sandbox
  expect_code 0 "$RC" "a sandbox ship should launch"$'\n'"$OUT"
  assert_present "$PRIMARY/state/procevent/$SID.source" "spawn arms the status mirror"
}

place_scout() {
  new_case "$1" scout
  sandbox_brief --scout
  run_spawn "$ID" "$PRIMARY/projects/alpha" --scout --harness pi --model minimax/m2 --placement sandbox
  expect_code 0 "$RC" "a sandbox scout should launch"$'\n'"$OUT"
}

# start_mirror: run the armed status mirror's listener the way the watcher's
# reconcile launches it, mirror one worker line through it, and set MIRROR_PID.
start_mirror() {
  primary_env "$CODE_ROOT/bin/fm-procevent.sh" start "$SID" > "$CASE/runner.out" 2>&1 &
  MIRROR_PID=$!
  for _ in $(seq 1 200); do
    [ -f "$CLAIMS/$SID.claim" ] && break
    sleep 0.05
  done
  [ -f "$CLAIMS/$SID.claim" ] || fail "the status mirror's listener never claimed $SID: $(cat "$CASE/runner.out")"
  printf '%s\n' "working [at=1700000000]: making the sandboxed change" >> "$HOST_HOME/state/$ID.status"
  for _ in $(seq 1 400); do
    grep -qF 'making the sandboxed change' "$PRIMARY/state/$ID.status" 2>/dev/null && return 0
    sleep 0.05
  done
  fail "the worker's line never mirrored: $(cat "$CASE/runner.out")"
}

# session_start: bootstrap's local phase, which replays a recorded backlog
# close, then its deferred network phase, which retries an owed destroy, as a
# session start runs them. Sets OUT to both phases' output.
session_start() {
  local fakebin="$CASE/bootstrap-bin"
  mkdir -p "$fakebin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/gh"
  chmod +x "$fakebin/gh"
  OUT=$(PATH="$fakebin:$PATH" primary_env env FM_BOOTSTRAP_NETWORK=skip "$CODE_ROOT/bin/fm-bootstrap.sh" 2>&1)
  OUT=$OUT$'\n'$(PATH="$fakebin:$PATH" primary_env env FM_BOOTSTRAP_NETWORK=only "$CODE_ROOT/bin/fm-bootstrap.sh" 2>&1)
}

run_teardown() { # [teardown args...]; sets OUT and RC
  OUT=$(primary_env "$TEARDOWN" "$ID" "$@" 2>&1)
  RC=$?
}

# The worker lands its change: a commit pushed to the project's origin.
land_work() {
  printf 'landed\n' > "$HOST_DIR/wt/landed.txt"
  git -C "$HOST_DIR/wt" add landed.txt
  git -C "$HOST_DIR/wt" -c user.name='Sandbox Worker' -c user.email='worker@example.invalid' \
    -c core.hooksPath=/dev/null commit -qm 'the sandboxed change' || fail "could not commit the worker's change"
  git -C "$HOST_DIR/wt" push -q origin "HEAD:refs/heads/fm/$ID" || fail "could not push the worker's change"
}

row_state() {
  tasks-axi show "$ID" --file "$PRIMARY/data/backlog.md" 2>/dev/null | sed -n 's/^  state: *//p' | head -1
}

destroy_calls() {
  grep -c '^destroy ' "$CASE/provider/argv.log" 2>/dev/null || true
}

host_retires() {
  grep -c "^alias-$ID fm-remote-task-control.sh retire$" "$CASE/ssh.log" 2>/dev/null || true
}

# Everything a refused or uncertain teardown must leave exactly as it was.
assert_preserved() { # <label>
  assert_present "$PRIMARY/state/$ID.meta" "$1: the task record was removed"
  assert_present "$CASE/provider/vm.$NAME" "$1: the sandbox was destroyed"
  assert_equals 0 "$(destroy_calls)" "$1: the provider was asked to destroy the sandbox"
  assert_equals in_flight "$(row_state)" "$1: the backlog item moved"
  assert_absent "$PRIMARY/state/$ID.sandbox-destroy-pending" "$1: a destroy was recorded as owed"
  assert_absent "$PRIMARY/state/$ID.backlog-close" "$1: a backlog close was recorded"
}

# --- a ship -----------------------------------------------------------------------

test_unlanded_ship_refusal_keeps_the_sandbox() {
  place_ship unlanded
  printf 'unlanded\n' > "$HOST_DIR/wt/work-in-progress"
  run_teardown
  [ "$RC" -ne 0 ] || fail "teardown of an unlanded sandbox ship was accepted"$'\n'"$OUT"
  assert_contains "$OUT" "has uncommitted changes" "the host's landed-work refusal is relayed"
  assert_contains "$OUT" "host refused its teardown, so its sandbox $NAME and hold label are kept" \
    "the primary refuses with the host's reason"
  assert_preserved "an unlanded ship"
  assert_present "$HOST_HOME/state/$ID.meta" "the host's refusal kept the host's task record"
  assert_present "$HOST_DIR/wt/work-in-progress" "the unlanded work is still in the sandbox"
  assert_present "$PRIMARY/state/procevent/$SID.source" "the refused teardown re-armed the status mirror"
  assert_equals 1 "$(host_retires)" "the host's retire ran once"
  assert_absent "$CASE/local-tmux.log" "a sandbox teardown touched local tmux"
  pass "an unlanded sandbox ship is refused with the host's reason, keeping the sandbox, records, and mirror"
}

test_landed_ship_destroys_exactly_once_after_its_records() {
  local tag
  place_ship landed
  start_mirror
  land_work
  run_teardown
  expect_code 0 "$RC" "teardown of a landed sandbox ship"$'\n'"$OUT"
  # The live listener stops with its source, and nothing it reads afterwards
  # re-creates the retired status log or reports a broken stream.
  for _ in $(seq 1 400); do
    kill -0 "$MIRROR_PID" 2>/dev/null || break
    sleep 0.05
  done
  ! kill -0 "$MIRROR_PID" 2>/dev/null || fail "the status mirror's listener outlived teardown: $(cat "$CASE/runner.out")"
  assert_absent "$PRIMARY/state/$ID.status" "the retired status log was re-created after teardown"
  assert_absent "$CLAIMS/$SID.claim" "the status mirror's claim outlived teardown"
  assert_contains "$OUT" "teardown $ID complete (sandbox $NAME destroyed)" "teardown reports the destroy"
  tag=$(grep '^create ' "$CASE/provider/argv.log" | sed -n 's/.* --home \([^ ]*\) .*/\1/p' | head -1)
  [ -n "$tag" ] || fail "the provider never saw this home's tag at create"
  assert_equals 1 "$(destroy_calls)" "the sandbox was not destroyed exactly once"
  assert_grep "destroy $NAME --expect-task $ID --home $tag" "$CASE/provider/argv.log" \
    "the destroy did not confirm the task and home labels"
  grep -n '' "$CASE/provider/argv.log" | grep -E '^[0-9]+:(list|destroy) ' | head -1 | grep -q ':list ' \
    || fail "the inventory was not read before the destroy: $(cat "$CASE/provider/argv.log")"
  assert_equals absent "$(cat "$CASE/provider/destroy-saw-record.log")" \
    "the sandbox was destroyed while its task record still existed"
  assert_absent "$CASE/provider/vm.$NAME" "the sandbox still exists"
  assert_absent "$PRIMARY/state/$ID.meta" "the task record survived teardown"
  assert_equals "done" "$(row_state)" "the backlog item was not closed"
  assert_absent "$PRIMARY/state/$ID.sandbox-destroy-pending" "a completed destroy left its pending record"
  assert_absent "$PRIMARY/state/procevent/$SID.source" "the status mirror source survived teardown"
  assert_absent "$PRIMARY/state/remote-replies/$ID.cursor" "the status mirror cursor survived teardown"
  assert_present "$HOST_HOME/state/$ID.retired" "the host recorded no retirement"
  assert_absent "$HOST_HOME/state/$ID.meta" "the host's task record survived its retire"

  run_teardown
  [ "$RC" -ne 0 ] || fail "a second teardown of a torn-down task was accepted"
  assert_equals 1 "$(destroy_calls)" "a second teardown destroyed again"
  assert_absent "$CASE/local-tmux.log" "a sandbox teardown touched local tmux"
  pass "a landed sandbox ship is retired on its host, then its sandbox destroyed once with label confirmation after its records"
}

test_landed_ship_records_its_hosts_app_token_revoke() {
  local fp hit closure=${1:-revoked}
  new_case "app-revoke-$closure"
  APP_TOKEN="ghs_TEARDOWNAPP${RUN_ID}$(printf 'Ab9_%.0s' $(seq 1 100))"
  (umask 077; printf '%s\n' "$APP_TOKEN" > "$CREDS/app-$RUN_ID.token")
  printf 'gh-app  github  %s\n' "$CREDS/app-$RUN_ID.token" >> "$PRIMARY/config/sandbox-credentials"
  sandbox_brief --mode direct-PR
  run_spawn "$ID" "$PRIMARY/projects/alpha" --mode direct-PR --yolo off --harness pi --model minimax/m2 --placement sandbox
  expect_code 0 "$RC" "a sandbox ship holding an App token should launch"$'\n'"$OUT"
  land_work
  printf '502\n' > "$HOST_DIR/gh-revoke-status"
  run_teardown
  [ "$RC" -ne 0 ] || fail "unconfirmed revocation completed teardown"
  assert_equals 0 "$(destroy_calls)" "failed revocation preserves the sandbox"
  assert_absent "$HOST_HOME/state/$ID.retired" "failed revocation leaves retirement open"
  assert_contains "$(tail -n 1 "$PRIMARY/state/cred-ledger")" 'result=failed via=host' "the supervisor records failed revocation"
  if [ "$closure" = expired ]; then
    fp=$(printf '%s' "$APP_TOKEN" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-12)
    printf '1 mint github task=%s fp=%s expires=2000-01-01T00:00:00Z\n' "$ID" "$fp" >> "$PRIMARY/state/cred-ledger"
  else
    printf '204\n' > "$HOST_DIR/gh-revoke-status"
  fi
  run_teardown
  expect_code 0 "$RC" "teardown of a landed sandbox ship"$'\n'"$OUT"
  fp=$(printf '%s' "$APP_TOKEN" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-12)
  assert_equals 2 "$(grep -c . "$HOST_DIR/gh.revokes")" "the host retries an unconfirmed revoke"
  grep -Eq "^[0-9]+ revoke github task=$ID fp=$fp result=$closure via=host$" "$PRIMARY/state/cred-ledger" \
    || fail "this home's credential ledger does not record the host's revoke: $(cat "$PRIMARY/state/cred-ledger" 2>/dev/null)"
  case "$OUT" in *"$APP_TOKEN"*) fail "teardown output holds the App token" ;; esac
  hit=$(grep -rlF "$APP_TOKEN" "$PRIMARY" "$HOST_HOME" "$CASE/ssh.log" 2>/dev/null || true)
  [ -z "$hit" ] || fail "the App token was written to $hit"
  assert_equals 1 "$(destroy_calls)" "the sandbox was destroyed exactly once"
  pass "a landed ship's host revokes its stored App token and teardown records it in the credential ledger"
}

test_ssh_255_preserves_everything_until_a_rerun() {
  place_ship unreachable
  land_work
  SSH_MODE=retire-unreachable run_teardown
  expect_code 255 "$RC" "an unreachable host's retire"$'\n'"$OUT"
  assert_contains "$OUT" "unknown completion (SSH exit 255)" "the uncertain outcome is named"
  assert_preserved "an unreachable host"
  assert_present "$HOST_HOME/state/$ID.meta" "the host's record changed although its retire never ran"

  # The host retired but its answer was lost: still unknown here.
  SSH_MODE=retire-lost run_teardown
  expect_code 255 "$RC" "a lost retire answer"$'\n'"$OUT"
  assert_preserved "a lost retire answer"
  assert_present "$HOST_HOME/state/$ID.retired" "the lost retire did not run on the host"

  # The rerun meets the host's retirement record and finishes.
  run_teardown
  expect_code 0 "$RC" "the rerun after a lost answer"$'\n'"$OUT"
  assert_equals 1 "$(destroy_calls)" "the rerun did not destroy the sandbox exactly once"
  assert_absent "$PRIMARY/state/$ID.meta" "the rerun left the task record"
  assert_equals "done" "$(row_state)" "the rerun did not close the backlog item"
  pass "SSH exit 255 preserves the sandbox, records, and backlog, and a rerun finishes after the host retired"
}

test_force_destroys_without_the_landed_proof() {
  place_ship forced
  printf 'unlanded\n' > "$HOST_DIR/wt/work-in-progress"
  run_teardown --legacy-record
  [ "$RC" -ne 0 ] || fail "--legacy-record was accepted for a sandbox task"
  assert_contains "$OUT" "--legacy-record applies only to a local task record" "the legacy flag refusal is named"
  # A record its launch never finished publishing names no incarnation to close.
  cp "$PRIMARY/state/$ID.meta" "$CASE/final.meta"
  grep -v '^spawn_gen=' "$CASE/final.meta" > "$PRIMARY/state/$ID.meta"
  run_teardown --force
  [ "$RC" -ne 0 ] || fail "a record whose launch never published was torn down"
  assert_contains "$OUT" "its launch never published a final record" "the unpublished record is named"
  assert_preserved "an unpublished record under --force"
  cp "$CASE/final.meta" "$PRIMARY/state/$ID.meta"

  run_teardown --force
  expect_code 0 "$RC" "a forced teardown of an unlanded sandbox ship"$'\n'"$OUT"
  assert_equals 0 "$(host_retires)" "a forced teardown still ran the host's landed-work retire"
  assert_equals 1 "$(destroy_calls)" "a forced teardown did not destroy the sandbox exactly once"
  assert_absent "$CASE/provider/vm.$NAME" "a forced teardown left the sandbox"
  assert_absent "$PRIMARY/state/$ID.meta" "a forced teardown left the task record"
  assert_equals "done" "$(row_state)" "a forced teardown did not close the backlog item"
  pass "--force destroys a sandbox without the landed proof, but never a record no launch finished publishing"
}

test_identity_refusals_hold_under_force() {
  place_ship identity
  land_work
  printf 'rtt-other-%s %s\n' "$RUN_ID" "$(cut -d' ' -f2 "$CASE/provider/vm.$NAME")" > "$CASE/provider/vm.$NAME"
  run_teardown
  [ "$RC" -ne 0 ] || fail "a sandbox labelled for another task was torn down"
  assert_contains "$OUT" "is labelled for task rtt-other-$RUN_ID, not $ID" "the label refusal names both tasks"
  run_teardown --force
  [ "$RC" -ne 0 ] || fail "--force destroyed a sandbox labelled for another task"
  assert_preserved "a sandbox labelled for another task"
  assert_equals 0 "$(host_retires)" "a label refusal still reached the host"

  printf '%s %s\n' "$ID" "$(cut -d' ' -f2 "$CASE/provider/vm.$NAME")" > "$CASE/provider/vm.$NAME"
  : > "$CASE/provider/fail-list"
  run_teardown --force
  [ "$RC" -ne 0 ] || fail "--force proceeded without a readable inventory"
  assert_contains "$OUT" "sandbox inventory could not be read (sandbox provider exited 1: the cluster API is unreachable)" \
    "the unreadable inventory is named with the provider's reason"
  assert_preserved "an unreadable inventory"
  rm -f "$CASE/provider/fail-list"

  cp "$CASE/provider/vm.$NAME" "$CASE/vm.owned"
  printf '%s other-home\n' "$ID" > "$CASE/provider/vm.$NAME"
  run_teardown --force
  [ "$RC" -ne 0 ] || fail "--force cleared a sandbox labelled for another home"
  assert_contains "$OUT" "provider status does not confirm absence" "the foreign-home sandbox refuses"
  assert_preserved "a sandbox labelled for another home"
  assert_present "$PRIMARY/state/procevent/$SID.source" "the foreign-home refusal removed the mirror"

  : > "$CASE/provider/fail-status"
  run_teardown --force
  [ "$RC" -ne 0 ] || fail "--force proceeded after a failed provider status"
  assert_contains "$OUT" "status could not be confirmed" "the failed provider lookup is named"
  assert_preserved "a failed provider status"
  rm -f "$CASE/provider/fail-status"

  : > "$CASE/provider/invalid-status"
  run_teardown --force
  [ "$RC" -ne 0 ] || fail "--force proceeded after an invalid provider status"
  assert_preserved "an invalid provider status"
  rm -f "$CASE/provider/invalid-status"

  cp "$CASE/vm.owned" "$CASE/provider/vm.$NAME"
  mv "$CASE/provider/vm.$NAME" "$CASE/vm.gone"
  run_teardown
  [ "$RC" -ne 0 ] || fail "a sandbox missing from the inventory was torn down without --force"
  assert_contains "$OUT" "is not in this home's sandbox inventory" "the missing sandbox is named"
  assert_present "$PRIMARY/state/$ID.meta" "a refused teardown removed the task record"
  run_teardown --force
  expect_code 0 "$RC" "a forced teardown of a record whose sandbox is gone"$'\n'"$OUT"
  assert_contains "$OUT" "was confirmed absent, so nothing was destroyed" "the absent sandbox is reported"
  assert_equals 0 "$(destroy_calls)" "a sandbox missing from the inventory was destroyed anyway"
  assert_absent "$PRIMARY/state/$ID.meta" "the forced teardown left the task record"
  assert_absent "$PRIMARY/state/$ID.sandbox-destroy-pending" "a missing sandbox was recorded as owed a destroy"
  assert_equals "done" "$(row_state)" "confirmed absence did not close the backlog item"
  assert_equals 0 "$(host_retires)" "identity checks or forced cleanup reached the host"
  assert_absent "$PRIMARY/state/procevent/$SID.source" "confirmed absence left the mirror source"
  pass "--force preserves unknown or foreign sandboxes and clears records only after confirmed absence"
}

test_failed_destroy_is_retried_by_session_start() {
  local marker
  place_ship destroy-fails
  land_work
  : > "$CASE/provider/fail-destroy"
  run_teardown
  expect_code 1 "$RC" "a teardown whose destroy failed"$'\n'"$OUT"
  assert_contains "$OUT" "could not be destroyed (sandbox provider exited 1: the cluster API timed out)" \
    "the destroy failure is named with the provider's reason"
  marker="$PRIMARY/state/$ID.sandbox-destroy-pending"
  assert_present "$marker" "a failed destroy left no pending record"
  assert_equals "task_id=$ID"$'\n'"sandbox_name=$NAME" "$(cat "$marker")" "the pending record does not name the owed destroy"
  assert_absent "$PRIMARY/state/$ID.meta" "the passed teardown kept its task record"
  assert_equals "done" "$(row_state)" "the passed teardown did not close the backlog item"
  assert_present "$CASE/provider/vm.$NAME" "the failed destroy removed the sandbox"

  # Session start finishes the owed destroy.
  rm -f "$CASE/provider/fail-destroy"
  session_start
  assert_contains "$OUT" "BOOTSTRAP_INFO: destroyed sandbox $NAME for $ID, which an earlier teardown left pending" \
    "session start did not finish the owed destroy"
  assert_not_contains "$OUT" "SANDBOX_" "session start reported a sandbox problem after finishing the destroy"
  assert_absent "$marker" "the finished destroy left its pending record"
  assert_absent "$CASE/provider/vm.$NAME" "session start did not destroy the sandbox"
  assert_equals 2 "$(destroy_calls)" "the owed destroy was not retried exactly once"
  pass "a failed destroy keeps a pending record that session start retries until the sandbox is gone"
}

# The sandbox is destroyed only after the task's backlog transition lands. Here
# the close fails during teardown, after the record is gone, and again on its
# session-start replay: the sandbox and its owed destroy survive both. Once the
# close can land, the next session start closes the item and then destroys.
test_destroy_waits_for_the_backlog_transition() {
  place_ship backlog-fails
  land_work
  : > "$CASE/fail-tasks-axi-done"
  run_teardown
  expect_code 1 "$RC" "a teardown whose backlog close failed"$'\n'"$OUT"
  assert_contains "$OUT" "backlog item could not be moved atomically (error: the backlog file could not be written)" \
    "the failed backlog close is named"
  assert_absent "$PRIMARY/state/$ID.meta" "the failed close did not remove the record first"
  assert_present "$PRIMARY/state/$ID.backlog-close" "the failed close dropped its pending record"
  assert_present "$PRIMARY/state/$ID.sandbox-destroy-pending" "the passed gate recorded no owed destroy"
  assert_present "$CASE/provider/vm.$NAME" "the sandbox was destroyed before its backlog close landed"
  assert_equals 0 "$(destroy_calls)" "teardown destroyed the sandbox although its backlog close failed"

  session_start
  assert_contains "$OUT" "BACKLOG_RECONCILE: $ID: recorded backlog close could not be replayed" \
    "session start did not report the failed replay"
  assert_contains "$OUT" "SANDBOX_DESTROY_PENDING: $ID: sandbox $NAME waits for the task's backlog transition still pending in state/$ID.backlog-close, so it was kept" \
    "session start did not hold the destroy for the pending backlog close"
  assert_present "$CASE/provider/vm.$NAME" "session start destroyed the sandbox while its backlog close was still pending"
  assert_equals 0 "$(destroy_calls)" "session start asked the provider to destroy before the backlog close landed"
  assert_present "$PRIMARY/state/$ID.sandbox-destroy-pending" "the held destroy lost its pending record"
  assert_equals in_flight "$(row_state)" "the backlog item moved although its close failed"

  rm -f "$CASE/fail-tasks-axi-done"
  session_start
  assert_contains "$OUT" "BOOTSTRAP_INFO: closed the backlog item for $ID" "the replayed close did not land"
  assert_contains "$OUT" "BOOTSTRAP_INFO: destroyed sandbox $NAME for $ID, which an earlier teardown left pending" \
    "the destroy did not follow the landed close"
  assert_equals "done" "$(row_state)" "the replay did not close the backlog item"
  assert_absent "$PRIMARY/state/$ID.backlog-close" "the landed close left its pending record"
  assert_absent "$PRIMARY/state/$ID.sandbox-destroy-pending" "the finished destroy left its pending record"
  assert_absent "$CASE/provider/vm.$NAME" "the sandbox survived its finished destroy"
  assert_equals 1 "$(destroy_calls)" "the sandbox was not destroyed exactly once"
  pass "a sandbox survives a backlog close that fails in teardown and in its replay, and goes once the close lands"
}

# --- a scout ------------------------------------------------------------------------

test_scout_report_and_completion_gates() {
  place_scout scout
  run_teardown
  [ "$RC" -ne 0 ] || fail "a sandbox scout with no report was torn down"
  assert_contains "$OUT" "has no report at $PRIMARY/data/$ID/report.md" "the missing report refuses"
  assert_contains "$OUT" "report could not be fetched from its sandbox" "the failed fetch is named"
  assert_preserved "a scout with no report"

  printf '# Findings\n\nThe cache key omits the locale.\n' > "$HOST_HOME/data/$ID/report.md"
  run_teardown
  [ "$RC" -ne 0 ] || fail "a sandbox scout passed teardown without its completion gate"
  assert_contains "$OUT" "has not passed the captain-call completion gate" "the completion gate refuses"
  cmp -s "$HOST_HOME/data/$ID/report.md" "$PRIMARY/data/$ID/report.md" \
    || fail "teardown did not fetch the scout's report into this home"
  assert_preserved "a scout before its completion gate"

  primary_env "$CODE_ROOT/bin/fm-captain-hold.sh" complete "$ID" --none >/dev/null 2>&1 \
    || fail "could not record the scout's completion inventory"
  run_teardown
  expect_code 0 "$RC" "teardown of a completed sandbox scout"$'\n'"$OUT"
  assert_equals 0 "$(host_retires)" "a scout's teardown ran a retire on its host"
  assert_equals 1 "$(destroy_calls)" "the scout's sandbox was not destroyed exactly once"
  assert_equals absent "$(cat "$CASE/provider/destroy-saw-record.log")" \
    "the scout's sandbox was destroyed while its record still existed"
  assert_absent "$PRIMARY/state/$ID.meta" "the scout's record survived teardown"
  assert_equals "done" "$(row_state)" "the scout's backlog item was not closed"
  assert_present "$PRIMARY/data/$ID/report.md" "teardown removed the scout's report"
  pass "a sandbox scout needs its report locally, fetched when missing, and its completion gate before its sandbox goes"
}

test_unlanded_ship_refusal_keeps_the_sandbox
test_landed_ship_destroys_exactly_once_after_its_records
test_landed_ship_records_its_hosts_app_token_revoke
test_landed_ship_records_its_hosts_app_token_revoke expired
test_ssh_255_preserves_everything_until_a_rerun
test_force_destroys_without_the_landed_proof
test_identity_refusals_hold_under_force
test_failed_destroy_is_retried_by_session_start
test_destroy_waits_for_the_backlog_transition
test_scout_report_and_completion_gates

#!/usr/bin/env bash
# tests/fm-remote-task-spawn.test.sh - sandbox placement in bin/fm-spawn.sh
# (--placement sandbox), end to end through launch.
#
# The supervising home is a real home on this machine: a real markdown backlog
# driven by tasks-axi, a registered project with a file:// origin, a brief
# rendered by the real fm-brief.sh for the sandbox home, and a configured fake
# sandbox provider that records every argv it receives and answers create,
# status, exec, and destroy from a small state directory. Spawn runs from a
# committed copy of this checkout, so bin/fm-on.sh's tracked-command check and
# the default-branch commit the code root converges to are real.
#
# The fake ssh is bin/fm-on.sh's FM_SSH_BIN seam. It decodes the fixed
# entrypoint's protocol arguments and runs the named command from that code
# root against the sandbox home under an empty environment, as the remote job
# worker would, with the sandbox account's HOME and a fake tmux, treehouse, gh,
# and no-mistakes first on PATH. Provisioning and launch are therefore the real
# bin/fm-remote-task-control.sh and the host's real bin/fm-spawn.sh. The
# readiness doctor alone is answered at that boundary, because the real doctor
# would inspect the runner's own account; tests/fm-remote-doctor.test.sh owns
# its behavior. A tripwire tmux on the supervising side records any local call.
#
# The credential cases plant recognizable secret values in 0600 source files
# and search every output channel, both homes, the provision journal, the
# transport and provider logs, the argv of every jq and base64 call, and the
# sandbox host's tmux log and environment for them. The app-source cases mint
# GitHub App installation tokens from tests/fixtures.sh's fake GitHub API with a
# throwaway key, and search the same places for every token it minted.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
unset TASKS_AXI_BACKEND || :

TMP_ROOT=$(fm_test_tmproot fm-remote-task-spawn)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
RUN_ID=$$
GH_SECRET="github_pat_SPAWNGHSECRET${RUN_ID}x"
OTHER_GH_SECRET="github_pat_SPAWNOTHERGH${RUN_ID}x"
PI_SECRET="sk-SPAWNPISECRET${RUN_ID}x"
OTHER_PI_SECRET="sk-SPAWNGLMSECRET${RUN_ID}x"
# Every token the fake GitHub API mints begins with this.
APP_TOKEN_MARK="ghs_SPAWNAPP${RUN_ID}"
export FM_FAKE_GITHUB_TOKEN_TAG="SPAWNAPP${RUN_ID}"

# Host-side spawns stage per-task temp roots at /tmp/fm-<id>, outside every
# fixture, so task ids carry this run's id and the roots are removed here.
cleanup() {
  rm -rf /tmp/fm-rts-*-"$RUN_ID" /tmp/fm-rts-*-"$RUN_ID"+* 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

# --- shared fixtures -----------------------------------------------------------

# The code root: this checkout, committed, so its default branch resolves and
# every command bin/fm-on.sh names is tracked.
CODE_ROOT="$TMP_ROOT/code-root"
mkdir -p "$CODE_ROOT"
(cd "$ROOT" && tar --exclude=.git --exclude=.no-mistakes --exclude=data --exclude=state \
  --exclude=config --exclude=projects -cf - .) | (cd "$CODE_ROOT" && tar -xf -)
git -C "$CODE_ROOT" init -q -b main
git -C "$CODE_ROOT" add -A
git -C "$CODE_ROOT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'code root fixture'
CODE_COMMIT=$(git -C "$CODE_ROOT" rev-parse HEAD)
SPAWN="$CODE_ROOT/bin/fm-spawn.sh"
BRIEF="$CODE_ROOT/bin/fm-brief.sh"

ORIGIN="$TMP_ROOT/alpha.git"
fm_git_init_commit "$TMP_ROOT/alpha-seed"
git init -q --bare "$ORIGIN"
git -C "$TMP_ROOT/alpha-seed" push -q "$ORIGIN" HEAD:refs/heads/main
git --git-dir="$ORIGIN" symbolic-ref HEAD refs/heads/main

CREDS="$TMP_ROOT/creds"
mkdir -p "$CREDS"
(
  umask 077
  printf '%s\n' "$GH_SECRET" > "$CREDS/gh-alpha.token"
  printf '%s\n' "$OTHER_GH_SECRET" > "$CREDS/gh-beta.token"
  printf '%s' "$PI_SECRET" > "$CREDS/minimax.key"
  printf '%s\n' "$OTHER_PI_SECRET" > "$CREDS/glm.key"
)

# Supervising-side tools: a tripwire tmux, and jq and base64 wrappers that log
# their argv so no credential can pass through an argument unseen.
LOCAL_BIN="$TMP_ROOT/local-bin"
mkdir -p "$LOCAL_BIN"
REAL_JQ=$(command -v jq)
REAL_BASE64=$(command -v base64)
export REAL_JQ REAL_BASE64 FM_FAKE_ARGV_LOG="$TMP_ROOT/argv.log"
cat > "$LOCAL_BIN/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_LOCAL_TMUX_LOG:?}"
exit 1
SH
cat > "$LOCAL_BIN/jq" <<'SH'
#!/usr/bin/env bash
printf 'jq %s\n' "$*" >> "$FM_FAKE_ARGV_LOG"
exec "$REAL_JQ" "$@"
SH
cat > "$LOCAL_BIN/base64" <<'SH'
#!/usr/bin/env bash
printf 'base64 %s\n' "$*" >> "$FM_FAKE_ARGV_LOG"
exec "$REAL_BASE64" "$@"
SH
chmod +x "$LOCAL_BIN/tmux" "$LOCAL_BIN/jq" "$LOCAL_BIN/base64"

# The provider: argv-logged, with per-case failure switches in its state dir.
PROVIDER_DIR="$TMP_ROOT/provider"
mkdir -p "$PROVIDER_DIR"
PROVIDER="$PROVIDER_DIR/pve-sandbox"
cat > "$PROVIDER" <<'SH'
#!/usr/bin/env bash
set -u
d=${FM_FAKE_PROVIDER_STATE:?}
printf '%s\n' "$*" >> "$d/argv.log"
case "${1:-}" in
  create)
    [ ! -f "$d/no-capacity" ] || { echo "cluster full" >&2; exit 75; }
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
      "$id" "$id" "$(cat "$d/applied-profile" 2>/dev/null || printf '%s' "$profile")"
    ;;
  status)
    if [ -f "$d/vm.$2" ]; then
      read -r id home < "$d/vm.$2"
      printf 'name=%s state=running fm_task=%s fm_home=%s hold=yes\n' "$2" "$id" "$home"
    else
      printf 'name=%s state=absent\n' "$2"
    fi
    ;;
  exec)
    shift 3
    printf '%s\n' "$*" >> "$d/exec.log"
    [ ! -f "$d/fail-exec" ] || { echo "fatal: Not possible to fast-forward, aborting." >&2; exit 128; }
    if [ -f "$d/code-root" ]; then
      root=$(cat "$d/code-root")
      args=()
      for arg in "$@"; do
        [ "$arg" != "$FM_TEST_SANDBOX_ROOT" ] || arg=$root
        args+=("$arg")
      done
      exec "${args[@]}"
    fi
    case "$*" in *' pull '*) exit 0 ;; esac
    exec "$@"
    ;;
  destroy)
    printf '%s\n' "$2" >> "$d/destroyed.log"
    rm -f "$d/vm.$2"
    ;;
  *) exit 64 ;;
esac
SH
chmod +x "$PROVIDER"

# The sandbox host's tools: the stateful fake tmux and credential fakes the
# host-side control plane suite uses.
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
chmod +x "$HOST_BIN/pi"
cat > "$HOST_BIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  init) touch .no-mistakes-init ;;
  doctor) touch .no-mistakes-doctor ;;
esac
exit 0
SH
cat > "$HOST_BIN/git" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$HOME/../git.argv"
exec "$REAL_GIT" "$@"
SH
cat > "$HOST_BIN/gh" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$@" >> "$HOME/../gh.argv"
store="$HOME/.config/gh"
case "$*" in
  "auth login --hostname github.com --git-protocol https --insecure-storage --with-token")
    mkdir -p "$store"
    cat > "$store/hosts.yml"
    printf 'git_protocol: https\n' > "$store/config.yml"
    ;;
  "auth git-credential get")
    protocol= host=
    while IFS= read -r line && [ -n "$line" ]; do
      case "$line" in
        protocol=*) protocol=${line#protocol=} ;;
        host=*) host=${line#host=} ;;
      esac
    done
    [ "$protocol" = https ] && [ "$host" = github.com ] || exit 0
    printf 'username=x-access-token\npassword=%s\n' "$(cat "$store/hosts.yml")"
    ;;
  "auth git-credential store"|"auth git-credential erase") cat >/dev/null ;;
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
  new-session)
    : > "$d/server"
    env > "$d/environment"
    ;;
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
    env > "$d/environment"
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
      *'/exit'*) printf 'bash\n' > "$d/pane-command" ;;
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
chmod +x "$HOST_BIN/no-mistakes" "$HOST_BIN/git" "$HOST_BIN/gh" "$HOST_BIN/tmux"
REAL_GIT=$(command -v git)
export REAL_GIT

# The transport. A command runs under an empty environment, as the job worker
# runs it; FM_FAKE_SSH_MODE injects transport failures at one verb.
cat > "$LOCAL_BIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
set -u
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
host=$1 entry=$2
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
root=$(printf '%s' "$4" | "$REAL_BASE64" --decode)
home=$(printf '%s' "$5" | "$REAL_BASE64" --decode)
args=()
while IFS= read -r -d '' arg; do args+=("$arg"); done < <(printf '%s' "$6" | "$REAL_BASE64" --decode)
cmd=${args[0]}
verb=${args[1]:-}
printf '%s %s %s %s %s\n' "$host" "$root" "$home" "$cmd" "$verb" >> "$FM_FAKE_SSH_LOG"
[ "$host" = "$FM_FAKE_SSH_HOST" ] || { echo "ssh: Could not resolve hostname $host" >&2; exit 255; }
mode=${FM_FAKE_SSH_MODE:-normal}
if [ "$cmd" = fm-remote-doctor.sh ]; then
  case "$mode" in
    doctor-human)
      printf 'check harness=human: no harness on this host\n'
      printf 'error: this host is not ready for the task profile; unresolved: harness\n' >&2
      exit 1
      ;;
  esac
  printf 'check harness=ok: claude\nok: task readiness confirmed on this host\n'
  exit 0
fi
case "$mode:$verb" in
  provision-unreachable:provision) cat > /dev/null; exit 255 ;;
  launch-unreachable:launch) exit 255 ;;
  launch-stub:launch)
    printf 'schema=fm-remote-task-control.v1\nbackend=tmux\ntarget=firstmate:fm-%s\nworktree=%s\nbranch=\nspawn_gen=s1.2.3\nbusy_gen=\nharness=%s\nmodel=%s\neffort=default\n' \
      "${args[2]}" "$FM_FAKE_HOST_DIR/wt" "$FM_FAKE_STUB_HARNESS" "$FM_FAKE_STUB_MODEL"
    exit 0
    ;;
  launch-wrong-backend:launch)
    printf 'schema=fm-remote-task-control.v1\nbackend=herdr\ntarget=firstmate:fm-%s\nworktree=/w\nbranch=\nspawn_gen=s1.2.3\nbusy_gen=\nharness=claude\nmodel=default\neffort=default\n' "${args[2]}"
    exit 0
    ;;
esac
if [ "$cmd" = fm-remote-task-control.sh ] && [ "$verb" = launch ] && [ ! -d "$FM_FAKE_HOST_DIR/wt" ]; then
  # Stand in for treehouse: the slot the host's spawn adopts from the pane.
  git -C "$home/projects/alpha" worktree add -q --detach "$FM_FAKE_HOST_DIR/wt" >/dev/null 2>&1 || exit 93
  printf '%s\n' "$FM_FAKE_HOST_DIR/wt" > "$FM_FAKE_HOST_DIR/tmux/pane-path"
fi
env -i PATH="$FM_FAKE_HOST_BIN:$PATH" HOME="$FM_FAKE_HOST_DIR/account" \
  TMPDIR="$FM_FAKE_HOST_DIR/tmp" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" CLAUDE_CONFIG_DIR= \
  FM_FAKE_TMUX_DIR="$FM_FAKE_HOST_DIR/tmux" REAL_GIT="$REAL_GIT" REAL_JQ="$REAL_JQ" \
  REAL_BASE64="$REAL_BASE64" FM_FAKE_ARGV_LOG="$FM_FAKE_ARGV_LOG" FM_GATE_REFUSE_BYPASS=1 FM_TEST_SEAM=1 \
  "$root/bin/$cmd" "${args[@]:1}"
rc=$?
[ "$mode:$verb" != launch-lost:launch ] || exit 255
exit "$rc"
SH
chmod +x "$LOCAL_BIN/fake-ssh"

# --- per-case homes --------------------------------------------------------------

# new_case <name> [kind]: a supervising home with one registered project, a
# configured provider whose sandbox home is this case's, a markdown backlog
# holding the task, and a fresh sandbox host. Sets CASE, ID, PRIMARY,
# HOST_DIR, HOST_HOME, and HOST_ACCOUNT.
new_case() {
  local name=$1 kind=${2:-ship}
  CASE="$TMP_ROOT/$name"
  ID="rts-$name-$RUN_ID"
  PRIMARY="$CASE/primary"
  HOST_DIR="$CASE/host"
  HOST_HOME="$HOST_DIR/fm-home"
  HOST_ACCOUNT="$HOST_DIR/account"
  mkdir -p "$PRIMARY/data" "$PRIMARY/state" "$PRIMARY/config" "$PRIMARY/projects" \
    "$HOST_DIR/tmp" "$HOST_DIR/tmux" "$HOST_ACCOUNT" "$CASE/provider"
  git clone -q "file://$ORIGIN" "$PRIMARY/projects/alpha"
  printf '%s\n' '- alpha [direct-PR] - alpha fixture (added 2026-10-01)' '- beta [direct-PR] - beta fixture (added 2026-10-01)' \
    > "$PRIMARY/data/projects.md"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$PRIMARY/data/backlog.md"
  printf '%s\n' 'backend = "markdown"' '' '[markdown]' 'path = "data/backlog.md"' > "$PRIMARY/.tasks.toml"
  tasks-axi add "$ID" "sandbox fixture $name" --kind "$kind" --file "$PRIMARY/data/backlog.md" >/dev/null \
    || fail "could not file the backlog item for $ID"
  write_provider_config
  cat > "$PRIMARY/config/sandbox-credentials" <<EOF
# name destination source [condition...]
gh-alpha  github      $CREDS/gh-alpha.token  project=alpha
gh-beta   github      $CREDS/gh-beta.token   project=beta
minimax   pi:minimax  $CREDS/minimax.key
glm       pi:glm      $CREDS/glm.key         harness=pi,pi-signed
EOF
  printf 'auto\n' > "$PRIMARY/config/claude-permission-mode"
}

write_provider_config() {
  printf '%s\n' "$PROVIDER" default_profile=default ttl=4h "ssh_include=$TMP_ROOT/ssh-include" \
    > "$PRIMARY/config/sandbox-provider"
}

# render_brief [fm-brief args...]: the real scaffold for this case's sandbox
# home, filled.
render_brief() {
  FM_HOME="$PRIMARY" "$BRIEF" "$ID" alpha "$@" >/dev/null || fail "fm-brief.sh could not render the brief for $ID"
  fill_brief
}

fill_brief() {
  local file="$PRIMARY/data/$ID/brief.md" content
  content=$(cat "$file")
  content=${content//'{TASK}'/Make the sandbox change.}
  content=${content//'{FIRSTMATE_SPEC}'/Build only what the intent asks.}
  printf '%s\n' "$content" > "$file"
}

sandbox_brief() { # [fm-brief args...]: a brief rendered for the sandbox home
  render_brief "$@" --for-home "$HOST_HOME" --for-root "$CODE_ROOT"
}

run_spawn() { # <spawn args...>; sets OUT and RC, with stderr in OUT
  fm_test_track_procevent_home "$PRIMARY" "$CASE/claims"
  OUT=$(env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    -u FM_BACKEND -u FM_ROOT_OVERRIDE -u TRACEPARENT -u TMUX -u TMUX_PANE \
    FM_HOME="$PRIMARY" FM_SPAWN_NO_GUARD=1 FM_TEST_SEAM=1 FM_PROCEVENT_CLAIM_ROOT="$CASE/claims" \
    FM_TEST_SANDBOX_ROOT="$CODE_ROOT" FM_TEST_SANDBOX_HOME="$HOST_HOME" PATH="$LOCAL_BIN:$PATH" \
    FM_SSH_BIN="$LOCAL_BIN/fake-ssh" FM_FAKE_SSH_HOST="alias-$ID" FM_FAKE_SSH_LOG="$CASE/ssh.log" \
    FM_FAKE_SSH_MODE="${SSH_MODE:-normal}" FM_FAKE_HOST_DIR="$HOST_DIR" FM_FAKE_HOST_BIN="$HOST_BIN" \
    FM_FAKE_STUB_HARNESS="${STUB_HARNESS:-claude}" FM_FAKE_STUB_MODEL="${STUB_MODEL:-default}" \
    FM_FAKE_PROVIDER_STATE="$CASE/provider" FM_FAKE_LOCAL_TMUX_LOG="$CASE/local-tmux.log" \
    "$SPAWN" "$@" 2>&1)
  RC=$?
}

row_state() {
  tasks-axi show "$ID" --file "$PRIMARY/data/backlog.md" 2>/dev/null | sed -n 's/^  state: *//p' | head -1
}

meta_value() { # <key>
  sed -n "s/^$1=//p" "$PRIMARY/state/$ID.meta" | head -n 1
}

assert_line() { # <file> <exact-line> <msg>
  grep -qxF -- "$1" "$2" 2>/dev/null || fail "$3"
}

# Nothing happened beyond the refusal: no provider call, no record, no host
# home, the backlog item still queued, and no local tmux.
assert_refused_before_any_sandbox() { # <label> <expected-reason>
  [ "$RC" -ne 0 ] || fail "$1: the spawn was accepted"$'\n'"$OUT"
  assert_contains "$OUT" "$2" "$1: the refusal names its reason"
  [ ! -s "$CASE/provider/argv.log" ] || fail "$1: the provider was invoked: $(cat "$CASE/provider/argv.log")"
  assert_absent "$PRIMARY/state/$ID.meta" "$1: a refused spawn left a task record"
  assert_absent "$HOST_HOME" "$1: a refused spawn reached the sandbox host"
  assert_equals queued "$(row_state)" "$1: a refused spawn moved the backlog item"
  assert_absent "$CASE/local-tmux.log" "$1: a sandbox spawn touched local tmux"
}

assert_no_secret_text() { # <label> <text>
  case "$2" in
    *"$GH_SECRET"*|*"$OTHER_GH_SECRET"*|*"$PI_SECRET"*|*"$OTHER_PI_SECRET"*|*"$APP_TOKEN_MARK"*) fail "$1 holds a credential value" ;;
  esac
}

assert_no_secret_files() { # <label> <path...>
  local label=$1 hit
  shift
  hit=$(grep -rlF -e "$GH_SECRET" -e "$OTHER_GH_SECRET" -e "$PI_SECRET" -e "$OTHER_PI_SECRET" -e "$APP_TOKEN_MARK" "$@" 2>/dev/null || true)
  [ -z "$hit" ] || fail "$label holds a credential value: $hit"
}

# Every place this run's output, records, logs, and argv could carry a secret.
assert_no_secret_anywhere() { # <label>
  assert_no_secret_text "$1 spawn output" "$OUT"
  assert_no_secret_files "$1 supervising home" "$PRIMARY"
  assert_no_secret_files "$1 transport and provider logs" "$CASE/ssh.log" "$CASE/provider"
  assert_no_secret_files "$1 jq and base64 argv" "$FM_FAKE_ARGV_LOG"
  [ ! -d "$HOST_HOME" ] || assert_no_secret_files "$1 sandbox home (records, journal, brief, status)" "$HOST_HOME"
  assert_no_secret_files "$1 sandbox tmux log and environment" "$HOST_DIR/tmux"
  assert_no_secret_files "$1 sandbox git and gh argv" "$HOST_DIR/git.argv" "$HOST_DIR/gh.argv"
}

# --- refusals ----------------------------------------------------------------------

test_refusals_happen_before_any_sandbox_exists() {
  new_case refuse
  sandbox_brief --mode direct-PR

  run_spawn "$ID" "$PRIMARY/projects/alpha" --mode direct-PR --yolo off --harness claude --placement sandbox
  assert_refused_before_any_sandbox "Claude" "Claude in sandboxes requires a credential design in config/sandbox-credentials, which currently refuses a Claude destination"

  git -C "$PRIMARY/projects/alpha" remote set-url origin "https://user:$GH_SECRET@github.com/org/repo.git"
  run_spawn "$ID" "$PRIMARY/projects/alpha" --mode direct-PR --yolo off --harness pi --model minimax/m2 --placement sandbox
  assert_refused_before_any_sandbox "embedded password" "embedded passwords are forbidden"
  git -C "$PRIMARY/projects/alpha" remote set-url origin "file://$ORIGIN"
  assert_no_secret_anywhere "an embedded origin password"

  run_spawn "$ID" --secondmate --placement sandbox
  assert_refused_before_any_sandbox "secondmate" "--placement sandbox refuses --secondmate"

  local long_id
  long_id="rts-long-$RUN_ID-$(printf 'x%.0s' $(seq 1 46))"
  run_spawn "$long_id" "$PRIMARY/projects/alpha" --mode direct-PR --yolo off --harness pi --model minimax/m2 --placement sandbox
  assert_refused_before_any_sandbox "overlong task id" "is too long to name its status mirror's process-event source"
  assert_absent "$PRIMARY/state/$long_id.meta" "an overlong task id left a record"

  run_spawn "$ID" "$PRIMARY/projects/alpha" --mode local-only --yolo off --harness pi --model minimax/m2 --placement sandbox
  assert_refused_before_any_sandbox "local-only" "--placement sandbox refuses --mode local-only"

  run_spawn "$ID" "$PRIMARY/projects/alpha" --mode direct-PR --yolo off --harness pi --model minimax/m2 --placement sandbox --backend herdr
  assert_refused_before_any_sandbox "non-tmux backend" "runs its worker only on the tmux backend in this version, not 'herdr'"

  run_spawn "$ID" "$PRIMARY/projects/alpha" --mode direct-PR --yolo off --harness pi --model minimax/m2 --sandbox-profile open
  assert_refused_before_any_sandbox "profile without sandbox placement" "--sandbox-profile applies only to --placement sandbox"

  run_spawn "$ID" "$PRIMARY/projects/alpha" --mode direct-PR --yolo off --harness 'claude --yolo' --placement sandbox
  assert_refused_before_any_sandbox "raw launch command" "needs a verified harness adapter"

  run_spawn "$ID" "$PRIMARY/projects/alpha" --mode direct-PR --yolo off --harness pi --placement sandbox
  assert_refused_before_any_sandbox "Pi without a model provider" "needs --model <provider>/<id>"

  run_spawn "$ID" "$PRIMARY/projects/alpha" --mode direct-PR --yolo off --harness pi --model qwen/q3 --placement sandbox
  assert_refused_before_any_sandbox "Pi without a credential" "supplies Pi provider qwen"

  run_spawn "$ID" "$PRIMARY/projects/alpha" --mode direct-PR --yolo off --harness pi --model minimax/m2 --placement sandbox --sandbox-profile open
  assert_refused_before_any_sandbox "unauthorized profile" "sandbox profile open is not authorized for $ID"

  mv "$PRIMARY/config/sandbox-provider" "$CASE/sandbox-provider.off"
  run_spawn "$ID" "$PRIMARY/projects/alpha" --mode direct-PR --yolo off --harness pi --model minimax/m2 --placement sandbox
  assert_refused_before_any_sandbox "no provider" "no sandbox provider configured"
  assert_contains "$OUT" "default-off" "the no-provider refusal says sandbox placement is default-off"
  # A batch hands its placement to every pair rather than launching one locally.
  run_spawn "$ID=$PRIMARY/projects/alpha" --mode direct-PR --yolo off --harness pi --model minimax/m2 --placement sandbox
  assert_refused_before_any_sandbox "batch pair" "no sandbox provider configured"
  mv "$CASE/sandbox-provider.off" "$PRIMARY/config/sandbox-provider"

  sed 's/^ttl=4h$/ttl=forever/' "$PRIMARY/config/sandbox-provider" > "$CASE/sandbox-provider.bad"
  mv "$CASE/sandbox-provider.bad" "$PRIMARY/config/sandbox-provider"
  run_spawn "$ID" "$PRIMARY/projects/alpha" --mode direct-PR --yolo off --harness pi --model minimax/m2 --placement sandbox
  assert_refused_before_any_sandbox "invalid provider config" "ttl 'forever'"
  write_provider_config

  # A brief edited to carry the Herdr-lab contract, taken from the real scaffold.
  mkdir -p "$CASE/lab-home/data"
  FM_HOME="$CASE/lab-home" "$BRIEF" lab-source alpha --mode direct-PR --herdr-lab >/dev/null \
    || fail "fm-brief.sh could not render a Herdr-lab brief"
  sed -n '/^# Herdr isolation/,/^# Setup/p' "$CASE/lab-home/data/lab-source/brief.md" | sed '$d' >> "$PRIMARY/data/$ID/brief.md"
  run_spawn "$ID" "$PRIMARY/projects/alpha" --mode direct-PR --yolo off --harness pi --model minimax/m2 --placement sandbox
  assert_refused_before_any_sandbox "Herdr-lab brief" "carries the fm-brief.sh --herdr-lab isolation contract"

  rm -rf "$PRIMARY/data/$ID"
  render_brief --mode direct-PR
  run_spawn "$ID" "$PRIMARY/projects/alpha" --mode direct-PR --yolo off --harness pi --model minimax/m2 --placement sandbox
  assert_refused_before_any_sandbox "brief for this home" "must tell its worker to append status to the sandbox home's $HOST_HOME/state/$ID.status"

  rm -rf "$PRIMARY/data/$ID"
  sandbox_brief --mode direct-PR --sandbox-profile open
  run_spawn "$ID" "$PRIMARY/projects/alpha" --mode direct-PR --yolo off --harness pi --model minimax/m2 --placement sandbox
  assert_refused_before_any_sandbox "profile disagreement" "the brief records sandbox profile open but this spawn selected default"

  rm -rf "$PRIMARY/data/$ID"
  sandbox_brief --mode no-mistakes
  run_spawn "$ID" "$PRIMARY/projects/alpha" --mode direct-PR --yolo off --harness pi --model minimax/m2 --placement sandbox
  assert_refused_before_any_sandbox "delivery disagreement" "the brief says mode=no-mistakes but this spawn passed --mode direct-PR"

  rm -rf "$PRIMARY/data/$ID"
  sandbox_brief --mode direct-PR
  tasks-axi "done" "$ID" --file "$PRIMARY/data/backlog.md" >/dev/null 2>&1 || fail "could not close the fixture item"
  run_spawn "$ID" "$PRIMARY/projects/alpha" --mode direct-PR --yolo off --harness pi --model minimax/m2 --placement sandbox
  [ "$RC" -ne 0 ] || fail "a closed backlog item dispatched a sandbox"
  assert_contains "$OUT" "is not dispatchable" "the backlog gate names the item's state"
  [ ! -s "$CASE/provider/argv.log" ] || fail "the backlog gate ran after the provider: $(cat "$CASE/provider/argv.log")"
  assert_absent "$PRIMARY/state/$ID.meta" "the backlog gate left a record"

  fm_write_meta "$PRIMARY/state/$ID.meta" "window=fm-$ID" "endpoint_task_id=$ID" "worktree=$CASE" \
    "project=$PRIMARY/projects/alpha" "harness=claude" "kind=ship" "mode=direct-PR" "yolo=off"
  cp "$PRIMARY/state/$ID.meta" "$CASE/local.meta"
  run_spawn "$ID" --relaunch --placement sandbox
  [ "$RC" -ne 0 ] || fail "a relaunch moved a local task into a sandbox"
  assert_contains "$OUT" "--relaunch keeps task $ID's recorded placement (local); --placement sandbox cannot move it" \
    "the relaunch refusal names both placements"
  cmp -s "$CASE/local.meta" "$PRIMARY/state/$ID.meta" || fail "a refused relaunch changed the local record"
  [ ! -s "$CASE/provider/argv.log" ] || fail "a refused relaunch invoked the provider"

  fm_write_meta "$PRIMARY/state/$ID-held.meta" "window=remote:$ID-held" "endpoint_task_id=$ID-held" \
    "project=$PRIMARY/projects/alpha" "harness=claude" "kind=ship" "mode=direct-PR" "yolo=off" \
    "placement=sandbox" "remote_kind=task" "remote_host=alias-$ID-held" "remote_root=$CODE_ROOT" "remote_home=$HOST_HOME"
  cp "$PRIMARY/state/$ID-held.meta" "$CASE/held.meta"
  run_spawn "$ID-held" --relaunch
  [ "$RC" -ne 0 ] || fail "a relaunch of a sandbox task was accepted"
  assert_contains "$OUT" "so its relaunch runs on that host: use bin/fm-control.sh $ID-held relaunch" \
    "the sandbox relaunch refusal names the control plane that relaunches it"
  cmp -s "$CASE/held.meta" "$PRIMARY/state/$ID-held.meta" || fail "a refused sandbox relaunch changed its record"
  [ ! -e "$CASE/ssh.log" ] || fail "a refused sandbox relaunch reached the transport"
  pass "fm-spawn --placement sandbox refuses each named case before any sandbox, record, or backlog change"
}

# --- a launched ship ----------------------------------------------------------------

test_ship_launches_in_a_sandbox_and_records_its_route() {
  local tag spawn_gen key
  new_case ship
  sandbox_brief --mode direct-PR
  run_spawn "$ID" "$PRIMARY/projects/alpha" --mode direct-PR --yolo off --harness pi --model minimax/m2 --placement sandbox
  expect_code 0 "$RC" "a sandbox ship should launch"$'\n'"$OUT"
  assert_contains "$OUT" "spawned $ID harness=pi kind=ship mode=direct-PR yolo=off window=remote:$ID worktree=$HOST_DIR/wt placement=sandbox remote=alias-$ID sandbox=sbx-$ID profile=default credentials=gh-alpha,minimax" \
    "the success line names the placement, route, sandbox, profile, and credential names"
  assert_contains "$OUT" "sandbox placement real-cluster verification is recorded in docs/verification/remote-sandboxes.md" \
    "success points to the real-cluster verification record"
  assert_line "adapter=remote-reply" "$PRIMARY/state/procevent/remote-reply-$ID.source" \
    "the status mirror is armed at publish"
  assert_line "$CODE_ROOT/bin/fm-procevent-remote-reply.sh" "$PRIMARY/state/procevent/remote-reply-$ID.source" \
    "the armed source runs the status mirror adapter"

  tag=$(sed -n "s/^create $ID --home \([^ ]*\) .*/\1/p" "$CASE/provider/argv.log")
  [ -n "$tag" ] || fail "the provider never received create for $ID: $(cat "$CASE/provider/argv.log")"
  assert_line "create $ID --home $tag --profile default --ttl 4h" "$CASE/provider/argv.log" "create carries the task, home tag, profile, and TTL"
  assert_line "git -C $CODE_ROOT pull --quiet --ff-only --no-rebase --no-tags origin $CODE_COMMIT" "$CASE/provider/exec.log" \
    "the one provider exec fast-forwards the code root to this home's default-branch commit"
  assert_equals 3 "$(grep -c . "$CASE/provider/exec.log")" "convergence is followed by two read-only checks"
  assert_absent "$CASE/provider/destroyed.log" "a launched sandbox is never destroyed by its spawn"
  assert_equals "alias-$ID fm-remote-doctor.sh --profile" "$(head -n 1 "$CASE/ssh.log" | awk '{print $1, $4, $5}')" \
    "the readiness gate is the first transport call, after convergence"
  grep -q " fm-remote-task-control.sh provision$" "$CASE/ssh.log" || fail "provision never reached the host"
  grep -q " fm-remote-task-control.sh launch$" "$CASE/ssh.log" || fail "launch never reached the host"

  for key in window=remote:$ID endpoint_task_id=$ID worktree=$HOST_DIR/wt project=$PRIMARY/projects/alpha \
    harness=pi kind=ship mode=direct-PR yolo=off branch=fm/$ID tasktmp= model=minimax/m2 effort=default \
    placement=sandbox remote_kind=task remote_host=alias-$ID remote_root=$CODE_ROOT remote_home=$HOST_HOME \
    remote_backend=tmux remote_target=firstmate:fm-$ID sandbox_provider=pve-sandbox sandbox_name=sbx-$ID \
    sandbox_profile=default; do
    assert_line "$key" "$PRIMARY/state/$ID.meta" "the record carries $key"
  done
  spawn_gen=$(meta_value spawn_gen)
  assert_line "spawn_gen=$spawn_gen" "$HOST_HOME/state/$ID.meta" "the record's spawn_gen is the host worker's incarnation"
  assert_equals 23 "$(grep -c . "$PRIMARY/state/$ID.meta")" "the record carries exactly the ordinary and sandbox fields"
  (
    # shellcheck source=/dev/null
    . "$CODE_ROOT/bin/fm-remote-route-lib.sh"
    fm_remote_route_resolve "$PRIMARY/state/$ID.meta" "$ID" || exit 1
    [ "$FM_REMOTE_ROUTE_KIND" = task ] && [ "$FM_REMOTE_ROUTE_HOST" = "alias-$ID" ]
  ) || fail "the published record does not resolve to the sandbox task route"
  assert_equals in_flight "$(row_state)" "the backlog item moves In flight with the record"

  assert_line "task_id=$ID" "$HOST_HOME/.fm-task-home" "the sandbox home is provisioned for this task"
  assert_line "mode=direct-PR" "$HOST_HOME/.fm-task-home" "the sandbox home records the delivery mode"
  cmp -s "$PRIMARY/data/$ID/brief.md" "$HOST_HOME/data/$ID/brief.md" || fail "the brief did not reach the sandbox byte for byte"
  assert_equals auto "$(cat "$HOST_HOME/config/claude-permission-mode")" "launch configuration reaches the sandbox"
  assert_equals manual "$(cat "$HOST_HOME/config/backlog-backend")" "the sandbox home's backlog is manual"
  assert_equals "$GH_SECRET" "$(cat "$HOST_ACCOUNT/.config/gh/hosts.yml")" "the project's GitHub token reaches the sandbox account"
  assert_equals "$PI_SECRET" "$(jq -r .minimax.key "$HOST_ACCOUNT/.pi/agent/auth.json")" "the Pi credential reaches the ship"
  assert_absent "$CASE/local-tmux.log" "a sandbox spawn never touches local tmux"
  assert_no_secret_anywhere "a launched ship"
  pass "fm-spawn --placement sandbox creates, converges, gates, provisions, launches, and records a ship"
}

# --- a scout on Pi -------------------------------------------------------------------

test_scout_sends_only_its_providers_credential_on_an_authorized_profile() {
  local auth
  new_case scout scout
  sandbox_brief --scout --sandbox-profile open
  SSH_MODE=launch-stub STUB_HARNESS=pi STUB_MODEL=minimax/m2 \
    run_spawn "$ID" "$PRIMARY/projects/alpha" --scout --harness pi --model minimax/m2 --placement sandbox --sandbox-profile open
  expect_code 0 "$RC" "a Pi scout on an authorized profile should launch"$'\n'"$OUT"
  assert_contains "$OUT" "profile=open credentials=gh-alpha,minimax" "the scout names its profile and both credential names"
  grep -q "^create $ID --home [^ ]* --profile open --ttl 4h$" "$CASE/provider/argv.log" \
    || fail "create did not request the authorized profile: $(cat "$CASE/provider/argv.log")"
  assert_line "sandbox_profile=open" "$PRIMARY/state/$ID.meta" "the record carries the authorized profile"
  assert_line "kind=scout" "$PRIMARY/state/$ID.meta" "the record is a scout"
  ! grep -q '^mode=\|^yolo=\|^branch=' "$PRIMARY/state/$ID.meta" || fail "a scout record carries a delivery posture"
  assert_line "kind=scout" "$HOST_HOME/.fm-task-home" "the sandbox home is provisioned as a scout"
  auth="$HOST_ACCOUNT/.pi/agent/auth.json"
  assert_equals '["minimax"]' "$(jq -c 'keys' "$auth")" "only the model's provider entry is sent"
  assert_equals "$PI_SECRET" "$(jq -r '.minimax.key' "$auth")" "the Pi key arrives intact"
  assert_equals api_key "$(jq -r '.minimax.type' "$auth")" "the Pi entry is an API key"
  assert_equals "$GH_SECRET" "$(cat "$HOST_ACCOUNT/.config/gh/hosts.yml")" "the project's token reaches a scout too"
  assert_equals in_flight "$(row_state)" "the scout's backlog item moves In flight"
  assert_no_secret_anywhere "a Pi scout"
  pass "fm-spawn --placement sandbox sends only the selected credentials and honors a brief-authorized profile"
}

# --- failures --------------------------------------------------------------------------

test_failures_before_launch_destroy_the_sandbox() {
  new_case doctor
  sandbox_brief --mode direct-PR
  SSH_MODE=doctor-human run_spawn "$ID" "$PRIMARY/projects/alpha" --mode direct-PR --yolo off --harness pi --model minimax/m2 --placement sandbox
  [ "$RC" -ne 0 ] || fail "an unready sandbox host launched"
  assert_contains "$OUT" "sandbox host alias-$ID is not ready for task $ID" "the readiness refusal names the host"
  assert_contains "$OUT" "check harness=human" "the doctor's own report is relayed"
  assert_contains "$OUT" "never launched, so its sandbox sbx-$ID was destroyed" "the spawn reports the destroy"
  assert_line "sbx-$ID" "$CASE/provider/destroyed.log" "an unready sandbox is destroyed"
  grep -q "^destroy sbx-$ID --expect-task $ID --home " "$CASE/provider/argv.log" || fail "destroy did not confirm the task label"
  assert_absent "$PRIMARY/state/$ID.meta" "a destroyed sandbox leaves no record"
  assert_absent "$HOST_HOME" "nothing was provisioned"
  assert_equals queued "$(row_state)" "the backlog item stays queued"
  assert_absent "$PRIMARY/state/procevent/remote-reply-$ID.source" "a sandbox that never launched arms no status mirror"
  assert_no_secret_anywhere "an unready host"

  new_case converge
  sandbox_brief --mode direct-PR
  : > "$CASE/provider/fail-exec"
  run_spawn "$ID" "$PRIMARY/projects/alpha" --mode direct-PR --yolo off --harness pi --model minimax/m2 --placement sandbox
  [ "$RC" -ne 0 ] || fail "a sandbox whose code root could not converge launched"
  assert_contains "$OUT" "could not fast-forward to this home's default-branch commit $CODE_COMMIT" "the convergence refusal names the commit"
  assert_contains "$OUT" "Not possible to fast-forward" "the host's own reason is relayed"
  assert_line "sbx-$ID" "$CASE/provider/destroyed.log" "an unconverged sandbox is destroyed"
  [ ! -s "$CASE/ssh.log" ] || fail "a transport call ran before convergence succeeded"
  assert_absent "$PRIMARY/state/$ID.meta" "an unconverged sandbox leaves no record"

  new_case provision
  sandbox_brief --mode direct-PR
  SSH_MODE=provision-unreachable run_spawn "$ID" "$PRIMARY/projects/alpha" --mode direct-PR --yolo off --harness pi --model minimax/m2 --placement sandbox
  expect_code 255 "$RC" "an SSH 255 during provisioning is returned unchanged"
  assert_contains "$OUT" "did not complete over SSH (exit 255)" "the unknown provision is named"
  assert_line "sbx-$ID" "$CASE/provider/destroyed.log" "nothing launched, so the sandbox is destroyed"
  assert_absent "$PRIMARY/state/$ID.meta" "the provisional record is removed"
  ! grep -q " launch$" "$CASE/ssh.log" || fail "launch ran after a failed provision"
  assert_equals queued "$(row_state)" "the backlog item stays queued"
  assert_no_secret_anywhere "an unknown provision"

  new_case capacity
  sandbox_brief --mode direct-PR
  : > "$CASE/provider/no-capacity"
  run_spawn "$ID" "$PRIMARY/projects/alpha" --mode direct-PR --yolo off --harness pi --model minimax/m2 --placement sandbox
  [ "$RC" -ne 0 ] || fail "a spawn without capacity succeeded"
  assert_contains "$OUT" "blocked: the sandbox provider has no capacity for task $ID" "a capacity refusal is a named blocker"
  assert_contains "$OUT" "never fall back to local placement" "the blocker rules out a local fallback"
  assert_absent "$CASE/provider/destroyed.log" "nothing was created, so nothing is destroyed"
  assert_absent "$PRIMARY/state/$ID.meta" "a blocked spawn leaves no record"
  assert_absent "$CASE/local-tmux.log" "a blocked spawn never falls back to local tmux"

  new_case profile-drift
  sandbox_brief --mode direct-PR
  printf 'open' > "$CASE/provider/applied-profile"
  run_spawn "$ID" "$PRIMARY/projects/alpha" --mode direct-PR --yolo off --harness pi --model minimax/m2 --placement sandbox
  [ "$RC" -ne 0 ] || fail "a sandbox on an unrequested profile launched"
  assert_contains "$OUT" "runs profile 'open', not the requested default" "the profile drift is named"
  assert_line "sbx-$ID" "$CASE/provider/destroyed.log" "a sandbox on the wrong profile is destroyed"
  assert_absent "$PRIMARY/state/$ID.meta" "a wrong-profile sandbox leaves no record"
  pass "fm-spawn --placement sandbox destroys a sandbox that fails before launch and leaves the backlog queued"
}

test_launch_failures_hold_the_sandbox_and_its_route() {
  new_case lost
  sandbox_brief --mode direct-PR
  SSH_MODE=launch-lost run_spawn "$ID" "$PRIMARY/projects/alpha" --mode direct-PR --yolo off --harness pi --model minimax/m2 --placement sandbox
  expect_code 255 "$RC" "an SSH 255 at launch is preserved as unknown completion"$'\n'"$OUT"
  assert_contains "$OUT" "launch on sandbox host alias-$ID has unknown completion (SSH exit 255)" "the unknown launch is named"
  assert_contains "$OUT" "is held and its task record kept for reconciliation" "the spawn reports the hold"
  assert_absent "$CASE/provider/destroyed.log" "a sandbox whose launch may have started is never destroyed"
  ! grep -q '^destroy ' "$CASE/provider/argv.log" || fail "the provider was asked to destroy a held sandbox"
  assert_present "$PRIMARY/state/$ID.meta" "the route record is kept"
  assert_line "placement=sandbox" "$PRIMARY/state/$ID.meta" "the kept record is the sandbox route"
  assert_line "remote_host=alias-$ID" "$PRIMARY/state/$ID.meta" "the kept record still reaches the host"
  assert_line "sandbox_name=sbx-$ID" "$PRIMARY/state/$ID.meta" "the kept record names the held sandbox"
  assert_present "$HOST_HOME/state/$ID.meta" "the worker the lost reply hid is running on the host"
  assert_equals queued "$(row_state)" "the spawn leaves the backlog transition to reconciliation"
  assert_absent "$PRIMARY/state/procevent/remote-reply-$ID.source" "an unconfirmed launch arms no status mirror"
  assert_no_secret_anywhere "a lost launch reply"

  new_case unreachable
  sandbox_brief --mode direct-PR
  SSH_MODE=launch-unreachable run_spawn "$ID" "$PRIMARY/projects/alpha" --mode direct-PR --yolo off --harness pi --model minimax/m2 --placement sandbox
  expect_code 255 "$RC" "an unreachable launch keeps SSH's exit 255"
  assert_absent "$CASE/provider/destroyed.log" "an unreachable launch holds its sandbox"
  assert_present "$PRIMARY/state/$ID.meta" "an unreachable launch keeps its route"

  new_case bad-route
  sandbox_brief --mode direct-PR
  SSH_MODE=launch-wrong-backend run_spawn "$ID" "$PRIMARY/projects/alpha" --mode direct-PR --yolo off --harness pi --model minimax/m2 --placement sandbox
  [ "$RC" -ne 0 ] || fail "a malformed route block was accepted"
  assert_contains "$OUT" "returned malformed route metadata: backend 'herdr', expected tmux" "the route defect is named"
  assert_contains "$OUT" "is held and its task record kept" "a malformed route holds"
  assert_absent "$CASE/provider/destroyed.log" "a malformed route never destroys"
  assert_present "$PRIMARY/state/$ID.meta" "a malformed route keeps the provisional record"
  ! grep -q '^remote_target=' "$PRIMARY/state/$ID.meta" || fail "an untrusted route block reached the record"
  assert_equals queued "$(row_state)" "a malformed route never moves the backlog item"

  # The mirror is armed last, after the record and the backlog move; a failed
  # arm keeps the launched task, its record, and its sandbox.
  new_case arm-fails
  sandbox_brief --mode direct-PR
  : > "$PRIMARY/state/procevent"
  run_spawn "$ID" "$PRIMARY/projects/alpha" --mode direct-PR --yolo off --harness pi --model minimax/m2 --placement sandbox
  [ "$RC" -ne 0 ] || fail "a spawn whose status mirror could not be armed reported success"
  assert_contains "$OUT" "task $ID launched in sandbox sbx-$ID and is recorded, but its status mirror could not be armed" \
    "the arm failure names the launched task"
  assert_contains "$OUT" "until bin/fm-procevent-remote-reply.sh arm $ID succeeds" "the arm failure names the recovery"
  assert_line "remote_target=firstmate:fm-$ID" "$PRIMARY/state/$ID.meta" "the final record is kept"
  assert_equals in_flight "$(row_state)" "the backlog item still moves In flight"
  assert_absent "$CASE/provider/destroyed.log" "a failed arm never destroys the sandbox"
  pass "fm-spawn --placement sandbox holds the sandbox and its route once launch may have started, preserving SSH 255"
}

test_code_root_verification() {
  local kind actual before after content
  for kind in ahead dirty staged; do
    new_case "$kind"
    sandbox_brief --mode direct-PR
    git clone -q "$CODE_ROOT" "$CASE/template"
    printf '%s\n' "$CASE/template" > "$CASE/provider/code-root"
    printf 'template change\n' >> "$CASE/template/README.md"
    if [ "$kind" = ahead ] || [ "$kind" = staged ]; then
      git -C "$CASE/template" add README.md
    fi
    if [ "$kind" = ahead ]; then
      git -C "$CASE/template" -c user.name=Tests -c user.email=tests@example.invalid commit -qm ahead
    fi
    content=$(git -C "$CASE/template" hash-object README.md)
    actual=$(git -C "$CASE/template" rev-parse HEAD)
    before=$(git -C "$CASE/template" status --porcelain --untracked-files=no)
    run_spawn "$ID" "$PRIMARY/projects/alpha" --mode direct-PR --yolo off --harness pi --model minimax/m2 --placement sandbox
    [ "$RC" -ne 0 ] || fail "$kind code root launched"
    assert_contains "$OUT" "expected $CODE_COMMIT, actual $actual" "$kind refusal names both commits"
    assert_absent "$CASE/ssh.log" "$kind code root must refuse before readiness"
    assert_line "sbx-$ID" "$CASE/provider/destroyed.log" "$kind sandbox is destroyed before launch"
    assert_absent "$PRIMARY/state/$ID.meta" "$kind provisional record is removed"
    assert_equals "$actual" "$(git -C "$CASE/template" rev-parse HEAD)" "$kind HEAD is preserved"
    after=$(git -C "$CASE/template" status --porcelain --untracked-files=no)
    assert_equals "$before" "$after" "$kind tracked changes are preserved"
    assert_equals "$content" "$(git -C "$CASE/template" hash-object README.md)" "$kind content is preserved"
  done
  pass "sandbox bootstrap refuses ahead and dirty code roots without discarding changes"
}

# --- GitHub App installation tokens (an app source) ---------------------------------

APP_KEY_READY=0
if command -v openssl >/dev/null 2>&1; then
  mkdir -p "$TMP_ROOT/app-keys"
  chmod 700 "$TMP_ROOT/app-keys"
  if openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$TMP_ROOT/app-keys/app.pem" >/dev/null 2>&1; then
    chmod 600 "$TMP_ROOT/app-keys/app.pem"
    APP_KEY_READY=1
  fi
fi
fm_test_fake_github_api "$LOCAL_BIN" "$TMP_ROOT/github-unused"

sha12() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -c1-12; else shasum -a 256 | cut -c1-12; fi
}

# app_case <name> [kind]: new_case with config/github-app, an app github entry
# for alpha, a github.com origin that the sandbox account's Git rewrites to the
# local bare repository, and a fresh fake GitHub API in $CASE/github.
app_case() {
  new_case "$@"
  printf 'app_id=424242\ninstallation_id=987654321\nprivate_key=%s\nworkflows=off\n' "$TMP_ROOT/app-keys/app.pem" \
    > "$PRIMARY/config/github-app"
  chmod 600 "$PRIMARY/config/github-app"
  cat > "$PRIMARY/config/sandbox-credentials" <<EOF
gh-app   github      app                    project=alpha
minimax  pi:minimax  $CREDS/minimax.key
EOF
  git -C "$PRIMARY/projects/alpha" remote set-url origin https://github.com/acme/alpha.git
  git config --file "$HOST_ACCOUNT/.gitconfig" "url.file://$ORIGIN.insteadOf" https://github.com/acme/alpha.git
  export FM_FAKE_GITHUB_DIR="$CASE/github"
  mkdir -p "$FM_FAKE_GITHUB_DIR"
}

minted_count() {
  local n=
  n=$(grep -c . "$FM_FAKE_GITHUB_DIR/minted" 2>/dev/null) || true
  printf '%s\n' "${n:-0}"
}

test_app_credential_mints_the_task_repository_token() {
  local fp
  [ "$APP_KEY_READY" = 1 ] || { echo "skip: openssl could not generate a throwaway App key"; return 0; }
  app_case app-ship
  sandbox_brief --mode direct-PR
  run_spawn "$ID" "$PRIMARY/projects/alpha" --mode direct-PR --yolo off --harness pi --model minimax/m2 --placement sandbox
  expect_code 0 "$RC" "a sandbox ship with an app credential should launch"$'\n'"$OUT"
  assert_contains "$OUT" "credentials=gh-app,minimax" "the success line names the app credential"
  assert_equals 1 "$(minted_count)" "one token is minted for the launch"
  sed -n 1p "$FM_FAKE_GITHUB_DIR/minted" | tr -d '\n' > "$CASE/launch.token"
  cmp -s "$CASE/launch.token" "$HOST_ACCOUNT/.config/gh/hosts.yml" || fail "the sandbox account does not hold the minted token"
  assert_equals '["alpha"]' "$(jq -c .repositories "$FM_FAKE_GITHUB_DIR/request.1.json")" "the token is for the task's one repository"
  assert_equals '{"actions":"read","checks":"read","contents":"write","issues":"write","metadata":"read","pull_requests":"write","statuses":"read"}' \
    "$(jq -cS .permissions "$FM_FAKE_GITHUB_DIR/request.1.json")" "a ship's token asks for the write set"
  fp=$(tr -d '\n' < "$CASE/launch.token" | sha12)
  grep -Eq "^[0-9]+ mint github task=$ID repo=acme/alpha access=write expires=[^ ]+ fp=$fp purpose=launch$" "$PRIMARY/state/cred-ledger" \
    || fail "the launch mint is not recorded: $(cat "$PRIMARY/state/cred-ledger" 2>/dev/null)"
  assert_absent "$FM_FAKE_GITHUB_DIR/revoked" "a launched task's token is never revoked by its spawn"
  assert_no_secret_anywhere "an app credential"

  app_case app-scout scout
  sandbox_brief --scout
  SSH_MODE=launch-stub STUB_HARNESS=pi STUB_MODEL=minimax/m2 \
    run_spawn "$ID" "$PRIMARY/projects/alpha" --scout --harness pi --model minimax/m2 --placement sandbox
  expect_code 0 "$RC" "a sandbox scout with an app credential should launch"$'\n'"$OUT"
  assert_equals '{"contents":"read","metadata":"read","pull_requests":"read"}' \
    "$(jq -cS .permissions "$FM_FAKE_GITHUB_DIR/request.1.json")" "a scout's token is read-only"
  grep -q " mint github task=$ID repo=acme/alpha access=read " "$PRIMARY/state/cred-ledger" || fail "the scout's read mint is not recorded"
  assert_no_secret_anywhere "an app credential for a scout"
  pass "an app credential mints a token for exactly the task's repository, write for a ship and read for a scout, and records it"
}

test_app_credential_refusals_happen_before_any_sandbox() {
  [ "$APP_KEY_READY" = 1 ] || { echo "skip: openssl could not generate a throwaway App key"; return 0; }
  app_case app-refuse
  sandbox_brief --mode direct-PR
  printf '401\n' > "$FM_FAKE_GITHUB_DIR/mode"
  run_spawn "$ID" "$PRIMARY/projects/alpha" --mode direct-PR --yolo off --harness pi --model minimax/m2 --placement sandbox
  assert_refused_before_any_sandbox "a mint failure" "GitHub refused an installation token for acme/alpha (HTTP 401"
  assert_contains "$OUT" "credential gh-app could not mint a GitHub App token for acme/alpha" "the refusal names the credential"
  assert_contains "$(cat "$PRIMARY/state/cred-ledger")" "mint-failed github task=$ID repo=acme/alpha access=write purpose=launch reason=http-401" \
    "the mint failure is recorded"
  rm -f "$FM_FAKE_GITHUB_DIR/mode"

  git -C "$PRIMARY/projects/alpha" remote set-url origin "file://$ORIGIN"
  run_spawn "$ID" "$PRIMARY/projects/alpha" --mode direct-PR --yolo off --harness pi --model minimax/m2 --placement sandbox
  assert_refused_before_any_sandbox "an origin off github.com" "project alpha's origin is not a github.com repository"
  git -C "$PRIMARY/projects/alpha" remote set-url origin https://github.com/acme/alpha.git

  mv "$PRIMARY/config/github-app" "$CASE/github-app.off"
  run_spawn "$ID" "$PRIMARY/projects/alpha" --mode direct-PR --yolo off --harness pi --model minimax/m2 --placement sandbox
  assert_refused_before_any_sandbox "no GitHub App configuration" "credential gh-app names the app source, but the GitHub App configuration"
  mv "$CASE/github-app.off" "$PRIMARY/config/github-app"

  printf 'pi-app  pi:glm  app\n' >> "$PRIMARY/config/sandbox-credentials"
  run_spawn "$ID" "$PRIMARY/projects/alpha" --mode direct-PR --yolo off --harness pi --model minimax/m2 --placement sandbox
  assert_refused_before_any_sandbox "an app Pi credential" "credential pi-app names the app source, which only a github credential may use"
  assert_equals 0 "$(minted_count)" "no refused spawn holds a minted token"
  assert_no_secret_anywhere "app credential refusals"
  pass "an app credential's mint failure, origin, configuration, and destination are refused before any sandbox exists"
}

test_app_token_is_revoked_when_the_spawn_never_launches() {
  local fp
  [ "$APP_KEY_READY" = 1 ] || { echo "skip: openssl could not generate a throwaway App key"; return 0; }
  app_case app-unready
  sandbox_brief --mode direct-PR
  SSH_MODE=doctor-human run_spawn "$ID" "$PRIMARY/projects/alpha" --mode direct-PR --yolo off --harness pi --model minimax/m2 --placement sandbox
  [ "$RC" -ne 0 ] || fail "an unready sandbox host launched"
  assert_contains "$OUT" "task $ID's GitHub App token was never used, so it was revoked" "the spawn reports the revoke"
  assert_line "sbx-$ID" "$CASE/provider/destroyed.log" "the unready sandbox is destroyed"
  cmp -s "$FM_FAKE_GITHUB_DIR/minted" "$FM_FAKE_GITHUB_DIR/revoked" || fail "the unused launch token was not revoked"
  fp=$(sed -n 1p "$FM_FAKE_GITHUB_DIR/minted" | tr -d '\n' | sha12)
  grep -q " revoke github task=$ID fp=$fp result=revoked$" "$PRIMARY/state/cred-ledger" || fail "the revoke is not recorded"
  assert_no_secret_anywhere "an unready host with an app credential"

  app_case app-full
  sandbox_brief --mode direct-PR
  : > "$CASE/provider/no-capacity"
  run_spawn "$ID" "$PRIMARY/projects/alpha" --mode direct-PR --yolo off --harness pi --model minimax/m2 --placement sandbox
  assert_contains "$OUT" "has no capacity for task $ID" "the capacity blocker is named"
  assert_contains "$OUT" "GitHub App token was never used, so it was revoked" "a token minted for a sandbox that was never created is revoked"
  cmp -s "$FM_FAKE_GITHUB_DIR/minted" "$FM_FAKE_GITHUB_DIR/revoked" || fail "the token minted before creation was not revoked"

  app_case app-lost
  sandbox_brief --mode direct-PR
  SSH_MODE=launch-lost run_spawn "$ID" "$PRIMARY/projects/alpha" --mode direct-PR --yolo off --harness pi --model minimax/m2 --placement sandbox
  expect_code 255 "$RC" "an SSH 255 at launch is preserved"
  assert_absent "$FM_FAKE_GITHUB_DIR/revoked" "a token a launched worker may be using is never revoked"
  assert_no_secret_anywhere "a lost launch with an app credential"
  pass "a token minted for a spawn that never launches is revoked, and one a worker may hold is kept"
}

test_code_root_verification
test_refusals_happen_before_any_sandbox_exists
test_ship_launches_in_a_sandbox_and_records_its_route
test_scout_sends_only_its_providers_credential_on_an_authorized_profile
test_failures_before_launch_destroy_the_sandbox
test_launch_failures_hold_the_sandbox_and_its_route
test_app_credential_mints_the_task_repository_token
test_app_credential_refusals_happen_before_any_sandbox
test_app_token_is_revoked_when_the_spawn_never_launches

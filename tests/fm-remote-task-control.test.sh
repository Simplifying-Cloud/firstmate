#!/usr/bin/env bash
# tests/fm-remote-task-control.test.sh - the sandbox task home's host-side
# control plane (bin/fm-remote-task-control.sh).
#
# Every verb runs against a real fixture home on this machine, the way the
# remote job worker runs it on a sandbox host: FM_HOME names the one-task home
# and FM_ROOT_OVERRIDE this checkout. The project origin is a local bare
# repository, tmux, treehouse, and no-mistakes are fakes that record what they
# were asked, and HOME is a throwaway account home, so neither the Pi
# credential file nor Claude's trust store is ever the runner's own. The
# credential cases plant recognizable secret values and grep every output
# channel, the provision journal, the marker, the brief, the task record, the
# staged launch command, and the status file for them.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

CONTROL="$ROOT/bin/fm-remote-task-control.sh"
TMP_ROOT=$(fm_test_tmproot fm-remote-task-control)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
RUN_ID=$$
GH_SECRET="github_pat_SANDBOXGHSECRET${RUN_ID}x"
PI_SECRET="sk-pi-SANDBOXPISECRET${RUN_ID}x"
# GitHub App installation tokens, long like the stateless format.
APP_SECRET="ghs_SANDBOXAPPSECRET${RUN_ID}$(printf 'Ab9_%.0s' $(seq 1 120))"
REFRESH_SECRET="ghs_SANDBOXREFRESHSECRET${RUN_ID}$(printf 'Zq7-%.0s' $(seq 1 120))"

# A spawn stages its per-task temp root at /tmp/fm-<id>, outside every fixture,
# so task ids carry this run's id and the roots are removed here.
cleanup() {
  rm -rf /tmp/fm-rtc-*-"$RUN_ID" /tmp/fm-rtc-*-"$RUN_ID"+* 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

b64() { base64 | tr -d '\n'; }

hash_text() {
  if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d' ' -f1; fi
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1" | awk '{print $1}'; else shasum -a 256 < "$1" | awk '{print $1}'; fi
}

mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

# --- fixtures ----------------------------------------------------------------

FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
fm_fake_exit0 "$FAKEBIN" treehouse
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "${FM_FAKE_NM_FAIL:-0}" != 1 ] || { echo "fake no-mistakes failure" >&2; exit 1; }
case "${1:-}" in
  init)
    touch .no-mistakes-init
    gate="$HOME/.no-mistakes/repos/gate-$(printf '%s' "$PWD" | cksum | cut -d' ' -f1).git"
    mkdir -p "$HOME/.no-mistakes/repos"
    git init --quiet --bare "$gate"
    git remote add no-mistakes "$gate"
    ;;
  doctor) touch .no-mistakes-doctor ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/no-mistakes"

REAL_GIT=$(command -v git)
export REAL_GIT
cat > "$FAKEBIN/git" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$HOME/../git.argv"
exec "$REAL_GIT" "$@"
SH
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$@" >> "$HOME/../gh.argv"
env > "$HOME/../gh.environment"
store="${GH_CONFIG_DIR:-$HOME/.config/gh}"
case "$*" in
  "auth login --hostname github.com --git-protocol https --insecure-storage --with-token")
    cat > "$HOME/../gh.stdin"
    mkdir -p "$store"
    cp "$HOME/../gh.stdin" "$store/hosts.yml"
    printf 'git_protocol: https\n' > "$store/config.yml"
    if [ "${FM_FAKE_GH_FAIL:-0}" = 1 ]; then
      cat "$store/hosts.yml" >&2
      exit 1
    fi
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
  "auth token --hostname github.com") cat "$store/hosts.yml" ;;
  "api --method DELETE /installation/token --include")
    printf 'revoke\n' >> "$HOME/../gh.revokes"
    code=$(cat "$HOME/../gh-revoke-status" 2>/dev/null || printf '204')
    printf 'HTTP/2.0 %s Fake\r\nContent-Length: 0\r\n\r\n' "$code"
    [ "$code" = 204 ] || exit 1
    ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/git" "$FAKEBIN/gh"

cat > "$FAKEBIN/tmux" <<'SH'
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
      *"/launch."*) printf 'claude\n' > "$d/pane-command" ;;
    esac
    ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/tmux"

ORIGIN="$TMP_ROOT/alpha.git"
git init -q --bare "$ORIGIN"
fm_git_init_commit "$TMP_ROOT/alpha-seed"
git -C "$TMP_ROOT/alpha-seed" push -q "$ORIGIN" HEAD:refs/heads/main
git --git-dir="$ORIGIN" symbolic-ref HEAD refs/heads/main
ORIGIN_URL="file://$ORIGIN"
REGISTRY_LINE='- alpha [direct-PR] - alpha fixture (added 2026-10-01)'

# new_case <name>: a fresh account home, sandbox host directory, tmux state,
# and task id. Sets CASE, ID, TASK_HOME, ACCOUNT_HOME, TMUX_DIR, and PRIMARY.
new_case() {
  CASE="$TMP_ROOT/$1"
  ID="rtc-$1-$RUN_ID"
  TASK_HOME="$CASE/host/fm-home"
  ACCOUNT_HOME="$CASE/account"
  TMUX_DIR="$CASE/tmux"
  PRIMARY="$CASE/primary"
  mkdir -p "$CASE/host" "$ACCOUNT_HOME" "$TMUX_DIR" "$PRIMARY/data" "$CASE/tmp"
}

# render_brief <file> <for-home> [fm-brief args...]: a filled brief rendered by
# the real scaffold for the sandbox home <for-home>.
render_brief() {
  local file=$1 for_home=$2 scratch
  shift 2
  scratch=$(mktemp -d "$CASE/brief.XXXXXX")
  mkdir -p "$scratch/data"
  FM_HOME="$scratch" "$ROOT/bin/fm-brief.sh" "$ID" alpha "$@" --for-home "$for_home" --for-root "$ROOT" >/dev/null \
    || fail "fm-brief.sh could not render a sandbox brief"
  sed -e 's/{TASK}/Make the sandbox change./' -e 's/{FIRSTMATE_SPEC}/Build only what the intent asks./' \
    "$scratch/data/$ID/brief.md" > "$file"
}

# write_manifest <file> <kind> <harness> [mode]: a complete manifest for $ID
# whose brief is rendered for $TASK_HOME. A ship carries mode, yolo, and the
# default prefix; every manifest carries the GitHub token.
write_manifest() {
  local file=$1 kind=$2 harness=$3 mode=${4:-direct-PR}
  if [ "$kind" = ship ]; then
    render_brief "$CASE/brief.md" "$TASK_HOME" --mode "$mode"
  else
    render_brief "$CASE/brief.md" "$TASK_HOME" --scout
  fi
  {
    printf 'schema=fm-remote-task-provision.v1\n'
    printf 'task_id=%s\n' "$ID"
    printf 'kind=%s\n' "$kind"
    printf 'project=alpha\n'
    printf 'origin_b64=%s\n' "$(printf '%s' "$ORIGIN_URL" | b64)"
    printf 'registry_b64=%s\n' "$(printf '%s' "$REGISTRY_LINE" | b64)"
    printf 'harness=%s\n' "$harness"
    printf 'model=default\n'
    printf 'effort=default\n'
    printf 'brief_b64=%s\n' "$(b64 < "$CASE/brief.md")"
    if [ "$kind" = ship ]; then
      printf 'mode=%s\n' "$mode"
      printf 'yolo=off\n'
      printf 'branch_prefix_b64=%s\n' "$(printf 'fm/' | b64)"
    fi
    printf 'gh_token_b64=%s\n' "$(printf '%s' "$GH_SECRET" | b64)"
  } > "$file"
}

# manifest_set <file> <key> [<line>]: drop every <key>= line, then append <line>.
manifest_set() {
  local file=$1 key=$2 line=${3:-}
  grep -v "^$key=" "$file" > "$file.edit" || true
  mv "$file.edit" "$file"
  [ -z "$line" ] || printf '%s\n' "$line" >> "$file"
}

pi_auth_field() { printf 'pi_auth_b64=%s\n' "$(printf '{"minimax":{"type":"api_key","key":"%s"}}' "$PI_SECRET" | b64)"; }

run_control() { # <verb> [args...]; stdin passes through
  env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    -u GH_CONFIG_DIR -u XDG_CONFIG_HOME -u GH_TOKEN -u GITHUB_TOKEN \
    FM_HOME="$TASK_HOME" FM_ROOT_OVERRIDE="$ROOT" HOME="$ACCOUNT_HOME" CLAUDE_CONFIG_DIR= \
    TMUX= TMPDIR="$CASE/tmp" PATH="$FAKEBIN:$PATH" FM_FAKE_TMUX_DIR="$TMUX_DIR" \
    "$CONTROL" "$@"
}

# assert_no_secret <label> <path-or-text...>: neither credential value appears.
assert_no_secret_text() { # <label> <text>
  case "$2" in
    *"$GH_SECRET"*|*"$PI_SECRET"*|*"$APP_SECRET"*|*"$REFRESH_SECRET"*) fail "$1 echoed a credential value" ;;
  esac
}
# assert_secret_only_in <label> <root> [<file>...]: under <root>, exactly the
# listed files hold a credential value.
assert_secret_only_in() {
  local label=$1 root=$2 hits want
  shift 2
  hits=$(grep -rlF -e "$GH_SECRET" -e "$PI_SECRET" "$root" 2>/dev/null | LC_ALL=C sort || true)
  want=$(for f in "$@"; do printf '%s\n' "$f"; done | LC_ALL=C sort)
  assert_equals "$want" "$hits" "$label: credential values are held exactly where they belong"
}
assert_no_secret_files() { # <label> <path...>
  local label=$1 hit
  shift
  hit=$(grep -rlF -e "$GH_SECRET" -e "$PI_SECRET" -e "$APP_SECRET" -e "$REFRESH_SECRET" "$@" 2>/dev/null || true)
  [ -z "$hit" ] || fail "$label holds a credential value: $hit"
}

token_fp() { printf '%s' "$1" | sha256_of /dev/stdin | cut -c1-12; }

# provision_ship <harness> [mode]: provision $ID as a ship and fail on refusal.
provision_ship() {
  local out
  write_manifest "$CASE/manifest" ship "$@"
  out=$(run_control provision "$ID" < "$CASE/manifest" 2>&1) || fail "provisioning $ID failed: $out"
  assert_no_secret_text "provision" "$out"
}

# launch_ready: give the provisioned home a task worktree the fake pane reports.
launch_ready() {
  WT="$CASE/host/wt"
  git -C "$TASK_HOME/projects/alpha" worktree add -q --detach "$WT" >/dev/null 2>&1 \
    || fail "could not create the fixture task worktree"
  printf '%s\n' "$WT" > "$TMUX_DIR/pane-path"
}

route_value() { # <block> <key>
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1
}

assert_line() { # <file> <exact-line> <msg>
  grep -qxF -- "$2" "$1" 2>/dev/null || fail "$3"
}

assert_no_line_prefix() { # <file> <prefix> <msg>
  ! grep -q -- "^$2" "$1" 2>/dev/null || fail "$3"
}

# --- provision ---------------------------------------------------------------

test_provision_builds_a_private_marked_home() {
  local out rc auth
  new_case provision
  mkdir -p "$ACCOUNT_HOME/.pi/agent"
  printf '{"other":{"type":"api_key","key":"keep-me"}}\n' > "$ACCOUNT_HOME/.pi/agent/auth.json"
  chmod 600 "$ACCOUNT_HOME/.pi/agent/auth.json"
  write_manifest "$CASE/manifest" ship pi no-mistakes
  {
    pi_auth_field
    printf 'config=claude-permission-mode|%s\n' "$(printf 'auto\n' | b64)"
    printf 'config=keep-ai-trailers|\n'
    printf 'config=launch-env-allowlist|%s\n' "$(printf 'OPENAI_API_KEY' | b64)"
  } >> "$CASE/manifest"
  out=$(run_control provision "$ID" < "$CASE/manifest" 2>&1); rc=$?
  expect_code 0 "$rc" "a complete ship manifest should provision"$'\n'"$out"
  assert_contains "$out" "schema=fm-remote-task-control.v1" "provision prints a schema-tagged block"
  assert_contains "$out" "provision=created" "a first provision reports created"
  assert_contains "$out" "task_id=$ID" "provision names its task"
  assert_contains "$out" "manifest_sha256=$(sha256_of "$CASE/manifest")" "provision reports the manifest digest"
  assert_no_secret_text "provision output" "$out"

  assert_equals 700 "$(mode_of "$TASK_HOME")" "the task home is private"
  assert_line "$TASK_HOME/.fm-task-home" "task_id=$ID" "the marker names the task"
  assert_line "$TASK_HOME/.fm-task-home" kind=ship "the marker records the kind"
  assert_line "$TASK_HOME/.fm-task-home" mode=no-mistakes "the marker records the delivery mode"
  assert_line "$TASK_HOME/.fm-task-home" branch_prefix=fm/ "the marker records the branch prefix"
  assert_line "$TASK_HOME/.fm-task-home" harness=pi "the marker records the harness"
  cmp -s "$CASE/brief.md" "$TASK_HOME/data/$ID/brief.md" || fail "the brief was not written byte for byte"
  assert_equals "$REGISTRY_LINE" "$(cat "$TASK_HOME/data/projects.md")" "the registry holds the project's line"
  assert_equals manual "$(cat "$TASK_HOME/config/backlog-backend")" "the backlog transition belongs to the primary"
  assert_equals auto "$(cat "$TASK_HOME/config/claude-permission-mode")" "launch config is written"
  assert_present "$TASK_HOME/config/keep-ai-trailers" "an empty flag config is still written"
  assert_equals OPENAI_API_KEY "$(cat "$TASK_HOME/config/launch-env-allowlist")" \
    "an inherited allowlist is unchanged"
  assert_equals "$ORIGIN_URL" "$(git -C "$TASK_HOME/projects/alpha" remote get-url origin)" "the project is cloned from its origin"
  assert_present "$TASK_HOME/projects/alpha/.no-mistakes-init" "a no-mistakes ship initializes no-mistakes in its clone"
  gate_repo=$(git -C "$TASK_HOME/projects/alpha" remote get-url no-mistakes 2>/dev/null || true)
  assert_equals 2 "$(git -C "$gate_repo" config --local --get-all credential.https://github.com.helper 2>/dev/null | wc -l | tr -d ' ')" \
    "the no-mistakes gate repository resets and sets the absolute gh credential helper"
  assert_contains "$(git -C "$gate_repo" config --local --get-all credential.https://github.com.helper 2>/dev/null)" \
    "!$FAKEBIN/gh auth git-credential" "the gate repository's helper is the absolute gh helper"

  assert_absent "$TASK_HOME/config/credentials.env" "no environment credential file is created"
  assert_equals 600 "$(mode_of "$ACCOUNT_HOME/.config/gh/hosts.yml")" "the gh credential store is mode 0600"
  assert_equals "$GH_SECRET" "$(cat "$CASE/gh.stdin")" "gh receives the token on stdin"
  assert_equals "$GH_SECRET" "$(cat "$ACCOUNT_HOME/.config/gh/hosts.yml")" "gh stores the token"
  assert_no_secret_files "credential process argv and environment" "$CASE/gh.argv" "$CASE/git.argv" "$CASE/gh.environment"
  auth="$ACCOUNT_HOME/.pi/agent/auth.json"
  assert_equals 600 "$(mode_of "$auth")" "the Pi credential file is mode 0600"
  assert_equals keep-me "$(jq -r '.other.key' "$auth")" "existing Pi entries survive the merge"
  assert_equals "$PI_SECRET" "$(jq -r '.minimax.key' "$auth")" "the needed Pi entry is merged in"

  assert_grep "begin task=$ID" "$TASK_HOME/state/task-provision.journal" "the journal records the start"
  assert_grep 'credential gh_token=gh/github.com' "$TASK_HOME/state/task-provision.journal" "the journal names the token's file"
  assert_grep 'credential pi_auth providers=minimax' "$TASK_HOME/state/task-provision.journal" "the journal names the Pi providers"
  assert_grep 'no-mistakes-init project=alpha' "$TASK_HOME/state/task-provision.journal" "the journal records no-mistakes init"
  assert_grep 'no-mistakes-gate project=alpha' "$TASK_HOME/state/task-provision.journal" "the journal records the gate repository's credential helper"
  assert_grep 'complete' "$TASK_HOME/state/task-provision.journal" "the journal records completion"
  assert_no_secret_files "the provisioned home" "$TASK_HOME"
  assert_secret_only_in "the account home" "$ACCOUNT_HOME" "$ACCOUNT_HOME/.pi/agent/auth.json" "$ACCOUNT_HOME/.config/gh/hosts.yml"
  [ -z "$(find "$CASE/tmp" -mindepth 1 -maxdepth 1 -name 'fm-task-provision.*' -print)" ] \
    || fail "provision left its private staging directory behind"

  # A Pi configuration directory provision creates is private.
  new_case provision-fresh-pi
  write_manifest "$CASE/manifest" scout pi
  printf 'pi_auth_b64=%s\n' "$(printf '{"minimax":{"type":"api_key","key":"%s","env":{"REGION":"test"}}}' "$PI_SECRET" | b64)" >> "$CASE/manifest"
  out=$(run_control provision "$ID" < "$CASE/manifest" 2>&1) || fail "a scout manifest should provision: $out"
  assert_equals 700 "$(mode_of "$ACCOUNT_HOME/.pi")" "a created .pi directory is private"
  assert_equals 700 "$(mode_of "$ACCOUNT_HOME/.pi/agent")" "a created .pi/agent directory is private"
  assert_equals 600 "$(mode_of "$ACCOUNT_HOME/.pi/agent/auth.json")" "a created Pi credential file is mode 0600"
  assert_line "$TASK_HOME/.fm-task-home" kind=scout "a scout home records its kind"
  assert_no_line_prefix "$TASK_HOME/.fm-task-home" mode= "a scout records no delivery mode"
  assert_absent "$TASK_HOME/projects/alpha/.no-mistakes-init" "a scout never initializes no-mistakes"

  # A no-mistakes ship without a GitHub token provisions with no gate-repository
  # helper, because there is no token for it to serve.
  new_case provision-no-token-gate
  write_manifest "$CASE/manifest" ship pi no-mistakes
  grep -v '^gh_token_b64=' "$CASE/manifest" > "$CASE/manifest.notoken" && mv "$CASE/manifest.notoken" "$CASE/manifest"
  out=$(run_control provision "$ID" < "$CASE/manifest" 2>&1); rc=$?
  expect_code 0 "$rc" "a no-mistakes ship without a GitHub token should provision"$'\n'"$out"
  gate_repo=$(git -C "$TASK_HOME/projects/alpha" remote get-url no-mistakes 2>/dev/null || true)
  [ -n "$gate_repo" ] || fail "the fake no-mistakes init did not name its gate repository"
  assert_equals "" "$(git -C "$gate_repo" config --local --get-all credential.https://github.com.helper 2>/dev/null)" \
    "a provision without a GitHub token configures no gate-repository helper"
  assert_no_grep 'no-mistakes-gate' "$TASK_HOME/state/task-provision.journal" "the journal records no gate step without a token"

  pass "provision builds a private home, writes the 0600 credentials, and marks the home last"
}

test_provision_is_idempotent_and_refuses_another_task_or_manifest() {
  local out rc before after
  new_case idempotent
  provision_ship claude
  before=$(cd "$TASK_HOME" && find . -type f -exec cksum {} + | sort)
  out=$(run_control provision "$ID" < "$CASE/manifest" 2>&1); rc=$?
  expect_code 0 "$rc" "the same manifest again should succeed"$'\n'"$out"
  assert_contains "$out" "provision=current" "a repeated manifest reports current"
  after=$(cd "$TASK_HOME" && find . -type f -exec cksum {} + | sort)
  assert_equals "$before" "$after" "a repeated manifest changes nothing"

  cp "$CASE/manifest" "$CASE/changed"
  manifest_set "$CASE/changed" effort 'effort=high'
  out=$(run_control provision "$ID" < "$CASE/changed" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a different manifest for a provisioned task was accepted"
  assert_contains "$out" "provisioned from a different manifest" "the refusal names the changed manifest"
  after=$(cd "$TASK_HOME" && find . -type f -exec cksum {} + | sort)
  assert_equals "$before" "$after" "a refused manifest changes nothing"

  local first=$ID
  ID="rtc-other-$RUN_ID"
  write_manifest "$CASE/other" ship claude
  out=$(run_control provision "$ID" < "$CASE/other" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "provisioning a second task into a marked home was accepted"
  assert_contains "$out" "already belongs to task $first" "the refusal names the home's task"
  assert_absent "$TASK_HOME/data/$ID" "the refused task left nothing in the foreign home"
  out=$(run_control launch "$ID" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a verb for another task was accepted in a marked home"
  assert_contains "$out" "belongs to task $first, not $ID" "a verb in a foreign home names the owner"

  new_case unmarked
  mkdir -p "$TASK_HOME"
  printf 'keep\n' > "$TASK_HOME/stray"
  write_manifest "$CASE/manifest" ship claude
  out=$(run_control provision "$ID" < "$CASE/manifest" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "provision over an unmarked home with content was accepted"
  assert_contains "$out" "has content but no provisioning marker" "the refusal names the unknown content"
  assert_equals keep "$(cat "$TASK_HOME/stray")" "the unknown content is untouched"
  assert_absent "$TASK_HOME/data" "nothing was provisioned beside the unknown content"
  out=$(run_control state "$ID" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a verb in an unprovisioned home was accepted"
  assert_contains "$out" "not a provisioned sandbox task home" "an unprovisioned home is refused by name"
  pass "provision is idempotent per manifest and refuses another task, another manifest, or unknown content"
}

test_provision_rolls_back_a_failed_attempt() {
  local out rc
  new_case rollback
  mkdir -p "$ACCOUNT_HOME/.pi/agent"
  printf '{"other":{"type":"api_key","key":"before"}}\n' > "$ACCOUNT_HOME/.pi/agent/auth.json"
  chmod 600 "$ACCOUNT_HOME/.pi/agent/auth.json"
  cp -p "$ACCOUNT_HOME/.pi/agent/auth.json" "$CASE/auth.before"
  mkdir -p "$ACCOUNT_HOME/.config/gh"
  printf 'old-gh-credential\n' > "$ACCOUNT_HOME/.config/gh/hosts.yml"
  printf 'old-gh-config\n' > "$ACCOUNT_HOME/.config/gh/config.yml"
  chmod 600 "$ACCOUNT_HOME/.config/gh/hosts.yml"
  cp -p "$ACCOUNT_HOME/.config/gh/hosts.yml" "$CASE/gh.before"
  cp -p "$ACCOUNT_HOME/.config/gh/config.yml" "$CASE/gh-config.before"
  write_manifest "$CASE/manifest" ship pi
  pi_auth_field >> "$CASE/manifest"
  manifest_set "$CASE/manifest" origin_b64 "origin_b64=$(printf '%s' "file://$CASE/missing.git" | b64)"
  out=$(run_control provision "$ID" < "$CASE/manifest" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a provision whose clone fails was accepted"
  assert_contains "$out" "could not clone project alpha" "the refusal names the failed clone"
  assert_no_secret_text "a failed provision" "$out"
  assert_absent "$TASK_HOME" "a failed provision removes the home it created"
  cmp -s "$CASE/auth.before" "$ACCOUNT_HOME/.pi/agent/auth.json" || fail "a failed provision did not restore the Pi credential file"
  cmp -s "$CASE/gh.before" "$ACCOUNT_HOME/.config/gh/hosts.yml" || fail "failed provision did not restore gh credentials"
  cmp -s "$CASE/gh-config.before" "$ACCOUNT_HOME/.config/gh/config.yml" || fail "failed provision did not restore gh configuration"
  assert_equals 600 "$(mode_of "$ACCOUNT_HOME/.config/gh/hosts.yml")" "rollback preserves credential permissions"
  [ -z "$(find "$CASE/tmp" -mindepth 1 -maxdepth 1 -name 'fm-task-provision.*' -print)" ] \
    || fail "a failed provision left its private staging directory behind"

  new_case rollback-nm
  write_manifest "$CASE/manifest" ship pi no-mistakes
  pi_auth_field >> "$CASE/manifest"
  mkdir -p "$TASK_HOME"
  out=$(FM_FAKE_NM_FAIL=1 run_control provision "$ID" < "$CASE/manifest" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a provision whose no-mistakes init fails was accepted"
  assert_contains "$out" "no-mistakes initialization failed" "the refusal names the failed init"
  assert_present "$TASK_HOME" "a pre-existing empty home is kept"
  assert_equals '' "$(find "$TASK_HOME" -mindepth 1 -print)" "a pre-existing empty home is emptied again"
  assert_absent "$ACCOUNT_HOME/.pi/agent/auth.json" "a Pi credential file the failed provision created is removed"
  assert_absent "$ACCOUNT_HOME/.config/gh/hosts.yml" "a new gh credential is removed on rollback"
  assert_absent "$ACCOUNT_HOME/.config/gh/config.yml" "a new gh configuration is removed on rollback"

  out=$(FM_FAKE_GH_FAIL=1 run_control provision "$ID" < "$CASE/manifest" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "failed gh login was accepted"
  assert_contains "$out" "gh credential storage failed for github.com" "gh login failure has a named reason"
  assert_no_secret_text "failed gh login" "$out"
  assert_absent "$ACCOUNT_HOME/.config/gh/hosts.yml" "partial gh login is rolled back"

  write_manifest "$CASE/manifest" ship pi no-mistakes
  pi_auth_field >> "$CASE/manifest"
  out=$(run_control provision "$ID" < "$CASE/manifest" 2>&1); rc=$?
  expect_code 0 "$rc" "provision should succeed once the failure clears"$'\n'"$out"
  assert_contains "$out" "provision=created" "the retry provisions the home"
  pass "a failed provision removes what it created and restores the Pi credential file"
}

test_provision_refuses_unsafe_manifests() {
  local label key line expect out rc
  new_case refusals
  write_manifest "$CASE/base" ship claude
  while IFS='~' read -r label key line expect; do
    [ -n "$label" ] || continue
    cp "$CASE/base" "$CASE/manifest"
    case "$key" in
      +) printf '%s\n' "$line" >> "$CASE/manifest" ;;
      *) manifest_set "$CASE/manifest" "$key" "$line" ;;
    esac
    out=$(run_control provision "$ID" < "$CASE/manifest" 2>&1); rc=$?
    [ "$rc" -ne 0 ] || fail "$label: the manifest was accepted"
    assert_contains "$out" "$expect" "$label: the refusal did not explain itself"
    assert_no_secret_text "$label" "$out"
    assert_absent "$TASK_HOME" "$label: a refused manifest created the home"
  done <<ROWS
unknown field~+~extra=1~unknown field: extra
a Claude credential field~+~claude_oauth_b64=$(printf 'sk-ant-%s' "$GH_SECRET" | b64)~unknown field: claude_oauth_b64
repeated field~+~kind=ship~repeats field kind
missing field~harness~~has no harness field
wrong schema~schema~schema=fm-remote-task-provision.v2~incompatible provisioning manifest
another task~task_id~task_id=someone-else~for another task
local-only ship~mode~mode=local-only~never placed in a sandbox
scout with a delivery contract~kind~kind=scout~must not carry mode
traversal project~project~project=..~unsafe project
remote-helper origin~origin_b64~origin_b64=$(printf 'ext::sh -c touch' | b64)~not an accepted clone URL
foreign registry line~registry_b64~registry_b64=$(printf '%s' '- beta [direct-PR] - beta' | b64)~does not register project alpha
Pi credentials for claude~+~$(pi_auth_field)~only for a pi or pi-signed harness
unverified harness~harness~harness=bogus~not a verified crewmate adapter
token with a space~gh_token_b64~gh_token_b64=$(printf 'bad %s' "$GH_SECRET" | b64)~printable ASCII without spaces
unaccepted config~+~config=crew-harness|$(printf 'claude' | b64)~carries config a sandbox does not take
ROWS
  # Pi entries must be provider objects, and jq's diagnostics never surface.
  cp "$CASE/base" "$CASE/manifest"
  manifest_set "$CASE/manifest" harness 'harness=pi'
  printf 'pi_auth_b64=%s\n' "$(printf '["%s"]' "$PI_SECRET" | b64)" >> "$CASE/manifest"
  out=$(run_control provision "$ID" < "$CASE/manifest" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "malformed Pi credential entries were accepted"
  assert_contains "$out" "JSON object of provider objects" "the malformed Pi entries are named"
  assert_no_secret_text "malformed Pi entries" "$out"

  # A brief rendered for another home is refused after the home is created,
  # and that home is removed again.
  cp "$CASE/base" "$CASE/manifest"
  render_brief "$CASE/foreign-brief.md" "$CASE/elsewhere/fm-home" --mode direct-PR
  manifest_set "$CASE/manifest" brief_b64 "brief_b64=$(b64 < "$CASE/foreign-brief.md")"
  out=$(run_control provision "$ID" < "$CASE/manifest" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a brief naming another home's status file was accepted"
  assert_contains "$out" "append status to $CASE/elsewhere/fm-home/state/$ID.status" "the refusal names the foreign status file"
  assert_absent "$TASK_HOME" "the refused brief left no home behind"

  head -c 1100000 /dev/zero | tr '\0' 'x' > "$CASE/huge"
  out=$(run_control provision "$ID" < "$CASE/huge" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "an oversized manifest was accepted"
  assert_contains "$out" "exceeds its 1 MiB bound" "the oversized manifest is named"
  pass "provision refuses every unsafe or unaccepted manifest before writing anything it keeps"
}

# --- launch and the read verbs -----------------------------------------------

test_provision_refuses_non_api_key_credentials() {
  local entry reason out rc
  new_case credential-boundary
  write_manifest "$CASE/base" ship pi
  while IFS='|' read -r entry reason; do
    cp "$CASE/base" "$CASE/manifest"
    printf 'pi_auth_b64=%s\n' "$(printf '%s' "$entry" | b64)" >> "$CASE/manifest"
    out=$(run_control provision "$ID" < "$CASE/manifest" 2>&1); rc=$?
    [ "$rc" -ne 0 ] || fail "invalid Pi credential was accepted"
    assert_contains "$out" "$reason" "the credential refusal names its provider, type, and reason"
    assert_no_secret_text "credential refusal" "$out"
    assert_absent "$TASK_HOME" "invalid credentials created no task home"
    assert_absent "$ACCOUNT_HOME/.pi" "invalid credentials created no Pi auth"
    [ -z "$(find "$CASE/tmp" -mindepth 1 -print)" ] || fail "invalid credentials left staging files"
  done <<ROWS
{"minimax":{"type":"oauth","access":"$PI_SECRET"}}|provider=minimax type=oauth reason=oauth-forbidden
{"minimax":{"type":"future","key":"$PI_SECRET"}}|provider=minimax type=future reason=unsupported-type
{"minimax":{"key":"$PI_SECRET"}}|provider=minimax type=<missing> reason=unsupported-type
{"minimax":{"type":"api_key","key":"$PI_SECRET","refresh":"$GH_SECRET"}}|provider=minimax type=api_key reason=unknown-field
{"minimax":{"type":"api_key","key":""}}|provider=minimax type=api_key reason=invalid-key
{"minimax":{"type":"api_key","key":"$PI_SECRET","env":{"TOKEN":false}}}|provider=minimax type=api_key reason=invalid-env
ROWS
  cp "$CASE/base" "$CASE/manifest"
  printf 'claude_auth_b64=%s\n' "$(printf '%s' "$PI_SECRET" | b64)" >> "$CASE/manifest"
  out=$(run_control provision "$ID" < "$CASE/manifest" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "unknown credential field was accepted"
  assert_contains "$out" "unknown field: claude_auth_b64" "unknown credential field is named"
  assert_no_secret_text "unknown credential field" "$out"
  assert_absent "$TASK_HOME" "unknown credential field created no task home"
  assert_absent "$ACCOUNT_HOME/.pi" "unknown credential field created no Pi auth"
  [ -z "$(find "$CASE/tmp" -mindepth 1 -print)" ] || fail "unknown credential field left staging files"
  pass "provision refuses credentials outside the API-key and GitHub boundary before writing"
}

test_provision_requires_gh_for_a_token() {
  local out rc tool executable
  new_case missing-gh
  write_manifest "$CASE/manifest" ship claude
  local FAKEBIN="$CASE/no-gh"
  mkdir "$FAKEBIN"
  for tool in env bash dirname head wc tr base64 git jq rm cat sed mktemp mkdir chmod cksum awk grep cut sha256sum shasum; do
    executable=$(command -v "$tool") || continue
    ln -s "$executable" "$FAKEBIN/$tool"
  done
  out=$(PATH="$FAKEBIN" run_control provision "$ID" < "$CASE/manifest" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a token was provisioned without gh"
  assert_contains "$out" "gh is unavailable" "a missing gh has a named refusal"
  assert_no_secret_text "missing gh refusal" "$out"
  assert_absent "$TASK_HOME" "missing gh creates no task home"
  assert_absent "$ACCOUNT_HOME/.config/gh/hosts.yml" "missing gh creates no credential store"
  [ -z "$(find "$CASE/tmp" -mindepth 1 -print)" ] || fail "missing gh leaves staging files"
  pass "a GitHub token requires gh before provisioning writes the home"
}

test_git_credentials_are_repository_and_host_scoped() {
  local repo out rc
  new_case git-credentials
  provision_ship pi
  launch_ready
  for repo in "$TASK_HOME/projects/alpha" "$WT"; do
    out=$(printf 'protocol=https\nhost=github.com\n\n' |
      env -u GH_CONFIG_DIR -u XDG_CONFIG_HOME -u GH_TOKEN -u GITHUB_TOKEN HOME="$ACCOUNT_HOME" PATH="$FAKEBIN:$PATH" GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 \
      git -C "$repo" credential fill 2>"$CASE/credential.err"); rc=$?
    expect_code 0 "$rc" "GitHub credential fill should succeed"
    assert_contains "$out" "username=x-access-token" "Git receives the token username"
    assert_contains "$out" "password=$GH_SECRET" "Git reads the task token from gh storage"
    out=$(printf 'protocol=https\nhost=example.com\n\n' |
      env -u GH_CONFIG_DIR -u XDG_CONFIG_HOME -u GH_TOKEN -u GITHUB_TOKEN HOME="$ACCOUNT_HOME" PATH="$FAKEBIN:$PATH" GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/false \
      git -C "$repo" credential fill 2>"$CASE/credential.err"); rc=$?
    [ "$rc" -ne 0 ] || fail "another host received credentials"
    assert_equals "" "$out" "another host receives no credential output"
    assert_no_secret_text "other host error" "$(cat "$CASE/credential.err")"
    assert_no_secret_text "repository Git configuration" "$(git -C "$repo" config --local --list)"
  done
  assert_no_secret_files "Git and gh arguments" "$CASE/git.argv" "$CASE/gh.argv"
  pass "Git authenticates the clone and worktree using gh credential storage"
}

test_launch_reports_the_route_without_credential_environment() {
  local out rc meta spawn_gen
  new_case launch
  write_manifest "$CASE/manifest" ship claude
  printf 'config=launch-env-allowlist|%s\n' "$(printf 'OPENAI_API_KEY' | b64)" >> "$CASE/manifest"
  out=$(run_control provision "$ID" < "$CASE/manifest" 2>&1) || fail "provision failed: $out"
  launch_ready
  out=$(run_control launch "$ID" 2>"$CASE/launch.err"); rc=$?
  expect_code 0 "$rc" "launch should succeed"$'\n'"$out"$'\n'"$(cat "$CASE/launch.err")"
  meta="$TASK_HOME/state/$ID.meta"
  assert_present "$meta" "launch publishes the host-local task record"
  assert_equals fm-remote-task-control.v1 "$(route_value "$out" schema)" "the route block is schema-tagged"
  assert_equals tmux "$(route_value "$out" backend)" "a sandbox task runs on tmux"
  assert_equals "firstmate:fm-$ID" "$(route_value "$out" target)" "the route names the worker's window"
  assert_equals "$WT" "$(route_value "$out" worktree)" "the route names the worktree"
  assert_equals "fm/$ID" "$(route_value "$out" branch)" "the route names the ship branch"
  spawn_gen=$(route_value "$out" spawn_gen)
  [ -n "$spawn_gen" ] || fail "the route carries no spawn_gen"
  assert_line "$meta" "spawn_gen=$spawn_gen" "the route's spawn_gen is the record's"
  assert_equals "$(sed -n 's/^busy_gen=//p' "$meta")" "$(route_value "$out" busy_gen)" "the route's busy_gen is the record's"
  assert_equals claude "$(route_value "$out" harness)" "the route names the harness"
  assert_equals default "$(route_value "$out" model)" "the route names the model"
  assert_equals default "$(route_value "$out" effort)" "the route names the effort"
  assert_line "$meta" "project=$TASK_HOME/projects/alpha" "the worker belongs to the home's own clone"

  assert_no_secret_files "tmux environment" "$TMUX_DIR/environment"
  assert_not_contains "$(cat "$TMUX_DIR/environment")" "GH_TOKEN=" "tmux receives no GH_TOKEN"
  assert_equals OPENAI_API_KEY "$(cat "$TASK_HOME/config/launch-env-allowlist")" "launch allowlist contains no token entry"
  assert_no_secret_files "Git and gh arguments" "$CASE/git.argv" "$CASE/gh.argv"
  assert_no_secret_text "launch output" "$out$(cat "$CASE/launch.err")"
  assert_no_secret_files "the launched home" "$TASK_HOME"
  assert_no_secret_files "the task's temp root" /tmp/fm-"$ID"
  assert_no_secret_files "the staged launch command" /tmp/fm-"$ID"+*
  assert_no_secret_files "the tmux command log" "$TMUX_DIR/log"

  out=$(run_control launch "$ID" 2>&1); rc=$?
  expect_code 0 "$rc" "launching a running worker again should report its route"
  assert_equals "$spawn_gen" "$(route_value "$out" spawn_gen)" "a repeated launch reports the same worker"
  assert_equals 1 "$(grep -c '^new-window' "$TMUX_DIR/log")" "a repeated launch starts no second worker"

  printf 'bash\n' > "$TMUX_DIR/pane-command"
  cp "$meta" "$CASE/meta.before"
  out=$(run_control launch "$ID" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "launch over an exited worker was accepted"
  assert_contains "$out" "recover it with control relaunch" "the refusal points at relaunch"
  cmp -s "$CASE/meta.before" "$meta" || fail "a refused launch changed the task record"
  pass "launch runs the host's spawn on tmux, reports the route, without a credential environment"
}

test_launch_uses_an_existing_tmux_server_without_credentials() {
  local out rc
  new_case existing-server
  provision_ship claude
  launch_ready
  : > "$TMUX_DIR/server"
  out=$(run_control launch "$ID" 2>&1); rc=$?
  expect_code 0 "$rc" "launch should use an existing server without a token"
  assert_present "$TASK_HOME/state/$ID.meta" "launch publishes the worker"
  assert_no_secret_text "launch on existing server" "$out"
  assert_no_secret_files "tmux log and environment" "$TMUX_DIR/log" "$TMUX_DIR/environment"
  pass "launch uses an existing tmux server without credential checks"
}

test_read_verbs_report_the_endpoint() {
  local out rc head
  new_case read
  provision_ship claude
  launch_ready
  run_control launch "$ID" >/dev/null 2>&1 || fail "launch failed"

  assert_equals alive "$(run_control state "$ID" 2>/dev/null)" "state reads a running worker"
  printf 'fake pane line one\nfake pane line two\n' > "$TMUX_DIR/pane"
  out=$(run_control observe "$ID" 2>&1); rc=$?
  expect_code 0 "$rc" "observe should succeed"$'\n'"$out"
  assert_equals fm-remote-task-control.v1 "$(route_value "$out" schema)" "observe is schema-tagged"
  case "$(route_value "$out" now)" in ''|*[!0-9]*) fail "observe now is not an epoch" ;; esac
  case "$(route_value "$out" boot)" in unknown|[0-9]*) ;; *) fail "observe boot is neither an epoch nor unknown" ;; esac
  assert_equals alive "$(route_value "$out" agent)" "observe reads the agent"
  assert_equals busy "$(route_value "$out" busy)" "a freshly launched worker is busy"
  assert_equals fm-spawn "$(route_value "$out" busy_source)" "observe names the busy source"
  # The watcher hashes the captured text as a command substitution holds it,
  # without its trailing newline.
  assert_equals "$(printf 'fake pane line one\nfake pane line two' | hash_text)" "$(route_value "$out" pane_hash)" \
    "observe hashes the pane as the watcher does"
  case "$(route_value "$out" worktree_write)" in ''|*[!0-9]*) fail "observe worktree_write is not an epoch" ;; esac
  assert_equals none "$(route_value "$out" inbox_oldest)" "no steer is waiting"
  case "$(route_value "$out" turn_at)" in ''|*[!0-9]*) fail "observe turn_at is not an epoch" ;; esac
  assert_equals "$(stat -c %Y "$TASK_HOME/state/$ID.meta" 2>/dev/null || stat -f %m "$TASK_HOME/state/$ID.meta")" \
    "$(route_value "$out" turn_at)" "before a completed turn, turn_at is the spawn record's time"

  run_control send "$ID" "rebase onto main" 0123456789abcdef >/dev/null 2>&1 || fail "send failed"
  out=$(run_control observe "$ID" 2>&1)
  assert_equals 001.msg "$(route_value "$out" inbox_oldest)" "observe names the oldest unacknowledged steer"
  case "$(route_value "$out" inbox_oldest_at)" in ''|*[!0-9]*) fail "observe inbox_oldest_at is not an epoch" ;; esac

  : > "$TMUX_DIR/log"
  out=$(run_control ring "$ID" 001.msg 2>&1) || fail "ring failed: $out"
  assert_equals fm-remote-task-control.v1 "$(route_value "$out" schema)" "ring is schema-tagged"
  assert_equals rang "$(route_value "$out" ring)" "ring rings the doorbell for an unacknowledged steer"
  grep -q 'Firstmate instruction waiting' "$TMUX_DIR/log" || fail "ring typed no doorbell"
  out=$(run_control ring "$ID" 009.msg 2>&1) || fail "ring of an absent record failed: $out"
  assert_equals absent "$(route_value "$out" ring)" "ring reports a record that does not exist"
  out=$(run_control ring "$ID" ../001.msg 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "ring accepted a record name that is not NNN.msg"

  out=$(run_control capture "$ID" 5 2>&1) || fail "capture failed"
  assert_contains "$out" "fake pane line two" "capture returns the pane"
  out=$(run_control capture "$ID" 101 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "an oversized capture was accepted"
  out=$(run_control capture "$ID" 0 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "an empty capture was accepted"

  out=$(run_control head "$ID" 2>&1) || fail "head failed: $out"
  head=$(git -C "$WT" rev-parse HEAD)
  assert_equals "$head" "$(route_value "$out" head)" "head names the worktree HEAD"
  assert_equals '' "$(route_value "$out" branch)" "a detached worktree has no branch"
  assert_equals no "$(route_value "$out" dirty)" "a clean worktree is not dirty"
  git -C "$WT" checkout -q -b "fm/$ID"
  printf 'untracked\n' > "$WT/new-file"
  out=$(run_control head "$ID" 2>&1)
  assert_equals "fm/$ID" "$(route_value "$out" branch)" "head names the checked-out branch"
  assert_equals yes "$(route_value "$out" dirty)" "an untracked file makes the worktree dirty"

  printf 'needs-decision [at=1]: which way\n' >> "$TASK_HOME/state/$ID.status"
  out=$(run_control crew-state "$ID" 2>&1) || fail "crew-state failed: $out"
  assert_contains "$(route_value "$out" crew_state)" "source: pane" "crew-state reads the pane without a run"
  assert_not_contains "$out" "status-log" "crew-state leaves the host's status log out"
  assert_not_contains "$out" "parked" "the host's open decision does not decide the crew's state"
  assert_equals busy "$(route_value "$out" busy)" "crew-state reports the busy verdict"

  printf 'bash\n' > "$TMUX_DIR/pane-command"
  assert_equals dead "$(run_control state "$ID" 2>/dev/null)" "state reads an exited agent as dead"
  out=$(run_control ring "$ID" 001.msg 2>&1) || fail "ring of an exited agent failed: $out"
  assert_equals unavailable "$(route_value "$out" ring)" "ring types nothing into an exited agent's pane"
  mv "$TASK_HOME/state/$ID.inbox/001.msg" "$TASK_HOME/state/$ID.inbox/handled/"
  out=$(run_control ring "$ID" 001.msg 2>&1) || fail "ring of an acknowledged record failed: $out"
  assert_equals handled "$(route_value "$out" ring)" "ring reports an acknowledged steer"
  out=$(run_control observe "$ID" 2>&1) || fail "observe of an exited agent failed"
  assert_equals dead "$(route_value "$out" busy)" "an exited agent cannot remain busy"
  assert_equals endpoint-gone "$(route_value "$out" busy_source)" "observe identifies the exited agent"
  rm -f "$TMUX_DIR/window"
  assert_equals missing "$(run_control state "$ID" 2>/dev/null)" "state reads a vanished window as missing"
  out=$(run_control observe "$ID" 2>&1) || fail "observe of a vanished window failed"
  assert_equals missing "$(route_value "$out" agent)" "observe sees the vanished endpoint"
  assert_equals dead "$(route_value "$out" busy)" "a vanished worker cannot remain busy"
  assert_equals endpoint-gone "$(route_value "$out" busy_source)" "observe attributes death to the endpoint"
  out=$(run_control crew-state "$ID" 2>&1) || fail "crew-state of a vanished window failed"
  assert_equals dead "$(route_value "$out" busy)" "crew-state ignores the stale busy record"
  assert_equals endpoint-gone "$(route_value "$out" busy_source)" "crew-state attributes death to the endpoint"
  pass "state, observe, ring, capture, head, and crew-state read the host-local endpoint"
}

test_send_writes_one_durable_record_per_steer() {
  local out rc inbox steer=$'rebase onto main\nthen rerun the suite'
  local first=0123456789abcdef second=fedcba9876543210 third=00112233445566aa
  new_case send
  provision_ship claude
  out=$(run_control send "$ID" "too early" "$first" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a steer for a task with no worker was accepted"
  launch_ready
  run_control launch "$ID" >/dev/null 2>&1 || fail "launch failed"
  inbox="$TASK_HOME/state/$ID.inbox"
  run_control send "$ID" "$steer" "$first" >/dev/null 2>&1 || fail "send failed"
  assert_present "$inbox/001.msg" "the steer is a durable record in the task's inbox"
  assert_contains "$(cat "$inbox/001.msg")" "$steer" "the record keeps the whole message"
  assert_contains "$(cat "$inbox/001.msg")" "request=$first" "the record carries the steer's request id"
  run_control send "$ID" "$steer" "$first" >/dev/null 2>&1 || fail "a retried send failed"
  assert_absent "$inbox/002.msg" "a retry of the same request lands on its existing record"
  run_control send "$ID" "a second steer" "$second" >/dev/null 2>&1 || fail "a second send failed"
  assert_present "$inbox/002.msg" "a new steer gets a new record"
  mv "$inbox/001.msg" "$inbox/handled/"
  out=$(run_control send "$ID" "$steer" "$first" 2>&1) || fail "retrying an acknowledged request failed"
  assert_contains "$out" "already delivered and acknowledged" "a retried request is not delivered twice"
  assert_absent "$inbox/003.msg" "a retried acknowledged request writes nothing"
  run_control send "$ID" "$steer" "$third" >/dev/null 2>&1 || fail "repeating the steer as a new request failed"
  assert_present "$inbox/003.msg" "the same text under a new request id is a new instruction"
  out=$(run_control send "$ID" "a different steer" "$first" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a request id already keying another steer was accepted"
  assert_contains "$out" "request id $first already keys a different steer" "the conflict names the request id"
  assert_absent "$inbox/004.msg" "a conflicting request writes nothing"
  out=$(run_control send "$ID" "x" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a steer without a request id was accepted"
  out=$(run_control send "$ID" "x" bogus 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a malformed request id was accepted"
  assert_contains "$out" "16 lowercase hex characters" "the refusal names the request id shape"
  pass "send writes one idempotent record per request into the task's own inbox"
}

test_brief_update_replaces_the_brief_only_for_this_home() {
  local out rc
  new_case brief-update
  provision_ship claude
  render_brief "$CASE/updated.md" "$TASK_HOME" --mode direct-PR
  printf '\nAn added line for the relaunch.\n' >> "$CASE/updated.md"
  out=$(run_control brief-update "$ID" < "$CASE/updated.md" 2>&1); rc=$?
  expect_code 0 "$rc" "a brief for this home should replace the old one"$'\n'"$out"
  assert_contains "$out" "brief=updated" "brief-update reports the update"
  assert_equals "$(sha256_of "$CASE/updated.md")" "$(route_value "$out" brief_sha256)" "brief-update reports the new brief's digest"
  cmp -s "$CASE/updated.md" "$TASK_HOME/data/$ID/brief.md" || fail "the brief was not replaced byte for byte"

  render_brief "$CASE/foreign.md" "$CASE/elsewhere/fm-home" --mode direct-PR
  out=$(run_control brief-update "$ID" < "$CASE/foreign.md" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a brief for another home was accepted"
  assert_contains "$out" "append status to $CASE/elsewhere/fm-home/state/$ID.status" "the refusal names the foreign status file"
  cmp -s "$CASE/updated.md" "$TASK_HOME/data/$ID/brief.md" || fail "a refused brief changed the brief on disk"
  out=$(run_control brief-update "$ID" < /dev/null 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "an empty brief was accepted"
  [ -z "$(find "$TASK_HOME/data/$ID" -name '.brief.md.update.*' -print)" ] || fail "a refused brief left its staging file"
  pass "brief-update replaces the brief only with one naming this home's status file"
}

test_control_drives_the_host_control_plane() {
  local out rc spawn_gen
  new_case control
  write_manifest "$CASE/manifest" ship claude
  printf 'config=launch-env-allowlist|%s\n' "$(printf 'OPENAI_API_KEY' | b64)" >> "$CASE/manifest"
  out=$(run_control provision "$ID" < "$CASE/manifest" 2>&1) || fail "provision failed: $out"
  launch_ready
  out=$(run_control launch "$ID" 2>&1) || fail "launch failed: $out"
  spawn_gen=$(route_value "$out" spawn_gen)

  out=$(run_control key "$ID" Escape 2>/dev/null); rc=$?
  expect_code 0 "$rc" "a named key should be delivered"
  assert_line "$TMUX_DIR/log" "send-keys -t firstmate:fm-$ID Escape"
  out=$(run_control key "$ID" 2>&1); rc=$?
  expect_code 2 "$rc" "key without a key name is a usage error"

  out=$(run_control control "$ID" interrupt 2>&1); rc=$?
  expect_code 0 "$rc" "interrupt should be delivered"$'\n'"$out"
  assert_contains "$out" "interrupt-delivered $ID" "interrupt relays fm-control's result"

  out=$(run_control control "$ID" relaunch bogus - - "note" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "an unverified relaunch harness was accepted"
  out=$(run_control control "$ID" relaunch - - - "   " 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a relaunch without a progress note was accepted"
  assert_contains "$out" "nonempty progress note" "the empty note is named"
  out=$(run_control control "$ID" relaunch - - 2>&1); rc=$?
  expect_code 2 "$rc" "an incomplete relaunch is a usage error"
  out=$(run_control control "$ID" teleport 2>&1); rc=$?
  expect_code 2 "$rc" "an unknown control action is a usage error"

  # fm-control types the exit command only into a composer it can prove empty:
  # Claude's bare prompt glyph on the cursor row.
  printf '\342\235\257\n' > "$TMUX_DIR/pane"
  out=$(FM_CONTROL_POLL=0.1 run_control control "$ID" relaunch - default - "Resume from the committed state." 2>&1); rc=$?
  expect_code 0 "$rc" "relaunch should replace the worker"$'\n'"$out"
  assert_equals fm-remote-task-control.v1 "$(route_value "$out" schema)" "relaunch ends with the route block"
  [ "$(route_value "$out" spawn_gen)" != "$spawn_gen" ] || fail "relaunch reported the old worker"
  assert_line "$TASK_HOME/state/$ID.meta" "spawn_gen=$(route_value "$out" spawn_gen)" "the route is read back from the republished record"
  assert_equals claude "$(route_value "$out" harness)" "relaunch keeps the recorded harness"
  assert_no_secret_text "relaunch output" "$out"

  printf 'bash\n' > "$TMUX_DIR/pane-command"
  out=$(FM_CONTROL_POLL=0.1 run_control control "$ID" exit 2>&1); rc=$?
  expect_code 0 "$rc" "exit of a stopped worker is idempotent"$'\n'"$out"
  assert_no_secret_text "control output" "$out"
  assert_no_secret_files "relaunch commands and environment" "$TMUX_DIR/log" "$TMUX_DIR/environment" "$CASE/git.argv" "$CASE/gh.argv" /tmp/fm-"$ID" /tmp/fm-"$ID"+*
  assert_no_secret_files "relaunch home records" "$TASK_HOME"
  assert_equals OPENAI_API_KEY "$(cat "$TASK_HOME/config/launch-env-allowlist")" "relaunch does not add a token to the allowlist"
  pass "control relays interrupt and exit and relaunches through the host's control plane"
}

test_retire_runs_the_host_teardown_for_ships_only() {
  local out rc
  new_case retire
  provision_ship claude
  launch_ready
  run_control launch "$ID" >/dev/null 2>&1 || fail "launch failed"
  printf 'bash\n' > "$TMUX_DIR/pane-command"
  printf 'unlanded\n' > "$WT/work-in-progress"
  out=$(run_control retire "$ID" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "retire over unlanded work was accepted"
  assert_contains "$out" "REFUSED" "the host teardown's refusal is relayed"
  assert_present "$TASK_HOME/state/$ID.meta" "a refused retire keeps the task record"
  assert_present "$WT/work-in-progress" "a refused retire keeps the unlanded work"
  assert_absent "$TASK_HOME/state/$ID.retired" "a refused retire records no retirement"

  rm -f "$WT/work-in-progress"
  out=$(run_control retire "$ID" 2>&1); rc=$?
  expect_code 0 "$rc" "retire of landed work should pass"$'\n'"$out"
  assert_contains "$out" "teardown $ID complete" "the host teardown's result is relayed"
  assert_absent "$TASK_HOME/state/$ID.meta" "retire removes the task record"
  assert_present "$TASK_HOME/state/$ID.retired" "retire records the retirement"
  out=$(run_control observe "$ID" 2>&1)
  assert_equals missing "$(route_value "$out" agent)" "a retired task has no endpoint to observe"
  assert_equals missing "$(run_control state "$ID" 2>/dev/null)" "a retired task's state is missing"
  assert_absent "$CASE/gh.revokes" "a stored token that is not an App installation token is never revoked"
  out=$(run_control retire "$ID" 2>&1); rc=$?
  expect_code 0 "$rc" "a repeated retire should succeed"
  assert_equals "already-retired: $ID" "$out" "a repeated retire reports already-retired"
  out=$(run_control retire "$ID" --now 2>&1); rc=$?
  expect_code 2 "$rc" "an unknown retire flag is a usage error"

  new_case retire-scout
  write_manifest "$CASE/manifest" scout claude
  run_control provision "$ID" < "$CASE/manifest" >/dev/null 2>&1 || fail "scout provision failed"
  out=$(run_control retire "$ID" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "retiring a scout on its host was accepted"
  assert_contains "$out" "is a scout" "the scout refusal names the kind"
  pass "retire relays the host teardown's landed-work verdict, records a pass, and refuses scouts"
}

refresh_input() { # <token>; one cred-refresh request on stdout
  printf 'gh_token_b64=%s\n' "$(printf '%s' "$1" | b64)"
}

test_cred_refresh_replaces_the_stored_token() {
  local out rc again fp store
  new_case cred-refresh
  provision_ship claude
  store="$ACCOUNT_HOME/.config/gh/hosts.yml"
  refresh_input "$REFRESH_SECRET" > "$CASE/refresh"
  out=$(run_control cred-refresh "$ID" < "$CASE/refresh" 2>&1); rc=$?
  expect_code 0 "$rc" "a valid refresh should store the new token"$'\n'"$out"
  fp=$(token_fp "$REFRESH_SECRET")
  assert_equals "schema=fm-remote-task-control.v1"$'\n'"refresh=stored"$'\n'"task_id=$ID"$'\n'"gh_token_fp=$fp" "$out" \
    "the refresh reports the stored token's fingerprint"
  assert_equals "$REFRESH_SECRET" "$(cat "$store")" "the gh store holds the new token"
  assert_equals 600 "$(mode_of "$store")" "the refreshed credential file is private"
  grep -q ' credential refresh gh_token=gh/github.com$' "$TASK_HOME/state/task-provision.journal" \
    || fail "the refresh is journaled"
  again=$(run_control cred-refresh "$ID" < "$CASE/refresh" 2>&1); rc=$?
  expect_code 0 "$rc" "replaying a refresh should succeed"
  assert_equals "$out" "$again" "a replayed refresh reports the same block"
  assert_equals "$REFRESH_SECRET" "$(cat "$store")" "a replayed refresh leaves the same token"

  out=$(run_control cred-refresh "other-$ID" < "$CASE/refresh" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a refresh for another task was accepted"
  assert_contains "$out" "belongs to task $ID, not other-$ID" "a refresh for another task names the home's owner"
  : > "$CASE/empty"
  out=$(run_control cred-refresh "$ID" < "$CASE/empty" 2>&1)
  assert_contains "$out" "has no gh_token_b64 line" "an empty refresh is refused"
  { refresh_input "$APP_SECRET"; printf 'pi_auth_b64=e30=\n'; } > "$CASE/extra"
  out=$(run_control cred-refresh "$ID" < "$CASE/extra" 2>&1)
  assert_contains "$out" "carries a line other than gh_token_b64" "a refresh carries nothing but the token"
  { refresh_input "$APP_SECRET"; refresh_input "$APP_SECRET"; } > "$CASE/twice"
  out=$(run_control cred-refresh "$ID" < "$CASE/twice" 2>&1)
  assert_contains "$out" "repeats gh_token_b64" "a refresh names one token"
  printf 'gh_token_b64=@@not-base64@@\n' > "$CASE/garbled"
  out=$(run_control cred-refresh "$ID" < "$CASE/garbled" 2>&1)
  assert_contains "$out" "the credential refresh's GitHub token is not valid base64" "an undecodable token is refused"
  refresh_input "ghs_two words" > "$CASE/spaced"
  out=$(run_control cred-refresh "$ID" < "$CASE/spaced" 2>&1)
  assert_contains "$out" "must be printable ASCII without spaces" "an unusable token is refused"
  head -c 70000 /dev/zero | tr '\0' a > "$CASE/huge"
  out=$(run_control cred-refresh "$ID" < "$CASE/huge" 2>&1)
  assert_contains "$out" "exceeds its 64 KiB bound" "an oversized refresh is refused"
  refresh_input "$APP_SECRET" > "$CASE/failing"
  out=$(FM_FAKE_GH_FAIL=1 run_control cred-refresh "$ID" < "$CASE/failing" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a refresh gh could not store was accepted"
  assert_contains "$out" "gh credential storage failed for github.com" "a failed store is named"
  assert_no_secret_text "a failed refresh" "$out"
  assert_equals "$REFRESH_SECRET" "$(cat "$store")" "every refused refresh keeps the previous token"
  assert_equals 2 "$(grep -c ' credential refresh ' "$TASK_HOME/state/task-provision.journal")" "only stored refreshes are journaled"
  assert_no_secret_files "the task home after refreshes" "$TASK_HOME"
  [ -z "$(find "$CASE/tmp" -mindepth 1 -print)" ] || fail "refreshes left staging files: $(find "$CASE/tmp" -mindepth 1 -print)"

  : > "$TASK_HOME/state/$ID.retired"
  out=$(run_control cred-refresh "$ID" < "$CASE/refresh" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a retired task's token was refreshed"
  assert_contains "$out" "is retired on this host" "a retired task is never refreshed"

  new_case cred-unprovisioned
  mkdir -p "$TASK_HOME"
  out=$(run_control cred-refresh "$ID" < "$CASE/../cred-refresh/refresh" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "an unprovisioned home accepted a refresh"
  assert_contains "$out" "not a provisioned sandbox task home" "an unprovisioned home is refused"
  assert_absent "$ACCOUNT_HOME/.config/gh/hosts.yml" "an unprovisioned home stores nothing"
  pass "cred-refresh stores a fresh token idempotently and refuses another task, an unprovisioned or retired home, and malformed input"
}

test_retire_revokes_a_stored_app_token() {
  local out rc fp
  new_case retire-app
  write_manifest "$CASE/manifest" ship claude
  manifest_set "$CASE/manifest" gh_token_b64 "gh_token_b64=$(printf '%s' "$APP_SECRET" | b64)"
  run_control provision "$ID" < "$CASE/manifest" >/dev/null 2>&1 || fail "provisioning with an App token failed"
  launch_ready
  run_control launch "$ID" >/dev/null 2>&1 || fail "launch failed"
  printf 'bash\n' > "$TMUX_DIR/pane-command"
  out=$(run_control retire "$ID" 2>&1); rc=$?
  expect_code 0 "$rc" "retire of landed work should pass"$'\n'"$out"
  fp=$(token_fp "$APP_SECRET")
  assert_contains "$out" "teardown $ID complete" "the host teardown's result is relayed"
  assert_equals "gh_token_revoke=revoked"$'\n'"gh_token_fp=$fp" "$(printf '%s\n' "$out" | grep '^gh_token_')" \
    "retire reports the App token's revoke and fingerprint"
  assert_equals 1 "$(grep -c . "$CASE/gh.revokes")" "retire deletes the installation token once"
  grep -q ' credential revoke gh_token result=revoked$' "$TASK_HOME/state/task-provision.journal" \
    || fail "the revoke is journaled"
  assert_equals "revoked $fp" "$(cat "$TASK_HOME/state/$ID.gh-token-revoke")" "the revoke result is kept for a retry"
  assert_no_secret_text "retire output" "$out"
  assert_no_secret_files "the retired home" "$TASK_HOME"
  out=$(run_control retire "$ID" 2>&1); rc=$?
  expect_code 0 "$rc" "a repeated retire should succeed"
  assert_equals "already-retired: $ID"$'\n'"gh_token_revoke=revoked"$'\n'"gh_token_fp=$fp" "$out" \
    "a repeated retire reports the recorded revoke"
  assert_equals 1 "$(grep -c . "$CASE/gh.revokes")" "a repeated retire never deletes again"

  new_case retire-app-failed
  write_manifest "$CASE/manifest" ship claude
  manifest_set "$CASE/manifest" gh_token_b64 "gh_token_b64=$(printf '%s' "$APP_SECRET" | b64)"
  run_control provision "$ID" < "$CASE/manifest" >/dev/null 2>&1 || fail "provisioning with an App token failed"
  launch_ready
  run_control launch "$ID" >/dev/null 2>&1 || fail "launch failed"
  printf 'bash\n' > "$TMUX_DIR/pane-command"
  printf '502\n' > "$CASE/gh-revoke-status"
  out=$(run_control retire "$ID" 2>&1); rc=$?
  expect_code 1 "$rc" "a failed revoke blocks retirement"$'\n'"$out"
  assert_contains "$out" "gh_token_revoke=failed" "a revoke GitHub did not confirm is reported as failed"
  assert_absent "$TASK_HOME/state/$ID.retired" "an unconfirmed revoke keeps retirement retryable"
  printf '204\n' > "$CASE/gh-revoke-status"
  out=$(run_control retire "$ID" 2>&1); rc=$?
  expect_code 0 "$rc" "a later confirmed revoke completes retirement"$'\n'"$out"
  assert_present "$TASK_HOME/state/$ID.retired" "confirmed retirement is recorded"
  assert_equals 2 "$(grep -c . "$CASE/gh.revokes")" "the failed revoke is retried"
  out=$(run_control retire "$ID" 2>&1); rc=$?
  expect_code 0 "$rc" "successful retirement replays"
  assert_equals 2 "$(grep -c . "$CASE/gh.revokes")" "replay does not revoke again"

  new_case retire-app-expiry
  write_manifest "$CASE/manifest" ship claude
  manifest_set "$CASE/manifest" gh_token_b64 "gh_token_b64=$(printf '%s' "$APP_SECRET" | b64)"
  run_control provision "$ID" < "$CASE/manifest" >/dev/null 2>&1 || fail "provision failed"
  launch_ready
  run_control launch "$ID" >/dev/null 2>&1 || fail "launch failed"
  printf 'bash\n' > "$TMUX_DIR/pane-command"
  printf '502\n' > "$CASE/gh-revoke-status"
  printf '1 mint github task=%s fp=%s expires=2099-01-01T00:00:00Z\n' "$ID" "$fp" > "$CASE/ledger"
  out=$(run_control retire "$ID" < "$CASE/ledger" 2>&1); rc=$?
  expect_code 1 "$rc" "a live token cannot close retirement"
  out=$(run_control retire "$ID" < "$CASE/ledger" 2>&1); rc=$?
  expect_code 1 "$rc" "persistent failure stays retryable"
  assert_absent "$TASK_HOME/state/$ID.retired" "no marker exists before expiry"
  printf '1 mint github task=%s fp=%s expires=2000-01-01T00:00:00Z\n' "$ID" "$fp" > "$CASE/ledger"
  out=$(run_control retire "$ID" < "$CASE/ledger" 2>&1); rc=$?
  expect_code 0 "$rc" "ledger expiry closes persistent revoke failure"$'\n'"$out"
  assert_contains "$out" 'gh_token_revoke=expired' "expiry is distinguished from revocation"
  out=$(run_control retire "$ID" < "$CASE/ledger" 2>&1); rc=$?
  expect_code 0 "$rc" "expiry closure replays"
  assert_contains "$out" 'gh_token_revoke=expired' "replay retains the closure reason"
  assert_equals 3 "$(grep -c . "$CASE/gh.revokes")" "expiry replay does not repeat revocation"
  pass "retire revokes a stored App installation token once, reports it, and keeps the result for a retry"
}

test_retire_without_credentials_or_gh() {
  local out rc base_path
  new_case retire-no-gh
  write_manifest "$CASE/manifest" ship claude
  manifest_set "$CASE/manifest" gh_token_b64 ''
  run_control provision "$ID" < "$CASE/manifest" >/dev/null 2>&1 || fail "provision failed"
  launch_ready
  run_control launch "$ID" >/dev/null 2>&1 || fail "launch failed"
  printf 'bash\n' > "$TMUX_DIR/pane-command"
  base_path=$(fm_test_base_path_sans "$FAKEBIN:$PATH" gh)
  out=$(PATH="$base_path" FAKEBIN="$base_path" run_control retire "$ID" 2>&1); rc=$?
  expect_code 0 "$rc" "credential-free retirement does not require gh"$'\n'"$out"
  assert_present "$TASK_HOME/state/$ID.retired" "credential-free retirement completes"
  assert_absent "$CASE/gh.revokes" "credential-free retirement never revokes"
}

test_dispatch_refuses_malformed_calls() {
  local out rc
  new_case dispatch
  out=$(run_control 2>&1); rc=$?
  expect_code 2 "$rc" "no verb is a usage error"
  out=$(run_control teleport "$ID" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "an unknown verb was accepted"
  assert_contains "$out" "unknown command: teleport" "the unknown verb is named"
  out=$(run_control state '../escape' 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "an unsafe task id was accepted"
  assert_contains "$out" "invalid task id" "the unsafe id is refused"
  out=$(run_control provision .. < /dev/null 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a traversal task id was accepted"
  assert_absent "$TASK_HOME" "a refused call created no home"
  pass "the dispatcher refuses unknown verbs, unsafe ids, and unprovisioned homes"
}

test_provision_builds_a_private_marked_home
test_provision_is_idempotent_and_refuses_another_task_or_manifest
test_provision_rolls_back_a_failed_attempt
test_provision_refuses_unsafe_manifests
test_provision_refuses_non_api_key_credentials
test_provision_requires_gh_for_a_token
test_git_credentials_are_repository_and_host_scoped
test_launch_reports_the_route_without_credential_environment
test_launch_uses_an_existing_tmux_server_without_credentials
test_read_verbs_report_the_endpoint
test_send_writes_one_durable_record_per_steer
test_brief_update_replaces_the_brief_only_for_this_home
test_control_drives_the_host_control_plane
test_retire_runs_the_host_teardown_for_ships_only
test_cred_refresh_replaces_the_stored_token
test_retire_revokes_a_stored_app_token
test_retire_without_credentials_or_gh
test_dispatch_refuses_malformed_calls
echo "ALL TESTS PASSED"

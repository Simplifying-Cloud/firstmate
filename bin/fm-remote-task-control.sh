#!/usr/bin/env bash
# Host-local control for the one-task sandbox home selected by fm-on.
#
# Usage:
#   fm-remote-task-control.sh provision <id>              (manifest on stdin)
#   fm-remote-task-control.sh launch <id>
#   fm-remote-task-control.sh state <id>
#   fm-remote-task-control.sh observe <id>
#   fm-remote-task-control.sh capture <id> [lines]
#   fm-remote-task-control.sh send <id> <message> <request-id>
#   fm-remote-task-control.sh ring <id> <NNN.msg>
#   fm-remote-task-control.sh key <id> <key>
#   fm-remote-task-control.sh crew-state <id>
#   fm-remote-task-control.sh head <id>
#   fm-remote-task-control.sh control <id> interrupt|exit
#   fm-remote-task-control.sh control <id> relaunch <harness|-> <model|default|-> <effort|default|-> <note>
#   fm-remote-task-control.sh brief-update <id>           (brief on stdin)
#   fm-remote-task-control.sh cred-refresh <id>           (gh_token_b64= on stdin)
#   fm-remote-task-control.sh retire <id> [--force]
#
# A sandbox task is an ordinary ship or scout whose worker runs in a one-task
# Firstmate home on a disposable host, which the supervising primary reaches
# through bin/fm-on.sh's task route (bin/fm-remote-route-lib.sh). This script
# is that home's host-side control plane and follows
# bin/fm-remote-secondmate-control.sh: every verb but provision first validates
# the home's .fm-task-home marker for <id>, runs the ordinary host-local script
# under explicit FM_HOME, state, data, config, and projects overrides naming
# the task home, and prints a schema-tagged block where it reports an identity.
# Lifecycle code runs where the files are: launch, control, crew-state, and
# retire are this host's own fm-spawn.sh, fm-control.sh, fm-crew-state.sh, and
# fm-teardown.sh, never a reimplementation. Nothing here calls the sandbox
# provider, and nothing here removes a worktree except fm-teardown.sh behind
# its landed-work test. docs/remote-sandboxes.md owns the operator view.
#
# Every block is key=value lines opening with schema=fm-remote-task-control.v1.
#
# provision reads a fm-remote-task-provision.v1 manifest, at most 1 MiB, on
# stdin: one key=value line per field, each field at most once, any other
# field refused.
#   schema=fm-remote-task-provision.v1
#   task_id=<id>                      must equal the <id> argument
#   kind=ship|scout
#   project=<name>                    cloned into projects/<name>
#   origin_b64=<base64 clone URL>     re-validated by bin/fm-project-origin-lib.sh
#   registry_b64=<base64 line>        the project's data/projects.md line, whose
#                                     forge binding this host's spawn checks
#                                     the brief against
#   harness=<adapter>                 a verified crewmate adapter
#   model=<name|default>  effort=<low|medium|high|xhigh|max|ultra|default>
#   brief_b64=<base64 bytes>          written as data/<id>/brief.md
#   mode=no-mistakes|direct-PR  yolo=on|off  branch_prefix_b64=<base64 prefix>
#                                     a ship's delivery contract; refused on a
#                                     scout, and local-only is never placed here
#   config=<name>|<base64 content>    optional, once per name, only for
#                                     claude-permission-mode, keep-ai-trailers,
#                                     and launch-env-allowlist
#   pi_auth_b64=<base64 JSON object>  optional Pi API-key provider entries,
#                                     only for a pi or pi-signed harness;
#                                     each provider object requires type=api_key
#                                     and a nonempty string key, permits only
#                                     an optional env object of string values,
#                                     and refuses OAuth and all other fields
#   gh_token_b64=<base64 token>       optional per-repository GitHub token
# It clones the project from its origin, runs no-mistakes init for a
# no-mistakes ship, and writes the brief, the registry line, the named config,
# config/backlog-backend as manual - so this host's spawn and teardown skip the
# backlog transition that belongs to the primary - and the credentials. The
# .fm-task-home marker is written last: it commits the provision and records the
# task identity launch uses and the manifest's SHA-256. The home is created mode
# 0700. Re-running the same manifest changes nothing and reports
# provision=current; a home marked for another task, another manifest for this
# task, and an unmarked home with any content are refused. A failed provision
# removes everything it created and restores the credential files it changed.
# Prints provision=created|current, task_id, and manifest_sha256.
#
# Credentials are Pi API-key providers and the GitHub token, and nothing else
# is accepted, so no Claude credential can reach a sandbox. They arrive only on
# stdin and are written only here: the Pi entries are merged into the account's
# ~/.pi/agent/auth.json and the token is stored in the account's gh configuration
# for github.com via gh auth login --insecure-storage --with-token on stdin.
# Credential files are mode 0600. Failed provision restores the previous Pi
# and gh configuration. gh is required when a GitHub token is supplied.
# The clone and its worktrees use the absolute gh auth git-credential helper,
# scoped to https://github.com, with the same helper passed to the clone.
# A no-mistakes ship's gate repository - the bare repository no-mistakes init
# creates under the account and names as the clone's "no-mistakes" remote -
# receives the same helper, because the pipeline fetches the trusted default
# branch through it and a private origin needs the task's token there too.
# No token enters argv, URLs, Git config, the launch environment, or output.
# state/task-provision.journal records steps and credential names only.
#
# launch runs this host's fm-spawn.sh for the provisioned ship or scout on tmux
# and prints the route block - backend, target, worktree, branch (empty for a
# scout), spawn_gen, busy_gen, harness, model, and effort - read back from the
# task record the spawn published. A worker that is already running reports its
# route again; any other existing endpoint is refused, because its worktree may
# hold work that only control relaunch preserves.
#
# state prints the endpoint's recovery-grade agent state (bin/fm-backend.sh),
# missing when the task has no record. observe is one bounded call per watcher
# cadence and prints now and boot (this host's clock and boot time,
# bin/fm-control-lib.sh), agent, busy and busy_source (bin/fm-busy-lib.sh's
# classification), pane_hash (of the last 40 pane lines, as the watcher hashes
# them), worktree_write (the newest regular-file mtime in the worktree under the
# watcher's prune list, depth, and time bound from bin/fm-classify-lib.sh),
# inbox_oldest with inbox_oldest_at (the oldest unacknowledged steering record
# and its mtime), and turn_at (when the worker last completed a turn or showed
# native-harness progress, the busy-turn bound's clock from
# bin/fm-classify-lib.sh); a field that cannot be read is unknown and an absent
# one none. Every time is this host's clock, so the supervising watcher compares
# them with now rather than with its own clock.
#
# capture, send, and key match the secondmate control script: a bounded pane
# capture, a steer written idempotently into the task's own steering inbox and
# announced by its doorbell (bin/fm-task-inbox-lib.sh), and one named key
# through fm-send.sh. A task steer carries no correlation token, so send takes
# the 16-hex request id the primary minted for it: a retry of that request
# lands on its existing record, even one already acknowledged, while an
# identical steer under a new id is a new record, and an id already keying a
# different steer is refused.
#
# ring is the supervising watcher's re-ring ladder step: it rings the doorbell
# once more for the named unacknowledged record, with the same endpoint,
# composer, and liveness guards as send's ring (fm_task_inbox_ring), and prints
# ring=rang, skipped (the composer visibly holds other text), failed,
# unavailable (the agent has exited or its endpoint is missing, so nothing was
# typed), handled (already acknowledged), or absent.
#
# crew-state prints crew_state, this host's fm-crew-state.sh line computed with
# the status log left out - its run-step attribution or its pane fallback -
# because the primary's mirrored status log is the authoritative fold, plus
# busy and busy_source. The read runs with FM_CREW_STATE_FOR_PRIMARY=1, so a
# working run that is fixing or whose CI is not ready says so as its own
# component for the primary's reconciliation. head prints branch (empty when
# detached), head, and dirty (yes for any uncommitted or untracked change).
#
# control runs this host's fm-control.sh. interrupt and exit relay its output
# and status. relaunch keeps the recorded harness, model, or effort given as -,
# clears a model or effort given as default, takes the progress note fm-control
# requires as its last argument, and prints the route block from the record the
# relaunch republished. exit and relaunch accept this host's boot-time absence
# proof (FM_CONTROL_BOOT_ABSENCE_PROOF, bin/fm-control-lib.sh): the VM's tmux
# server dies with a reboot or HA restart while its disk survives, so a host
# booted after the record's launch proves a missing endpoint gone - exit then
# reports endpoint-gone, and relaunch re-creates the window in the recorded
# worktree from the brief on disk.
#
# brief-update replaces data/<id>/brief.md with the brief on stdin, because a
# relaunch reads the brief on disk, and prints brief=updated and brief_sha256.
# Provision and brief-update refuse a brief whose status-append command names
# any status file but this home's own (bin/fm-brief-heading-lib.sh), which
# bin/fm-spawn.sh refuses again at launch.
#
# cred-refresh replaces the provisioned GitHub token with a fresh one, because
# provision itself never accepts another manifest for its task: the supervising
# home's bin/fm-cred-broker.sh refresh-due pushes a new GitHub App installation
# token before the old one expires. stdin carries exactly one gh_token_b64= line,
# at most 64 KiB, validated as provision validates that field. It is refused
# for a retired task, stores the token as provision does, and restores the
# previous gh configuration if storing fails. state/task-provision.journal
# records the refresh without the value. Prints refresh=stored, task_id, and
# gh_token_fp for the primary to compare with the token it sent. The supervisor
# owns all minted-token retention and predecessor revocation in its broker.
#
# retire runs this host's fm-teardown.sh for a ship, landed-work test and all,
# and relays its output and status unchanged, so a refusal reaches the
# primary's teardown as written; --force passes through only as the captain's
# explicit discard. A scout is refused, because its worktree is scratch and its
# completion gate runs in the supervising home. After a passing teardown, a
# stored GitHub App installation token (a ghs_ token) is revoked with
# `gh api --method DELETE /installation/token`, and any other token is left
# alone. For a token it tried, retire then prints gh_token_revoke=revoked,
# invalid (GitHub already refused it), expired, or failed, with gh_token_fp;
# it journals the result and keeps it in state/<id>.gh-token-revoke. stdin may
# carry only this task's mint records: a mint matching this task and
# stored fingerprint supplies expiry evidence. A failed revoke stays retryable
# until confirmed or expired. state/<id>.teardown-passed preserves the passing
# teardown across retries; only closure writes state/<id>.retired, so SSH exit 255
# (unknown completion) prints already-retired and the recorded revoke result.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
TARGET_HOME=${FM_HOME:?FM_HOME is required}
SCHEMA=fm-remote-task-control.v1
MANIFEST_SCHEMA=fm-remote-task-provision.v1
MAX_INPUT_BYTES=1048576
LAUNCH_CONFIG_NAMES="claude-permission-mode keep-ai-trailers launch-env-allowlist"
TASK_HARNESSES="claude codex opencode pi pi-signed grok kimi cursor gemini muse rovo omp agy devin"

# shellcheck source=bin/fm-project-origin-lib.sh
. "$SCRIPT_DIR/fm-project-origin-lib.sh"
# shellcheck source=bin/fm-brief-heading-lib.sh
. "$SCRIPT_DIR/fm-brief-heading-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
validate_id() {
  case "$1" in ''|.|..|*[!A-Za-z0-9._-]*) die "invalid task id: $1" ;; esac
}

# --- small helpers -------------------------------------------------------------

kv_value() { # <file> <key>; the value of a key that appears exactly once
  local count
  count=$(LC_ALL=C grep -c "^$2=" "$1" 2>/dev/null || true)
  [ "$count" = 1 ] || return 1
  LC_ALL=C grep "^$2=" "$1" | cut -d= -f2-
}

marker_field() { # <key>
  kv_value "$TARGET_HOME/.fm-task-home" "$1" || die "the sandbox task home marker does not record $1 exactly once"
}

base64_decode_to() { # <encoded> <destination>
  if printf '%s' "$1" | base64 --decode > "$2" 2>/dev/null; then return 0; fi
  if printf '%s' "$1" | base64 -D > "$2" 2>/dev/null; then return 0; fi
  return 1
}

sha256_file() { # <path>
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum < "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 < "$1" | awk '{print $1}'
  else
    return 1
  fi
}

file_mtime() { # <path>; epoch seconds
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

has_nul() { # <path>
  [ "$(LC_ALL=C tr -cd '\000' < "$1" | LC_ALL=C wc -c | tr -d ' ')" != 0 ]
}

# The exact hash bin/fm-watch.sh applies to a pane's last 40 lines.
hash_text() {
  if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d' ' -f1; fi
}

run_host() { # <script> [args...]; one of this host's scripts, on the task home
  FM_HOME="$TARGET_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
    FM_STATE_OVERRIDE="$TARGET_HOME/state" FM_DATA_OVERRIDE="$TARGET_HOME/data" \
    FM_CONFIG_OVERRIDE="$TARGET_HOME/config" FM_PROJECTS_OVERRIDE="$TARGET_HOME/projects" \
    "$SCRIPT_DIR/$1" "${@:2}"
}

validate_home() { # <id>; pure, so it runs before any library can create state/
  local id=$1 marker owner dir
  [ -d "$TARGET_HOME" ] && [ ! -L "$TARGET_HOME" ] || die "the sandbox task home is unavailable or unsafe"
  marker="$TARGET_HOME/.fm-task-home"
  [ -f "$marker" ] && [ ! -L "$marker" ] || die "the remote home is not a provisioned sandbox task home"
  owner=$(kv_value "$marker" task_id) || die "the sandbox task home marker is malformed"
  [ "$owner" = "$id" ] || die "the sandbox task home belongs to task $owner, not $id"
  for dir in data state config projects; do
    [ -d "$TARGET_HOME/$dir" ] && [ ! -L "$TARGET_HOME/$dir" ] \
      || die "the sandbox task home has an unsafe or missing $dir directory"
  done
}

# --- provision -------------------------------------------------------------------

PROVISION_TMP=
PROVISION_LOCK=
PROVISION_LOCK_HELD=0
PROVISION_PUBLISHED=0
PROVISION_CREATED_HOME=0
PROVISION_EMPTY_HOME=0
PI_AUTH_FILE=
PI_AUTH_WRITTEN=0
PI_AUTH_BACKUP=0
GH_AUTH_DIR=
GH_AUTH_WRITTEN=0
GH_BIN=
P_SEEN=' '
P_CONFIG_NAMES=
P_DIGEST=
P_PI_PROVIDERS=
P_BRANCH_PREFIX=
P_FIELD_schema=
P_FIELD_task_id=
P_FIELD_kind=
P_FIELD_project=
P_FIELD_origin_b64=
P_FIELD_registry_b64=
P_FIELD_harness=
P_FIELD_model=
P_FIELD_effort=
P_FIELD_brief_b64=
P_FIELD_mode=
P_FIELD_yolo=
P_FIELD_branch_prefix_b64=
P_FIELD_pi_auth_b64=
P_FIELD_gh_token_b64=

provision_has() { case "$P_SEEN" in *" $1 "*) return 0 ;; esac; return 1; }

provision_cleanup() {
  local status=$? name
  if [ "$PROVISION_PUBLISHED" -eq 0 ] && [ "$status" -ne 0 ]; then
    if [ "$GH_AUTH_WRITTEN" -eq 1 ]; then
      for name in hosts.yml config.yml; do
        if [ -f "$PROVISION_TMP/gh-$name.before" ]; then
          cp -p -- "$PROVISION_TMP/gh-$name.before" "$GH_AUTH_DIR/$name" 2>/dev/null \
            || printf 'error: could not restore gh %s after the failed provision\n' "$name" >&2
        else
          rm -f -- "$GH_AUTH_DIR/$name" 2>/dev/null || true
        fi
      done
    fi
    if [ "$PI_AUTH_WRITTEN" -eq 1 ]; then
      if [ "$PI_AUTH_BACKUP" -eq 1 ]; then
        cp -p -- "$PROVISION_TMP/pi-auth.before" "$PI_AUTH_FILE.rollback.$$" 2>/dev/null \
          && mv -f -- "$PI_AUTH_FILE.rollback.$$" "$PI_AUTH_FILE" 2>/dev/null \
          || printf 'error: could not restore %s after the failed provision\n' "$PI_AUTH_FILE" >&2
      else
        rm -f -- "$PI_AUTH_FILE" 2>/dev/null || true
      fi
    fi
    if [ "$PROVISION_CREATED_HOME" -eq 1 ]; then
      rm -rf -- "$TARGET_HOME" 2>/dev/null || true
    elif [ "$PROVISION_EMPTY_HOME" -eq 1 ]; then
      find "$TARGET_HOME" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || true
    fi
  fi
  if [ "$PROVISION_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$PROVISION_LOCK" || true
    PROVISION_LOCK_HELD=0
  fi
  [ -z "$PROVISION_TMP" ] || rm -rf -- "$PROVISION_TMP"
  exit "$status"
}

# Read and validate the whole manifest before anything outside the private
# staging directory changes. Errors never quote a manifest value that could
# carry a secret.
provision_read() { # <id>
  local id=$1 bytes line key value name encoded credential_error
  umask 077
  PROVISION_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-task-provision.XXXXXX") \
    || die "cannot create private provisioning state"
  trap provision_cleanup EXIT
  trap 'exit 1' HUP INT TERM
  head -c "$((MAX_INPUT_BYTES + 1))" > "$PROVISION_TMP/manifest" || die "cannot read the provisioning manifest"
  bytes=$(LC_ALL=C wc -c < "$PROVISION_TMP/manifest" | tr -d ' ')
  [ "$bytes" -le "$MAX_INPUT_BYTES" ] || die "the provisioning manifest exceeds its 1 MiB bound"
  [ "$bytes" -gt 0 ] || die "the provisioning manifest is empty"
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    case "$line" in *=*) ;; *) die "the provisioning manifest has a line that is not key=value" ;; esac
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      config)
        name=${value%%|*}
        encoded=${value#*|}
        [ "$name" != "$value" ] || die "a provisioning manifest config field is not <name>|<base64>"
        case " $LAUNCH_CONFIG_NAMES " in
          *" $name "*) ;;
          *) die "the provisioning manifest carries config a sandbox does not take" ;;
        esac
        case "$P_CONFIG_NAMES " in *" $name "*) die "the provisioning manifest repeats config $name" ;; esac
        P_CONFIG_NAMES="$P_CONFIG_NAMES $name"
        base64_decode_to "$encoded" "$PROVISION_TMP/config.$name" \
          || die "the provisioning manifest's $name config is not valid base64"
        ! has_nul "$PROVISION_TMP/config.$name" || die "the provisioning manifest's $name config contains NUL bytes"
        ;;
      schema|task_id|kind|project|origin_b64|registry_b64|harness|model|effort|brief_b64|mode|yolo|branch_prefix_b64|pi_auth_b64|gh_token_b64)
        ! provision_has "$key" || die "the provisioning manifest repeats field $key"
        P_SEEN="$P_SEEN$key "
        printf -v "P_FIELD_$key" '%s' "$value"
        ;;
      *)
        case "$key" in
          ''|*[!a-z0-9_]*) die "the provisioning manifest carries an unknown field" ;;
          *) die "the provisioning manifest carries an unknown field: $key" ;;
        esac
        ;;
    esac
  done < "$PROVISION_TMP/manifest"
  for key in schema task_id kind project origin_b64 registry_b64 harness model effort brief_b64; do
    provision_has "$key" || die "the provisioning manifest has no $key field"
  done
  [ "$P_FIELD_schema" = "$MANIFEST_SCHEMA" ] || die "incompatible provisioning manifest (expected schema $MANIFEST_SCHEMA)"
  [ "$P_FIELD_task_id" = "$id" ] || die "the provisioning manifest is for another task"
  case "$P_FIELD_kind" in ship|scout) ;; *) die "the provisioning manifest kind must be ship or scout" ;; esac
  case "$P_FIELD_project" in
    ''|.|..|*[!A-Za-z0-9._-]*) die "the provisioning manifest names an unsafe project" ;;
  esac
  case "$P_FIELD_harness" in ''|*[!a-z-]*) die "the provisioning manifest names an unsafe harness" ;; esac
  case " $TASK_HARNESSES " in
    *" $P_FIELD_harness "*) ;;
    *) die "the provisioning manifest harness $P_FIELD_harness is not a verified crewmate adapter" ;;
  esac
  case "$P_FIELD_model" in
    ''|-*|*[[:space:]]*|*[[:cntrl:]]*) die "the provisioning manifest names an unsafe model" ;;
  esac
  case "$P_FIELD_effort" in
    default|low|medium|high|xhigh|max|ultra) ;;
    *) die "the provisioning manifest effort must be default, low, medium, high, xhigh, max, or ultra" ;;
  esac
  if [ "$P_FIELD_effort" = ultra ]; then
    "$SCRIPT_DIR/fm-harness.sh" validate-native-effort "$P_FIELD_harness" "$P_FIELD_model" ultra \
      || die "the provisioning manifest asks for ultra effort its harness and model do not support"
  fi

  base64_decode_to "$P_FIELD_origin_b64" "$PROVISION_TMP/origin" || die "the provisioning manifest origin is not valid base64"
  fm_project_origin_safe "$(cat "$PROVISION_TMP/origin")" \
    || die "the provisioning manifest origin is not an accepted clone URL"
  base64_decode_to "$P_FIELD_registry_b64" "$PROVISION_TMP/registry" \
    || die "the provisioning manifest registry line is not valid base64"
  [ "$(LC_ALL=C tr -cd '\000\n\r' < "$PROVISION_TMP/registry" | LC_ALL=C wc -c | tr -d ' ')" = 0 ] \
    || die "the provisioning manifest registry entry must be one line"
  case "$(cat "$PROVISION_TMP/registry")" in
    "- $P_FIELD_project "*) ;;
    *) die "the provisioning manifest registry line does not register project $P_FIELD_project" ;;
  esac
  base64_decode_to "$P_FIELD_brief_b64" "$PROVISION_TMP/brief" || die "the provisioning manifest brief is not valid base64"
  [ -s "$PROVISION_TMP/brief" ] || die "the provisioning manifest brief is empty"
  ! has_nul "$PROVISION_TMP/brief" || die "the provisioning manifest brief contains NUL bytes"

  if [ "$P_FIELD_kind" = ship ]; then
    for key in mode yolo branch_prefix_b64; do
      provision_has "$key" || die "a ship's provisioning manifest has no $key field"
    done
    case "$P_FIELD_mode" in
      no-mistakes|direct-PR) ;;
      local-only) die "a local-only ship is never placed in a sandbox: its landing fast-forwards the supervising home's own clone" ;;
      *) die "the provisioning manifest mode must be no-mistakes or direct-PR" ;;
    esac
    case "$P_FIELD_yolo" in on|off) ;; *) die "the provisioning manifest yolo must be on or off" ;; esac
    base64_decode_to "$P_FIELD_branch_prefix_b64" "$PROVISION_TMP/branch-prefix" \
      || die "the provisioning manifest branch prefix is not valid base64"
    P_BRANCH_PREFIX=$(cat "$PROVISION_TMP/branch-prefix")
    case "$P_BRANCH_PREFIX" in
      -*|*[[:space:]]*|*[[:cntrl:]]*) die "the provisioning manifest branch prefix is unsafe" ;;
    esac
    git check-ref-format --branch "$P_BRANCH_PREFIX$id" >/dev/null 2>&1 \
      || die "the provisioning manifest branch prefix and task id do not form a valid branch"
  else
    for key in mode yolo branch_prefix_b64; do
      ! provision_has "$key" || die "a scout's provisioning manifest must not carry $key: a scout has no delivery contract"
    done
  fi

  if provision_has pi_auth_b64; then
    case "$P_FIELD_harness" in
      pi|pi-signed) ;;
      *) die "Pi credentials are sent only for a pi or pi-signed harness, not $P_FIELD_harness" ;;
    esac
    command -v jq >/dev/null 2>&1 || die "jq is required to write the Pi credential entries"
    base64_decode_to "$P_FIELD_pi_auth_b64" "$PROVISION_TMP/pi-auth" \
      || die "the provisioning manifest's Pi credential entries are not valid base64"
    # jq's own diagnostics can quote input, so they are discarded.
    jq -e 'type == "object" and length > 0
      and all(to_entries[]; (.key | test("^[A-Za-z0-9._-]+$")) and (.value | type == "object"))' \
      "$PROVISION_TMP/pi-auth" >/dev/null 2>&1 \
      || die "the Pi credential entries must be a JSON object of provider objects"
    credential_error=$(jq -r '
      to_entries[] | .key as $provider | .value |
      (if .type == "api_key" then
        if (keys - ["type", "key", "env"] | length) > 0 then "unknown-field"
        elif (.key | type != "string") or .key == "" then "invalid-key"
        elif has("env") and (.env | if type == "object" then any(.[]; type != "string") else true end) then "invalid-env"
        else empty end
      elif .type == "oauth" then "oauth-forbidden"
      else "unsupported-type" end) as $reason |
      "provider=\($provider) type=\(if has("type") then (.type | if type == "string" and test("^[A-Za-z0-9._-]+$") then . else "<invalid>" end) else "<missing>" end) reason=\($reason)"
    ' "$PROVISION_TMP/pi-auth" 2>/dev/null) \
      || die "the Pi credential entries are unreadable"
    [ -z "$credential_error" ] || die "Pi credential refused: $credential_error"
    P_PI_PROVIDERS=$(jq -r 'keys | join(",")' "$PROVISION_TMP/pi-auth" 2>/dev/null) \
      || die "the Pi credential provider names are unreadable"
  fi
  if provision_has gh_token_b64; then
    gh_token_stage "$P_FIELD_gh_token_b64" "the provisioning manifest's"
  fi
  P_DIGEST=$(sha256_file "$PROVISION_TMP/manifest") || die "no SHA-256 tool is available to fingerprint the manifest"
}

# Decode one gh_token_b64 value into $PROVISION_TMP/gh-token and resolve gh.
gh_token_stage() { # <encoded> <whose>
  GH_BIN=$(command -v gh) || die "gh is unavailable: a GitHub token requires gh credential storage"
  GH_BIN="$(cd -- "$(dirname -- "$GH_BIN")" && pwd)/$(basename -- "$GH_BIN")"
  base64_decode_to "$1" "$PROVISION_TMP/gh-token" \
    || die "$2 GitHub token is not valid base64"
  [ -s "$PROVISION_TMP/gh-token" ] || die "$2 GitHub token is empty"
  [ -z "$(LC_ALL=C tr -d '!-~' < "$PROVISION_TMP/gh-token")" ] \
    || die "$2 GitHub token must be printable ASCII without spaces"
}

# The lock that serializes provisioning of this home lives beside it, because
# the home itself may not exist yet; it must be prepared before
# bin/fm-wake-lib.sh is sourced against it.
provision_lock_root() {
  local parent parent_real root
  case "$TARGET_HOME" in /*) ;; *) die "FM_HOME must be an absolute path" ;; esac
  parent=$(dirname "$TARGET_HOME")
  parent_real=$(CDPATH='' cd -- "$parent" 2>/dev/null && pwd -P) || die "the sandbox task home's parent directory is unavailable"
  [ "$parent_real" = "$parent" ] || die "the sandbox task home's parent directory is not canonical"
  root="$parent/.firstmate-provision-locks"
  if [ -e "$root" ] || [ -L "$root" ]; then
    [ -d "$root" ] && [ ! -L "$root" ] || die "the provisioning lock root is unsafe"
  else
    (umask 077; mkdir "$root" 2>/dev/null) || true
    [ -d "$root" ] && [ ! -L "$root" ] || die "cannot create the provisioning lock root"
  fi
  printf '%s\n' "$root"
}

journal() { # <event...>; steps and names only, never a credential value
  printf '%s %s\n' "$(date +%s)" "$*" >> "$TARGET_HOME/state/task-provision.journal"
}

provision_report() { # <created|current>
  printf 'schema=%s\n' "$SCHEMA"
  printf 'provision=%s\n' "$1"
  printf 'task_id=%s\n' "$P_FIELD_task_id"
  printf 'manifest_sha256=%s\n' "$P_DIGEST"
}

write_private_file() { # <source> <destination>; atomic, mode 0600
  local tmp
  tmp=$(mktemp "$2.XXXXXX") || return 1
  if cat -- "$1" > "$tmp" && chmod 600 "$tmp" && mv -f -- "$tmp" "$2"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

pi_auth_merge() {
  local base
  [ -n "${HOME:-}" ] && [ -d "$HOME" ] || die "HOME is not a directory, so the Pi credential file has no location"
  [ ! -L "$HOME/.pi" ] && [ ! -L "$HOME/.pi/agent" ] || die "the Pi configuration directory is a symlink; refusing to write credentials through it"
  [ -d "$HOME/.pi" ] || mkdir -m 700 "$HOME/.pi" || die "cannot create the Pi configuration directory"
  [ -d "$HOME/.pi/agent" ] || mkdir -m 700 "$HOME/.pi/agent" || die "cannot create the Pi agent directory"
  PI_AUTH_FILE="$HOME/.pi/agent/auth.json"
  if [ -e "$PI_AUTH_FILE" ] || [ -L "$PI_AUTH_FILE" ]; then
    [ -f "$PI_AUTH_FILE" ] && [ ! -L "$PI_AUTH_FILE" ] || die "the Pi credential file is not a regular file"
    jq -e 'type == "object"' "$PI_AUTH_FILE" >/dev/null 2>&1 \
      || die "the existing Pi credential file is not a JSON object; refusing to rewrite it"
    cp -p -- "$PI_AUTH_FILE" "$PROVISION_TMP/pi-auth.before" || die "cannot snapshot the existing Pi credential file"
    PI_AUTH_BACKUP=1
    base="$PROVISION_TMP/pi-auth.before"
  else
    printf '{}\n' > "$PROVISION_TMP/pi-auth.empty"
    base="$PROVISION_TMP/pi-auth.empty"
  fi
  jq -s '.[0] + .[1]' "$base" "$PROVISION_TMP/pi-auth" > "$PROVISION_TMP/pi-auth.merged" 2>/dev/null \
    || die "could not merge the Pi credential entries"
  PI_AUTH_WRITTEN=1
  write_private_file "$PROVISION_TMP/pi-auth.merged" "$PI_AUTH_FILE" || die "could not write the Pi credential file"
}

gh_auth_store() {
  local name dir index
  local -a missing_dirs=()
  GH_AUTH_DIR=${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gh}
  [ ! -L "$GH_AUTH_DIR" ] || die "the gh configuration directory is a symlink"
  dir=$GH_AUTH_DIR
  while [ ! -d "$dir" ]; do
    missing_dirs+=("$dir")
    dir=$(dirname -- "$dir")
  done
  for ((index=${#missing_dirs[@]}-1; index>=0; index--)); do
    mkdir -m 700 "${missing_dirs[index]}" || die "cannot create the gh configuration directory"
  done
  for name in hosts.yml config.yml; do
    if [ -e "$GH_AUTH_DIR/$name" ] || [ -L "$GH_AUTH_DIR/$name" ]; then
      [ -f "$GH_AUTH_DIR/$name" ] && [ ! -L "$GH_AUTH_DIR/$name" ] \
        || die "the gh $name configuration is not a regular file"
      cp -p -- "$GH_AUTH_DIR/$name" "$PROVISION_TMP/gh-$name.before" \
        || die "cannot snapshot the gh $name configuration"
    fi
  done
  GH_AUTH_WRITTEN=1
  "$GH_BIN" auth login --hostname github.com --git-protocol https --insecure-storage --with-token \
    < "$PROVISION_TMP/gh-token" >/dev/null 2>&1 \
    || die "gh credential storage failed for github.com"
  if [ ! -f "$GH_AUTH_DIR/hosts.yml" ] || ! chmod 600 "$GH_AUTH_DIR/hosts.yml"; then
    die "gh did not store its github.com credential file"
  fi
}

provision_apply() { # <id>
  local id=$1 marker owner digest name dest foreign helper gate_repo
  local -a git_auth=()
  PROVISION_LOCK="$PROVISION_LOCK_ROOT/.remote-task-provision-$(printf '%s' "$TARGET_HOME" | cksum | awk '{print $1}').lock"
  fm_lock_acquire_wait "$PROVISION_LOCK"
  PROVISION_LOCK_HELD=1

  if [ -e "$TARGET_HOME" ] || [ -L "$TARGET_HOME" ]; then
    [ -d "$TARGET_HOME" ] && [ ! -L "$TARGET_HOME" ] || die "the sandbox task home exists but is not a safe directory"
    marker="$TARGET_HOME/.fm-task-home"
    if [ -e "$marker" ] || [ -L "$marker" ]; then
      [ -f "$marker" ] && [ ! -L "$marker" ] || die "the sandbox task home marker is unsafe"
      owner=$(kv_value "$marker" task_id) || die "the sandbox task home marker is malformed"
      [ "$owner" = "$id" ] || die "this sandbox task home already belongs to task $owner; refusing to provision $id over it"
      digest=$(kv_value "$marker" manifest_sha256) || die "the sandbox task home marker records no manifest digest"
      [ "$digest" = "$P_DIGEST" ] \
        || die "the sandbox task home for $id was provisioned from a different manifest; refusing to change it in place"
      provision_report current
      return 0
    fi
    if find "$TARGET_HOME" -mindepth 1 -maxdepth 1 -print 2>/dev/null | grep -q .; then
      die "the sandbox task home has content but no provisioning marker; refusing to provision over it"
    fi
    PROVISION_EMPTY_HOME=1
    chmod 700 "$TARGET_HOME" || die "cannot make the sandbox task home private"
  else
    mkdir -m 700 "$TARGET_HOME" || die "cannot create the sandbox task home"
    PROVISION_CREATED_HOME=1
  fi
  for name in data state config projects; do
    mkdir "$TARGET_HOME/$name" || die "cannot create the task home's $name directory"
  done
  mkdir "$TARGET_HOME/data/$id" || die "cannot create the task's data directory"
  journal "begin task=$id kind=$P_FIELD_kind project=$P_FIELD_project manifest_sha256=$P_DIGEST"

  cp -- "$PROVISION_TMP/brief" "$TARGET_HOME/data/$id/brief.md" || die "cannot write the brief"
  if foreign=$(fm_brief_foreign_status_file "$TARGET_HOME/data/$id/brief.md" "$TARGET_HOME/state" "$id"); then
    die "the brief tells its worker to append status to $foreign, not to this home's $TARGET_HOME/state/$id.status; render it with fm-brief.sh --for-home and --for-root for this sandbox"
  fi
  printf '%s\n' "$(cat "$PROVISION_TMP/registry")" > "$TARGET_HOME/data/projects.md" || die "cannot write the project registry"
  printf 'manual\n' > "$TARGET_HOME/config/backlog-backend" || die "cannot write the backlog backend"
  for name in $P_CONFIG_NAMES; do
    cp -- "$PROVISION_TMP/config.$name" "$TARGET_HOME/config/$name" || die "cannot write config/$name"
  done
  journal "home brief=data/$id/brief.md registry=data/projects.md backlog-backend=manual config=${P_CONFIG_NAMES# }"
  if provision_has gh_token_b64; then
    gh_auth_store
    journal "credential gh_token=gh/github.com"
  fi
  if provision_has pi_auth_b64; then
    pi_auth_merge
    journal "credential pi_auth providers=$P_PI_PROVIDERS"
  fi

  dest="$TARGET_HOME/projects/$P_FIELD_project"
  if provision_has gh_token_b64; then
    printf -v helper '!%q auth git-credential' "$GH_BIN"
    git_auth=(-c credential.https://github.com.helper= -c "credential.https://github.com.helper=$helper")
  fi
  git ${git_auth[@]+"${git_auth[@]}"} clone --no-local --quiet -- "$(cat "$PROVISION_TMP/origin")" "$dest" \
    || die "could not clone project $P_FIELD_project from its origin"
  if provision_has gh_token_b64; then
    if ! git -C "$dest" config --local --add credential.https://github.com.helper "" \
      || ! git -C "$dest" config --local --add credential.https://github.com.helper "$helper"; then
      die "could not configure GitHub authentication for project $P_FIELD_project"
    fi
  fi
  journal "clone project=$P_FIELD_project"
  if [ "$P_FIELD_kind" = ship ] && [ "$P_FIELD_mode" = no-mistakes ]; then
    command -v no-mistakes >/dev/null 2>&1 || die "no-mistakes is unavailable for project $P_FIELD_project"
    (cd "$dest" && no-mistakes init >/dev/null && no-mistakes doctor >/dev/null) \
      || die "no-mistakes initialization failed for project $P_FIELD_project"
    journal "no-mistakes-init project=$P_FIELD_project"
    if provision_has gh_token_b64; then
      gate_repo=$(git -C "$dest" remote get-url no-mistakes) \
        || die "could not resolve project $P_FIELD_project's no-mistakes gate repository"
      if ! git -C "$gate_repo" config --local --add credential.https://github.com.helper "" \
        || ! git -C "$gate_repo" config --local --add credential.https://github.com.helper "$helper"; then
        die "could not configure GitHub authentication for project $P_FIELD_project's no-mistakes gate repository"
      fi
      journal "no-mistakes-gate project=$P_FIELD_project"
    fi
  fi

  {
    printf 'schema=fm-task-home.v1\n'
    printf 'task_id=%s\n' "$id"
    printf 'kind=%s\n' "$P_FIELD_kind"
    printf 'project=%s\n' "$P_FIELD_project"
    if [ "$P_FIELD_kind" = ship ]; then
      printf 'mode=%s\n' "$P_FIELD_mode"
      printf 'yolo=%s\n' "$P_FIELD_yolo"
      printf 'branch_prefix=%s\n' "$P_BRANCH_PREFIX"
    fi
    printf 'harness=%s\n' "$P_FIELD_harness"
    printf 'model=%s\n' "$P_FIELD_model"
    printf 'effort=%s\n' "$P_FIELD_effort"
    printf 'manifest_sha256=%s\n' "$P_DIGEST"
  } > "$TARGET_HOME/.fm-task-home.new" || die "cannot stage the provisioning marker"
  journal "complete"
  mv -f -- "$TARGET_HOME/.fm-task-home.new" "$TARGET_HOME/.fm-task-home" || die "cannot publish the provisioning marker"
  PROVISION_PUBLISHED=1
  provision_report created
}

# --- the recorded endpoint ---------------------------------------------------------

EP_META=
EP_BACKEND=
EP_TARGET=
EP_ERROR=

endpoint_load() { # <id>
  EP_ERROR=
  EP_META="$TARGET_HOME/state/$1.meta"
  if ! fm_backend_validate_task_endpoint "$EP_META" "$1" 2>/dev/null; then
    EP_ERROR="task $1 has no valid endpoint record in this home"
    return 1
  fi
  EP_BACKEND=$FM_BACKEND_VALIDATED_BACKEND
  EP_TARGET=$FM_BACKEND_VALIDATED_TARGET
  if [ "$EP_BACKEND" != tmux ]; then
    EP_ERROR="task $1 is recorded on backend '$EP_BACKEND', but a sandbox task runs only on tmux"
    return 1
  fi
}

endpoint_require() { endpoint_load "$1" || die "$EP_ERROR"; }

print_route() { # <id>
  endpoint_require "$1"
  printf 'schema=%s\n' "$SCHEMA"
  printf 'backend=%s\n' "$EP_BACKEND"
  printf 'target=%s\n' "$EP_TARGET"
  printf 'worktree=%s\n' "$(fm_meta_get "$EP_META" worktree)"
  printf 'branch=%s\n' "$(fm_meta_get "$EP_META" branch)"
  printf 'spawn_gen=%s\n' "$(fm_meta_get "$EP_META" spawn_gen)"
  printf 'busy_gen=%s\n' "$(fm_meta_get "$EP_META" busy_gen)"
  printf 'harness=%s\n' "$(fm_meta_get "$EP_META" harness)"
  printf 'model=%s\n' "$(fm_meta_get "$EP_META" model)"
  printf 'effort=%s\n' "$(fm_meta_get "$EP_META" effort)"
}

busy_verdict() { # <id> <tail40>; prints "<state> <source>"
  local verdict agent
  agent=$(fm_backend_agent_state "$EP_BACKEND" "$EP_TARGET" 2>/dev/null) || agent=
  case "$agent" in
    dead|missing) printf 'dead endpoint-gone\n'; return 0 ;;
  esac
  verdict=$(fm_busy_classify_meta "$EP_META" "$1" "$TARGET_HOME/state" "$2" 2>/dev/null) || verdict=
  case "$verdict" in
    *' '*) printf '%s\n' "$verdict" ;;
    *) printf 'unknown unreadable\n' ;;
  esac
}

worktree_newest_write() { # <worktree>; epoch, none, or unknown
  local wt=$1 name out rc=0 newest bound
  local -a names=() prune=() stat_cmd=()
  [ -n "$wt" ] && [ -d "$wt" ] || { printf 'unknown\n'; return 0; }
  read -r -a names <<< "$FM_WORKTREE_WRITE_PRUNE"
  for name in ${names[@]+"${names[@]}"}; do
    [ "${#prune[@]}" -eq 0 ] || prune+=( -o )
    prune+=( -name "$name" )
  done
  if stat -c %Y / >/dev/null 2>&1; then stat_cmd=(stat -c %Y); else stat_cmd=(stat -f %m); fi
  bound=$FM_WORKTREE_WRITE_TIMEOUT
  case "$bound" in ''|*[!0-9]*|0) bound=10 ;; esac
  if [ "${#prune[@]}" -gt 0 ]; then
    out=$(fm_run_timed "$bound" find "$wt" -xdev -maxdepth "$FM_WORKTREE_WRITE_MAXDEPTH" \
      \( "${prune[@]}" \) -prune -o -type f -exec "${stat_cmd[@]}" {} + 2>/dev/null) || rc=$?
  else
    out=$(fm_run_timed "$bound" find "$wt" -xdev -maxdepth "$FM_WORKTREE_WRITE_MAXDEPTH" \
      -type f -exec "${stat_cmd[@]}" {} + 2>/dev/null) || rc=$?
  fi
  if fm_timed_out "$rc"; then printf 'unknown\n'; return 0; fi
  newest=$(printf '%s\n' "$out" | awk '/^[0-9]+$/ { if (!seen || $1 + 0 > max) max = $1 + 0; seen = 1 } END { if (seen) print max }')
  if [ -n "$newest" ]; then
    printf '%s\n' "$newest"
  elif [ "$rc" -eq 0 ]; then
    printf 'none\n'
  else
    printf 'unknown\n'
  fi
}

# --- verbs ---------------------------------------------------------------------

cmd_launch() {
  local id=$1 meta current out kind project mode yolo prefix harness model effort
  local -a args
  meta="$TARGET_HOME/state/$id.meta"
  if [ -e "$meta" ] || [ -L "$meta" ]; then
    endpoint_require "$id"
    current=$(fm_backend_agent_state "$EP_BACKEND" "$EP_TARGET" 2>/dev/null || printf 'unreadable\n')
    [ "$current" = alive ] \
      || die "task $id already has an endpoint whose agent reads $current; a second launch would start another worker beside its worktree, so recover it with control relaunch"
    print_route "$id"
    return 0
  fi
  kind=$(marker_field kind)
  project=$(marker_field project)
  harness=$(marker_field harness)
  model=$(marker_field model)
  effort=$(marker_field effort)
  args=("$id" "$TARGET_HOME/projects/$project")
  if [ "$kind" = scout ]; then
    args+=(--scout)
  else
    mode=$(marker_field mode)
    yolo=$(marker_field yolo)
    prefix=$(marker_field branch_prefix)
    args+=(--mode "$mode" --yolo "$yolo" "--branch-prefix=$prefix")
  fi
  args+=(--harness "$harness")
  [ "$model" = default ] || args+=(--model "$model")
  [ "$effort" = default ] || args+=(--effort "$effort")
  args+=(--backend tmux)

  # The task home has no supervisor of its own, so the watcher guard has
  # nothing to report here; supervision lives in the primary.
  if ! out=$(FM_SPAWN_NO_GUARD=1 run_host fm-spawn.sh "${args[@]}" 2>&1); then
    [ -z "$out" ] || printf '%s\n' "$out" >&2
    die "the host-local task launch failed"
  fi
  [ -f "$meta" ] || die "the host-local launch returned without a task record"
  print_route "$id"
}

cmd_state() {
  local id=$1 meta="$TARGET_HOME/state/$1.meta" agent
  if [ ! -e "$meta" ] && [ ! -L "$meta" ]; then
    printf 'missing\n'
    return 0
  fi
  if ! endpoint_load "$id"; then
    printf 'error: %s\n' "$EP_ERROR" >&2
    printf 'unverified\n'
    return 0
  fi
  agent=$(fm_backend_agent_state "$EP_BACKEND" "$EP_TARGET" 2>/dev/null) || agent=
  printf '%s\n' "${agent:-unreadable}"
}

cmd_observe() {
  local id=$1 meta now boot agent=missing busy=unknown busy_source=no-record
  local hash=unknown write=unknown tail40='' verdict oldest oldest_name=none oldest_at=none turn=unknown
  meta="$TARGET_HOME/state/$id.meta"
  now=$(date +%s)
  boot=$(fm_control_host_boot_epoch) || boot=unknown
  if [ -e "$meta" ] || [ -L "$meta" ]; then
    if endpoint_load "$id"; then
      agent=$(fm_backend_agent_state "$EP_BACKEND" "$EP_TARGET" 2>/dev/null) || agent=unreadable
      if tail40=$(fm_backend_capture "$EP_BACKEND" "$EP_TARGET" 40 "fm-$id" 2>/dev/null); then
        hash=$(printf '%s' "$tail40" | hash_text) || hash=unknown
      else
        tail40=
      fi
      verdict=$(busy_verdict "$id" "$tail40")
      busy=${verdict%% *}
      busy_source=${verdict#* }
      write=$(worktree_newest_write "$(fm_meta_get "$meta" worktree)")
      turn=$(file_mtime "$(crew_busy_turn_marker "$TARGET_HOME/state" "$id")") || turn=unknown
    else
      printf 'error: %s\n' "$EP_ERROR" >&2
      agent=unverified
      busy_source=unverified
    fi
  fi
  if oldest=$(fm_task_inbox_oldest_unhandled "$TARGET_HOME/state" "$id"); then
    oldest_name=${oldest##*/}
    oldest_at=$(file_mtime "$oldest") || oldest_at=unknown
  fi
  printf 'schema=%s\n' "$SCHEMA"
  printf 'now=%s\n' "$now"
  printf 'boot=%s\n' "$boot"
  printf 'agent=%s\n' "$agent"
  printf 'busy=%s\n' "$busy"
  printf 'busy_source=%s\n' "$busy_source"
  printf 'pane_hash=%s\n' "$hash"
  printf 'worktree_write=%s\n' "$write"
  printf 'inbox_oldest=%s\n' "$oldest_name"
  printf 'inbox_oldest_at=%s\n' "$oldest_at"
  printf 'turn_at=%s\n' "${turn:-unknown}"
}

cmd_capture() {
  local id=$1 lines=${2:-20}
  case "$lines" in ''|*[!0-9]*|0) die "capture line count must be positive" ;; esac
  [ "$lines" -le 100 ] || die "capture line count exceeds 100"
  endpoint_require "$id"
  fm_backend_capture "$EP_BACKEND" "$EP_TARGET" "$lines" "fm-$id" | head -c 65536
}

# A steer is a durable record, never text typed into the pane; the record and
# doorbell are bin/fm-task-inbox-lib.sh's, exactly as for a remote secondmate.
cmd_send() {
  local id=$1 message=$2 request=$3 rec write_rc=0 ring_rc=0 meta_lock
  fm_task_inbox_request_id_valid "$request" || die "send needs the steer's request id: 16 lowercase hex characters"
  meta_lock=$(fm_meta_lock_path "$TARGET_HOME/state/$id.meta") || die "the task metadata lock path is invalid"
  fm_task_inbox_lock_acquire "$meta_lock" \
    || die "the task endpoint record could not be locked for final delivery validation"
  if ! endpoint_load "$id"; then
    fm_lock_release "$meta_lock"
    die "$EP_ERROR"
  fi
  rec=$(fm_task_inbox_write_idempotent "$TARGET_HOME/state" "$id" "$message" '' "$request") || write_rc=$?
  fm_lock_release "$meta_lock"
  if [ "$write_rc" -eq 2 ]; then
    die "request id $request already keys a different steer in $TARGET_HOME/state/$id.inbox; nothing was written"
  fi
  [ "$write_rc" -eq 0 ] || die "the steering-inbox record could not be written under $TARGET_HOME/state/$id.inbox"
  case "$rec" in
    */handled/*)
      printf 'notice: this steer was already delivered and acknowledged at %s; nothing re-rung\n' "$rec" >&2
      return 0
      ;;
  esac
  fm_task_inbox_ring "$EP_BACKEND" "$EP_TARGET" "$rec" "fm-$id" || ring_rc=$?
  case "$ring_rc" in
    1) printf 'notice: doorbell skipped (composer visibly holds pending text); the steer is durably recorded at %s\n' "$rec" >&2 ;;
    2) printf 'notice: doorbell did not reach %s; the steer is durably recorded at %s\n' "$EP_TARGET" "$rec" >&2 ;;
    3) printf 'notice: doorbell not typed because the agent in %s has exited; the steer is durably recorded at %s for recovery\n' "$EP_TARGET" "$rec" >&2 ;;
  esac
}

cmd_ring() {
  local id=$1 name=$2 dir result ring_rc=0
  fm_task_inbox_seq_of "$name" >/dev/null || die "ring needs an inbox record name of the form NNN.msg"
  endpoint_require "$id"
  dir=$(fm_task_inbox_dir "$TARGET_HOME/state" "$id")
  if [ -f "$dir/$name" ] && [ ! -L "$dir/$name" ]; then
    fm_task_inbox_ring "$EP_BACKEND" "$EP_TARGET" "$dir/$name" "fm-$id" || ring_rc=$?
    case "$ring_rc" in
      0) result=rang ;;
      1) result=skipped ;;
      3) result=unavailable ;;
      *) result=failed ;;
    esac
  elif [ -f "$dir/handled/$name" ]; then
    result=handled
  else
    result=absent
  fi
  printf 'schema=%s\n' "$SCHEMA"
  printf 'ring=%s\n' "$result"
}

cmd_key() {
  local id=$1 key=$2
  endpoint_require "$id"
  run_host fm-send.sh "$EP_TARGET" --key "$key"
}

cmd_crew_state() {
  local id=$1 empty line verdict='unknown no-record' tail40=''
  empty=$(mktemp "${TMPDIR:-/tmp}/fm-task-crew-state.XXXXXX") || die "cannot stage the empty status log"

  line=$(FM_CREW_STATE_STATUS_OVERRIDE="$empty" FM_CREW_STATE_FOR_PRIMARY=1 run_host fm-crew-state.sh "$id" 2>/dev/null) || line=
  rm -f -- "$empty"
  line=$(printf '%s\n' "$line" | tail -1)
  [ -n "$line" ] || line='state: unknown · source: none · crew state unreadable on the sandbox host'
  if endpoint_load "$id"; then
    tail40=$(fm_backend_capture "$EP_BACKEND" "$EP_TARGET" 40 "fm-$id" 2>/dev/null) || tail40=
    verdict=$(busy_verdict "$id" "$tail40")
  fi
  printf 'schema=%s\n' "$SCHEMA"
  printf 'crew_state=%s\n' "$line"
  printf 'busy=%s\n' "${verdict%% *}"
  printf 'busy_source=%s\n' "${verdict#* }"
}

cmd_head() {
  local id=$1 wt branch head porcelain dirty=no
  endpoint_require "$id"
  wt=$(fm_backend_meta_exact_value "$EP_META" worktree) || die "task $id records no worktree"
  [ -d "$wt" ] && [ ! -L "$wt" ] || die "task $id's worktree is missing on this host"
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null) || branch=
  head=$(git -C "$wt" rev-parse --verify --quiet HEAD 2>/dev/null) || die "task $id's worktree HEAD is unreadable"
  porcelain=$(git -C "$wt" status --porcelain --untracked-files=normal 2>/dev/null) \
    || die "task $id's worktree status is unreadable"
  [ -z "$porcelain" ] || dirty=yes
  printf 'schema=%s\n' "$SCHEMA"
  printf 'branch=%s\n' "$branch"
  printf 'head=%s\n' "$head"
  printf 'dirty=%s\n' "$dirty"
}

cmd_control() {
  local id=$1 action=${2:-} harness model effort note
  local -a args
  case "$action" in
    interrupt|exit)
      [ "$#" -eq 2 ] || usage
      endpoint_require "$id"
      FM_CONTROL_BOOT_ABSENCE_PROOF=1 run_host fm-control.sh "$id" "$action"
      ;;
    relaunch)
      [ "$#" -eq 6 ] || usage
      harness=$3 model=$4 effort=$5 note=$6
      case "$harness" in
        -) ;;
        ''|*[!a-z-]*) die "invalid relaunch harness" ;;
        *)
          case " $TASK_HARNESSES " in
            *" $harness "*) ;;
            *) die "relaunch harness $harness is not a verified crewmate adapter" ;;
          esac
          ;;
      esac
      case "$model" in ''|-?*|*[[:space:]]*|*[[:cntrl:]]*) die "invalid relaunch model" ;; esac
      case "$effort" in
        -|default|low|medium|high|xhigh|max|ultra) ;;
        *) die "invalid relaunch effort" ;;
      esac
      [ -n "$(printf '%s' "$note" | tr -d '[:space:]')" ] || die "relaunch needs a nonempty progress note"
      endpoint_require "$id"
      args=("$id" relaunch)
      [ "$harness" = - ] || args+=(--harness "$harness")
      [ "$model" = - ] || args+=(--model "$model")
      [ "$effort" = - ] || args+=(--effort "$effort")
      args+=(--note "$note")
      FM_CONTROL_BOOT_ABSENCE_PROOF=1 run_host fm-control.sh "${args[@]}"
      print_route "$id"
      ;;
    *) usage ;;
  esac
}

cmd_brief_update() {
  local id=$1 dir tmp bytes foreign
  dir="$TARGET_HOME/data/$id"
  [ -d "$dir" ] && [ ! -L "$dir" ] || die "task $id has no brief directory in this home"
  tmp=$(umask 077; mktemp "$dir/.brief.md.update.XXXXXX") || die "cannot stage the brief"
  if ! head -c "$((MAX_INPUT_BYTES + 1))" > "$tmp"; then
    rm -f -- "$tmp"
    die "cannot read the brief"
  fi
  bytes=$(LC_ALL=C wc -c < "$tmp" | tr -d ' ')
  if [ "$bytes" -eq 0 ] || [ "$bytes" -gt "$MAX_INPUT_BYTES" ] || has_nul "$tmp"; then
    rm -f -- "$tmp"
    die "the brief must be nonempty text of at most 1 MiB"
  fi
  if foreign=$(fm_brief_foreign_status_file "$tmp" "$TARGET_HOME/state" "$id"); then
    rm -f -- "$tmp"
    die "the brief tells its worker to append status to $foreign, not to this home's $TARGET_HOME/state/$id.status; render it with fm-brief.sh --for-home and --for-root for this sandbox"
  fi
  if ! mv -f -- "$tmp" "$dir/brief.md"; then
    rm -f -- "$tmp"
    die "cannot replace the brief"
  fi
  printf 'schema=%s\n' "$SCHEMA"
  printf 'brief=updated\n'
  printf 'brief_sha256=%s\n' "$(sha256_file "$dir/brief.md" || printf 'unknown')"
}

cmd_cred_refresh() {
  local id=$1 bytes line value='' seen=0 fp
  [ ! -e "$TARGET_HOME/state/$id.retired" ] && [ ! -L "$TARGET_HOME/state/$id.retired" ] \
    || die "task $id is retired on this host, so its GitHub token is never refreshed"
  umask 077
  PROVISION_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-task-cred-refresh.XXXXXX") \
    || die "cannot create private credential refresh state"
  trap provision_cleanup EXIT
  trap 'exit 1' HUP INT TERM
  head -c 65537 > "$PROVISION_TMP/refresh" || die "cannot read the credential refresh"
  bytes=$(LC_ALL=C wc -c < "$PROVISION_TMP/refresh" | tr -d ' ')
  [ "$bytes" -le 65536 ] || die "the credential refresh exceeds its 64 KiB bound"
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    case "$line" in
      gh_token_b64=*)
        [ "$seen" -eq 0 ] || die "the credential refresh repeats gh_token_b64"
        seen=1
        value=${line#gh_token_b64=}
        ;;
      *) die "the credential refresh carries a line other than gh_token_b64" ;;
    esac
  done < "$PROVISION_TMP/refresh"
  [ "$seen" -eq 1 ] || die "the credential refresh has no gh_token_b64 line"
  gh_token_stage "$value" "the credential refresh's"
  value=
  gh_auth_store
  PROVISION_PUBLISHED=1
  fp=$(sha256_file "$PROVISION_TMP/gh-token" | cut -c1-12)
  [ -n "$fp" ] || die "no SHA-256 tool is available to fingerprint the GitHub token"
  journal "credential refresh gh_token=gh/github.com"
  printf 'schema=%s\n' "$SCHEMA"
  printf 'refresh=stored\n'
  printf 'task_id=%s\n' "$id"
  printf 'gh_token_fp=%s\n' "$fp"
}

# After a passing teardown, revoke a stored GitHub App installation token and
# report the result; any other stored token is left alone.
gh_revoke_stored() {
  local id=$1 auth_dir=$2 gh dir result=failed fp='' code expires epoch
  if gh=$(command -v gh 2>/dev/null) && dir=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-task-revoke.XXXXXX"); then
    # The stored token is read into this private directory only; the
    # environment's tokens are cleared so gh reads and presents the stored one.
    if env -u GH_TOKEN -u GITHUB_TOKEN GH_CONFIG_DIR="$auth_dir" "$gh" auth token --hostname github.com > "$dir/token" 2>/dev/null; then
      if [ "$(head -c 4 "$dir/token")" != ghs_ ]; then
        rm -rf -- "$dir"
        return 0
      fi
      LC_ALL=C tr -d '\n' < "$dir/token" > "$dir/bare"
      fp=$(sha256_file "$dir/bare" | cut -c1-12)
      expires=$(awk -v fp="$fp" -v task="$id" '
        $2 == "mint" && $3 == "github" {
          f = t = e = ""
          for (i = 4; i <= NF; i++) {
            if ($i ~ /^fp=/) f = substr($i, 4)
            if ($i ~ /^task=/) t = substr($i, 6)
            if ($i ~ /^expires=/) e = substr($i, 9)
          }
          if (f == fp && t == task) expires = e
        }
        END { print expires }')
      code=$(env -u GH_TOKEN -u GITHUB_TOKEN GH_CONFIG_DIR="$auth_dir" "$gh" api --method DELETE /installation/token --include 2>/dev/null \
        | awk 'NR == 1 { print $2 }') || true
      case "$code" in
        2[0-9][0-9]) result=revoked ;;
        401|404) result=invalid ;;
        *) result=failed ;;
      esac
      if [ "$result" = failed ] && [ -n "$expires" ] \
        && epoch=$(fm_utc_iso_to_epoch "$expires") && [ "$epoch" -le "$(date +%s)" ]; then
        result=expired
      fi
    fi
    rm -rf -- "$dir"
  fi
  journal "credential revoke gh_token result=$result"
  retire_report_revoke "$result" "$fp"
  [ "$result" != failed ]
}

retire_revoke_gh_token() {
  local id=$1 auth_dir report rc=0
  grep -q 'credential .*gh_token=' "$TARGET_HOME/state/task-provision.journal" || return 0
  auth_dir=${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gh}
  report=$(gh_revoke_stored "$id" "$auth_dir") || rc=$?
  if [ -n "$report" ]; then
    printf '%s\n' "$report"
    printf '%s\n' "$report" | awk -F= '
      $1 == "gh_token_revoke" { result=$2 }
      $1 == "gh_token_fp" { print result, $2 }' > "$TARGET_HOME/state/$id.gh-token-revoke"
  fi
  return "$rc"
}

retire_report_revoke() { # <result> <fp|->
  case "$1" in revoked|invalid|expired|failed) ;; *) return 0 ;; esac
  [[ "${2:-}" =~ ^[0-9a-f]{12}$ ]] || return 0
  printf 'gh_token_revoke=%s\n' "$1"
  printf 'gh_token_fp=%s\n' "$2"
}

cmd_retire() {
  local id=$1 force=${2:-} retired kind result fp expiry_records
  expiry_records=$(cat)
  [ -z "$force" ] || [ "$force" = --force ] || usage
  kind=$(marker_field kind)
  [ "$kind" = ship ] \
    || die "task $id is a scout: its worktree is declared scratch and its completion gate runs in the supervising home, so it is never retired on its host"
  retired="$TARGET_HOME/state/$id.retired"
  if [ -f "$retired" ] && [ ! -L "$retired" ]; then
    printf 'already-retired: %s\n' "$id"
    if [ -f "$TARGET_HOME/state/$id.gh-token-revoke" ]; then
      while read -r result fp; do
        retire_report_revoke "$result" "$fp"
      done < "$TARGET_HOME/state/$id.gh-token-revoke"
    fi
    return 0
  fi

  if [ ! -f "$TARGET_HOME/state/$id.teardown-passed" ]; then
    if [ -n "$force" ]; then
      FM_TEARDOWN_GUARD_DONE=1 run_host fm-teardown.sh "$id" --force < /dev/null
    else
      FM_TEARDOWN_GUARD_DONE=1 run_host fm-teardown.sh "$id" < /dev/null
    fi
    date +%s > "$TARGET_HOME/state/$id.teardown-passed"
  fi
  retire_revoke_gh_token "$id" <<< "$expiry_records" || die "GitHub token revocation is unconfirmed; retirement remains retryable"
  if ! date +%s > "$retired.new" || ! mv -f -- "$retired.new" "$retired"; then
    rm -f -- "$retired.new"
    printf 'warning: task %s retired, but its retirement record could not be written; a retry will reach teardown again\n' "$id" >&2
  fi
}

# --- dispatch ----------------------------------------------------------------

VERB=${1:-}
case "$VERB" in
  ''|-h|--help|help) usage ;;
  provision)
    shift
    [ "$#" -eq 1 ] || usage
    validate_id "$1"
    provision_read "$1"
    PROVISION_LOCK_ROOT=$(provision_lock_root)
    # bin/fm-wake-lib.sh creates its state directory when sourced, so it is
    # pointed at the lock root rather than at a home that may not exist yet.
    FM_STATE_OVERRIDE=$PROVISION_LOCK_ROOT
    # shellcheck source=bin/fm-wake-lib.sh
    . "$SCRIPT_DIR/fm-wake-lib.sh"
    provision_apply "$1"
    exit 0
    ;;
  launch|state|observe|capture|send|ring|key|crew-state|head|control|brief-update|cred-refresh|retire) ;;
  *) die "unknown command: $VERB" ;;
esac
shift
[ "$#" -ge 1 ] || usage
validate_id "$1"
validate_home "$1"
# Only a proven home may have its state directory touched by the libraries,
# which resolve this home's directories exactly as run_host hands them on.
FM_STATE_OVERRIDE="$TARGET_HOME/state"
FM_CONFIG_OVERRIDE="$TARGET_HOME/config"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
case "$VERB" in
  launch) [ "$#" -eq 1 ] || usage; cmd_launch "$1" ;;
  state) [ "$#" -eq 1 ] || usage; cmd_state "$1" ;;
  observe) [ "$#" -eq 1 ] || usage; cmd_observe "$1" ;;
  capture) [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; cmd_capture "$@" ;;
  send) [ "$#" -eq 3 ] || usage; cmd_send "$@" ;;
  ring) [ "$#" -eq 2 ] || usage; cmd_ring "$@" ;;
  key) [ "$#" -eq 2 ] || usage; cmd_key "$@" ;;
  crew-state) [ "$#" -eq 1 ] || usage; cmd_crew_state "$1" ;;
  head) [ "$#" -eq 1 ] || usage; cmd_head "$1" ;;
  control) [ "$#" -ge 2 ] || usage; cmd_control "$@" ;;
  brief-update) [ "$#" -eq 1 ] || usage; cmd_brief_update "$1" ;;
  cred-refresh) [ "$#" -eq 1 ] || usage; cmd_cred_refresh "$1" ;;
  retire) [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; cmd_retire "$@" ;;
esac

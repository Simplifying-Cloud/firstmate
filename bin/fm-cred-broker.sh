#!/usr/bin/env bash
# fm-cred-broker.sh - mint, refresh, and revoke short-lived credentials for one
# task at a time, and record each event in state/cred-ledger without its value.
#
# Usage:
#   fm-cred-broker.sh github mint --task <id> --repo <owner/name> --access read|write [--out <file>]
#   fm-cred-broker.sh github revoke --token-file <file>
#   fm-cred-broker.sh github refresh-due
#   fm-cred-broker.sh github retire --task <id>
#   fm-cred-broker.sh github record-revoke --task <id> --fp <fingerprint> --result revoked|invalid|expired|failed
#
# The one credential issued today is a GitHub App installation token for a
# sandbox task; docs/remote-sandboxes.md#credentials owns the operator view.
# config/github-app names the App, its installation, and its private key:
# docs/configuration.md owns its format, and bin/fm-sandbox-credentials-lib.sh
# (fm_github_app_config_load) reads it and checks the key file.
#
# mint signs an RS256 JWT with openssl (iat now-60, exp now+540, iss the App
# ID), exchanges it at POST /app/installations/<installation>/access_tokens for
# a token limited to the one named repository, and accepts only a reply with a
# ghs_ token, an expires_at time, and a repository list equal to the request.
# read asks for contents, metadata, and pull_requests read; write asks for
# contents, pull_requests, and issues write with metadata, checks, statuses, and
# actions read, plus workflows write only when config/github-app says
# workflows=on. The token goes to --out (mode 0600, replaced atomically) or to
# stdout, with its API response retained mode 0600 in the supervisor's protected
# state/cred-pending/<task>/token.* set (directories mode 0700). The response is
# captured there before validation or delivery so interrupted requests cannot
# discard returned credentials. Each record holds the token and expires_at.
# A mint is ledgered before delivery; a refused mint attempts cleanup revocation.
# Confirmed revocation removes the matching pending record; failures retain it.
# Responses without a parseable token are discarded. A token GitHub may have
# issued but the broker never received cannot be revoked and expires within the hour.
#
# revoke presents the token in --token-file, a private file holding it on one
# line, to DELETE /installation/token: 2xx is revoked, 401/404 is invalid (already
# revoked or expired, so dead either way), and anything else fails non-zero.
# It prints revoke=<result> and fp=<fingerprint>.
#
# refresh-due keeps each live sandbox task's minted token fresh. For every task
# record this home places in a sandbox (bin/fm-remote-route-lib.sh) whose
# current token expires, by the ledger, within 900 seconds, it mints a token
# for the same repository and access and pushes
# it through bin/fm-on.sh to the host's cred-refresh verb
# (bin/fm-remote-task-control.sh), which stores it and confirms its fingerprint.
# A task whose spawn or control lock is held is skipped for that pass, and the
# control lock is held across the refresh. A success is silent. A host that
# refuses or whose reply never arrives (SSH exit 255, the 60-second delivery
# bound, or an unconfirmed fingerprint) triggers revocation of the new token.
# A confirmed delivery triggers revocation of the predecessor. Unconfirmed
# revocations remain in the same pending set for retirement. Either delivery
# failure waits 300 seconds before retrying and queues one wake per current
# token, `check: sandbox <id> credential refresh failed: ...`, printing that
# reason on stdout for bin/fm-watch.sh to surface; later failures for the same
# token are recorded silently; tasks run soonest expiry first within a 150-second
# pass budget, reserving 105 seconds before starting each bounded attempt.
#
# record-revoke records the revoke a sandbox host's retire made with the task's
# stored token, which bin/fm-teardown.sh relays from the host's report.
# retire --task drains every pending mint for the task, recording revoked,
# invalid, or expired before removal. Pending-set readers discard safe files
# without a parseable ghs_ token and record mint-failed reason=tokenless
# outcome=unknown; these placeholders cannot block retirement. Unsafe files or
# failed revocations fail the command and preserve the sandbox at the
# supervising teardown boundary.
# Scouts and --force skip this gate and retain their expiry-only behavior.
#
# state/cred-ledger is append-only, created mode 0600, and holds one event per
# line and never a credential value; fp is the first 12 hex digits of the
# token's SHA-256:
#   <epoch> mint github task=<id> repo=<owner/name> access=<a> expires=<iso> fp=<fp> purpose=launch|refresh
#   <epoch> mint-failed github task=<id> repo=<owner/name> access=<a> purpose=<p> reason=<slug> [outcome=unknown]
#   <epoch> mint-failed github task=<id> reason=tokenless outcome=unknown
#   <epoch> refresh github task=<id> fp=<fp> expires=<iso> result=delivered
#   <epoch> refresh github task=<id> result=failed|unknown reason=<slug> alerted=yes|no [fp=<fp>]
#   <epoch> revoke github task=<id> fp=<fp> result=revoked|invalid|expired|failed [reason=<slug>] [via=host]
# A task's current token is its latest launch mint, or the latest delivered
# refresh after it; once that token is revoked the task is never refreshed.
#
# No JWT or token ever enters argv, the environment, a log, the ledger, or a
# diagnostic: curl starts with --disable so no curlrc applies, and reads its
# Authorization header from --config on stdin; tokens otherwise live only in a
# protected pending set and a private temporary directory removed on exit.
# Every refusal exits non-zero and
# names what was wrong, never a value.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
LEDGER="$STATE/cred-ledger"
PENDING="$STATE/cred-pending"
GITHUB_API=https://api.github.com
GITHUB_API_VERSION=2022-11-28
CURL_MAX_TIME=20

# shellcheck source=bin/fm-sandbox-credentials-lib.sh
. "$SCRIPT_DIR/fm-sandbox-credentials-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '5,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

LEAD_SECS=900
RETRY_SECS=300
PUSH_TIMEOUT=60
PASS_BUDGET=150
ATTEMPT_BUDGET=105
ACTIVE_TASK=
DELIVERY_CONFIRMED=0

refresh_interrupted() {
  if [ -n "$ACTIVE_TASK" ]; then
    if [ "$DELIVERY_CONFIRMED" -eq 0 ]; then
      if [ -n "$MINT_PENDING" ] && [ -f "$MINT_PENDING" ]; then
        revoke_undelivered "$ACTIVE_TASK"
      fi
      refresh_failed "$ACTIVE_TASK" unknown interrupted "the refresh attempt was interrupted"
    fi
    fm_lock_release "$STATE/.control-$ACTIVE_TASK.lock" || true
  fi
  exit 1
}

WORK=
cleanup() { [ -z "$WORK" ] || rm -rf -- "$WORK"; }
trap cleanup EXIT
trap refresh_interrupted HUP INT TERM

work_dir() {
  [ -z "$WORK" ] || return 0
  WORK=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-cred-broker.XXXXXX") \
    || die "cannot create a private working directory"
}

valid_task() { case "$1" in ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;; esac; }
valid_repo() {
  case "$1" in */*/*) return 1 ;; */*) ;; *) return 1 ;; esac
  case "${1%%/*}" in ''|-*|*[!A-Za-z0-9-]*) return 1 ;; esac
  case "${1#*/}" in ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;; esac
}
valid_access() { case "$1" in read|write) return 0 ;; esac; return 1; }
valid_fp() { [[ "$1" =~ ^[0-9a-f]{12}$ ]]; }
valid_iso() { [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; }

# One printable line of at most 200 bytes, for text from GitHub or a host.
one_line() {
  LC_ALL=C tr -d '\000-\010\013-\037\177' | awk 'NF { print; exit }' | cut -c1-200
}

sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

# The fingerprint of the token in <file>: its SHA-256, first 12 hex digits.
token_fp() { # <file>
  LC_ALL=C tr -d '\n' < "$1" | sha256_hex | cut -c1-12
}

# A token is one line of printable ASCII without spaces, quotes, or
# backslashes, so it can sit inside a quoted curl config value unchanged.
token_ok() { # <file>
  fm_sandbox_credential_value_ok "$1" || return 1
  [ -z "$(LC_ALL=C tr -d '\n' < "$1" | LC_ALL=C tr -d '\041\043-\133\135-\176')" ]
}

ledger_append() { # <event fields...>; never a value
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  if [ -e "$LEDGER" ] || [ -L "$LEDGER" ]; then
    [ -f "$LEDGER" ] && [ ! -L "$LEDGER" ] || return 1
  fi
  (umask 077; printf '%s %s\n' "$(date +%s)" "$*" >> "$LEDGER")
}

pending_directory() {
  local dir
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  for dir in "$PENDING" "$PENDING/$1"; do
    [ ! -L "$dir" ] || return 1
    if [ ! -d "$dir" ]; then
      (umask 077; mkdir "$dir") || return 1
    fi
    chmod 700 "$dir" || return 1
  done
}

pending_fingerprint() {
  local task=$1 entry=$2
  fm_sandbox_credential_file_ok "pending credential" "$entry" || return 1
  if ! jq -e '.token | type == "string" and startswith("ghs_")' "$entry" >/dev/null 2>&1; then
    ledger_append "mint-failed github task=$task reason=tokenless outcome=unknown" || return 1
    rm -f -- "$entry"
    return $?
  fi
  jq -ej '.token | select(type == "string" and startswith("ghs_"))' "$entry" 2>/dev/null \
    | sha256_hex | cut -c1-12
}

pending_clear() {
  local task=$1 fp=$2 entry found
  [ ! -L "$PENDING" ] && [ ! -L "$PENDING/$task" ] || return 1
  for entry in "$PENDING/$task"/*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    found=$(pending_fingerprint "$task" "$entry") || return 1
    [ "$found" != "$fp" ] || rm -f -- "$entry" || return 1
  done
}

pending_revoke() {
  local task=$1 entry=$2 reason=$3 allow_expiry=${4:-no} fp expires epoch result=failed
  fp=$(pending_fingerprint "$task" "$entry") || return 1
  [ -n "$fp" ] || return 0
  work_dir
  jq -ej '.token | select(type == "string" and startswith("ghs_"))' "$entry" > "$WORK/pending-token" 2>/dev/null \
    && token_ok "$WORK/pending-token" || return 1
  fp=$(token_fp "$WORK/pending-token")
  expires=$(jq -r '.expires_at // empty' "$entry" 2>/dev/null) || expires=
  if [ "$allow_expiry" = yes ] && valid_iso "$expires" \
    && epoch=$(fm_utc_iso_to_epoch "$expires") && [ "$epoch" -le "$(date +%s)" ]; then
    result=expired
  else
    result=$(github_revoke "$WORK/pending-token") || result=failed
  fi
  ledger_append "revoke github task=$task fp=$fp result=$result reason=$reason" || return 1
  [ "$result" != failed ] || return 1
  rm -f -- "$entry"
}

pending_revoke_fp() {
  local task=$1 fp=$2 entry found
  [ ! -L "$PENDING" ] && [ ! -L "$PENDING/$task" ] || return 1
  for entry in "$PENDING/$task"/*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    found=$(pending_fingerprint "$task" "$entry") || return 1
    if [ "$found" = "$fp" ]; then
      pending_revoke "$task" "$entry" superseded || return 1
    fi
  done
}

cmd_retire() {
  local task entry failed=0
  [ "$#" -eq 2 ] && [ "$1" = --task ] || usage
  task=$2
  valid_task "$task" || die "retire needs --task <id>"
  [ ! -L "$PENDING" ] && [ ! -L "$PENDING/$task" ] || die "unsafe pending credential directory"
  ledger_append "retire github task=$task result=attempted" || die "could not record credential retirement"
  . "$SCRIPT_DIR/fm-classify-lib.sh"
  for entry in "$PENDING/$task"/*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    pending_revoke "$task" "$entry" retire yes || failed=1
  done
  [ "$failed" -eq 0 ] || die "task $task still has unresolved GitHub credentials; retirement remains retryable"
}

# --- GitHub ---------------------------------------------------------------------

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

github_jwt() { # prints the App's JWT; FM_GITHUB_APP_* must be loaded
  local now header payload signature
  now=$(date +%s)
  header=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)
  payload=$(printf '{"iat":%s,"exp":%s,"iss":%s}' "$((now - 60))" "$((now + 540))" "$FM_GITHUB_APP_ID" | b64url)
  signature=$(printf '%s.%s' "$header" "$payload" \
    | openssl dgst -sha256 -sign "$FM_GITHUB_APP_KEY" -binary 2>/dev/null | b64url)
  [ -n "$header" ] && [ -n "$payload" ] && [ -n "$signature" ] || return 1
  printf '%s.%s.%s' "$header" "$payload" "$signature"
}

# One GitHub API call whose Authorization config line arrives on stdin, never
# in argv. Prints the HTTP status; non-zero when no reply arrived.
github_call() { # <method> <path> <body-file|-> <response-file>
  local -a args=(--disable --silent --show-error --max-time "$CURL_MAX_TIME" --config -
    --request "$1" --header 'Accept: application/vnd.github+json'
    --header "X-GitHub-Api-Version: $GITHUB_API_VERSION" --output "$4" --write-out '%{http_code}')
  [ "$3" = - ] || args+=(--header 'Content-Type: application/json' --data-binary "@$3")
  curl "${args[@]}" --url "$GITHUB_API$2" 2>/dev/null
}

github_message() { # <response-file>; GitHub's own value-free error text
  jq -r '.message // empty | tostring' "$1" 2>/dev/null | one_line || true
}

MINT_FP=
MINT_EXPIRES=
MINT_DIAG=
MINT_PENDING=

mint_refused() { # <task> <repo> <access> <purpose> <reason> <diagnostic>
  local outcome=
  MINT_DIAG=$6
  if [ -n "$MINT_PENDING" ] && [ -f "$MINT_PENDING" ] \
      && ! jq -e '.token | type == "string" and startswith("ghs_")' "$MINT_PENDING" >/dev/null 2>&1; then
    rm -f -- "$MINT_PENDING"
  fi
  case "$5" in unreachable|response) outcome=" outcome=unknown" ;; esac
  ledger_append "mint-failed github task=$1 repo=$2 access=$3 purpose=$4 reason=$5$outcome" || true
  return 1
}

# Mint one token into <token-file> and record it; sets MINT_FP and MINT_EXPIRES,
# or returns 1 with MINT_DIAG set.
github_mint() { # <task> <repo> <access> <purpose> <token-file>
  local task=$1 repo=$2 access=$3 purpose=$4 out=$5 jwt status message
  MINT_FP=
  MINT_EXPIRES=
  MINT_DIAG=
  MINT_PENDING=
  if ! fm_github_app_config_load "$CONFIG/github-app"; then
    mint_refused "$task" "$repo" "$access" "$purpose" config "$FM_SANDBOX_CREDENTIAL_ERROR"
    return 1
  fi
  work_dir
  if ! jq -n --arg name "${repo#*/}" --arg access "$access" --arg workflows "$FM_GITHUB_APP_WORKFLOWS" '
      {repositories: [$name],
       permissions: (if $access == "read"
         then {contents: "read", metadata: "read", pull_requests: "read"}
         else {contents: "write", metadata: "read", pull_requests: "write", issues: "write",
               checks: "read", statuses: "read", actions: "read"}
           + (if $workflows == "on" then {workflows: "write"} else {} end)
         end)}' > "$WORK/request.json" 2>/dev/null; then
    mint_refused "$task" "$repo" "$access" "$purpose" request "the installation token request could not be built"
    return 1
  fi
  if ! jwt=$(github_jwt); then
    mint_refused "$task" "$repo" "$access" "$purpose" jwt "the GitHub App private key $FM_GITHUB_APP_KEY could not sign a JWT"
    return 1
  fi
  pending_directory "$task" || die "cannot protect pending credentials for task $task"
  MINT_PENDING=$(umask 077; mktemp "$PENDING/$task/token.XXXXXX") \
    || die "cannot retain the mint response for task $task"
  if ! status=$(printf 'header = "Authorization: Bearer %s"\n' "$jwt" \
      | github_call POST "/app/installations/$FM_GITHUB_APP_INSTALLATION_ID/access_tokens" \
        "$WORK/request.json" "$MINT_PENDING"); then
    jwt=
    mint_refused "$task" "$repo" "$access" "$purpose" unreachable "GitHub could not be reached to mint a token for $repo"
    return 1
  fi
  jwt=
  if [ "$status" != 201 ]; then
    message=$(github_message "$MINT_PENDING")
    case "$status" in ''|*[!0-9]*) status=unknown ;; esac
    mint_refused "$task" "$repo" "$access" "$purpose" "http-$status" \
      "GitHub refused an installation token for $repo (HTTP $status${message:+: $message})"
    return 1
  fi
  # jq's diagnostics could quote the reply, which holds the token, so they are
  # discarded; the token itself goes only into the private token file.
  if ! jq -e '(.token | type == "string" and startswith("ghs_"))
      and (.expires_at | type == "string")' "$MINT_PENDING" >/dev/null 2>&1 \
    || ! jq -j '.token' "$MINT_PENDING" > "$out" 2>/dev/null \
    || ! token_ok "$out" \
    || ! MINT_EXPIRES=$(jq -r '.expires_at' "$MINT_PENDING" 2>/dev/null) \
    || ! valid_iso "$MINT_EXPIRES"; then
    pending_revoke "$task" "$MINT_PENDING" malformed || true
    rm -f -- "$out"
    mint_refused "$task" "$repo" "$access" "$purpose" response "GitHub's installation token reply for $repo was malformed"
    return 1
  fi
  MINT_FP=$(token_fp "$out")
  if ! jq -e --arg repo "$repo" '[(.repositories // [])[] | .full_name | ascii_downcase] == [$repo | ascii_downcase]' \
      "$MINT_PENDING" >/dev/null 2>&1; then
    pending_revoke "$task" "$MINT_PENDING" repository || true
    rm -f -- "$out"
    mint_refused "$task" "$repo" "$access" "$purpose" repository \
      "GitHub minted a token whose repositories are not exactly $repo; cleanup revocation was attempted"
    return 1
  fi
  if ! ledger_append "mint github task=$task repo=$repo access=$access expires=$MINT_EXPIRES fp=$MINT_FP purpose=$purpose"; then
    pending_revoke "$task" "$MINT_PENDING" ledger || true
    rm -f -- "$out"
    MINT_DIAG="the mint for $repo could not be recorded in $LEDGER; its credential remains tracked until revoked"
    return 1
  fi
}

# Present <token-file> to DELETE /installation/token; prints revoked, invalid,
# or failed, and returns 1 only for failed. It needs no private state, so it
# is safe in a command substitution.
github_revoke() { # <token-file>
  local file=$1 status
  if ! status=$( { printf 'header = "Authorization: Bearer '; LC_ALL=C tr -d '\n' < "$file"; printf '"\n'; } \
      | github_call DELETE /installation/token - /dev/null); then
    status=none
  fi
  case "$status" in
    2[0-9][0-9]) printf 'revoked\n' ;;
    401|404) printf 'invalid\n' ;;
    *) printf 'failed\n'; return 1 ;;
  esac
}

# The task a fingerprint was minted for, from the ledger; unknown otherwise.
ledger_task_for_fp() { # <fp>
  local task=
  [ -f "$LEDGER" ] && task=$(awk -v fp="$1" '
    $2 == "mint" && $3 == "github" {
      t = ""; f = ""
      for (i = 4; i <= NF; i++) {
        if (index($i, "task=") == 1) t = substr($i, 6)
        if (index($i, "fp=") == 1) f = substr($i, 4)
      }
      if (f == fp) task = t
    }
    END { print task }' "$LEDGER" 2>/dev/null) || task=
  valid_task "$task" || task=unknown
  printf '%s\n' "$task"
}

# --- verbs ----------------------------------------------------------------------

cmd_mint() {
  local task='' repo='' access='' out='' dir tmp
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task|--repo|--access|--out)
        [ "$#" -ge 2 ] || usage
        case "$1" in
          --task) task=$2 ;;
          --repo) repo=$2 ;;
          --access) access=$2 ;;
          --out) out=$2 ;;
        esac
        shift 2
        ;;
      *) usage ;;
    esac
  done
  valid_task "$task" || die "mint needs --task <id>: letters, digits, '.', '_', and '-'"
  valid_repo "$repo" || die "mint needs --repo <owner/name> naming one GitHub repository"
  valid_access "$access" || die "mint needs --access read or --access write"
  if [ -n "$out" ]; then
    case "$out" in /*) ;; *) die "--out must be an absolute path" ;; esac
    if [ -e "$out" ] || [ -L "$out" ]; then
      [ -f "$out" ] && [ ! -L "$out" ] || die "--out $out exists and is not a regular file"
    fi
    dir=$(dirname -- "$out")
    [ -d "$dir" ] && [ ! -L "$dir" ] || die "--out's directory $dir does not exist or is a symlink"
  fi
  work_dir
  github_mint "$task" "$repo" "$access" launch "$WORK/token" || die "$MINT_DIAG"
  if [ -n "$out" ]; then
    if ! tmp=$(umask 077; mktemp "$dir/.fm-cred-token.XXXXXX") \
      || ! cat -- "$WORK/token" > "$tmp" || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$out"; then
      [ -z "${tmp:-}" ] || rm -f -- "$tmp"
      revoke_undelivered "$task"
      die "the token for $repo could not be written to $out; cleanup revocation was attempted"
    fi
  elif ! { cat -- "$WORK/token" && printf '\n'; }; then
    revoke_undelivered "$task"
    die "the token for $repo could not be written to stdout; cleanup revocation was attempted"
  fi
}

revoke_undelivered() { # <task>; revokes and records $WORK/token
  pending_revoke "$1" "$MINT_PENDING" undelivered || true
}

cmd_revoke() {
  local file='' fp task result
  [ "$#" -eq 2 ] && [ "$1" = --token-file ] || usage
  file=$2
  fm_sandbox_credential_file_ok "the token file" "$file" || die "$FM_SANDBOX_CREDENTIAL_ERROR"
  token_ok "$file" || die "the token file $file must hold one token on one line"
  fp=$(token_fp "$file")
  task=$(ledger_task_for_fp "$fp")
  result=$(github_revoke "$file") || result=failed
  ledger_append "revoke github task=$task fp=$fp result=$result" \
    || printf 'warning: the revoke of fp=%s could not be recorded in %s\n' "$fp" "$LEDGER" >&2
  [ "$result" != failed ] || die "GitHub did not confirm the revoke of the token with fp=$fp"
  pending_clear "$task" "$fp" || die "could not clear the confirmed revoke from pending credentials"
  printf 'revoke=%s\nfp=%s\n' "$result" "$fp"
}

cmd_record_revoke() {
  local task='' fp='' result=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task|--fp|--result)
        [ "$#" -ge 2 ] || usage
        case "$1" in
          --task) task=$2 ;;
          --fp) fp=$2 ;;
          --result) result=$2 ;;
        esac
        shift 2
        ;;
      *) usage ;;
    esac
  done
  valid_task "$task" || die "record-revoke needs --task <id>"
  valid_fp "$fp" || die "record-revoke needs --fp <12 hex digits>"
  case "$result" in revoked|invalid|expired|failed) ;; *) die "record-revoke needs --result revoked, invalid, expired, or failed" ;; esac
  ledger_append "revoke github task=$task fp=$fp result=$result via=host" \
    || die "the host's revoke of fp=$fp could not be recorded in $LEDGER"
  case "$result" in
    revoked|invalid) pending_clear "$task" "$fp" || die "could not clear the host's confirmed revoke" ;;
  esac
}

# --- refresh --------------------------------------------------------------------

CUR_FP=
CUR_EXPIRES=
CUR_REPO=
CUR_ACCESS=
CUR_REVOKED=
CUR_FAILED_AT=
CUR_ALERTED=

# The ledger's view of <task>'s current token; 1 when no launch mint names it.
ledger_current() { # <task>
  local line
  line=$(awk -v task="$1" '
    function field(k,   i) {
      for (i = 4; i <= NF; i++) if (index($i, k "=") == 1) return substr($i, length(k) + 2)
      return ""
    }
    $3 != "github" || field("task") != task { next }
    $2 == "mint" && field("purpose") == "launch" {
      fp = field("fp"); expires = field("expires"); repo = field("repo"); access = field("access")
      revoked = 0; failed = "-"; alerted = 0; have = 1; next
    }
    $2 == "retire" || ($2 == "revoke" && field("via") == "host") { retiring = 1 }
    !have { next }
    $2 == "refresh" && field("result") == "delivered" {
      fp = field("fp"); expires = field("expires"); failed = "-"; alerted = 0; next
    }
    $2 == "refresh" { failed = $1; if (field("alerted") == "yes") alerted = 1; next }
    $2 == "revoke" && field("fp") == fp && (field("result") == "revoked" || field("result") == "invalid" || field("result") == "expired") { revoked = 1 }
    END { if (have && !retiring) print fp, expires, repo, access, revoked, failed, alerted }' "$LEDGER" 2>/dev/null) || return 1
  [ -n "$line" ] || return 1
  read -r CUR_FP CUR_EXPIRES CUR_REPO CUR_ACCESS CUR_REVOKED CUR_FAILED_AT CUR_ALERTED <<< "$line"
}

lock_live() { # <lockdir>
  local pid
  [ -d "$1" ] || return 1
  pid=$(cat "$1/pid" 2>/dev/null || true)
  [ -n "$pid" ] && fm_pid_alive "$pid"
}

# One failed refresh: queue the current token's one wake, then record it.
refresh_failed() { # <task> <result> <reason> <diagnostic> [<minted-fp>]
  local task=$1 result=$2 reason=$3 diag=$4 fp=${5:-} alerted=no key text
  if [ "$CUR_ALERTED" != 1 ]; then
    key="cred-refresh-$task-$CUR_FP"
    text="check: sandbox $task credential refresh failed: $diag; its current GitHub token expires at $CUR_EXPIRES, and its worker loses GitHub access then until a refresh succeeds; the refresh retries every ${RETRY_SECS}s - check config/github-app, the App's installation, and the sandbox host (docs/remote-sandboxes.md#credentials)"
    if fm_wake_queued_keys check | grep -Fx -- "$key" >/dev/null 2>&1 \
      || fm_wake_append check "$key" "$text"; then
      alerted=yes
      CUR_ALERTED=1
      printf '%s\n' "$text"
    fi
  fi
  ledger_append "refresh github task=$task result=$result reason=$reason alerted=$alerted${fp:+ fp=$fp}" || true
}

refresh_task() { # <task>
  local task=$1
  ! lock_live "$STATE/.spawn-$task.lock" || return 0
  fm_lock_try_acquire "$STATE/.control-$task.lock" || return 0
  if fm_remote_route_resolve "$STATE/$task.meta" "$task" && [ "$FM_REMOTE_ROUTE_KIND" = task ]; then
    refresh_task_locked "$task"
  fi
  fm_lock_release "$STATE/.control-$task.lock" || true
}

refresh_task_locked() {
  local task=$1 now expires_at rc out back
  ledger_current "$task" || return 0
  [ "$CUR_REVOKED" = 0 ] || return 0
  if ! valid_fp "$CUR_FP" || ! valid_repo "$CUR_REPO" || ! valid_access "$CUR_ACCESS" \
    || ! valid_iso "$CUR_EXPIRES" || ! expires_at=$(fm_utc_iso_to_epoch "$CUR_EXPIRES"); then
    refresh_failed "$task" failed ledger "the ledger's record of its current token is malformed"
    return 0
  fi
  now=$(date +%s)
  [ "$((expires_at - now))" -le "$LEAD_SECS" ] || return 0
  case "$CUR_FAILED_AT" in
    -) ;;
    *[!0-9]*) ;;
    *) [ "$((now - CUR_FAILED_AT))" -ge "$RETRY_SECS" ] || return 0 ;;
  esac
  ACTIVE_TASK=$task
  DELIVERY_CONFIRMED=0
  work_dir
  rm -f -- "$WORK/token"
  if ! github_mint "$task" "$CUR_REPO" "$CUR_ACCESS" refresh "$WORK/token"; then
    refresh_failed "$task" failed mint "$MINT_DIAG"
    return 0
  fi
  # fm_exec_timed, unlike fm_run_timed, keeps stdin, which carries the token.
  rc=0
  out=$( { printf 'gh_token_b64='; base64 < "$WORK/token" | tr -d '\n'; printf '\n'; } \
    | ( fm_exec_timed "$PUSH_TIMEOUT" 5 "$SCRIPT_DIR/fm-on.sh" --stdin "$task" \
      fm-remote-task-control.sh cred-refresh "$task" ) 2>/dev/null) || rc=$?
  back=$(printf '%s\n' "$out" | sed -n 's/^gh_token_fp=//p' | tail -n 1)
  if [ "$rc" -eq 0 ] && [ "$(printf '%s\n' "$out" | sed -n '1p')" = "schema=fm-remote-task-control.v1" ] \
    && printf '%s\n' "$out" | grep -qx 'refresh=stored' && [ "$back" = "$MINT_FP" ]; then
    DELIVERY_CONFIRMED=1
    ledger_append "refresh github task=$task fp=$MINT_FP expires=$MINT_EXPIRES result=delivered" || true
    pending_revoke_fp "$task" "$CUR_FP" || true
    return 0
  fi
  revoke_undelivered "$task"
  if [ "$rc" -eq 0 ]; then
    refresh_failed "$task" unknown unconfirmed "the sandbox host did not confirm it stored the new token" "$MINT_FP"
  elif [ "$rc" -eq 255 ]; then
    refresh_failed "$task" unknown unreachable "SSH exit 255: the sandbox host could not be reached" "$MINT_FP"
  elif fm_timed_out "$rc"; then
    refresh_failed "$task" unknown timeout "no answer from the sandbox host within ${PUSH_TIMEOUT}s" "$MINT_FP"
  else
    refresh_failed "$task" failed refused "the sandbox host refused the new token (exit $rc); cleanup revocation was attempted" "$MINT_FP"
  fi
  rm -f -- "$WORK/token"
}

cmd_refresh_due() {
  local meta task expires started now
  [ "$#" -eq 0 ] || usage
  [ -f "$LEDGER" ] && [ ! -L "$LEDGER" ] || return 0
  LC_ALL=C grep -qx 'placement=sandbox' "$STATE"/*.meta 2>/dev/null || return 0
  # Loaded only when this home places a sandbox task: the lock, wake-queue,
  # route, ISO-time, and bounded-run owners this verb shares with the watcher.
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  # shellcheck source=bin/fm-remote-route-lib.sh
  . "$SCRIPT_DIR/fm-remote-route-lib.sh"
  # shellcheck source=bin/fm-classify-lib.sh
  . "$SCRIPT_DIR/fm-classify-lib.sh"
  started=$(date +%s)
  work_dir
  : > "$WORK/due"
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    task=$(basename "$meta" .meta)
    valid_task "$task" || continue
    LC_ALL=C grep -q '^placement=' "$meta" 2>/dev/null || continue
    fm_remote_route_resolve "$meta" "$task" || continue
    [ "$FM_REMOTE_ROUTE_KIND" = task ] || continue
    ledger_current "$task" || continue
    printf '%s %s\n' "$CUR_EXPIRES" "$task" >> "$WORK/due"
  done
  while read -r expires task; do
    now=$(date +%s)
    [ "$((now - started + ATTEMPT_BUDGET))" -le "$PASS_BUDGET" ] || break
    refresh_task "$task"
    ACTIVE_TASK=
  done < <(LC_ALL=C sort "$WORK/due")
}

# --- dispatch -------------------------------------------------------------------

[ "${1:-}" = github ] || usage
VERB=${2:-}
[ "$#" -ge 2 ] || usage
shift 2
case "$VERB" in
  mint) cmd_mint "$@" ;;
  revoke) cmd_revoke "$@" ;;
  retire) cmd_retire "$@" ;;
  refresh-due) cmd_refresh_due "$@" ;;
  record-revoke) cmd_record_revoke "$@" ;;
  *) usage ;;
esac

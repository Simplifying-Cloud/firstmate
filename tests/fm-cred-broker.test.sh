#!/usr/bin/env bash
# tests/fm-cred-broker.test.sh - bin/fm-cred-broker.sh against a fake GitHub API.
#
# The broker runs for real against a fixture home: config/github-app names a
# throwaway RSA key generated here, and curl is tests/fixtures.sh's fake GitHub
# API, so nothing reaches the network. refresh-due pushes through the real
# bin/fm-on.sh, whose fake ssh runs the real bin/fm-remote-task-control.sh
# cred-refresh against a fixture task home with a fake gh credential store.
# Every token the fake mints is 520 characters long and carries this run's tag,
# and each case searches the ledger, the broker's output, the wake queue, the
# curl and transport argv logs, and the host's records for it.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v openssl >/dev/null 2>&1 || { echo "skip: openssl not found"; exit 0; }

BROKER="$ROOT/bin/fm-cred-broker.sh"
TMP_ROOT=$(fm_test_tmproot fm-cred-broker)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
RUN_ID=$$
TAG="BROKERTEST${RUN_ID}"
export FM_FAKE_GITHUB_TOKEN_TAG=$TAG
APP_ID=424242
INSTALLATION_ID=987654321
REAL_JQ=$(command -v jq)
export REAL_JQ

FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
fm_test_fake_github_api "$FAKEBIN" "$TMP_ROOT/github-unused"

REAL_DATE=$(command -v date)
export REAL_DATE
cat > "$FAKEBIN/date" <<'SH'
#!/usr/bin/env bash
if [ "$*" = +%s ]; then
  offset=$(cat "$FM_FAKE_GITHUB_DIR/clock-offset" 2>/dev/null || echo 0)
  echo "$(( $("$REAL_DATE" +%s) + offset ))"
else
  exec "$REAL_DATE" "$@"
fi
SH
chmod +x "$FAKEBIN/date"

advance_clock() {
  local offset
  offset=$(cat "$GH_DIR/clock-offset" 2>/dev/null || echo 0)
  echo "$((offset + $1))" > "$GH_DIR/clock-offset"
}

# The sandbox host's tools: a gh whose credential store is a plain file, and
# which fails to store while <account>/../gh-fail exists.
HOST_BIN="$TMP_ROOT/host-bin"
mkdir -p "$HOST_BIN"
cat > "$HOST_BIN/gh" <<'SH'
#!/usr/bin/env bash
set -eu
store="$HOME/.config/gh"
case "$*" in
  "auth login --hostname github.com --git-protocol https --insecure-storage --with-token")
    if [ -e "$HOME/../gh-fail" ]; then cat > /dev/null; exit 1; fi
    mkdir -p "$store"
    cat > "$store/hosts.yml"
    printf 'git_protocol: https\n' > "$store/config.yml"
    ;;
  *) exit 1 ;;
esac
SH
chmod +x "$HOST_BIN/gh"

# The transport: fm-on.sh's FM_SSH_BIN seam, running the named command from the
# code root against the task home under an empty environment, as the remote job
# worker would. FM_FAKE_SSH_MODE=unreachable answers SSH's exit 255.
cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
set -u
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
host=$1
[ "$2" = fm-remote-entrypoint.sh ] || exit 92
root=$(printf '%s' "$4" | base64 --decode)
home=$(printf '%s' "$5" | base64 --decode)
args=()
while IFS= read -r -d '' arg; do args+=("$arg"); done < <(printf '%s' "$6" | base64 --decode)
printf '%s %s\n' "$host" "${args[*]}" >> "$FM_FAKE_SSH_LOG"
if [ -f "$FM_FAKE_GITHUB_DIR/delivery-elapsed" ]; then
  offset=$(cat "$FM_FAKE_GITHUB_DIR/clock-offset" 2>/dev/null || echo 0)
  elapsed=$(cat "$FM_FAKE_GITHUB_DIR/delivery-elapsed")
  echo "$((offset + elapsed))" > "$FM_FAKE_GITHUB_DIR/clock-offset"
fi
if [ "${FM_FAKE_SSH_MODE:-normal}" = unreachable ]; then
  cat > /dev/null
  exit 255
fi
exec env -i PATH="$FM_FAKE_HOST_BIN:$PATH" HOME="$FM_FAKE_HOST_ACCOUNT" TMPDIR="$FM_FAKE_HOST_TMP" \
  FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$root/bin/${args[0]}" "${args[@]:1}"
SH
chmod +x "$FAKEBIN/fake-ssh"

KEYS="$TMP_ROOT/keys"
mkdir -p "$KEYS"
chmod 700 "$KEYS"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$KEYS/app.pem" >/dev/null 2>&1 \
  || fail "could not generate the throwaway App key"
openssl pkey -in "$KEYS/app.pem" -pubout -out "$KEYS/app.pub" >/dev/null 2>&1 || fail "could not derive the public key"
openssl genrsa -traditional -out "$KEYS/app-rsa.pem" 2048 >/dev/null 2>&1 \
  || openssl genrsa -out "$KEYS/app-rsa.pem" 2048 >/dev/null 2>&1 || fail "could not generate the PKCS#1 App key"
openssl pkey -in "$KEYS/app-rsa.pem" -pubout -out "$KEYS/app-rsa.pub" >/dev/null 2>&1 || fail "could not derive the PKCS#1 public key"
chmod 600 "$KEYS"/*.pem

mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

fp_of() { # <file>; the ledger's fingerprint of the token in <file>
  if command -v sha256sum >/dev/null 2>&1; then
    tr -d '\n' < "$1" | sha256sum | cut -c1-12
  else
    tr -d '\n' < "$1" | shasum -a 256 | cut -c1-12
  fi
}

# minted_token <n> <file>: the fake API's <n>th minted token, into <file>.
minted_token() {
  sed -n "${1}p" "$GH_DIR/minted" | tr -d '\n' > "$2"
}

b64url_decode() {
  local s
  s=$(tr '_-' '/+')
  case $(( ${#s} % 4 )) in 2) s="$s==" ;; 3) s="$s=" ;; esac
  printf '%s' "$s" | openssl base64 -d -A
}

# --- per-case homes -------------------------------------------------------------

# new_case <name>: a supervising home with config/github-app and a fresh fake API.
new_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  GH_DIR="$CASE/github"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data" "$GH_DIR" "$CASE/tmp" "$CASE/out"
  export FM_FAKE_GITHUB_DIR=$GH_DIR
  write_app_config "$KEYS/app.pem" on
  LEDGER="$HOME_DIR/state/cred-ledger"
}

write_app_config() { # <key> <workflows|-> [extra line...]
  local key=$1 workflows=$2
  shift 2
  {
    printf '# the throwaway test App\n'
    printf 'app_id=%s\n' "$APP_ID"
    printf 'installation_id=%s\n' "$INSTALLATION_ID"
    printf 'private_key=%s\n' "$key"
    [ "$workflows" = - ] || printf 'workflows=%s\n' "$workflows"
    for line in "$@"; do printf '%s\n' "$line"; done
  } > "$HOME_DIR/config/github-app"
  chmod 600 "$HOME_DIR/config/github-app"
}

run_broker() { # <args...>; sets OUT, ERR, and RC
  OUT=$(env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" TMPDIR="$CASE/tmp" \
    FM_SSH_BIN="$FAKEBIN/fake-ssh" FM_FAKE_SSH_LOG="$CASE/ssh.log" FM_FAKE_HOST_BIN="$HOST_BIN" \
    FM_FAKE_HOST_ACCOUNT="${HOST_ACCOUNT:-$CASE/no-host}" FM_FAKE_HOST_TMP="${HOST_TMP:-$CASE/tmp}" \
    "$BROKER" "$@" 2>"$CASE/broker.err")
  RC=$?
  ERR=$(cat "$CASE/broker.err")
}

calls() { # <method>; how many calls the fake API answered for it
  local n=
  n=$(grep -c "^$1 " "$GH_DIR/calls.log" 2>/dev/null) || true
  printf '%s\n' "${n:-0}"
}
posts() { calls POST; }
deletes() { calls DELETE; }

# No minted token outside the fake API's own records and the host's gh store.
assert_no_token_anywhere() { # <label>
  local hit
  case "$OUT$ERR" in *"ghs_$TAG"*) fail "$1: the broker's output holds a token" ;; esac
  hit=$(grep -rlF "ghs_$TAG" "$HOME_DIR" "$CASE/tmp" "$CASE/ssh.log" "$GH_DIR/argv.log" "$GH_DIR/calls.log" \
    ${HOST_HOME:+"$HOST_HOME"} 2>/dev/null || true)
  [ -z "$hit" ] || fail "$1: a token value was written to $hit"
  [ -z "$(ls -A "$CASE/tmp" 2>/dev/null)" ] || fail "$1: the broker left private state in $CASE/tmp: $(ls -A "$CASE/tmp")"
}

# No JWT the broker presented ever reached curl's argv.
assert_no_jwt_in_argv() { # <label>
  local f jwt argv
  argv=$(cat "$GH_DIR/argv.log" 2>/dev/null || true)
  for f in "$GH_DIR"/jwt.*; do
    [ -f "$f" ] || continue
    jwt=$(cat "$f")
    [ -n "$jwt" ] || fail "$1: a token request carried no JWT"
    case "$argv" in *"$jwt"*) fail "$1: a JWT reached curl's argv" ;; esac
  done
}

ledger_line() { # <n>
  sed -n "${1}p" "$LEDGER"
}

# --- mint --------------------------------------------------------------------------

test_mint_writes_a_private_token_and_a_valueless_ledger_line() {
  local now header payload iat exp line fp
  new_case mint
  now=$(date +%s)
  run_broker github mint --task t-mint --repo acme/alpha --access read --out "$CASE/out/t.token"
  expect_code 0 "$RC" "a read mint should succeed"$'\n'"$ERR"
  assert_equals "" "$OUT" "a mint to --out prints nothing"
  assert_equals 600 "$(mode_of "$CASE/out/t.token")" "the token file is private"
  minted_token 1 "$CASE/expected.token"
  cmp -s "$CASE/expected.token" "$CASE/out/t.token" || fail "the token file does not hold exactly the minted token"
  assert_equals 520 "$(wc -c < "$CASE/out/t.token" | tr -d ' ')" "the stateless-format token is written whole"

  fp=$(fp_of "$CASE/out/t.token")
  line=$(ledger_line 1)
  [[ "$line" =~ ^[0-9]+\ mint\ github\ task=t-mint\ repo=acme/alpha\ access=read\ expires=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\ fp=$fp\ purpose=launch$ ]] \
    || fail "the ledger's mint line is not the expected shape: $line"
  assert_equals 1 "$(grep -c . "$LEDGER")" "one mint is one ledger line"
  assert_equals 600 "$(mode_of "$LEDGER")" "the ledger is private"

  assert_equals '{"permissions":{"contents":"read","metadata":"read","pull_requests":"read"},"repositories":["alpha"]}' \
    "$(jq -cS . "$GH_DIR/request.1.json")" "a read token asks for the one repository's read set only"
  assert_equals "POST /app/installations/$INSTALLATION_ID/access_tokens 201" "$(cat "$GH_DIR/calls.log")" \
    "the mint asks the configured installation"

  IFS=. read -r header payload _ < "$GH_DIR/jwt.1"
  assert_equals '{"alg":"RS256","typ":"JWT"}' "$(printf '%s' "$header" | b64url_decode | jq -cS .)" "the JWT is RS256"
  iat=$(printf '%s' "$payload" | b64url_decode | jq -r .iat)
  exp=$(printf '%s' "$payload" | b64url_decode | jq -r .exp)
  assert_equals "$APP_ID" "$(printf '%s' "$payload" | b64url_decode | jq -r .iss)" "the JWT's issuer is the App"
  assert_equals 600 "$((exp - iat))" "the JWT lives nine minutes past a backdated minute"
  [ "$iat" -le $((now - 59)) ] && [ "$iat" -ge $((now - 120)) ] || fail "the JWT's iat is not backdated a minute: $iat vs $now"
  printf '%s.%s' "$header" "$payload" > "$CASE/jwt.signed"
  cut -d. -f3 "$GH_DIR/jwt.1" | b64url_decode > "$CASE/jwt.sig"
  openssl dgst -sha256 -verify "$KEYS/app.pub" -signature "$CASE/jwt.sig" "$CASE/jwt.signed" >/dev/null 2>&1 \
    || fail "the JWT does not verify with the App's public key"
  assert_equals --disable "$(head -n 1 "$GH_DIR/argv.log" | cut -d' ' -f1)" "curl starts with --disable, so no curlrc applies"
  assert_no_jwt_in_argv "a mint"
  assert_no_token_anywhere "a mint"
  pass "mint writes a private token from a verifiable JWT and records it without its value"
}

test_write_access_requests_the_ship_set() {
  local token
  new_case write
  run_broker github mint --task t-write --repo acme/alpha --access write --out "$CASE/out/w.token"
  expect_code 0 "$RC" "a write mint should succeed"$'\n'"$ERR"
  assert_equals '{"permissions":{"actions":"read","checks":"read","contents":"write","issues":"write","metadata":"read","pull_requests":"write","statuses":"read","workflows":"write"},"repositories":["alpha"]}' \
    "$(jq -cS . "$GH_DIR/request.1.json")" "workflows=on adds workflows write to the ship set"

  write_app_config "$KEYS/app.pem" off
  run_broker github mint --task t-write --repo acme/alpha --access write --out "$CASE/out/w.token"
  expect_code 0 "$RC" "a write mint without workflows should succeed"
  assert_equals '{"permissions":{"actions":"read","checks":"read","contents":"write","issues":"write","metadata":"read","pull_requests":"write","statuses":"read"},"repositories":["alpha"]}' \
    "$(jq -cS . "$GH_DIR/request.2.json")" "workflows=off never asks for workflows"
  write_app_config "$KEYS/app.pem" -
  run_broker github mint --task t-write --repo acme/alpha --access write --out "$CASE/out/w.token"
  expect_code 0 "$RC" "a config without workflows should mint"
  assert_equals null "$(jq -c .permissions.workflows "$GH_DIR/request.3.json")" "workflows defaults to off"

  write_app_config "$KEYS/app-rsa.pem" on
  run_broker github mint --task t-write --repo acme/alpha --access write
  expect_code 0 "$RC" "a PKCS#1 key should mint to stdout"$'\n'"$ERR"
  token=$(sed -n 4p "$GH_DIR/minted")
  assert_equals "$token" "$OUT" "stdout carries exactly the token"
  cut -d. -f1,2 "$GH_DIR/jwt.4" | tr -d '\n' > "$CASE/jwt.signed"
  cut -d. -f3 "$GH_DIR/jwt.4" | b64url_decode > "$CASE/jwt.sig"
  openssl dgst -sha256 -verify "$KEYS/app-rsa.pub" -signature "$CASE/jwt.sig" "$CASE/jwt.signed" >/dev/null 2>&1 \
    || fail "a PKCS#1 key's JWT does not verify"
  OUT=
  assert_equals 4 "$(grep -c ' mint github task=t-write ' "$LEDGER")" "every mint is recorded"
  assert_no_jwt_in_argv "write mints"
  assert_no_token_anywhere "write mints"
  pass "a write token asks for the ship set, with workflows only when configured"
}

test_refuses_unsafe_keys_and_malformed_input() {
  local label
  new_case refuse
  refuse_case() { # <label> <expected-error>; the mint must fail before any request
    run_broker github mint --task t-refuse --repo acme/alpha --access write --out "$CASE/out/r.token"
    [ "$RC" -ne 0 ] || fail "$1: the mint was accepted"
    assert_contains "$ERR" "$2" "$1: the refusal names the problem"
    assert_equals 0 "$(posts)" "$1: no token was requested"
    assert_absent "$CASE/out/r.token" "$1: no token file was written"
  }

  rm -f "$HOME_DIR/config/github-app"
  refuse_case "no config" "github-app does not exist"
  write_app_config "$KEYS/app.pem" on
  chmod 644 "$HOME_DIR/config/github-app"
  refuse_case "a readable config" "is mode 644"
  write_app_config "$KEYS/app.pem" on
  chmod 640 "$KEYS/app.pem"
  refuse_case "a group-readable key" "is mode 640; it must not be readable or writable by group or others"
  chmod 600 "$KEYS/app.pem"
  ln -s "$KEYS/app.pem" "$CASE/link.pem"
  write_app_config "$CASE/link.pem" on
  refuse_case "a symlinked key" "must be a regular file, not a symlink"
  write_app_config "$CASE/missing.pem" on
  refuse_case "a missing key" "must be a regular file, not a symlink or a missing path"
  write_app_config keys/app.pem on
  refuse_case "a relative key path" "'keys/app.pem' must be an absolute path"
  printf 'not a key\n' > "$CASE/not-a-key.pem"
  chmod 600 "$CASE/not-a-key.pem"
  write_app_config "$CASE/not-a-key.pem" on
  refuse_case "a key that is not PEM" "is not a PEM RSA private key"
  write_app_config "$KEYS/app.pem" on "client_secret=x"
  refuse_case "an unknown key" "sets unknown key client_secret"
  write_app_config "$KEYS/app.pem" on "app_id=$APP_ID"
  refuse_case "a repeated key" "sets app_id more than once"
  write_app_config "$KEYS/app.pem" maybe
  refuse_case "a bad workflows value" "workflows must be on or off"
  write_app_config "$KEYS/app.pem" on "a bare line"
  refuse_case "a line that is not key=value" "must be <key>=<value>"
  printf 'app_id=abc\ninstallation_id=%s\nprivate_key=%s\n' "$INSTALLATION_ID" "$KEYS/app.pem" > "$HOME_DIR/config/github-app"
  refuse_case "a non-numeric App ID" "app_id must be a positive decimal number"
  printf 'app_id=%s\nprivate_key=%s\n' "$APP_ID" "$KEYS/app.pem" > "$HOME_DIR/config/github-app"
  refuse_case "no installation" "does not set installation_id"
  assert_equals 13 "$(grep -c ' mint-failed github task=t-refuse repo=acme/alpha access=write purpose=launch reason=config$' "$LEDGER")" \
    "every configuration refusal is recorded"

  write_app_config "$KEYS/app.pem" on
  : > "$LEDGER"
  for label in "alpha|--repo <owner/name>" "acme/alpha/extra|--repo <owner/name>" "-acme/alpha|--repo <owner/name>" "acme/..|--repo <owner/name>"; do
    run_broker github mint --task t-refuse --repo "${label%%|*}" --access read
    [ "$RC" -ne 0 ] || fail "repository '${label%%|*}' was accepted"
    assert_contains "$ERR" "${label#*|}" "repository '${label%%|*}' is refused by name"
  done
  run_broker github mint --task t-refuse --repo acme/alpha --access admin
  assert_contains "$ERR" "--access read or --access write" "an unknown access level is refused"
  run_broker github mint --task ../escape --repo acme/alpha --access read
  assert_contains "$ERR" "mint needs --task <id>" "an unsafe task id is refused"
  run_broker github mint --task t-refuse --repo acme/alpha --access read --out relative.token
  assert_contains "$ERR" "--out must be an absolute path" "a relative --out is refused"
  run_broker github mint --task t-refuse --repo acme/alpha --access read --out "$CASE/no-dir/t.token"
  assert_contains "$ERR" "does not exist or is a symlink" "an --out in a missing directory is refused"
  ln -s "$CASE/elsewhere" "$CASE/out/linked.token"
  run_broker github mint --task t-refuse --repo acme/alpha --access read --out "$CASE/out/linked.token"
  assert_contains "$ERR" "exists and is not a regular file" "an --out symlink is refused"
  assert_absent "$CASE/elsewhere" "nothing was written through the --out symlink"
  run_broker github mint --task t-refuse --repo acme/alpha
  [ "$RC" -ne 0 ] || fail "a mint without --access was accepted"
  assert_contains "$ERR" "mint needs --access read or --access write" "a missing access level is refused by name"
  run_broker github mint --task t-refuse --repo acme/alpha --access
  expect_code 2 "$RC" "an option without its value is a usage error"
  assert_equals 0 "$(posts)" "argument refusals never request a token"
  assert_equals "" "$(cat "$LEDGER")" "argument refusals record nothing"
  pass "mint refuses unsafe or missing keys, malformed configuration, and malformed arguments before any request"
}

test_api_refusals_and_a_repository_mismatch() {
  new_case api
  printf '401\n' > "$GH_DIR/mode"
  run_broker github mint --task t-api --repo acme/alpha --access write --out "$CASE/out/a.token"
  [ "$RC" -ne 0 ] || fail "a 401 mint was accepted"
  assert_contains "$ERR" "GitHub refused an installation token for acme/alpha (HTTP 401: A JSON web token could not be decoded)" \
    "a 401 is refused with GitHub's reason"
  assert_absent "$CASE/out/a.token" "a 401 writes no token"
  assert_contains "$(ledger_line 1)" "mint-failed github task=t-api repo=acme/alpha access=write purpose=launch reason=http-401" \
    "a 401 is recorded"

  printf '422\n' > "$GH_DIR/mode"
  run_broker github mint --task t-api --repo acme/alpha --access write --out "$CASE/out/a.token"
  assert_contains "$ERR" "(HTTP 422: There is at least one repository" "a repository outside the installation is refused"
  assert_contains "$(ledger_line 2)" "reason=http-422" "a 422 is recorded"

  printf 'unreachable\n' > "$GH_DIR/mode"
  run_broker github mint --task t-api --repo acme/alpha --access write --out "$CASE/out/a.token"
  assert_contains "$ERR" "GitHub could not be reached to mint a token for acme/alpha" "a transport failure is named"
  assert_contains "$(ledger_line 3)" "reason=unreachable" "a transport failure is recorded"

  printf 'mismatch\n' > "$GH_DIR/mode"
  run_broker github mint --task t-api --repo acme/alpha --access write --out "$CASE/out/a.token"
  [ "$RC" -ne 0 ] || fail "a token for another repository was accepted"
  assert_contains "$ERR" "whose repositories are not exactly acme/alpha, so it was revoked" "a repository mismatch is refused"
  assert_absent "$CASE/out/a.token" "a mismatched token is never written"
  assert_equals "DELETE /installation/token 204" "$(tail -n 1 "$GH_DIR/calls.log")" "the mismatched token is revoked at once"
  assert_equals 1 "$(grep -c . "$GH_DIR/revoked")" "exactly the mismatched token is revoked"
  assert_contains "$(ledger_line 4)" "reason=repository" "a mismatch is recorded"
  assert_equals 0 "$(grep -c ' mint github ' "$LEDGER")" "no refused token is recorded as minted"
  assert_no_jwt_in_argv "refused mints"
  assert_no_token_anywhere "refused mints"
  pass "mint refuses a 401, a 422, an unreachable API, and a token for another repository, which it revokes"
}

# --- revoke -------------------------------------------------------------------------

test_revoke_kills_a_token_and_records_it() {
  local fp
  new_case revoke
  run_broker github mint --task t-rev --repo acme/alpha --access write --out "$CASE/out/r.token"
  expect_code 0 "$RC" "the mint should succeed"
  fp=$(fp_of "$CASE/out/r.token")
  run_broker github revoke --token-file "$CASE/out/r.token"
  expect_code 0 "$RC" "a revoke should succeed"$'\n'"$ERR"
  assert_equals "revoke=revoked"$'\n'"fp=$fp" "$OUT" "revoke reports the result and fingerprint"
  assert_equals "DELETE /installation/token 204" "$(tail -n 1 "$GH_DIR/calls.log")" "revoke deletes the installation token"
  [[ "$(ledger_line 2)" =~ ^[0-9]+\ revoke\ github\ task=t-rev\ fp=$fp\ result=revoked$ ]] \
    || fail "the revoke is not recorded against its mint: $(ledger_line 2)"

  run_broker github revoke --token-file "$CASE/out/r.token"
  expect_code 0 "$RC" "revoking a dead token is not a failure"
  assert_equals "revoke=invalid"$'\n'"fp=$fp" "$OUT" "a dead token reads invalid"
  assert_contains "$(ledger_line 3)" "result=invalid" "the second revoke is recorded"

  printf 'unreachable\n' > "$GH_DIR/mode"
  run_broker github mint --task t-rev --repo acme/alpha --access write --out "$CASE/out/r2.token"
  [ "$RC" -ne 0 ] || fail "an unreachable mint succeeded"
  rm -f "$GH_DIR/mode"
  run_broker github mint --task t-rev --repo acme/alpha --access write --out "$CASE/out/r2.token"
  printf 'unreachable-delete\n' > "$GH_DIR/mode"
  cat > "$FAKEBIN/curl-unreachable" <<'SH'
#!/usr/bin/env bash
exit 7
SH
  chmod +x "$FAKEBIN/curl-unreachable"
  mv "$FAKEBIN/curl" "$FAKEBIN/curl-api"
  mv "$FAKEBIN/curl-unreachable" "$FAKEBIN/curl"
  run_broker github revoke --token-file "$CASE/out/r2.token"
  mv "$FAKEBIN/curl" "$FAKEBIN/curl-unreachable"
  mv "$FAKEBIN/curl-api" "$FAKEBIN/curl"
  rm -f "$GH_DIR/mode"
  [ "$RC" -ne 0 ] || fail "an unconfirmed revoke reported success"
  assert_contains "$ERR" "GitHub did not confirm the revoke" "an unconfirmed revoke fails loudly"
  assert_contains "$(tail -n 1 "$LEDGER")" "result=failed" "an unconfirmed revoke is recorded as failed"

  chmod 644 "$CASE/out/r2.token"
  run_broker github revoke --token-file "$CASE/out/r2.token"
  assert_contains "$ERR" "is mode 644" "a readable token file is refused"
  chmod 600 "$CASE/out/r2.token"
  printf 'ghs_"quoted\n' > "$CASE/out/quoted.token"
  chmod 600 "$CASE/out/quoted.token"
  run_broker github revoke --token-file "$CASE/out/quoted.token"
  assert_contains "$ERR" "must hold one token on one line" "a token that could escape curl's config is refused"
  run_broker github revoke "$CASE/out/r2.token"
  expect_code 2 "$RC" "revoke needs --token-file"
  assert_no_jwt_in_argv "revokes"
  assert_no_token_anywhere "revokes"
  pass "revoke deletes a token, reads a dead one as invalid, fails an unconfirmed one, and refuses unsafe files"
}

test_record_revoke_validates_the_host_report() {
  new_case record
  run_broker github record-revoke --task t-host --fp 0123456789ab --result revoked
  expect_code 0 "$RC" "a well-formed host report should be recorded"
  [[ "$(ledger_line 1)" =~ ^[0-9]+\ revoke\ github\ task=t-host\ fp=0123456789ab\ result=revoked\ via=host$ ]] \
    || fail "the host's revoke is not recorded as reported: $(ledger_line 1)"
  run_broker github record-revoke --task t-host --fp 0123456789AB --result revoked
  assert_contains "$ERR" "--fp <12 hex digits>" "a malformed fingerprint is refused"
  run_broker github record-revoke --task t-host --fp 0123456789ab --result deleted
  assert_contains "$ERR" "--result revoked, invalid, expired, or failed" "an unknown result is refused"
  run_broker github record-revoke --task 'a b' --fp 0123456789ab --result revoked
  assert_contains "$ERR" "record-revoke needs --task <id>" "an unsafe task id is refused"
  assert_equals 1 "$(grep -c . "$LEDGER")" "refused reports record nothing"
  run_broker github
  expect_code 2 "$RC" "a bare github is a usage error"
  run_broker github sign --task t
  expect_code 2 "$RC" "an unknown verb is a usage error"
  run_broker cloudflare mint
  expect_code 2 "$RC" "only github credentials are brokered"
  pass "record-revoke records only an exact host report, and unknown verbs are usage errors"
}

# --- refresh -------------------------------------------------------------------------

# sandbox_task <id> [kind]: a sandbox task record here and its provisioned
# one-task home on a fixture host. Sets HOST_DIR, HOST_HOME, HOST_ACCOUNT, and HOST_TMP.
sandbox_task() {
  local id=$1 kind=${2:-ship}
  HOST_DIR="$CASE/host-$id"
  HOST_HOME="$HOST_DIR/fm-home"
  HOST_ACCOUNT="$HOST_DIR/account"
  HOST_TMP="$HOST_DIR/tmp"
  mkdir -p "$HOST_HOME/data" "$HOST_HOME/state" "$HOST_HOME/config" "$HOST_HOME/projects" "$HOST_ACCOUNT" "$HOST_TMP"
  chmod 700 "$HOST_HOME"
  printf 'schema=fm-task-home.v1\ntask_id=%s\nkind=%s\nproject=alpha\n' "$id" "$kind" > "$HOST_HOME/.fm-task-home"
  fm_write_meta "$HOME_DIR/state/$id.meta" "window=remote:$id" "endpoint_task_id=$id" "kind=$kind" \
    "project=$HOME_DIR/projects/alpha" "harness=pi" "placement=sandbox" "remote_kind=task" \
    "remote_host=alias-$id" "remote_root=$ROOT" "remote_home=$HOST_HOME" "sandbox_name=sbx-$id"
}

# launch_mint <id> <access> <expires-in>: the spawn's mint, with that token
# stored on the task's host as provisioning would.
launch_mint() {
  printf '%s\n' "$3" > "$GH_DIR/expires_in"
  run_broker github mint --task "$1" --repo acme/alpha --access "$2" --out "$CASE/out/$1.launch"
  expect_code 0 "$RC" "the launch mint for $1 should succeed"$'\n'"$ERR"
  mkdir -p "$HOST_ACCOUNT/.config/gh"
  cp "$CASE/out/$1.launch" "$HOST_ACCOUNT/.config/gh/hosts.yml"
  rm -f "$GH_DIR/expires_in"
}

refresh_due() { # [env assignments...]; one refresh-due pass
  OUT=$(env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" TMPDIR="$CASE/tmp" \
    FM_SSH_BIN="$FAKEBIN/fake-ssh" FM_FAKE_SSH_LOG="$CASE/ssh.log" FM_FAKE_HOST_BIN="$HOST_BIN" \
    FM_FAKE_HOST_ACCOUNT="$HOST_ACCOUNT" FM_FAKE_HOST_TMP="$HOST_TMP" "$@" \
    "$BROKER" github refresh-due 2>"$CASE/broker.err")
  RC=$?
  ERR=$(cat "$CASE/broker.err")
}

queued_keys() { awk -F '\t' '$3 == "check" { print $4 }' "$HOME_DIR/state/.wake-queue" 2>/dev/null; }

test_refresh_due_replaces_an_expiring_token_on_its_host() {
  local fp2 line
  new_case refresh
  sandbox_task t-ref
  launch_mint t-ref read 600
  refresh_due
  expect_code 0 "$RC" "refresh-due should succeed"$'\n'"$ERR"
  assert_equals "" "$OUT" "a successful refresh is silent"
  assert_equals 2 "$(posts)" "the expiring token was replaced once"
  assert_equals "$(jq -cS . "$GH_DIR/request.1.json")" "$(jq -cS . "$GH_DIR/request.2.json")" \
    "the refresh asks for the launch token's repository and access"
  minted_token 2 "$CASE/refreshed.token"
  cmp -s "$CASE/refreshed.token" "$HOST_ACCOUNT/.config/gh/hosts.yml" || fail "the host does not hold the refreshed token"
  assert_equals 600 "$(mode_of "$HOST_ACCOUNT/.config/gh/hosts.yml")" "the refreshed token is stored privately"
  fp2=$(fp_of "$CASE/refreshed.token")
  assert_contains "$(ledger_line 2)" "mint github task=t-ref repo=acme/alpha access=read expires=" "the refresh mint is recorded"
  assert_contains "$(ledger_line 2)" "fp=$fp2 purpose=refresh" "the refresh mint is marked as one"
  line=$(ledger_line 3)
  [[ "$line" =~ ^[0-9]+\ refresh\ github\ task=t-ref\ fp=$fp2\ expires=[0-9T:Z-]+\ result=delivered$ ]] \
    || fail "the delivery is not recorded: $line"
  assert_equals "alias-t-ref fm-remote-task-control.sh cred-refresh t-ref" "$(cat "$CASE/ssh.log")" \
    "the token is pushed to the task's own host verb"
  grep -q ' credential refresh gh_token=gh/github.com$' "$HOST_HOME/state/task-provision.journal" \
    || fail "the host journals the refresh"
  assert_equals 0 "$(deletes)" "a delivered token is never revoked"

  refresh_due
  assert_equals 2 "$(posts)" "a refreshed token is not refreshed again before it is due"
  pass "refresh-due mints a token of the same scope and delivers it to the host's cred-refresh"
  assert_no_token_anywhere "a refresh"
}

test_refresh_skips_fresh_locked_retired_and_unminted_tasks() {
  local fp
  new_case skip
  sandbox_task t-fresh
  launch_mint t-fresh write 3600
  sandbox_task t-plain
  sandbox_task t-locked
  launch_mint t-locked write 600
  mkdir -p "$HOME_DIR/state/.control-t-locked.lock"
  printf '%s\n' "$$" > "$HOME_DIR/state/.control-t-locked.lock/pid"
  sandbox_task t-spawning
  launch_mint t-spawning write 600
  mkdir -p "$HOME_DIR/state/.spawn-t-spawning.lock"
  printf '%s\n' "$$" > "$HOME_DIR/state/.spawn-t-spawning.lock/pid"
  sandbox_task t-retired
  launch_mint t-retired write 600
  fp=$(fp_of "$CASE/out/t-retired.launch")
  run_broker github record-revoke --task t-retired --fp "$fp" --result revoked
  refresh_due
  expect_code 0 "$RC" "refresh-due should succeed"$'\n'"$ERR"
  assert_equals "" "$OUT" "nothing due is silent"
  assert_equals 4 "$(posts)" "no task was refreshed: not due, locked, spawning, retired, or never minted"
  assert_absent "$CASE/ssh.log" "no host was contacted"
  rm -rf "$HOME_DIR/state/.control-t-locked.lock" "$HOME_DIR/state/.spawn-t-spawning.lock"
  refresh_due
  assert_equals 6 "$(posts)" "once their locks are released, the two due tasks are refreshed"
  assert_no_token_anywhere "skipped refreshes"
  pass "refresh-due leaves fresh, locked, spawning, retired, and unminted tasks alone"
}

test_refresh_failure_wakes_once_and_retries() {
  local fp1 out1
  new_case fail
  sandbox_task t-fail
  launch_mint t-fail write 600
  fp1=$(fp_of "$CASE/out/t-fail.launch")
  : > "$HOST_DIR/gh-fail"
  refresh_due
  expect_code 0 "$RC" "a failed refresh is reported, not an error"$'\n'"$ERR"
  out1=$OUT
  assert_contains "$OUT" "check: sandbox t-fail credential refresh failed: the sandbox host refused the new token (exit 1), so it was revoked; its current GitHub token expires at" \
    "the failure names the task, the reason, and the expiry"
  assert_equals 1 "$(printf '%s\n' "$OUT" | grep -c .)" "one failure prints one reason"
  assert_equals "cred-refresh-t-fail-$fp1" "$(queued_keys)" "one keyed check wake is queued for the current token"
  cmp -s "$CASE/out/t-fail.launch" "$HOST_ACCOUNT/.config/gh/hosts.yml" || fail "a refused refresh changed the host's token"
  assert_equals "DELETE /installation/token 204" "$(tail -n 1 "$GH_DIR/calls.log")" "the undelivered token is revoked"
  assert_contains "$(tail -n 2 "$LEDGER" | head -n 1)" "revoke github task=t-fail fp=" "the undelivered revoke is recorded"
  assert_contains "$(tail -n 2 "$LEDGER" | head -n 1)" "result=revoked reason=undelivered" "the revoke says why"
  assert_contains "$(tail -n 1 "$LEDGER")" "refresh github task=t-fail result=failed reason=refused alerted=yes fp=" \
    "the failure is recorded as alerted"

  refresh_due
  assert_equals 2 "$(posts)" "a failed refresh waits before retrying"
  assert_equals "" "$OUT" "the wait is silent"
  advance_clock 301
  refresh_due
  assert_equals 3 "$(posts)" "the refresh retries after its wait"
  assert_equals "" "$OUT" "a repeat failure for the same token is silent"
  assert_equals "cred-refresh-t-fail-$fp1" "$(queued_keys)" "a repeat failure queues no second wake"
  assert_contains "$(tail -n 1 "$LEDGER")" "result=failed reason=refused alerted=no" "the repeat is recorded without an alert"

  rm -f "$HOST_DIR/gh-fail"
  advance_clock 301
  refresh_due
  assert_equals "" "$OUT" "the recovered refresh is silent"
  assert_contains "$(tail -n 1 "$LEDGER")" "result=delivered" "the retry delivers the token"
  minted_token 4 "$CASE/recovered.token"
  cmp -s "$CASE/recovered.token" "$HOST_ACCOUNT/.config/gh/hosts.yml" || fail "the host does not hold the recovered token"
  OUT=$out1
  assert_no_token_anywhere "failed refreshes"
  pass "a failed refresh revokes its token, wakes once per current token, retries after a wait, and recovers"
}

test_unknown_delivery_keeps_the_token() {
  local fp1
  new_case unknown
  sandbox_task t-lost
  launch_mint t-lost write 600
  fp1=$(fp_of "$CASE/out/t-lost.launch")
  refresh_due FM_FAKE_SSH_MODE=unreachable
  expect_code 0 "$RC" "an unreachable host is reported, not an error"
  assert_contains "$OUT" "check: sandbox t-lost credential refresh failed: SSH exit 255: the sandbox host could not be reached" \
    "the unreachable host is named"
  assert_equals "cred-refresh-t-lost-$fp1" "$(queued_keys)" "the unreachable host queues the token's wake"
  assert_equals 0 "$(deletes)" "a token the host may hold is never revoked"
  assert_contains "$(tail -n 1 "$LEDGER")" "refresh github task=t-lost result=unknown reason=unreachable alerted=yes fp=" \
    "an unknown delivery is recorded as unknown"

  printf 'bad route\n' >> "$HOME_DIR/state/t-lost.meta"
  printf 'placement=sandbox\n' >> "$HOME_DIR/state/t-lost.meta"
  advance_clock 301
  refresh_due
  assert_equals 2 "$(posts)" "a record that no longer resolves to a sandbox route is never refreshed"
  assert_no_token_anywhere "an unknown delivery"
  pass "an unconfirmed delivery keeps its token, wakes once, and an unresolvable record is skipped"
}

test_failed_revoke_still_refreshes() {
  new_case failed-revoke-refresh
  sandbox_task t-revoke
  launch_mint t-revoke write 600
  mv "$FAKEBIN/curl" "$FAKEBIN/curl-api"
  printf '#!/usr/bin/env bash\nexit 7\n' > "$FAKEBIN/curl"
  chmod +x "$FAKEBIN/curl"
  run_broker github revoke --token-file "$CASE/out/t-revoke.launch"
  [ "$RC" -ne 0 ] || fail "the revoke should fail"
  mv "$FAKEBIN/curl-api" "$FAKEBIN/curl"
  refresh_due
  assert_equals 2 "$(posts)" "a failed revoke leaves the running task eligible for refresh"
  assert_contains "$(tail -n 1 "$LEDGER")" 'result=delivered' "the live token is refreshed"
}

test_refresh_budget_and_expiry_order() {
  new_case refresh-budget
  sandbox_task a-later
  launch_mint a-later write 800
  sandbox_task z-sooner
  launch_mint z-sooner write 200
  printf '80\n' > "$GH_DIR/delivery-elapsed"
  refresh_due FM_FAKE_SSH_MODE=unreachable
  assert_equals 3 "$(posts)" "the pass stops before another bounded attempt would exceed its budget"
  assert_contains "$(cat "$CASE/ssh.log")" 'cred-refresh z-sooner' "soonest expiry runs first"
  refresh_due FM_FAKE_SSH_MODE=unreachable
  assert_equals 4 "$(posts)" "the next pass reaches the remaining task during the earlier task's retry wait"
  assert_contains "$(tail -n 1 "$CASE/ssh.log")" 'cred-refresh a-later' "later tasks make progress"
}

test_interrupted_refresh_is_reported_once() {
  local pid rc fp
  new_case interrupted
  sandbox_task t-interrupted
  launch_mint t-interrupted write 600
  fp=$(fp_of "$CASE/out/t-interrupted.launch")
  mv "$FAKEBIN/curl" "$FAKEBIN/curl-api"
  cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
while [ ! -s "$FM_FAKE_GITHUB_DIR/broker-pid" ]; do sleep 0.01; done
kill -TERM "$(cat "$FM_FAKE_GITHUB_DIR/broker-pid")"
exit 7
SH
  chmod +x "$FAKEBIN/curl"
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" TMPDIR="$CASE/tmp" \
    "$BROKER" github refresh-due > "$CASE/interrupted.out" 2> "$CASE/interrupted.err" &
  pid=$!
  echo "$pid" > "$GH_DIR/broker-pid"
  wait "$pid"; rc=$?
  mv "$FAKEBIN/curl-api" "$FAKEBIN/curl"
  [ "$rc" -ne 0 ] || fail "interrupted broker reported success"
  assert_contains "$(tail -n 1 "$LEDGER")" 'reason=interrupted alerted=yes' "interruption is recorded and reported"
  assert_equals "cred-refresh-t-interrupted-$fp" "$(queued_keys)" "interruption queues one wake"
  assert_absent "$HOME_DIR/state/.control-t-interrupted.lock" "interruption releases the control lock"
  refresh_due
  assert_equals 1 "$(posts)" "an interrupted attempt observes the retry delay"
  assert_equals '' "$OUT" "the next pass does not repeat the wake"
}

test_mint_writes_a_private_token_and_a_valueless_ledger_line
test_write_access_requests_the_ship_set
test_refuses_unsafe_keys_and_malformed_input
test_api_refusals_and_a_repository_mismatch
test_revoke_kills_a_token_and_records_it
test_record_revoke_validates_the_host_report
test_refresh_due_replaces_an_expiring_token_on_its_host
test_refresh_skips_fresh_locked_retired_and_unminted_tasks
test_refresh_failure_wakes_once_and_retries
test_unknown_delivery_keeps_the_token
test_failed_revoke_still_refreshes
test_refresh_budget_and_expiry_order
test_interrupted_refresh_is_reported_once
echo "ALL TESTS PASSED"

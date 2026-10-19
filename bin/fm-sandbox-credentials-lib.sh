# shellcheck shell=bash
# shellcheck disable=SC2034 # Credential fields are output globals for sourcing callers.
# fm-sandbox-credentials-lib.sh - the config/sandbox-credentials reader: which
# credentials one sandbox task's provisioning manifest carries.
#
# Source this file and call:
#   fm_sandbox_credentials_select <file> <harness> <model-provider> <mode> <project> <origin>
#   fm_sandbox_credentials_manifest_fields <task-id>
#   fm_github_app_config_load <file>
#
# docs/configuration.md, "Sandbox credentials" and "GitHub App", owns both file
# formats and the selection rules; this header owns the mechanics. The files are
# local, gitignored, and captain-owned. An absent config/sandbox-credentials
# selects nothing.
#
# select checks every entry's structure and source-file safety, and checks
# credential values for matching entries only. <mode> is the
# ship's delivery mode, or scout for a scout; <model-provider> is the provider an
# explicit --model <provider>/<id> names, or empty; <origin> is the project's
# clone URL. It sets
# FM_SANDBOX_CREDENTIAL_GH_NAME and FM_SANDBOX_CREDENTIAL_GH_SOURCE for the one
# github entry selected, FM_SANDBOX_CREDENTIAL_PI_NAME,
# FM_SANDBOX_CREDENTIAL_PI_PROVIDER, and FM_SANDBOX_CREDENTIAL_PI_SOURCE for the
# one Pi entry selected, and FM_SANDBOX_CREDENTIAL_NAMES to the selected entry
# names, space-separated. It returns 1 with FM_SANDBOX_CREDENTIAL_ERROR set on
# any refusal.
#
# A github entry may name the literal source app instead of a file: its token is
# then a GitHub App installation token that bin/fm-cred-broker.sh mints for the
# task's one repository. Any app entry needs a valid config/github-app beside
# config/sandbox-credentials, checked even when the entry does not match. A
# selected app entry also needs an origin on github.com, whose owner/name it
# sets in FM_SANDBOX_CREDENTIAL_GH_REPO, with FM_SANDBOX_CREDENTIAL_GH_ACCESS set
# to read for a scout and write for a ship.
#
# manifest_fields prints the selected credentials as the gh_token_b64= and
# pi_auth_b64= lines of bin/fm-remote-task-control.sh's provisioning manifest,
# reading each source file at that moment, and returns 1 with
# FM_SANDBOX_CREDENTIAL_ERROR set when a file no longer holds a usable value.
# An app source is minted at that moment for <task-id> instead, and a mint
# failure (whose reason the broker prints on stderr) returns 1 the same way.
#
# fm_github_app_config_load reads config/github-app, checks its private key file
# as select checks a source file, and sets FM_GITHUB_APP_ID,
# FM_GITHUB_APP_INSTALLATION_ID, FM_GITHUB_APP_KEY, and FM_GITHUB_APP_WORKFLOWS
# (on or off), or returns 1 with FM_SANDBOX_CREDENTIAL_ERROR set.
#
# A credential value travels only through files, pipes, and this function's
# stdout: it is never placed in argv, the environment, or a message. Every
# refusal names entries, destinations, and paths, never a value.

FM_SANDBOX_CREDENTIALS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_SANDBOX_CREDENTIAL_ERROR=
FM_SANDBOX_CREDENTIAL_NAMES=
FM_SANDBOX_CREDENTIAL_GH_NAME=
FM_SANDBOX_CREDENTIAL_GH_SOURCE=
FM_SANDBOX_CREDENTIAL_GH_REPO=
FM_SANDBOX_CREDENTIAL_GH_ACCESS=
FM_SANDBOX_CREDENTIAL_PI_NAME=
FM_SANDBOX_CREDENTIAL_PI_PROVIDER=
FM_SANDBOX_CREDENTIAL_PI_SOURCE=
FM_GITHUB_APP_ID=
FM_GITHUB_APP_INSTALLATION_ID=
FM_GITHUB_APP_KEY=
FM_GITHUB_APP_WORKFLOWS=

fm_sandbox_credentials_reset() {
  FM_SANDBOX_CREDENTIAL_ERROR=
  FM_SANDBOX_CREDENTIAL_NAMES=
  FM_SANDBOX_CREDENTIAL_GH_NAME=
  FM_SANDBOX_CREDENTIAL_GH_SOURCE=
  FM_SANDBOX_CREDENTIAL_GH_REPO=
  FM_SANDBOX_CREDENTIAL_GH_ACCESS=
  FM_SANDBOX_CREDENTIAL_PI_NAME=
  FM_SANDBOX_CREDENTIAL_PI_PROVIDER=
  FM_SANDBOX_CREDENTIAL_PI_SOURCE=
}

fm_sandbox_credentials_refuse() { # <reason>
  FM_SANDBOX_CREDENTIAL_ERROR=$1
  return 1
}

fm_sandbox_credential_token_ok() { # <word>
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

# A source file is private to this account: a regular file, not a symlink,
# owned by the current user, with no group or other permission bits.
fm_sandbox_credential_source_ok() { # <entry-name> <path>
  fm_sandbox_credential_file_ok "credential $1's source" "$2"
}

fm_sandbox_credential_file_ok() { # <label> <path>
  local label=$1 path=$2 mode
  case "$path" in
    /*) ;;
    *) fm_sandbox_credentials_refuse "$label '$path' must be an absolute path"; return 1 ;;
  esac
  if [ -L "$path" ] || [ ! -f "$path" ]; then
    fm_sandbox_credentials_refuse "$label $path must be a regular file, not a symlink or a missing path"
    return 1
  fi
  [ -O "$path" ] || { fm_sandbox_credentials_refuse "$label $path must be owned by this account"; return 1; }
  [ -r "$path" ] || { fm_sandbox_credentials_refuse "$label $path is not readable"; return 1; }
  mode=$(stat -c %a "$path" 2>/dev/null || stat -f %Lp "$path" 2>/dev/null) \
    || { fm_sandbox_credentials_refuse "$label $path has an unreadable mode"; return 1; }
  case "$mode" in
    *00) ;;
    *) fm_sandbox_credentials_refuse "$label $path is mode $mode; it must not be readable or writable by group or others (use chmod 600)"; return 1 ;;
  esac
}

fm_github_app_config_load() { # <file>
  local file=$1 line lineno=0 key value seen=' ' first
  FM_GITHUB_APP_ID=
  FM_GITHUB_APP_INSTALLATION_ID=
  FM_GITHUB_APP_KEY=
  FM_GITHUB_APP_WORKFLOWS=off
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    fm_sandbox_credentials_refuse "the GitHub App configuration $file does not exist"
    return 1
  fi
  fm_sandbox_credential_file_ok "the GitHub App configuration" "$file" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in
      *=*) key=${line%%=*} value=${line#*=} ;;
      *) fm_sandbox_credentials_refuse "line $lineno of $file must be <key>=<value>"; return 1 ;;
    esac
    case "$key" in
      app_id|installation_id|private_key|workflows) ;;
      ''|*[!a-z_]*) fm_sandbox_credentials_refuse "line $lineno of $file has a malformed key"; return 1 ;;
      *) fm_sandbox_credentials_refuse "line $lineno of $file sets unknown key $key; accepted keys are app_id, installation_id, private_key, and workflows"; return 1 ;;
    esac
    case "$seen" in *" $key "*) fm_sandbox_credentials_refuse "$file sets $key more than once"; return 1 ;; esac
    seen="$seen$key "
    case "$key" in
      app_id|installation_id)
        case "$value" in
          ''|0*|*[!0-9]*) fm_sandbox_credentials_refuse "$file's $key must be a positive decimal number"; return 1 ;;
        esac
        ;;
      workflows)
        case "$value" in on|off) ;; *) fm_sandbox_credentials_refuse "$file's workflows must be on or off"; return 1 ;; esac
        ;;
    esac
    case "$key" in
      app_id) FM_GITHUB_APP_ID=$value ;;
      installation_id) FM_GITHUB_APP_INSTALLATION_ID=$value ;;
      private_key) FM_GITHUB_APP_KEY=$value ;;
      workflows) FM_GITHUB_APP_WORKFLOWS=$value ;;
    esac
  done < "$file"
  for key in app_id installation_id private_key; do
    case "$seen" in *" $key "*) ;; *) fm_sandbox_credentials_refuse "$file does not set $key"; return 1 ;; esac
  done
  fm_sandbox_credential_file_ok "$file's private_key" "$FM_GITHUB_APP_KEY" || return 1
  # Only the PEM boundary line is read, which identifies the file's kind.
  first=$(head -n 1 "$FM_GITHUB_APP_KEY" 2>/dev/null | tr -d '\r') || first=
  case "$first" in
    '-----BEGIN RSA PRIVATE KEY-----'|'-----BEGIN PRIVATE KEY-----') ;;
    *) fm_sandbox_credentials_refuse "$file's private_key $FM_GITHUB_APP_KEY is not a PEM RSA private key"; return 1 ;;
  esac
}

# The owner/name of a github.com clone URL; 1 for any other origin.
fm_sandbox_credential_github_repo() { # <origin>
  local path owner name
  case "$1" in
    https://github.com/*) path=${1#https://github.com/} ;;
    ssh://git@github.com/*) path=${1#ssh://git@github.com/} ;;
    git@github.com:*) path=${1#git@github.com:} ;;
    *) return 1 ;;
  esac
  path=${path%.git}
  case "$path" in */*/*|*/) return 1 ;; */*) ;; *) return 1 ;; esac
  owner=${path%%/*}
  name=${path#*/}
  case "$owner" in ''|-*|*[!A-Za-z0-9-]*) return 1 ;; esac
  case "$name" in ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;; esac
  printf '%s/%s\n' "$owner" "$name"
}

# A usable value is one line of printable ASCII without spaces, optionally
# ended by a single newline. The value itself is never read into a variable.
fm_sandbox_credential_value_ok() { # <path>
  local path=$1 bytes newlines last
  bytes=$(LC_ALL=C wc -c < "$path" | tr -d ' ') || return 1
  newlines=$(LC_ALL=C tr -cd '\n' < "$path" | LC_ALL=C wc -c | tr -d ' ') || return 1
  case "$newlines" in
    0) ;;
    1)
      last=$(tail -c 1 "$path" | od -An -tx1 | tr -d ' \n') || return 1
      [ "$last" = 0a ] || return 1
      ;;
    *) return 1 ;;
  esac
  [ "$bytes" -gt "$newlines" ] || return 1
  [ -z "$(LC_ALL=C tr -d '!-~\n' < "$path")" ]
}

fm_sandbox_credential_list_has() { # <comma-list> <value>
  case ",$1," in *",$2,"*) return 0 ;; esac
  return 1
}

fm_sandbox_credentials_select() { # <file> <harness> <model-provider> <mode> <project> <origin>
  local file=$1 harness=$2 provider=$3 mode=$4 project=$5 origin=${6-}
  local line lineno=0 name destination source cond key value actual seen_names=' ' seen_keys matches
  local app_checked=0 repo='' app_config
  local -a fields
  fm_sandbox_credentials_reset
  app_config="$(dirname "$file")/github-app"
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    return 0
  fi
  if [ -L "$file" ] || [ ! -f "$file" ] || [ ! -r "$file" ]; then
    fm_sandbox_credentials_refuse "$file must be a readable regular file"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    case "$line" in ''|'#'*) continue ;; esac
    read -r -a fields <<< "$line"
    [ "${#fields[@]}" -gt 0 ] || continue
    case "${fields[0]}" in '#'*) continue ;; esac
    if [ "${#fields[@]}" -lt 3 ]; then
      fm_sandbox_credentials_refuse "line $lineno of $file must be '<name> <destination> <source> [<condition>...]'"
      return 1
    fi
    name=${fields[0]} destination=${fields[1]} source=${fields[2]}
    fm_sandbox_credential_token_ok "$name" \
      || { fm_sandbox_credentials_refuse "line $lineno of $file names credential '$name'; a name uses only letters, digits, '.', '_', and '-'"; return 1; }
    case "$seen_names" in *" $name "*) fm_sandbox_credentials_refuse "credential $name appears twice in $file"; return 1 ;; esac
    seen_names="$seen_names$name "
    case "$destination" in
      github) ;;
      pi:*)
        fm_sandbox_credential_token_ok "${destination#pi:}" \
          || { fm_sandbox_credentials_refuse "credential $name names Pi provider '${destination#pi:}'; a provider uses only letters, digits, '.', '_', and '-'"; return 1; }
        ;;
      *)
        fm_sandbox_credentials_refuse "credential $name has destination '$destination'; a sandbox takes only github and pi:<provider> credentials, and no Claude credential is sent to a sandbox until the real-host smoke test proves one"
        return 1
        ;;
    esac
    if [ "$source" = app ]; then
      [ "$destination" = github ] \
        || { fm_sandbox_credentials_refuse "credential $name names the app source, which only a github credential may use"; return 1; }
      if [ "$app_checked" -eq 0 ]; then
        if ! fm_github_app_config_load "$app_config"; then
          FM_SANDBOX_CREDENTIAL_ERROR="credential $name names the app source, but $FM_SANDBOX_CREDENTIAL_ERROR"
          return 1
        fi
        app_checked=1
      fi
    else
      fm_sandbox_credential_source_ok "$name" "$source" || return 1
    fi
    matches=1
    seen_keys=' '
    for cond in "${fields[@]:3}"; do
      case "$cond" in
        *=*) key=${cond%%=*} value=${cond#*=} ;;
        *) fm_sandbox_credentials_refuse "credential $name has condition '$cond'; a condition is <key>=<value>[,<value>...]"; return 1 ;;
      esac
      case "$key" in
        harness|provider|mode|project) ;;
        *) fm_sandbox_credentials_refuse "credential $name has unknown condition '$key'; accepted conditions are harness, provider, mode, and project"; return 1 ;;
      esac
      case "$seen_keys" in *" $key "*) fm_sandbox_credentials_refuse "credential $name repeats condition $key"; return 1 ;; esac
      seen_keys="$seen_keys$key "
      case "$value" in ''|,*|*,|*,,*|*[!A-Za-z0-9._,-]*)
        fm_sandbox_credentials_refuse "credential $name has malformed $key values '$value'"
        return 1
        ;;
      esac
      case "$key" in
        harness) actual=$harness ;;
        provider) actual=$provider ;;
        mode) actual=$mode ;;
        project) actual=$project ;;
      esac
      if [ -z "$actual" ] || ! fm_sandbox_credential_list_has "$value" "$actual"; then
        matches=0
      fi
    done
    if [ "$destination" != github ]; then
      # A Pi entry is needed only by a Pi worker whose model names its provider.
      case "$harness" in pi|pi-signed) ;; *) matches=0 ;; esac
      [ "${destination#pi:}" = "$provider" ] || matches=0
    fi
    [ "$matches" -eq 1 ] || continue
    if [ "$source" = app ]; then
      repo=$(fm_sandbox_credential_github_repo "$origin") \
        || { fm_sandbox_credentials_refuse "credential $name mints a GitHub App token for the task's repository, but project $project's origin is not a github.com repository"; return 1; }
    else
      fm_sandbox_credential_value_ok "$source" \
        || { fm_sandbox_credentials_refuse "credential $name's source $source must hold one line of printable ASCII without spaces"; return 1; }
    fi
    if [ "$destination" = github ]; then
      [ -z "$FM_SANDBOX_CREDENTIAL_GH_NAME" ] \
        || { fm_sandbox_credentials_refuse "credentials $FM_SANDBOX_CREDENTIAL_GH_NAME and $name both supply the GitHub token for this task; narrow their conditions so exactly one matches"; return 1; }
      FM_SANDBOX_CREDENTIAL_GH_NAME=$name
      FM_SANDBOX_CREDENTIAL_GH_SOURCE=$source
      if [ "$source" = app ]; then
        FM_SANDBOX_CREDENTIAL_GH_REPO=$repo
        if [ "$mode" = scout ]; then FM_SANDBOX_CREDENTIAL_GH_ACCESS='read'; else FM_SANDBOX_CREDENTIAL_GH_ACCESS='write'; fi
      fi
    else
      [ -z "$FM_SANDBOX_CREDENTIAL_PI_NAME" ] \
        || { fm_sandbox_credentials_refuse "credentials $FM_SANDBOX_CREDENTIAL_PI_NAME and $name both supply Pi provider $provider for this task; narrow their conditions so exactly one matches"; return 1; }
      command -v jq >/dev/null 2>&1 \
        || { fm_sandbox_credentials_refuse "jq is required to encode credential $name's Pi entry"; return 1; }
      FM_SANDBOX_CREDENTIAL_PI_NAME=$name
      FM_SANDBOX_CREDENTIAL_PI_PROVIDER=${destination#pi:}
      FM_SANDBOX_CREDENTIAL_PI_SOURCE=$source
    fi
    FM_SANDBOX_CREDENTIAL_NAMES="${FM_SANDBOX_CREDENTIAL_NAMES:+$FM_SANDBOX_CREDENTIAL_NAMES }$name"
  done < "$file"
  return 0
}

fm_sandbox_credentials_manifest_fields() { # <task-id>
  local task=${1-} gh='' pi=''
  if [ -n "$FM_SANDBOX_CREDENTIAL_GH_NAME" ] && [ "$FM_SANDBOX_CREDENTIAL_GH_SOURCE" != app ]; then
    fm_sandbox_credential_value_ok "$FM_SANDBOX_CREDENTIAL_GH_SOURCE" \
      || { fm_sandbox_credentials_refuse "credential $FM_SANDBOX_CREDENTIAL_GH_NAME's source no longer holds a usable value"; return 1; }
    gh=$(LC_ALL=C tr -d '\n' < "$FM_SANDBOX_CREDENTIAL_GH_SOURCE" | base64 | tr -d '\n')
    [ -n "$gh" ] \
      || { fm_sandbox_credentials_refuse "credential $FM_SANDBOX_CREDENTIAL_GH_NAME could not be encoded"; return 1; }
  fi
  if [ -n "$FM_SANDBOX_CREDENTIAL_PI_NAME" ]; then
    fm_sandbox_credential_value_ok "$FM_SANDBOX_CREDENTIAL_PI_SOURCE" \
      || { fm_sandbox_credentials_refuse "credential $FM_SANDBOX_CREDENTIAL_PI_NAME's source no longer holds a usable value"; return 1; }
    # jq reads the key from stdin, so it never appears in an argument; its own
    # diagnostics could quote input, so they are discarded.
    pi=$(LC_ALL=C tr -d '\n' < "$FM_SANDBOX_CREDENTIAL_PI_SOURCE" \
      | jq -cRs --arg provider "$FM_SANDBOX_CREDENTIAL_PI_PROVIDER" '{($provider): {type: "api_key", key: .}}' 2>/dev/null \
      | base64 | tr -d '\n')
    [ -n "$pi" ] \
      || { fm_sandbox_credentials_refuse "credential $FM_SANDBOX_CREDENTIAL_PI_NAME could not be encoded"; return 1; }
  fi
  # A minted token comes last, so no later refusal here can strand it.
  if [ "$FM_SANDBOX_CREDENTIAL_GH_SOURCE" = app ]; then
    case "$task" in ''|.|..|*[!A-Za-z0-9._-]*) fm_sandbox_credentials_refuse "an app credential is minted for one task, and none was named"; return 1 ;; esac
    gh=$("$FM_SANDBOX_CREDENTIALS_LIB_DIR/fm-cred-broker.sh" github mint --task "$task" \
        --repo "$FM_SANDBOX_CREDENTIAL_GH_REPO" --access "$FM_SANDBOX_CREDENTIAL_GH_ACCESS" \
        | LC_ALL=C tr -d '\n' | base64 | tr -d '\n'
      exit "${PIPESTATUS[0]}") \
      || { fm_sandbox_credentials_refuse "credential $FM_SANDBOX_CREDENTIAL_GH_NAME could not mint a GitHub App token for $FM_SANDBOX_CREDENTIAL_GH_REPO"; return 1; }
    [ -n "$gh" ] \
      || { fm_sandbox_credentials_refuse "credential $FM_SANDBOX_CREDENTIAL_GH_NAME minted an empty GitHub App token"; return 1; }
  fi
  [ -z "$gh" ] || printf 'gh_token_b64=%s\n' "$gh"
  [ -z "$pi" ] || printf 'pi_auth_b64=%s\n' "$pi"
  return 0
}

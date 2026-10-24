#!/usr/bin/env bash
# fm-opencode2-lib.sh - OpenCode 2.x worker-adapter helpers: 2.x binary
# selection, platform provider discovery, the per-task isolated config
# directory, and the launch-config JSON fragments that make every worker model
# request go through the governed platform.
# Usage: . bin/fm-opencode2-lib.sh
# The opencode2 adapter is verified for primary-harness supervision end to end
# on 2.1.4 (2026-10-23, docs/verification/supervision.md "OpenCode 2.x primary
# plugin supervision"), so crewmates, scouts, and secondmates may run on it
# (.agents/skills/harness-adapters/references/harness/opencode.md owns the
# operating facts; AGENTS.md section 4 owns the verified list). Every helper
# here fails closed: a binary that cannot be proven to be 2.x, a platform
# whose providers cannot be discovered, or an isolated config directory that
# cannot be written refuses the spawn rather than launching a worker that
# could use any other provider or the operator's own OpenCode setup.
# Selection never depends on PATH order: OpenCode 1.x and 2.x are separate
# packages that both install an `opencode` command, so which one a bare
# `opencode` resolves to is a property of the caller's PATH, not of the
# install. Every candidate is therefore gated on the
# binary's own `--version` answer, which 2.x prefixes with "opencode v2."
# and 1.x prints bare.

fm_opencode2_version_is_2() {  # <first-version-line>
  case "$1" in
  'opencode v2.'*) return 0 ;;
  *) return 1 ;;
  esac
}

fm_opencode2_candidate_is_2() {  # <path>
  local out
  [ -n "$1" ] || return 1
  [ -x "$1" ] || return 1
  out=$(timeout 30 "$1" --version 2>/dev/null | head -n1) || return 1
  fm_opencode2_version_is_2 "$out"
}

# fm_opencode2_resolve_binary: print the concrete OpenCode 2.x
# executable. The unambiguous 2.x command name `opencode2` (1.x installs no such name) is
# resolved on PATH, then the concrete per-user install paths, every candidate
# gated on a live --version check.
fm_opencode2_resolve_binary() {
  local bin home=${HOME:-/root}
  home=$(printf '%s' "$home" | head -n1)
  bin=$(command -v opencode2 2>/dev/null) || bin=
  if [ -n "$bin" ] && fm_opencode2_candidate_is_2 "$bin"; then
    printf '%s\n' "$bin"
    return 0
  fi
  for bin in "$home/.local/bin/opencode2" "$home/.local/bin/opencode"; do
    if fm_opencode2_candidate_is_2 "$bin"; then
      printf '%s\n' "$bin"
      return 0
    fi
  done
  echo "error: no OpenCode 2.x executable found (tried opencode2 on PATH, ~/.local/bin/opencode2, ~/.local/bin/opencode, each verified through --version); install OpenCode 2.x (@opencode/cli)" >&2
  return 1
}

# fm_opencode2_platform_providers <binary> <origin>: print the provider ids
# whose configured baseURL routes through the platform origin, one per line.
# Discovery reads `<binary> debug config`, whose output redacts secrets, and
# keeps exactly the providers defined in pathless org documents with a
# settings.baseURL under the origin, so a provider is allowed only when its
# traffic provably goes through the platform; anything else (including every
# provider backed by the operator's personal credentials) stays denied.
fm_opencode2_platform_providers() {
  local binary=$1 origin=$2 out rc
  command -v python3 >/dev/null 2>&1 || {
    echo "error: opencode2 platform discovery needs python3 to read '$binary debug config'" >&2
    return 1
  }
  out=$(OPENCODE_DISABLE_AUTOUPDATE=1 timeout 90 "$binary" debug config 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ] || {
    echo "error: could not read '$binary debug config' to discover the platform providers (exit $rc); is the OpenCode 2.x install working?" >&2
    return 1
  }
  if ! out=$(printf '%s\n' "$out" | python3 -c '
import json, sys

origin = sys.argv[1]
docs = json.load(sys.stdin)
allow = []
for doc in docs:
    if not isinstance(doc, dict) or doc.get("type") != "document":
        continue
    if doc.get("path"):
        continue
    providers = (doc.get("info") or {}).get("providers") or {}
    if not isinstance(providers, dict):
        continue
    for pid, p in providers.items():
        if not isinstance(p, dict):
            continue
        base = ((p.get("settings") or {}).get("baseURL") or "")
        if isinstance(base, str) and base.startswith(origin + "/") and pid not in allow:
            allow.append(pid)
print("\n".join(sorted(allow)))
' "$origin"); then
    echo "error: could not parse '$binary debug config' output as JSON to discover the platform providers" >&2
    return 1
  fi
  printf '%s\n' "$out"
}

# fm_opencode2_id_ok <id>: provider and model ids are embedded inside the
# launch's single-quoted OPENCODE_CONFIG_CONTENT JSON, so a quote or other
# shell-breaking byte must refuse the launch instead of breaking the quoting.
fm_opencode2_id_ok() {
  case "$1" in
  '' | *[!a-zA-Z0-9._/:+-]*)
    echo "error: opencode2 provider/model ids must be plain [a-zA-Z0-9._/:+-], got '$1'" >&2
    return 1
    ;;
  esac
  return 0
}

# fm_opencode2_policies_json <provider...>: print the ,"policies":[...] JSON
# fragment that denies provider.use for every provider and allows exactly the
# named platform providers. OpenCode evaluates policies with findLast, so the
# trailing per-provider allow entries override the leading blanket deny.
fm_opencode2_policies_json() {
  local p out=',"policies":[{"action":"provider.use","resource":"*","effect":"deny"}'
  for p in "$@"; do
    fm_opencode2_id_ok "$p" || return 1
    out="$out,{\"action\":\"provider.use\",\"resource\":\"$p\",\"effect\":\"allow\"}"
  done
  printf '%s' "$out]"
}

# fm_opencode2_model_json <model> <provider...>: print the ,"model":"..." JSON
# fragment selecting the worker's default model, or refuse when the model's
# provider is not one of the discovered platform providers: a worker model
# outside the platform would either fail at launch or, worse, resolve through
# a provider the blanket deny is meant to keep away.
fm_opencode2_model_json() {
  local model=$1 prov p
  shift
  fm_opencode2_id_ok "$model" || return 1
  prov=${model%%/*}
  for p in "$@"; do
    [ "$p" = "$prov" ] && {
      printf ',"model":"%s"' "$model"
      return 0
    }
  done
  echo "error: opencode2 model '$model' does not name one of the platform providers ($*); every worker model request must go through the platform" >&2
  return 1
}

# fm_opencode2_isolate_config_dir <dir>: create the launch's per-task
# OPENCODE_CONFIG_DIR, holding only OpenCode's own service setting with the
# shared background server turned off. The directory replaces the operator's
# global config dir for every OpenCode process in the worker's environment,
# and 2.x reads service.json from it, so the commands that would otherwise
# attach to the operator's background server - which answers from the
# operator's own config and ignores the launch's policies - start a private
# server inheriting the launch environment instead (the adapter reference's
# "Server isolation" and "Config isolation" rows own those facts). The file is
# written directly because `opencode service set disabled true` first stops
# the running background server, which belongs to the operator.
fm_opencode2_isolate_config_dir() {  # <dir>
  local dir=$1
  mkdir -p "$dir" || {
    echo "error: could not create the isolated opencode config directory $dir" >&2
    return 1
  }
  printf '%s\n' '{"disabled":true}' >"$dir/service.json" || {
    echo "error: could not turn the shared OpenCode background server off in $dir" >&2
    return 1
  }
}

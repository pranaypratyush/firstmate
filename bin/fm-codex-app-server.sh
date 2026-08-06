#!/usr/bin/env bash
# Own the managed Codex App Server lifecycle boundary used by Firstmate.
#
# Usage:
#   fm-codex-app-server.sh ensure
#   fm-codex-app-server.sh inspect
#
# `ensure` invokes only Codex's idempotent managed-daemon start operation.
# `inspect` invokes only its read-only version operation.
# Both parse the lifecycle JSON, validate the returned absolute Unix socket as
# a non-symlink socket owned by this uid with exact mode 0600, and emit one
# normalized JSON object whose endpoint is unix:// plus that absolute path.
# No caller learns Codex-home layout or control-socket conventions.
# This helper never scans processes or sockets and never stops or restarts the
# shared daemon.
set -u

usage() {
  sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//; $d'
}

die() {
  printf 'fm-codex-app-server: %s\n' "$*" >&2
  exit 1
}

socket_uid() {
  if [ "$(uname 2>/dev/null)" = Darwin ]; then
    stat -f %u "$1" 2>/dev/null
  else
    stat -c %u "$1" 2>/dev/null
  fi
}

socket_mode() {
  if [ "$(uname 2>/dev/null)" = Darwin ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

validate_lifecycle() {  # <operation> <json>
  local operation=$1 json=$2 status backend pid socket_path owner mode uid endpoint
  local cli_version app_server_version managed_codex_version
  printf '%s' "$json" | jq -e 'type == "object"' >/dev/null 2>&1 \
    || die "Codex returned malformed lifecycle JSON for daemon $operation"

  status=$(printf '%s' "$json" | jq -er '.status | select(type == "string")' 2>/dev/null) \
    || die "Codex lifecycle JSON omitted a string status for daemon $operation"
  case "$operation:$status" in
    ensure:started|ensure:alreadyRunning|inspect:running) ;;
    ensure:*) die "Codex daemon start returned unsupported lifecycle status '$status'" ;;
    inspect:notRunning) die "managed Codex App Server is not running; run '$0 ensure' first" ;;
    inspect:*) die "Codex daemon inspection returned unsupported lifecycle status '$status'" ;;
  esac

  backend=$(printf '%s' "$json" | jq -er '.backend | select(type == "string")' 2>/dev/null) \
    || die "Codex lifecycle JSON omitted its managed backend"
  [ "$backend" = pid ] \
    || die "Codex lifecycle backend '$backend' is not the managed pid backend"
  pid=$(printf '%s' "$json" | jq -er '.pid | select(type == "number" and floor == . and . > 0)' 2>/dev/null) \
    || die "Codex lifecycle JSON omitted a positive managed pid"

  cli_version=$(printf '%s' "$json" | jq -er '.cliVersion | select(type == "string" and length > 0)' 2>/dev/null) \
    || die "Codex lifecycle JSON omitted cliVersion"
  app_server_version=$(printf '%s' "$json" | jq -er '.appServerVersion | select(type == "string" and length > 0)' 2>/dev/null) \
    || die "Codex lifecycle JSON omitted appServerVersion"
  managed_codex_version=$(printf '%s' "$json" | jq -er '.managedCodexVersion | select(type == "string" and length > 0)' 2>/dev/null) \
    || die "Codex lifecycle JSON omitted managedCodexVersion"
  [ "$cli_version" = "$app_server_version" ] && [ "$app_server_version" = "$managed_codex_version" ] \
    || die "Codex lifecycle versions disagree (cli=$cli_version, app-server=$app_server_version, managed=$managed_codex_version); update the managed standalone through the current-session bootstrap/consent path"

  socket_path=$(printf '%s' "$json" | jq -er '.socketPath | select(type == "string" and length > 0)' 2>/dev/null) \
    || die "Codex lifecycle JSON omitted socketPath"
  case "$socket_path" in
    /*) ;;
    *) die "Codex lifecycle socketPath is not absolute: $socket_path" ;;
  esac
  case "$socket_path" in
    *$'\n'*|*$'\r'*) die "Codex lifecycle socketPath contains a line break" ;;
  esac
  [ ! -L "$socket_path" ] || die "Codex lifecycle socketPath is a symlink: $socket_path"
  [ -S "$socket_path" ] || die "Codex lifecycle socketPath is not a Unix socket: $socket_path"
  uid=$(id -u) || die "could not read the current uid"
  owner=$(socket_uid "$socket_path") || die "could not read socket ownership: $socket_path"
  [ "$owner" = "$uid" ] \
    || die "Codex lifecycle socket is owned by uid $owner, expected $uid: $socket_path"
  mode=$(socket_mode "$socket_path") || die "could not read socket permissions: $socket_path"
  mode=${mode#0}
  [ "$mode" = 600 ] \
    || die "Codex lifecycle socket mode is $mode, expected private mode 600: $socket_path"

  endpoint="unix://$socket_path"
  printf '%s' "$json" | jq -c \
    --arg endpoint "$endpoint" \
    --arg socket_path "$socket_path" \
    --argjson pid "$pid" \
    --arg cli_version "$cli_version" \
    --arg app_server_version "$app_server_version" \
    --arg managed_codex_version "$managed_codex_version" '
      {
        status: .status,
        backend: .backend,
        pid: $pid,
        socket_path: $socket_path,
        endpoint: $endpoint,
        cli_version: $cli_version,
        app_server_version: $app_server_version,
        managed_codex_version: $managed_codex_version
      }
    ' || die "could not normalize Codex lifecycle JSON"
}

[ "$#" -eq 1 ] || { usage >&2; exit 2; }
command -v codex >/dev/null 2>&1 || die "the 'codex' CLI is not installed"
command -v jq >/dev/null 2>&1 || die "'jq' is required to parse Codex lifecycle JSON"

operation=$1
case "$operation" in
  ensure)
    lifecycle=$(codex app-server daemon start 2>&1)
    status=$?
    if [ "$status" -ne 0 ]; then
      printf '%s\n' "$lifecycle" >&2
      die "managed standalone Codex is unavailable or could not start; install it only through the current-session bootstrap/consent path, then retry (nothing was installed, stopped, or restarted by Firstmate)"
    fi
    validate_lifecycle ensure "$lifecycle"
    ;;
  inspect)
    lifecycle=$(codex app-server daemon version 2>&1)
    status=$?
    if [ "$status" -ne 0 ]; then
      printf '%s\n' "$lifecycle" >&2
      die "managed Codex App Server inspection failed; run '$0 ensure' after its standalone installation is approved"
    fi
    validate_lifecycle inspect "$lifecycle"
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

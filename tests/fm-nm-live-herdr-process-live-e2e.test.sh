#!/usr/bin/env bash
# Opt-in live drift guard for the managed Codex lifecycle response and the
# Herdr process-info shape used to recognize one exact remote companion.
#
# This is not the mandatory multi-client acceptance smoke: the caller supplies
# an already-created disposable thread, and this guard neither creates a Codex
# thread nor invokes no-mistakes. It inspects (never starts) the managed shared
# App Server before provisioning its isolated named Herdr lab.
set -u

if [ "${FM_NM_LIVE_HERDR_PROCESS_E2E:-0}" != 1 ]; then
  echo "skip: set FM_NM_LIVE_HERDR_PROCESS_E2E=1 with FM_NM_LIVE_SMOKE_THREAD_ID to run the managed Codex/Herdr process drift guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
APP_SERVER_HELPER="$ROOT/bin/fm-codex-app-server.sh"
LIVE_HELPER="$ROOT/bin/fm-nm-live.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || fail "herdr not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"
thread=${FM_NM_LIVE_SMOKE_THREAD_ID:-}
[[ $thread =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
  || fail "FM_NM_LIVE_SMOKE_THREAD_ID must name one disposable canonical Codex thread UUID"

lifecycle=$($APP_SERVER_HELPER inspect) \
  || fail "managed Codex App Server read-only inspection failed; do not install or start it from this guard"
endpoint=$(printf '%s' "$lifecycle" | jq -er '.endpoint') \
  || fail "managed Codex lifecycle normalization omitted its endpoint"
codex_version=$(printf '%s' "$lifecycle" | jq -er '.managed_codex_version') \
  || fail "managed Codex lifecycle normalization omitted its version"

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-nm-live-proc) || fail "could not generate the isolated Herdr lab name"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-live-process.XXXXXX") || fail "could not create private smoke cwd"
cleanup() {
  original_status=$?
  trap - EXIT INT TERM
  teardown_status=0
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >/dev/null || teardown_status=$?
  rm -rf "$scratch"
  if [ "$teardown_status" -ne 0 ]; then
    printf 'not ok - isolated Herdr teardown or default-session fleet tripwire failed\n' >&2
    exit 1
  fi
  exit "$original_status"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail "could not provision the isolated named Herdr lab"
herdr_status=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" status --json) \
  || fail "could not read the isolated Herdr client/server versions"
herdr_client_version=$(printf '%s' "$herdr_status" | jq -er '.client.version') \
  || fail "Herdr status omitted its client version"
herdr_server_version=$(printf '%s' "$herdr_status" | jq -er '.server.version') \
  || fail "Herdr status omitted its server version"
created=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace create --cwd "$scratch" --label nm-live-process-guard --focus) \
  || fail "could not create the isolated focus anchor"
workspace=$(printf '%s' "$created" | jq -er '.result.workspace.workspace_id') \
  || fail "Herdr workspace create omitted its exact workspace id"
focus_before=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace list | jq -er '
  [.result.workspaces[] | select(.focused == true)]
  | select(length == 1) | .[0] | [.workspace_id, .active_tab_id] | @tsv
') || fail "could not capture exact focus before companion creation"

companion=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" tab create --workspace "$workspace" --cwd "$scratch" --label 'VIEW ONLY no-mistakes process guard' --no-focus) \
  || fail "could not create the unfocused companion tab"
pane=$(printf '%s' "$companion" | jq -er '.result.root_pane.pane_id') \
  || fail "Herdr tab create omitted its exact root pane id"
focus_after=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace list | jq -er '
  [.result.workspaces[] | select(.focused == true)]
  | select(length == 1) | .[0] | [.workspace_id, .active_tab_id] | @tsv
') || fail "could not capture exact focus after companion creation"
[ "$focus_after" = "$focus_before" ] || fail "unfocused companion creation changed exact Herdr focus"

command=$(FM_HOME="$scratch" "$LIVE_HELPER" render-command "$endpoint" "$thread") \
  || fail "managed Codex $codex_version command rendering failed"
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane run "$pane" "$command" >/dev/null \
  || fail "could not launch the exact remote resume command in the returned pane"

matched=0
attempt=0
while [ "$attempt" -lt 100 ]; do
  info=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane process-info --pane "$pane" 2>/dev/null || true)
  if printf '%s' "$info" | FM_HOME="$scratch" "$LIVE_HELPER" classify-process-info "$pane" "$endpoint" "$thread"; then
    matched=1
    break
  fi
  sleep 0.1
  attempt=$((attempt + 1))
done
[ "$matched" = 1 ] \
  || fail "Herdr process-info did not expose the exact Codex endpoint/thread argv identity (managed Codex $codex_version; Herdr client $herdr_client_version, server $herdr_server_version)"

pass "managed Codex $codex_version lifecycle inspect and exact endpoint/thread Herdr process identity (client $herdr_client_version, server $herdr_server_version)"

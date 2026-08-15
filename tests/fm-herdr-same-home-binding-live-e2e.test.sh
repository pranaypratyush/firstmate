#!/usr/bin/env bash
# tests/fm-herdr-same-home-binding-live-e2e.test.sh - opt-in, read-only drift
# guard for the Herdr fields that bind a same-home successor to one exact pane
# and shell incarnation.
#
# The portable counterpart, tests/fm-backend-herdr.test.sh, pins the parser and
# rejection behavior with scripted Herdr replies.
# This guard reads an operator-supplied existing pane only.
# It never starts, restores, sends input to, or stops a Herdr session or pane.
#
# Run after a Herdr upgrade and refresh docs/verification/runtime-backends.md:
# FM_HERDR_SAME_HOME_BINDING_LIVE=1 FM_HERDR_SAME_HOME_BINDING_TARGET='<session>:<pane>' FM_HERDR_SAME_HOME_BINDING_HOME='<absolute-home>' bin/fm-test-run.sh tests/fm-herdr-same-home-binding-live-e2e.test.sh
set -u

if [ "${FM_HERDR_SAME_HOME_BINDING_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_HERDR_SAME_HOME_BINDING_LIVE=1 to run the read-only Herdr same-home binding guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

for tool in herdr jq; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "skip: $tool not found, so the Herdr same-home binding is unverified"
    exit 0
  }
done

target=${FM_HERDR_SAME_HOME_BINDING_TARGET:-}
home=${FM_HERDR_SAME_HOME_BINDING_HOME:-${FM_HOME:-}}
[ -n "$target" ] || fail "FM_HERDR_SAME_HOME_BINDING_TARGET must name an existing <session>:<pane>"
[ -n "$home" ] || fail "FM_HERDR_SAME_HOME_BINDING_HOME or FM_HOME must name the owning home"
home_real=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P) || fail "same-home binding home cannot be resolved: $home"

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$ROOT/bin/fm-supervisor-target-lib.sh"

version=$(herdr --version 2>/dev/null | head -1) || fail "Herdr did not report its version"
status=$(herdr status --json 2>/dev/null) || fail "Herdr did not report current client/server protocol state"
client_protocol=$(printf '%s' "$status" | jq -er '.client.protocol | select(type == "number")' 2>/dev/null) || fail "Herdr status did not contain a numeric client protocol"
server_protocol=$(printf '%s' "$status" | jq -er '.server.protocol | select(type == "number")' 2>/dev/null) || fail "Herdr status did not contain a numeric server protocol"

binding=$(fm_supervisor_target_same_home_binding herdr "$target" "$home_real") || fail "same-home binding refused $target for $home_real"
pane=${target#*:}
case "$binding" in
  "herdr:$pane":*[1-9]* ) ;;
  *) fail "same-home binding returned an invalid pane/incarnation binding: $binding" ;;
esac

pass "same-home Herdr binding reads one exact existing pane and its shell incarnation"
printf 'evidence: herdr=%s client_protocol=%s server_protocol=%s binding=%s read_only=true\n' "$version" "$client_protocol" "$server_protocol" "$binding"

#!/usr/bin/env bash
# Real named-session Herdr regression for fm-send's approval-prefix-shaped
# explicit-home interface.
#
# The test records one exact Herdr pane in task metadata, leaves a different
# pane armed with a decoy command, and invokes fm-send with the executable as
# the command prefix:
#
#   bin/fm-send.sh --home <home> <task> --key Enter
#
# Every test-owned Herdr operation, including adapter calls made by fm-send,
# routes through fm-herdr-lab.sh with its generated non-default session.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-send-herdr-approval) \
  || fail "could not generate the isolated Herdr lab session name"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-send-herdr-approval.XXXXXX")
HOME_DIR="$TMP_ROOT/home"
FAKEBIN="$TMP_ROOT/fakebin"
TARGET_RESULT="$TMP_ROOT/target-ran"
DECOY_RESULT="$TMP_ROOT/decoy-ran"
ORIGINAL_PATH=$PATH

cleanup() {
  local status=$?
  trap - EXIT
  PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  rm -rf "$TMP_ROOT"
  exit "$status"
}
trap cleanup EXIT

"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not provision the isolated Herdr lab session"

mkdir -p "$HOME_DIR/state" "$FAKEBIN"

# The production adapter adds its own validated trailing --session pair.
# Strip only that exact pair, then let the lab helper append the same session
# itself so the helper remains the owner of every real Herdr call.
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -euo pipefail
helper='$HERDR_LAB_HELPER'
session='$HERDR_LAB_SESSION'
real_path='$ORIGINAL_PATH'
args=("\$@")
n=\${#args[@]}
if [ "\$n" -lt 2 ] || [ "\${args[\$((n-2))]}" != --session ] || [ "\${args[\$((n-1))]}" != "\$session" ]; then
  echo "wrapper requires the exact trailing isolated session" >&2
  exit 97
fi
args=("\${args[@]:0:\$((n-2))}")
PATH="\$real_path" exec "\$helper" run "\$session" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

TARGET_CREATE=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace create \
  --cwd "$TMP_ROOT" --label fm-send-target --no-focus) \
  || fail "could not create the recorded target workspace"
TARGET_PANE=$(printf '%s' "$TARGET_CREATE" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$TARGET_PANE" ] || fail "target workspace did not return a root pane"

DECOY_CREATE=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace create \
  --cwd "$TMP_ROOT" --label fm-send-decoy --no-focus) \
  || fail "could not create the decoy workspace"
DECOY_PANE=$(printf '%s' "$DECOY_CREATE" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$DECOY_PANE" ] || fail "decoy workspace did not return a root pane"
[ "$TARGET_PANE" != "$DECOY_PANE" ] || fail "target and decoy unexpectedly share one pane"

printf -v target_command 'touch %q' "$TARGET_RESULT"
printf -v decoy_command 'touch %q' "$DECOY_RESULT"
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-text "$TARGET_PANE" "$target_command" >/dev/null \
  || fail "could not arm the recorded target pane"
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-text "$DECOY_PANE" "$decoy_command" >/dev/null \
  || fail "could not arm the decoy pane"

ID=approval-target
fm_write_meta "$HOME_DIR/state/$ID.meta" \
  "window=$HERDR_LAB_SESSION:$TARGET_PANE" \
  "backend=herdr" \
  "herdr_session=$HERDR_LAB_SESSION" \
  "herdr_pane_id=$TARGET_PANE" \
  "kind=ship"

unset FM_HOME
FM_ROOT_OVERRIDE=$HOME_DIR
export FM_GATE_REFUSE_BYPASS=1 FM_SEND_SETTLE=0 FM_ROOT_OVERRIDE
PATH="$FAKEBIN:$ORIGINAL_PATH"
export PATH

# Keep the executable itself at the command prefix. This is the regression:
# there is no leading FM_HOME assignment for an approval matcher to miss.
SEND_ERR="$TMP_ROOT/send.err"
if ! "$ROOT/bin/fm-send.sh" --home "$HOME_DIR" "$ID" --key Enter 2>"$SEND_ERR"; then
  fail "approval-prefix-shaped fm-send invocation failed"$'\n'"$(cat "$SEND_ERR")"
fi

attempt=0
while [ ! -e "$TARGET_RESULT" ] && [ "$attempt" -lt 50 ]; do
  sleep 0.1
  attempt=$((attempt + 1))
done
[ -e "$TARGET_RESULT" ] || fail "the recorded Herdr pane did not execute its armed command"
[ ! -e "$DECOY_RESULT" ] || fail "fm-send submitted the decoy pane instead of the recorded endpoint"

pass "real Herdr: bin/fm-send.sh --home reaches the exact recorded named-session endpoint"

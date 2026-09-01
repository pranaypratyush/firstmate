#!/usr/bin/env bash
# Opt-in real OMP/Herdr ordinary endpoint recovery in a named isolated lab.
set -u

if [ "${FM_OMP_ORDINARY_RECOVER_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_OMP_ORDINARY_RECOVER_LIVE_E2E=1 to run the named Herdr lab recovery smoke"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v omp >/dev/null 2>&1 || fail "omp not found"
command -v herdr >/dev/null 2>&1 || fail "herdr not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"
command -v treehouse >/dev/null 2>&1 || fail "treehouse not found"

RECOVER="$ROOT/bin/fm-omp-ordinary-recover.sh"
HERDR_REAL=$(command -v herdr)
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$HERDR_LAB_HELPER" ] || fail "Herdr lab helper is not executable: $HERDR_LAB_HELPER"
"$ROOT/bin/fm-omp-capabilities.sh" --print-binary >/dev/null || fail "OMP capability check failed"

LAB=$(fm_test_tmproot fm-omp-ordinary-recover-live)
SESSION=$("$HERDR_LAB_HELPER" name fm-omp-ordinary-recovery-entrypoint)
HOME_DIR="$LAB/home"
PROJECT="$LAB/project"
REMOTE="$LAB/project-origin.git"
WRAPPER_BIN="$LAB/bin"
TASK_ID="omp-ordinary-recover-${RANDOM:-0}-$$"
TASK_META="$HOME_DIR/state/$TASK_ID.meta"
WORKTREE=
LAB_TORN_DOWN=0

cleanup() {
  local cleanup_ok=1
  if [ "${FM_OMP_ORDINARY_RECOVER_KEEP_FAILED:-0}" = 1 ] && [ "$LAB_TORN_DOWN" -ne 1 ]; then
    echo "diagnostic: preserving failed named recovery lab $SESSION at $LAB" >&2
    return
  fi
  if [ -n "$WORKTREE" ] && [ -d "$WORKTREE" ]; then
    if [ -z "$(git -C "$WORKTREE" status --porcelain 2>/dev/null)" ] \
      && [ "$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null || true)" = "$(git -C "$PROJECT" rev-parse HEAD 2>/dev/null || true)" ]; then
      (cd "$PROJECT" && treehouse return "$WORKTREE") >/dev/null 2>&1 || cleanup_ok=0
    else
      cleanup_ok=0
    fi
  fi
  if [ "$LAB_TORN_DOWN" -ne 1 ]; then
    "$HERDR_LAB_HELPER" teardown "$SESSION" >/dev/null 2>&1 || cleanup_ok=0
  fi
  if [ "$cleanup_ok" -eq 1 ]; then
    rm -rf "$LAB"
  else
    echo "not ok - named recovery lab cleanup was incomplete; preserving $LAB" >&2
    trap - EXIT
    exit 1
  fi
}
trap cleanup EXIT

mkdir -p "$HOME_DIR/data/$TASK_ID" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects" "$WRAPPER_BIN" "$PROJECT"
cat > "$WRAPPER_BIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
real=$(printf %q "$HERDR_REAL")
helper=$(printf %q "$HERDR_LAB_HELPER")
session=$(printf %q "$SESSION")
if [ "\${FM_HERDR_LAB_INNER:-0}" = 1 ]; then
  exec "\$real" "\$@"
fi
args=("\$@")
if [ "\${args[0]:-}" = --session ] && [ "\${args[1]:-}" = "\$session" ]; then
  args=("\${args[@]:2}")
fi
argc=\${#args[@]}
if [ "\$argc" -ge 2 ] && [ "\${args[\$((argc - 2))]}" = --session ] && [ "\${args[\$((argc - 1))]}" = "\$session" ]; then
  args=("\${args[@]:0:\$((argc - 2))}")
fi
exec env FM_HERDR_LAB_INNER=1 "\$helper" run "\$session" "\${args[@]}"
EOF
chmod +x "$WRAPPER_BIN/herdr"

printf 'herdr\n' > "$HOME_DIR/config/backend"
printf 'omp\n' > "$HOME_DIR/config/crew-harness"
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
printf 'Reply exactly: retained OMP session is ready.\n' > "$HOME_DIR/data/$TASK_ID/brief.md"
printf 'fixture\n' > "$PROJECT/README.md"
git init -q -b main "$PROJECT"
fm_git_identity fmtest fmtest@example.invalid
git -C "$PROJECT" add README.md
git -C "$PROJECT" commit -qm init
git init -q --bare "$REMOTE"
git -C "$PROJECT" remote add origin "$REMOTE"
git -C "$PROJECT" push -qu origin main
git -C "$REMOTE" symbolic-ref HEAD refs/heads/main

"$HERDR_LAB_HELPER" provision "$SESSION" || fail "could not provision named Herdr recovery lab"
env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
  PATH="$WRAPPER_BIN:$PATH" HERDR_SESSION="$SESSION" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-spawn.sh" "$TASK_ID" "$PROJECT" --harness omp --model openai-codex/gpt-5.6-luna \
  --effort low --mode direct-PR --yolo off >/dev/null || fail "could not create retained OMP fixture session"

for _ in $(seq 1 240); do
  [ -f "$TASK_META" ] && [ -f "$HOME_DIR/state/$TASK_ID.omp-ready" ] \
    && [ -f "$HOME_DIR/state/$TASK_ID.omp-doorbell-ready" ] && break
  sleep 0.25
done
[ -f "$TASK_META" ] || fail "fixture spawn did not publish task metadata"
[ -f "$HOME_DIR/state/$TASK_ID.omp-ready" ] || fail "fixture OMP session did not publish readiness"
[ -f "$HOME_DIR/state/$TASK_ID.omp-doorbell-ready" ] || fail "fixture OMP session did not publish a doorbell marker"
WORKTREE=$(sed -n 's/^worktree=//p' "$TASK_META")
OLD_TARGET=$(sed -n 's/^window=//p' "$TASK_META")
OLD_PANE=${OLD_TARGET#*:}
OLD_TAB=$(sed -n 's/^herdr_tab_id=//p' "$TASK_META")
OLD_WORKSPACE=$(sed -n 's/^herdr_workspace_id=//p' "$TASK_META")
OLD_READY_INODE=$(stat -c %i "$HOME_DIR/state/$TASK_ID.omp-ready")
OLD_DOORBELL_PID=$(cat "$HOME_DIR/state/$TASK_ID.omp-doorbell-ready")
TASK_TMP=$(sed -n 's/^tasktmp=//p' "$TASK_META")
for _ in $(seq 1 80); do
  shopt -s nullglob
  SESSION_FILES=("$TASK_TMP"/omp-sessions/*.jsonl)
  shopt -u nullglob
  [ "${#SESSION_FILES[@]}" = 1 ] && break
  sleep 0.25
done
[ "${#SESSION_FILES[@]}" = 1 ] || fail "fixture did not retain one direct-child OMP session file"
SESSION_FILE=${SESSION_FILES[0]}
mkdir -p "$HOME_DIR/state/$TASK_ID.inbox/handled"
printf 'schema=fm-task-inbox.v1\nat=live-recovery\n--\ncontinue the retained task\n' > "$HOME_DIR/state/$TASK_ID.inbox/001.msg"
SESSION_BYTES_BEFORE=$(wc -c < "$SESSION_FILE")

"$HERDR_LAB_HELPER" run "$SESSION" tab create --workspace "$OLD_WORKSPACE" --cwd "$WORKTREE" \
  --label recovery-keeper --no-focus >/dev/null \
  || fail "could not retain the recovery workspace while removing the recorded endpoint"

"$HERDR_LAB_HELPER" run "$SESSION" pane close "$OLD_PANE" >/dev/null \
  || fail "could not make the recorded endpoint authoritatively missing"
env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
  PATH="$WRAPPER_BIN:$PATH" HERDR_SESSION="$SESSION" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  FM_OMP_ORDINARY_RECOVER_READY_POLLS=240 FM_OMP_ORDINARY_RECOVER_READY_INTERVAL=0.25 \
  "$RECOVER" "$TASK_ID" >/dev/null || fail "ordinary OMP recovery command failed in named Herdr lab"

NEW_TARGET=$(sed -n 's/^window=//p' "$TASK_META")
NEW_PANE=${NEW_TARGET#*:}
NEW_TAB=$(sed -n 's/^herdr_tab_id=//p' "$TASK_META")
[ "$NEW_TARGET" != "$OLD_TARGET" ] || fail "recovery did not replace the missing endpoint"
[ "$NEW_TAB" != "$OLD_TAB" ] || fail "recovery did not publish a response-derived replacement tab"
[ "$(stat -c %i "$HOME_DIR/state/$TASK_ID.omp-ready")" != "$OLD_READY_INODE" ] \
  || fail "recovery reused rather than freshly publishing OMP readiness"
[ "$(cat "$HOME_DIR/state/$TASK_ID.omp-doorbell-ready")" != "$OLD_DOORBELL_PID" ] \
  || fail "recovery reused the historical OMP doorbell owner"
"$HERDR_LAB_HELPER" run "$SESSION" pane get "$NEW_PANE" | jq -e --arg pane "$NEW_PANE" --arg tab "$NEW_TAB" \
  '.result.pane.pane_id == $pane and .result.pane.tab_id == $tab' >/dev/null \
  || fail "published replacement endpoint did not match the named-lab pane"
for _ in $(seq 1 80); do
  [ "$(wc -c < "$SESSION_FILE")" -gt "$SESSION_BYTES_BEFORE" ] && break
  sleep 0.25
done
[ "$(wc -c < "$SESSION_FILE")" -gt "$SESSION_BYTES_BEFORE" ] \
  || fail "recovery did not hand off the existing durable inbox to the resumed session"

"$HERDR_LAB_HELPER" run "$SESSION" pane close "$NEW_PANE" >/dev/null || fail "could not close named-lab replacement endpoint"
LAB_TORN_DOWN=1
"$HERDR_LAB_HELPER" teardown "$SESSION" >/dev/null || fail "could not tear down named Herdr recovery lab"
pass "named Herdr lab recovery resumed the retained OMP session with fresh markers, atomic endpoint publication, and inbox handoff"

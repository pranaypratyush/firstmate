#!/usr/bin/env bash
# Narrow ordinary-worker OMP recovery through the real spawn entrypoint.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tmux >/dev/null 2>&1 || fail "tmux is required for the recovery fixture"
command -v bun >/dev/null 2>&1 || fail "bun is required for the recovery fixture"

LAB=$(fm_test_tmproot fm-spawn-recovery)
REAL_TMUX=$(command -v tmux)
REAL_BUN=$(command -v bun)
SOCKET="fm-spawn-recovery-$$"
HOME_DIR="$LAB/home"
PROJECT="$LAB/project"
WORKTREE="$LAB/worktree"
ORIGIN="$LAB/origin.git"
WRAPPER_BIN="$LAB/bin"
ID="recovery-worker-$$"
TARGET="firstmate:fm-$ID"
TASK_TMP="/tmp/fm-$ID"
TASK_TMP_OWNED=0

cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  [ "$TASK_TMP_OWNED" -eq 0 ] || rm -rf "$TASK_TMP"
  if [ -d "$WORKTREE" ] && [ -z "$(git -C "$WORKTREE" status --porcelain 2>/dev/null || true)" ]; then
    git -C "$PROJECT" worktree remove "$WORKTREE" >/dev/null 2>&1 || true
  fi
  fm_test_cleanup
}
trap cleanup EXIT

mkdir -p "$HOME_DIR/data/$ID" "$HOME_DIR/state" "$HOME_DIR/config" \
  "$HOME_DIR/projects" "$WRAPPER_BIN" "$PROJECT"
printf '%s\n' "$$" > "$HOME_DIR/state/.lock"
printf 'Recovery fixture: acknowledge the first turn.\n' > "$HOME_DIR/data/$ID/brief.md"
printf 'fixture\n' > "$PROJECT/README.md"
git init -q -b main "$PROJECT"
git -C "$PROJECT" -c user.name='Recovery Fixture' -c user.email=recovery@example.invalid \
  add README.md
git -C "$PROJECT" -c user.name='Recovery Fixture' -c user.email=recovery@example.invalid \
  commit -qm initial
git init -q --bare "$ORIGIN"
git -C "$PROJECT" remote add origin "$ORIGIN"
git -C "$PROJECT" push -q -u origin main
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git -C "$PROJECT" remote set-head origin main
git -C "$PROJECT" worktree add -q --detach "$WORKTREE"

[ ! -e "$TASK_TMP" ] && [ ! -L "$TASK_TMP" ] \
  || fail "recovery fixture task root already exists: $TASK_TMP"
TASK_TMP_OWNED=1

cat > "$WRAPPER_BIN/tmux" <<SH
#!/usr/bin/env bash
exec '$REAL_TMUX' -L '$SOCKET' "\$@"
SH
cat > "$WRAPPER_BIN/treehouse" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  get)
    shift
    holder=
    while [ "\$#" -gt 0 ]; do
      case "\$1" in
        --lease-holder) shift; holder=\${1:-} ;;
        --lease-holder=*) holder=\${1#--lease-holder=} ;;
      esac
      shift
    done
    [ "\$holder" = "fm-$ID" ] || exit 1
    (
      cd '$WORKTREE' || exit 1
      git reset --hard HEAD >/dev/null && git clean -fd >/dev/null
    ) || exit \$?
    printf '%s\n' '$WORKTREE'
    ;;
  status)
    [ "\${2:-}" = --json ] || exit 1
    if [ -f '$LAB/no-lease' ]; then
      printf '[{"path":"%s","status":"available","lease_holder":null,"lease_id":null}]\n' '$WORKTREE'
    else
      printf '[{"path":"%s","status":"leased","lease_holder":"fm-$ID","lease_id":"fixture-lease"}]\n' '$WORKTREE'
    fi
    ;;
  return) exit 0 ;;
  *) exit 1 ;;
esac
SH
ln -s /bin/bash "$WRAPPER_BIN/bun"
cat > "$WRAPPER_BIN/ack-extension.ts" <<'TS'
import { pathToFileURL } from "node:url";

const [extension, sessionFile] = process.argv.slice(2);
const handlers = new Map<string, (...args: any[]) => any>();
const omp = {
  on(event: string, handler: (...args: any[]) => any) {
    handlers.set(event, handler);
  },
};
const module = await import(`${pathToFileURL(extension).href}?fixture=${process.pid}`);
module.default(omp);
await handlers.get("session_start")?.({}, {
  sessionManager: { getSessionFile: () => sessionFile },
});
await new Promise((resolve) => setTimeout(resolve, 50));
await handlers.get("turn_start")?.();
TS
cat > "$WRAPPER_BIN/omp" <<SH
#!/usr/bin/env bun
case "\${1:-}" in
  --help)
    printf '%s\n' '--model= --thinking= --auto-approve --session-dir= --extension= --resume= --max-time='
    exit 0
    ;;
esac
session_dir=
resume=
extension=
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --session-dir) session_dir=\${2:-}; shift 2 ;;
    --session-dir=*) session_dir=\${1#*=}; shift ;;
    -e|--extension) extension=\${2:-}; shift 2 ;;
    --extension=*) extension=\${1#*=}; shift ;;
    -r|--resume) resume=\${2:-}; shift 2 ;;
    --resume=*) resume=\${1#*=}; shift ;;
    *) shift ;;
  esac
done
[ -n "\$session_dir" ] && [ -n "\$extension" ] || exit 2
mkdir -p "\$session_dir"
session_file="\$session_dir/selected.jsonl"
if [ -n "\$resume" ]; then
  [ "\$resume" = "\$session_file" ] && [ -f "\$resume" ] || exit 3
else
  printf '{"type":"session","version":3}\n' > "\$session_file"
fi
printf 'resume=%s\tsession=%s\textension=%s\n' "\$resume" "\$session_file" "\$extension" >> '$LAB/launches'
[ ! -f '$LAB/skip-ack' ] || while :; do sleep 1; done
'$REAL_BUN' '$WRAPPER_BIN/ack-extension.ts' "\$extension" "\$session_file" || exit 4
while :; do sleep 1; done
SH
chmod +x "$WRAPPER_BIN/tmux" "$WRAPPER_BIN/treehouse" "$WRAPPER_BIN/omp"

FIXTURE_PATH="$WRAPPER_BIN:$PATH"
PATH="$FIXTURE_PATH" tmux new-session -d -s firstmate -n fixture -c "$PROJECT"
PATH="$FIXTURE_PATH" tmux set-option -g default-shell /bin/bash
PATH="$FIXTURE_PATH" tmux set-option -g default-command "env PATH='$FIXTURE_PATH' bash --noprofile --norc"

spawn() {
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_BACKEND=tmux FM_SPAWN_NO_GUARD=1 \
    FM_OMP_LAUNCH_ACK_INTERVAL=0.05 OMP_SKIP_SETUP=1 PATH="$FIXTURE_PATH" \
    "$ROOT/bin/fm-spawn.sh" "$@"
}

agent_state() {
  PATH="$FIXTURE_PATH" bash -c \
    '. "$1/bin/fm-backend.sh"; fm_backend_agent_state tmux "$2" "$3"' \
    _ "$ROOT" "$TARGET" "$HOME_DIR/state/$ID.meta"
}

wait_for_state() {
  local want=$1 i=0 state
  while [ "$i" -lt 80 ]; do
    state=$(agent_state)
    [ "$state" = "$want" ] && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

kill_worker() {
  PATH="$FIXTURE_PATH" tmux kill-window -t "$TARGET"
  wait_for_state missing || fail "fixture endpoint did not become missing"
}

hash_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

spawn "$ID" "$PROJECT" --scout --harness omp --model fixture-model --effort low >/dev/null \
  || fail "initial OMP worker spawn failed"
META="$HOME_DIR/state/$ID.meta"
SESSION_DIR="$HOME_DIR/state/$ID.omp-sessions"
SESSION_POINTER="$HOME_DIR/state/$ID.omp-session"
SESSION_FILE="$SESSION_DIR/selected.jsonl"
wait_for_state alive || fail "initial OMP worker was not live"
[ -d "$SESSION_DIR" ] && [ ! -L "$SESSION_DIR" ] \
  || fail "fresh OMP worker did not use a durable regular session directory"
[ "$(cat "$SESSION_POINTER")" = "$SESSION_FILE" ] \
  || fail "fresh OMP worker did not publish its exact durable session pointer"
[ -f "$HOME_DIR/state/$ID.omp-started" ] \
  || fail "fresh OMP worker did not acknowledge turn_start"
assert_contains "$(cat "$LAB/launches")" "$(printf 'resume=\tsession=%s' "$SESSION_FILE")" \
  "fresh OMP launch unexpectedly resumed another session"
pass "fresh ordinary OMP workers publish durable session identity"

kill_worker
printf 'preserved uncommitted work\n' > "$WORKTREE/.recovery-preserved"
printf 'signal: preserved event\n' > "$HOME_DIR/state/$ID.status"
cp "$META" "$LAB/meta.before"
cp "$SESSION_FILE" "$LAB/session.before"
cp "$HOME_DIR/state/$ID.status" "$LAB/status.before"

out=$(spawn "$ID" --recover 2>&1) || fail "guarded OMP recovery failed: $out"
assert_contains "$out" "recovered $ID harness=omp" "recovery did not report success"
wait_for_state alive || fail "recovered OMP worker was not live"
cmp -s "$SESSION_FILE" "$LAB/session.before" || fail "recovery changed the retained OMP session"
cmp -s "$HOME_DIR/state/$ID.status" "$LAB/status.before" || fail "recovery rewrote preserved status history"
[ "$(cat "$SESSION_POINTER")" = "$SESSION_FILE" ] || fail "recovery changed the selected session"
assert_contains "$(tail -n 1 "$LAB/launches")" "resume=$SESSION_FILE" \
  "recovery did not pass the exact retained session to --resume"
assert_contains "$(cat "$META")" 'endpoint_generation=' \
  "recovery did not atomically distinguish the replacement endpoint generation"
for artifact in "$HOME_DIR/state/$ID.omp-replacement.meta" "$HOME_DIR/state/$ID.omp-replacement.base" \
  "$HOME_DIR/state/$ID.omp-replacement-ext.ts" "$HOME_DIR/state/$ID.omp-replacement-started"; do
  assert_absent "$artifact" "successful recovery retained replacement sidecar $artifact"
done
pass "missing OMP endpoint resumes exact session before metadata publication"

meta_hash=$(hash_file "$META")
out=$(spawn "$ID" --recover 2>&1)
status=$?
[ "$status" -ne 0 ] || fail "recovery accepted a live endpoint"
assert_contains "$out" 'requires an authoritatively missing endpoint' \
  "live-endpoint refusal did not state the ownership boundary"
[ "$(hash_file "$META")" = "$meta_hash" ] || fail "live-endpoint refusal changed metadata"
pass "live endpoints are refused before replacement creation"

kill_worker
rm -f "$SESSION_POINTER"
out=$(spawn "$ID" --recover 2>&1)
status=$?
[ "$status" -ne 0 ] || fail "recovery accepted a missing durable pointer"
wait_for_state missing || fail "missing-pointer refusal created an endpoint"
printf '%s\n' "$SESSION_FILE" > "$SESSION_POINTER"
mkdir -p "$TASK_TMP/omp-sessions"
rm -f "$SESSION_POINTER"
out=$(spawn "$ID" --recover 2>&1)
status=$?
[ "$status" -ne 0 ] || fail "recovery migrated a legacy temporary binding"
assert_contains "$out" 'legacy OMP session binding' \
  "legacy temporary binding refusal was not actionable"
printf '%s\n' "$SESSION_FILE" > "$SESSION_POINTER"
rm -rf "$TASK_TMP/omp-sessions"
pass "missing and legacy temporary session bindings are refused"

touch "$LAB/no-lease"
out=$(spawn "$ID" --recover 2>&1)
status=$?
[ "$status" -ne 0 ] || fail "recovery accepted an unleased worktree"
assert_contains "$out" 'exact leased isolated worktree' \
  "worktree preselection refusal did not name its invariant"
wait_for_state missing || fail "worktree preselection refusal created an endpoint"
rm -f "$LAB/no-lease"
pass "recovery revalidates worktree ownership before launch"

cp "$META" "$LAB/meta.before"
cp "$SESSION_FILE" "$LAB/session.before"
touch "$LAB/skip-ack"
out=$(FM_OMP_LAUNCH_ACK_POLLS=2 spawn "$ID" --recover 2>&1)
status=$?
[ "$status" -ne 0 ] || fail "recovery accepted a replacement without turn_start"
assert_contains "$out" 'not acknowledged by a turn_start event' \
  "unacknowledged replacement failure was not actionable"
wait_for_state missing || fail "unacknowledged recovery retained its replacement endpoint"
cmp -s "$META" "$LAB/meta.before" || fail "unacknowledged recovery published replacement metadata"
cmp -s "$SESSION_FILE" "$LAB/session.before" || fail "unacknowledged recovery changed the retained session"
[ ! -e "$HOME_DIR/state/$ID.omp-replacement.meta" ] \
  || fail "unacknowledged recovery retained its candidate metadata: $out"
rm -f "$LAB/skip-ack"
pass "failed recovery cleans only its exact replacement endpoint"

PATH="$FIXTURE_PATH" tmux new-window -d -t firstmate -n "fm-$ID" -c "$WORKTREE" \
  "FM_OMP_SESSION_POINTER='$SESSION_POINTER' '$WRAPPER_BIN/bun' '$WRAPPER_BIN/omp' --session-dir '$SESSION_DIR' --resume '$SESSION_FILE' -e '$HOME_DIR/state/$ID.omp-ext.ts'"
wait_for_state alive || fail "interrupted replacement fixture was not live"
awk -v generation="interrupted-$$" '
  /^endpoint_generation=/ { if (!seen++) print "endpoint_generation=" generation; next }
  { print }
  END { if (!seen) print "endpoint_generation=" generation }
' "$META" > "$HOME_DIR/state/$ID.omp-replacement.meta"
hash_file "$META" > "$HOME_DIR/state/$ID.omp-replacement.base"
touch "$HOME_DIR/state/$ID.omp-replacement-started"
out=$(spawn "$ID" --recover 2>&1) || fail "interrupted recovery reconciliation failed: $out"
assert_contains "$out" "recovered $ID harness=omp" \
  "interrupted recovery did not report reconciled success"
assert_contains "$(cat "$META")" "endpoint_generation=interrupted-$$" \
  "interrupted recovery did not publish its acknowledged candidate"
assert_absent "$HOME_DIR/state/$ID.omp-replacement.meta" \
  "interrupted recovery retained candidate metadata after reconciliation"
pass "acknowledged interrupted replacement publishes on guarded retry"

kill_worker
cp "$META" "$LAB/tmux.meta"
awk -v id="$ID" '
  /^window=/ { print "window=gone-herdr:w9:p9"; next }
  /^endpoint_task_id=/ { found_binding=1; print "endpoint_task_id=" id; next }
  /^backend=/ { next }
  /^endpoint_generation=/ { next }
  { print }
  END {
    if (!found_binding) print "endpoint_task_id=" id
    print "backend=herdr"
    print "herdr_session=gone-herdr"
    print "herdr_workspace_id=w9"
    print "herdr_tab_id=w9:t9"
    print "herdr_pane_id=w9:p9"
  }
' "$LAB/tmux.meta" > "$META"
out=$(spawn "$ID" --recover 2>&1)
status=$?
[ "$status" -ne 0 ] || fail "recovery accepted an unreadable Herdr server"
assert_contains "$out" 'server-gone recovery is not supported' \
  "unreadable Herdr inventory refusal did not narrow the supported claim"
pass "Herdr recovery requires its recorded server inventory"

pass "ordinary OMP recovery preserves task state and publishes only acknowledged replacements"

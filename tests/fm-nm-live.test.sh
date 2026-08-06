#!/usr/bin/env bash
# Deterministic executable-interface coverage for the no-mistakes live Codex
# companion, using fake Codex, no-mistakes, and Herdr command surfaces.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

APP_HELPER="$ROOT/bin/fm-codex-app-server.sh"
LIVE="$ROOT/bin/fm-nm-live.sh"
SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-nm-live)
SOCKET_PIDS=()

cleanup() {
  local pid
  for pid in "${SOCKET_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
  fm_test_cleanup
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

start_socket() {  # <path>
  local socket=$1
  python3 - "$socket" <<'PY' &
import os
import signal
import socket
import sys
import time

path = sys.argv[1]
try:
    os.unlink(path)
except FileNotFoundError:
    pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path)
os.chmod(path, 0o600)
s.listen(1)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
while True:
    time.sleep(1)
PY
  SOCKET_PID=$!
  SOCKET_PIDS+=("$SOCKET_PID")
  i=0
  while [ ! -S "$socket" ] && [ "$i" -lt 50 ]; do sleep 0.02; i=$((i + 1)); done
  [ -S "$socket" ] || fail "could not create test Unix socket"
}

make_codex_fake() {  # <fakebin>
  cat > "$1/codex" <<'SH'
#!/usr/bin/env bash
printf 'codex %s\n' "$*" >> "$FM_CODEX_LOG"
case "$*" in
  "app-server daemon start")
    [ "${FM_CODEX_FAIL:-0}" = 0 ] || { printf 'managed standalone Codex install not found\n' >&2; exit 7; }
    cat "$FM_CODEX_LIFECYCLE"
    ;;
  "app-server daemon version")
    cat "${FM_CODEX_INSPECT_LIFECYCLE:-$FM_CODEX_LIFECYCLE}"
    ;;
  *) exit 9 ;;
esac
SH
  chmod +x "$1/codex"
}

write_lifecycle() {  # <file> <status> <backend> <socket>
  printf '{"status":"%s","backend":"%s","pid":4242,"socketPath":"%s","cliVersion":"0.146.1","appServerVersion":"0.146.1","managedCodexVersion":"0.146.1"}\n' \
    "$2" "$3" "$4" > "$1"
}

test_app_server_boundary() {
  local dir fakebin socket lifecycle inspect log out rc regular symlink
  dir="$TMP_ROOT/app-server"; mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  socket="$dir/app server.sock"
  lifecycle="$dir/lifecycle.json"
  inspect="$dir/inspect.json"
  log="$dir/codex.log"; : > "$log"
  start_socket "$socket"
  make_codex_fake "$fakebin"
  write_lifecycle "$lifecycle" alreadyRunning pid "$socket"
  write_lifecycle "$inspect" running pid "$socket"

  out=$(PATH="$fakebin:$PATH" FM_CODEX_LOG="$log" FM_CODEX_LIFECYCLE="$lifecycle" \
    FM_CODEX_INSPECT_LIFECYCLE="$inspect" "$APP_HELPER" ensure) || fail "valid App Server ensure failed"
  [ "$(printf '%s' "$out" | jq -r .endpoint)" = "unix://$socket" ] || fail "App Server endpoint was not normalized"
  [ "$(printf '%s' "$out" | jq -r .backend)" = pid ] || fail "App Server backend was not retained"
  PATH="$fakebin:$PATH" FM_CODEX_LOG="$log" FM_CODEX_LIFECYCLE="$lifecycle" \
    FM_CODEX_INSPECT_LIFECYCLE="$inspect" "$APP_HELPER" inspect >/dev/null || fail "valid App Server inspect failed"
  write_lifecycle "$lifecycle" started pid "$socket"
  PATH="$fakebin:$PATH" FM_CODEX_LOG="$log" FM_CODEX_LIFECYCLE="$lifecycle" \
    "$APP_HELPER" ensure >/dev/null || fail "freshly started App Server lifecycle was rejected"
  write_lifecycle "$lifecycle" alreadyRunning pid "$socket"
  assert_grep 'codex app-server daemon start' "$log" "ensure did not use the managed start interface"
  assert_grep 'codex app-server daemon version' "$log" "inspect did not use the read-only version interface"
  assert_no_grep 'restart' "$log" "App Server helper invoked daemon restart"
  assert_no_grep ' stop' "$log" "App Server helper invoked daemon stop"

  printf 'not-json\n' > "$lifecycle"
  PATH="$fakebin:$PATH" FM_CODEX_LOG="$log" FM_CODEX_LIFECYCLE="$lifecycle" \
    "$APP_HELPER" ensure >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "malformed lifecycle JSON was accepted"
  write_lifecycle "$lifecycle" stopped pid "$socket"
  PATH="$fakebin:$PATH" FM_CODEX_LOG="$log" FM_CODEX_LIFECYCLE="$lifecycle" \
    "$APP_HELPER" ensure >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "unsupported lifecycle status was accepted"
  write_lifecycle "$lifecycle" alreadyRunning stdio "$socket"
  PATH="$fakebin:$PATH" FM_CODEX_LOG="$log" FM_CODEX_LIFECYCLE="$lifecycle" \
    "$APP_HELPER" ensure >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "unsupported lifecycle backend was accepted"
  printf '{"status":"alreadyRunning","backend":"pid","pid":null,"socketPath":"%s","cliVersion":"0.146.1","appServerVersion":"0.146.1","managedCodexVersion":"0.146.1"}\n' "$socket" > "$lifecycle"
  PATH="$fakebin:$PATH" FM_CODEX_LOG="$log" FM_CODEX_LIFECYCLE="$lifecycle" \
    "$APP_HELPER" ensure >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "missing managed pid was accepted"
  printf '{"status":"alreadyRunning","backend":"pid","pid":4242,"socketPath":"%s","cliVersion":"0.146.1","appServerVersion":"0.147.0","managedCodexVersion":"0.146.1"}\n' "$socket" > "$lifecycle"
  PATH="$fakebin:$PATH" FM_CODEX_LOG="$log" FM_CODEX_LIFECYCLE="$lifecycle" \
    "$APP_HELPER" ensure >"$dir/version.out" 2>"$dir/version.err"; rc=$?
  [ "$rc" -ne 0 ] || fail "mismatched managed App Server versions were accepted"
  assert_grep 'bootstrap/consent' "$dir/version.err" "version mismatch omitted the actionable managed-update path"
  write_lifecycle "$lifecycle" alreadyRunning pid relative.sock
  PATH="$fakebin:$PATH" FM_CODEX_LOG="$log" FM_CODEX_LIFECYCLE="$lifecycle" \
    "$APP_HELPER" ensure >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "relative lifecycle socket was accepted"

  regular="$dir/regular"; : > "$regular"; chmod 0600 "$regular"
  write_lifecycle "$lifecycle" alreadyRunning pid "$regular"
  PATH="$fakebin:$PATH" FM_CODEX_LOG="$log" FM_CODEX_LIFECYCLE="$lifecycle" \
    "$APP_HELPER" ensure >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "regular lifecycle path was accepted as a socket"
  symlink="$dir/socket-link"; ln -s "$socket" "$symlink"
  write_lifecycle "$lifecycle" alreadyRunning pid "$symlink"
  PATH="$fakebin:$PATH" FM_CODEX_LOG="$log" FM_CODEX_LIFECYCLE="$lifecycle" \
    "$APP_HELPER" ensure >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "symlink lifecycle socket was accepted"
  chmod 0660 "$socket"
  write_lifecycle "$lifecycle" alreadyRunning pid "$socket"
  PATH="$fakebin:$PATH" FM_CODEX_LOG="$log" FM_CODEX_LIFECYCLE="$lifecycle" \
    "$APP_HELPER" ensure >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "non-private lifecycle socket mode was accepted"
  chmod 0600 "$socket"
  FM_CODEX_FAIL=1 PATH="$fakebin:$PATH" FM_CODEX_LOG="$log" FM_CODEX_LIFECYCLE="$lifecycle" \
    "$APP_HELPER" ensure >"$dir/fail.out" 2>"$dir/fail.err"; rc=$?
  [ "$rc" -ne 0 ] || fail "missing managed standalone was accepted"
  assert_grep 'bootstrap/consent' "$dir/fail.err" "missing managed standalone diagnostic omitted consent routing"
  pass "managed App Server: lifecycle JSON, exact private socket, normalized endpoint, and no stop/restart fallback"
}

make_no_mistakes_fake() {  # <fakebin>
  cat > "$1/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf 'cwd=%s argv=%s\n' "$PWD" "$*" >> "$FM_NM_LOG"
case "$*" in
  --version) printf 'no-mistakes version test (0d39eadf)\n' ;;
  "axi status"|"axi status --run "*)
    [ -f "$FM_NM_STATUS" ] || exit 1
    cat "$FM_NM_STATUS"
    ;;
  *) exit 8 ;;
esac
SH
  chmod +x "$1/no-mistakes"
}

make_herdr_fake() {  # <fakebin>
  cat > "$1/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf 'env=%s argv=%s\n' "${HERDR_SESSION:-}" "$*" >> "$FM_HERDR_LOG"
session=
prev=
for arg in "$@"; do
  if [ "$prev" = --session ]; then session=$arg; fi
  prev=$arg
done
[ "$session" = "$FM_HERDR_SESSION_NAME" ] || exit 61
focus=$(cat "$FM_HERDR_FOCUS" 2>/dev/null || printf captain)
tab=$(cat "$FM_HERDR_TAB" 2>/dev/null || printf 'w-parent:t-view1')
pane=$(cat "$FM_HERDR_PANE" 2>/dev/null || printf 'w-parent:p-view1')
state=$(cat "$FM_HERDR_STATE" 2>/dev/null || printf gone)
case "${1:-} ${2:-}" in
  "session list")
    printf '{"sessions":[{"name":"%s","running":true,"socket_path":"%s"}]}\n' "$session" "$FM_HERDR_SOCKET"
    ;;
  "workspace list")
    if [ "$focus" = view ]; then active=$tab; else active=w-parent:t-captain; fi
    printf '{"result":{"workspaces":[{"workspace_id":"w-parent","label":"firstmate","focused":true,"active_tab_id":"%s"},{"workspace_id":"w-duplicate","label":"firstmate","focused":false,"active_tab_id":"w-duplicate:t1"}]}}\n' "$active"
    ;;
  "tab list")
    if [ "$focus" = view ]; then vf=true; cf=false; else vf=false; cf=true; fi
    printf '{"result":{"tabs":[{"tab_id":"w-parent:t-captain","focused":%s},{"tab_id":"w-parent:t-task","focused":false},{"tab_id":"%s","focused":%s}]}}\n' "$cf" "$tab" "$vf"
    ;;
  "tab create")
    count=$(cat "$FM_HERDR_COUNT" 2>/dev/null || printf 0); count=$((count + 1)); printf '%s\n' "$count" > "$FM_HERDR_COUNT"
    tab="w-parent:t-view$count"; pane="w-parent:p-view$count"
    printf '%s\n' "$tab" > "$FM_HERDR_TAB"; printf '%s\n' "$pane" > "$FM_HERDR_PANE"; printf idle > "$FM_HERDR_STATE"
    if [ "${FM_HERDR_CREATE_MODE:-ok}" = fail ]; then exit 7; fi
    if [ "${FM_HERDR_CREATE_MODE:-ok}" = malformed ]; then printf '{"result":{}}\n'; else printf '{"result":{"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' "$tab" "$pane"; fi
    ;;
  "pane run")
    [ "${FM_HERDR_RUN_FAIL:-0}" = 0 ] || exit 9
    printf launched > "$FM_HERDR_STATE"
    ;;
  "pane get")
    target=${3:-}
    if [ "$target" = w-parent:p-task ]; then
      printf '{"result":{"pane":{"pane_id":"w-parent:p-task","tab_id":"w-parent:t-task","workspace_id":"w-parent"}}}\n'
    elif [ "$target" = "$pane" ] && [ "$state" != gone ]; then
      printf '{"result":{"pane":{"pane_id":"%s","tab_id":"%s","workspace_id":"w-parent"}}}\n' "$pane" "$tab"
    else
      printf '{"error":{"code":"pane_not_found"}}\n'
    fi
    ;;
  "pane process-info")
    if [ "$state" = launched ]; then
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":4000,"foreground_process_group_id":5000,"foreground_processes":[{"pid":5000,"name":"codex","argv0":"codex","argv":["codex","--remote","%s","resume","%s"]}]}}}\n' "$pane" "$FM_EXPECT_ENDPOINT" "$FM_EXPECT_THREAD"
    else
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":4242,"foreground_process_group_id":4242,"foreground_processes":[{"pid":4242,"name":"bash","argv0":"bash","argv":["bash"]}]}}}\n' "$pane"
    fi
    ;;
  "pane list")
    printf '{"result":{"panes":[{"pane_id":"w-parent:p-task"},{"pane_id":"%s"}]}}\n' "$pane"
    ;;
  "pane close")
    printf gone > "$FM_HERDR_STATE"
    ;;
  "tab get")
    printf '{"result":{"tab":{"tab_id":"%s","workspace_id":"w-parent"}}}\n' "${3:-}"
    ;;
  "tab focus")
    printf captain > "$FM_HERDR_FOCUS"
    ;;
  *) printf '{"result":{}}\n' ;;
esac
SH
  chmod +x "$1/herdr"
  cat > "$1/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-axo pid=,ppid=") printf '4242 1\n' ;;
  "-p 4242 -o stat=") printf 'S\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$1/ps"
}

setup_live_case() {  # <name> [harness] [kind] [mode] [backend]
  CASE_DIR="$TMP_ROOT/$1"; mkdir -p "$CASE_DIR/home/state" "$CASE_DIR/home/config" "$CASE_DIR/home/.no-mistakes" "$CASE_DIR/project"
  CASE_HOME="$CASE_DIR/home"; CASE_STATE="$CASE_HOME/state"; CASE_WT="$CASE_DIR/wt"
  CASE_FAKEBIN=$(fm_fakebin "$CASE_DIR")
  make_codex_fake "$CASE_FAKEBIN"; make_no_mistakes_fake "$CASE_FAKEBIN"; make_herdr_fake "$CASE_FAKEBIN"
  fm_git_init_commit "$CASE_WT"
  git -C "$CASE_WT" checkout -qb fm/test
  CASE_HEAD=$(git -C "$CASE_WT" rev-parse HEAD)
  CASE_SOCKET="$CASE_DIR/codex.sock"; start_socket "$CASE_SOCKET"
  CASE_LIFECYCLE="$CASE_DIR/lifecycle.json"; write_lifecycle "$CASE_LIFECYCLE" alreadyRunning pid "$CASE_SOCKET"
  CASE_CODEX_LOG="$CASE_DIR/codex.log"; CASE_NM_LOG="$CASE_DIR/nm.log"; CASE_HERDR_LOG="$CASE_DIR/herdr.log"
  CASE_NM_STATUS="$CASE_DIR/status.toon"; CASE_HERDR_FOCUS="$CASE_DIR/focus"; CASE_HERDR_STATE="$CASE_DIR/pane-state"
  CASE_HERDR_TAB="$CASE_DIR/tab"; CASE_HERDR_PANE="$CASE_DIR/pane"; CASE_HERDR_COUNT="$CASE_DIR/count"
  : > "$CASE_CODEX_LOG"; : > "$CASE_NM_LOG"; : > "$CASE_HERDR_LOG"; printf captain > "$CASE_HERDR_FOCUS"; printf gone > "$CASE_HERDR_STATE"
  CASE_SESSION=nm-herdr-lab; CASE_HERDR_SOCKET="$CASE_DIR/herdr.sock"
  printf 'agent: codex\ncodex:\n  transport: app-server\n  app_server_endpoint: unix://%s\n' "$CASE_SOCKET" > "$CASE_HOME/.no-mistakes/config.yaml"
  printf 'runs: 0 runs yet in this repository\nhelp[1]:\n  - run no-mistakes\n' > "$CASE_NM_STATUS"
  fm_write_meta "$CASE_STATE/task.meta" \
    "endpoint_task_id=task" "window=$CASE_SESSION:w-parent:p-task" "backend=${5:-herdr}" \
    "harness=${2:-codex}" "kind=${3:-ship}" "mode=${4:-no-mistakes}" \
    "worktree=$CASE_WT" "project=$CASE_DIR/project" \
    "herdr_session=$CASE_SESSION" "herdr_workspace_id=w-parent" \
    "herdr_tab_id=w-parent:t-task" "herdr_pane_id=w-parent:p-task"
}

run_live() {
  PATH="$CASE_FAKEBIN:$PATH" HOME="$CASE_HOME" FM_HOME="$CASE_HOME" \
    FM_CODEX_LOG="$CASE_CODEX_LOG" FM_CODEX_LIFECYCLE="$CASE_LIFECYCLE" \
    FM_NM_LOG="$CASE_NM_LOG" FM_NM_STATUS="$CASE_NM_STATUS" \
    FM_HERDR_LOG="$CASE_HERDR_LOG" FM_HERDR_FOCUS="$CASE_HERDR_FOCUS" \
    FM_HERDR_STATE="$CASE_HERDR_STATE" FM_HERDR_TAB="$CASE_HERDR_TAB" \
    FM_HERDR_PANE="$CASE_HERDR_PANE" FM_HERDR_COUNT="$CASE_HERDR_COUNT" \
    FM_HERDR_SESSION_NAME="$CASE_SESSION" FM_HERDR_SOCKET="$CASE_HERDR_SOCKET" \
    FM_EXPECT_ENDPOINT="unix://$CASE_SOCKET" FM_EXPECT_THREAD="${FM_EXPECT_THREAD:-019f4d4d-5dc0-75c1-8efe-adf4531bd733}" \
    "$LIVE" "$@"
}

write_active_status() {  # <run> <head> <session> [second-session]
  local run=$1 head=$2 session=$3 second=${4:-} count=1
  [ -z "$second" ] || count=2
  {
    printf 'run:\n  id: "%s"\n  branch: fm/test\n  status: running\n  head: "%s"\n' "$run" "$head"
    printf '  active_steps[%s]{step,status,active_for,last_activity,agent_pid,session_id,round}:\n' "$count"
    printf '    review,running,2s,"codex active",4242,"%s",round 1\n' "$session"
    [ -z "$second" ] || printf '    test,running,1s,"codex active",4243,"%s",round 1\n' "$second"
  } > "$CASE_NM_STATUS"
}

write_terminal_status() {  # <run> <head>
  printf 'run:\n  id: "%s"\n  branch: fm/test\n  status: completed\n  head: "%s"\noutcome: passed\n' "$1" "$2" > "$CASE_NM_STATUS"
}

write_no_active_status() {  # <run> <head>
  printf 'run:\n  id: "%s"\n  branch: fm/test\n  status: running\n  head: "%s"\n  active_steps[0]{step,status,active_for,last_activity,agent_pid,session_id,round}:\n' \
    "$1" "$2" > "$CASE_NM_STATUS"
}

write_branch_status() {  # <run> <branch> <head> <session>
  printf 'run:\n  id: "%s"\n  branch: %s\n  status: running\n  head: "%s"\n  active_steps[1]{step,status,active_for,last_activity,agent_pid,session_id,round}:\n    review,running,2s,"codex active",4242,"%s",round 1\n' \
    "$1" "$2" "$3" "$4" > "$CASE_NM_STATUS"
}

phase_of() { sed -n 's/^phase=//p' "$1"; }

test_trigger_and_live_lifecycle() {
  local attempt journal before rc
  setup_live_case lifecycle
  attempt=$(run_live prepare task '$no-mistakes') || fail "eligible prepare failed"
  [ -n "$attempt" ] || fail "eligible prepare did not return an attempt"
  journal="$CASE_STATE/task.nm-live"
  [ "$(phase_of "$journal")" = prepared ] || fail "prepare did not publish prepared state"
  [ "$(stat -c %a "$journal" 2>/dev/null || stat -f %Lp "$journal")" = 600 ] || fail "journal is not mode 0600"
  assert_no_grep 'tab create' "$CASE_HERDR_LOG" "preflight created a Herdr tab before delivery"

  write_no_active_status RUN-1 "$CASE_HEAD"
  run_live confirm task "$attempt" || fail "delivery confirmation did not reconcile"
  [ "$(phase_of "$journal")" = waiting-run ] || fail "active run without a session did not remain waiting"
  assert_no_grep 'tab create' "$CASE_HERDR_LOG" "active run without a session created a companion"
  write_active_status RUN-1 "$CASE_HEAD" 019f4d4d-5dc0-75c1-8efe-adf4531bd733
  run_live reconcile task || fail "active run session did not reconcile"
  [ "$(phase_of "$journal")" = live ] || fail "confirmed attributed thread did not become live"
  assert_grep "env=nm-herdr-lab argv=tab create --workspace w-parent --cwd $CASE_STATE --label VIEW ONLY nm-task-RUN-1 --no-focus --session nm-herdr-lab" "$CASE_HERDR_LOG" "companion create was not exact, private-cwd, labeled, unfocused, and doubly session-scoped"
  assert_grep "pane run w-parent:p-view1 exec codex --remote 'unix://$CASE_SOCKET' resume '019f4d4d-5dc0-75c1-8efe-adf4531bd733' --session nm-herdr-lab" "$CASE_HERDR_LOG" "exact remote resume was not launched in the returned pane"
  [ "$(cat "$CASE_HERDR_FOCUS")" = captain ] || fail "companion creation changed focus"
  before=$(grep -c 'tab create' "$CASE_HERDR_LOG")
  run_live reconcile task || fail "idempotent live reconcile failed"
  [ "$(grep -c 'tab create' "$CASE_HERDR_LOG")" = "$before" ] || fail "same run/thread reconciliation created a duplicate"
  assert_grep "cwd=$CASE_WT argv=axi status --run RUN-1" "$CASE_NM_LOG" "reconciliation did not pin the attributed run in the exact worktree"

  printf view > "$CASE_HERDR_FOCUS"
  run_live cleanup task >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "focused cleanup did not defer"
  [ "$(phase_of "$journal")" = cleanup-deferred ] || fail "focused cleanup did not persist cleanup-deferred"
  assert_no_grep 'pane close' "$CASE_HERDR_LOG" "focused cleanup closed the active companion"
  printf captain > "$CASE_HERDR_FOCUS"
  run_live reconcile task || fail "deferred nonfocused cleanup did not reconcile"
  [ ! -e "$journal" ] || fail "confirmed exact cleanup did not retire the journal"
  assert_grep 'pane close w-parent:p-view1 --session nm-herdr-lab' "$CASE_HERDR_LOG" "cleanup did not close only the exact pane"
  assert_no_grep 'workspace close' "$CASE_HERDR_LOG" "live view closed a Herdr workspace"
  assert_no_grep 'workspace delete' "$CASE_HERDR_LOG" "live view deleted a Herdr workspace"
  assert_no_grep 'server stop' "$CASE_HERDR_LOG" "live view stopped a Herdr server"
  assert_no_grep 'session stop' "$CASE_HERDR_LOG" "live view stopped a Herdr session"

  setup_live_case quoted-endpoint
  CASE_SOCKET="$CASE_DIR/codex '\$(unsafe).sock"
  start_socket "$CASE_SOCKET"
  write_lifecycle "$CASE_LIFECYCLE" alreadyRunning pid "$CASE_SOCKET"
  printf 'agent: codex\ncodex:\n  transport: app-server\n  app_server_endpoint: unix://%s\n' "$CASE_SOCKET" > "$CASE_HOME/.no-mistakes/config.yaml"
  attempt=$(run_live prepare task '$no-mistakes') || fail "safely quotable endpoint prepare failed"
  write_active_status RUN-Q "$CASE_HEAD" 019f4d4d-5dc0-75c1-8efe-adf4531bd733
  run_live confirm task "$attempt" || fail "safely quotable endpoint creation failed"
  assert_grep "exec codex --remote 'unix://$CASE_DIR/codex '\"'\"'\$(unsafe).sock' resume" "$CASE_HERDR_LOG" "endpoint shell metacharacters were not safely single-quoted"
  [ ! -e "$CASE_DIR/unsafe" ] || fail "quoted endpoint executed command substitution"
  pass "live state machine: post-delivery attribution, exact unfocused creation, idempotence, pinned run, and focus-safe deferred cleanup"
}

test_rejections_rotation_and_quarantine() {
  local attempt journal creates rc
  setup_live_case reject
  attempt=$(run_live prepare task '$no-mistakes') || fail "rejection fixture prepare failed"
  write_active_status RUN-M "$CASE_HEAD" 019f4d4d-5dc0-75c1-8efe-adf4531bd733 029f4d4d-5dc0-75c1-8efe-adf4531bd733
  run_live confirm task "$attempt" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "multiple active identities were accepted"
  journal="$CASE_STATE/task.nm-live"
  [ "$(phase_of "$journal")" = quarantined ] || fail "multiple active identities were not quarantined"
  assert_no_grep 'tab create' "$CASE_HERDR_LOG" "multiple active identities reached Herdr mutation"

  setup_live_case rotation
  attempt=$(run_live prepare task '$no-mistakes') || fail "rotation fixture prepare failed"
  write_active_status RUN-R "$CASE_HEAD" 019f4d4d-5dc0-75c1-8efe-adf4531bd733
  run_live confirm task "$attempt" || fail "rotation initial create failed"
  FM_EXPECT_THREAD=029f4d4d-5dc0-75c1-8efe-adf4531bd733
  export FM_EXPECT_THREAD
  write_active_status RUN-R "$CASE_HEAD" "$FM_EXPECT_THREAD"
  run_live reconcile task || fail "thread rotation cleanup failed"
  [ "$(phase_of "$CASE_STATE/task.nm-live")" = waiting-run ] || fail "thread rotation did not promote the replacement only after cleanup"
  run_live reconcile task || fail "thread rotation replacement create failed"
  [ "$(phase_of "$CASE_STATE/task.nm-live")" = live ] || fail "thread rotation replacement did not become live"
  creates=$(grep -c 'tab create' "$CASE_HERDR_LOG")
  [ "$creates" -eq 2 ] || fail "thread rotation created $creates companions instead of exactly two sequential views"
  [ "$(grep -c 'pane close' "$CASE_HERDR_LOG")" -eq 1 ] || fail "thread rotation did not clean the old exact pane first"
  write_terminal_status RUN-R "$CASE_HEAD"
  run_live reconcile task || fail "terminal run cleanup failed"
  [ ! -e "$CASE_STATE/task.nm-live" ] || fail "terminal run retained a live companion journal"
  [ "$(grep -c 'pane close' "$CASE_HERDR_LOG")" -eq 2 ] || fail "terminal run did not close the replacement companion"
  unset FM_EXPECT_THREAD

  setup_live_case lost-create
  attempt=$(run_live prepare task '$no-mistakes') || fail "lost-create prepare failed"
  write_active_status RUN-L "$CASE_HEAD" 019f4d4d-5dc0-75c1-8efe-adf4531bd733
  FM_HERDR_CREATE_MODE=malformed run_live confirm task "$attempt" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "malformed mutation response was accepted"
  [ "$(phase_of "$CASE_STATE/task.nm-live")" = quarantined ] || fail "lost creation response was not quarantined"
  assert_no_grep 'workspace find' "$CASE_HERDR_LOG" "lost creation response triggered global rediscovery"
  assert_no_grep 'label get' "$CASE_HERDR_LOG" "lost creation response triggered label adoption"
  pass "attribution safety: multiple identities reject, rotation cleans before replacement, and ambiguous creation quarantines without label adoption"
}

test_run_attribution_matrix() {
  local attempt journal base descendant local_head diverged_run rc

  setup_live_case descendant
  base=$CASE_HEAD
  printf 'descendant\n' > "$CASE_WT/descendant.txt"
  git -C "$CASE_WT" add descendant.txt
  git -C "$CASE_WT" -c user.name=test -c user.email=test@example.invalid commit -qm descendant
  descendant=$(git -C "$CASE_WT" rev-parse HEAD)
  git -C "$CASE_WT" reset --hard -q "$base"
  attempt=$(run_live prepare task '$no-mistakes') || fail "descendant prepare failed"
  write_active_status RUN-D "$descendant" 019f4d4d-5dc0-75c1-8efe-adf4531bd733
  run_live confirm task "$attempt" || fail "descendant run head was rejected"
  [ "$(phase_of "$CASE_STATE/task.nm-live")" = live ] || fail "descendant run head did not create a companion"

  setup_live_case advanced
  base=$CASE_HEAD
  attempt=$(run_live prepare task '$no-mistakes') || fail "advanced prepare failed"
  printf 'local\n' > "$CASE_WT/local.txt"
  git -C "$CASE_WT" add local.txt
  git -C "$CASE_WT" -c user.name=test -c user.email=test@example.invalid commit -qm local
  local_head=$(git -C "$CASE_WT" rev-parse HEAD)
  [ "$local_head" != "$base" ] || fail "local-advance fixture did not advance"
  write_active_status RUN-A "$base" 019f4d4d-5dc0-75c1-8efe-adf4531bd733
  run_live confirm task "$attempt" || true
  journal="$CASE_STATE/task.nm-live"
  [ "$(phase_of "$journal")" = waiting-run ] || fail "locally advanced worktree was not rejected as unattributed"
  assert_no_grep 'tab create' "$CASE_HERDR_LOG" "locally advanced worktree reached Herdr creation"

  setup_live_case diverged
  base=$CASE_HEAD
  printf 'run\n' > "$CASE_WT/diverge.txt"; git -C "$CASE_WT" add diverge.txt
  git -C "$CASE_WT" -c user.name=test -c user.email=test@example.invalid commit -qm run-side
  diverged_run=$(git -C "$CASE_WT" rev-parse HEAD)
  git -C "$CASE_WT" reset --hard -q "$base"
  printf 'local\n' > "$CASE_WT/diverge.txt"; git -C "$CASE_WT" add diverge.txt
  git -C "$CASE_WT" -c user.name=test -c user.email=test@example.invalid commit -qm local-side
  attempt=$(run_live prepare task '$no-mistakes') || fail "diverged prepare failed"
  write_active_status RUN-V "$diverged_run" 019f4d4d-5dc0-75c1-8efe-adf4531bd733
  run_live confirm task "$attempt" || true
  [ "$(phase_of "$CASE_STATE/task.nm-live")" = waiting-run ] || fail "diverged run head was not rejected"
  assert_no_grep 'tab create' "$CASE_HERDR_LOG" "diverged run head reached Herdr creation"

  setup_live_case detached
  git -C "$CASE_WT" checkout --detach -q
  run_live prepare task '$no-mistakes' >/dev/null 2>"$CASE_DIR/detached.err"; rc=$?
  [ "$rc" -ne 0 ] && [ ! -e "$CASE_STATE/task.nm-live" ] || fail "detached worktree prepared a live-view journal"
  assert_grep 'detached' "$CASE_DIR/detached.err" "detached rejection diagnostic was not actionable"

  setup_live_case terminal-baseline
  write_terminal_status RUN-OLD "$CASE_HEAD"
  attempt=$(run_live prepare task '$no-mistakes') || fail "terminal baseline prepare failed"
  run_live confirm task "$attempt" || fail "terminal baseline confirmation failed"
  [ "$(phase_of "$CASE_STATE/task.nm-live")" = waiting-run ] || fail "terminal baseline was treated as causal"
  assert_no_grep 'tab create' "$CASE_HERDR_LOG" "terminal baseline created a companion"
  write_active_status RUN-NEW "$CASE_HEAD" 019f4d4d-5dc0-75c1-8efe-adf4531bd733
  run_live reconcile task || fail "new post-delivery run did not supersede terminal baseline"
  [ "$(phase_of "$CASE_STATE/task.nm-live")" = live ] || fail "new post-delivery run did not become live"

  setup_live_case malformed-uuid
  attempt=$(run_live prepare task '$no-mistakes') || fail "malformed UUID prepare failed"
  write_active_status RUN-U "$CASE_HEAD" not-a-canonical-uuid
  run_live confirm task "$attempt" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] && [ "$(phase_of "$CASE_STATE/task.nm-live")" = quarantined ] || fail "malformed active session identity was not quarantined"

  setup_live_case other-branch
  attempt=$(run_live prepare task '$no-mistakes') || fail "other-branch prepare failed"
  write_branch_status RUN-B fm/other "$CASE_HEAD" 019f4d4d-5dc0-75c1-8efe-adf4531bd733
  run_live confirm task "$attempt" || true
  [ "$(phase_of "$CASE_STATE/task.nm-live")" = waiting-run ] || fail "another branch was not rejected"

  setup_live_case unavailable
  attempt=$(run_live prepare task '$no-mistakes') || fail "unavailable-status prepare failed"
  rm -f "$CASE_NM_STATUS"
  run_live confirm task "$attempt" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "unavailable no-mistakes status was reported reconciled"
  [ "$(phase_of "$CASE_STATE/task.nm-live")" = delivery-confirmed ] || fail "status timeout/error mutated external state"
  assert_no_grep 'tab create' "$CASE_HERDR_LOG" "status timeout/error reached Herdr mutation"

  setup_live_case unavailable-baseline
  rm -f "$CASE_NM_STATUS"
  run_live prepare task '$no-mistakes' >/dev/null 2>"$CASE_DIR/unavailable-baseline.err"; rc=$?
  [ "$rc" -ne 0 ] && [ ! -e "$CASE_STATE/task.nm-live" ] || fail "unavailable pre-delivery baseline was accepted"

  setup_live_case ambiguous-baseline
  write_active_status RUN-AMB "$CASE_HEAD" 019f4d4d-5dc0-75c1-8efe-adf4531bd733 029f4d4d-5dc0-75c1-8efe-adf4531bd733
  run_live prepare task '$no-mistakes' >/dev/null 2>"$CASE_DIR/ambiguous-baseline.err"; rc=$?
  [ "$rc" -ne 0 ] && [ ! -e "$CASE_STATE/task.nm-live" ] || fail "ambiguous active baseline was accepted"
  pass "run attribution matrix: descendant accepted; advanced, diverged, detached, stale, terminal-baseline, malformed, and unavailable sources rejected"
}

test_restart_duplicate_and_binding_safety() {
  local attempt journal first_journal second_attempt rc before

  setup_live_case restart
  attempt=$(run_live prepare task '$no-mistakes') || fail "restart prepare failed"
  journal="$CASE_STATE/task.nm-live"
  sed -i 's/^phase=prepared$/phase=creating/' "$journal"
  run_live reconcile task >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] && [ "$(phase_of "$journal")" = quarantined ] || fail "unbound creating restart was not quarantined"

  setup_live_case restart-bound
  attempt=$(run_live prepare task '$no-mistakes') || fail "bound restart prepare failed"
  write_active_status RUN-RS "$CASE_HEAD" 019f4d4d-5dc0-75c1-8efe-adf4531bd733
  run_live confirm task "$attempt" || fail "bound restart initial create failed"
  journal="$CASE_STATE/task.nm-live"
  sed -i 's/^phase=live$/phase=creating/; s/^launch_state=submitted$/launch_state=not-started/' "$journal"
  printf idle > "$CASE_HERDR_STATE"
  before=$(grep -c 'pane run' "$CASE_HERDR_LOG")
  run_live reconcile task || fail "bound idle pre-launch restart did not finish launch"
  [ "$(phase_of "$journal")" = live ] || fail "bound idle pre-launch restart did not return live"
  [ "$(grep -c 'pane run' "$CASE_HERDR_LOG")" -eq $((before + 1)) ] || fail "restart did not issue exactly one recorded launch"

  printf gone > "$CASE_HERDR_STATE"
  run_live reconcile task || fail "gone live pane did not retire"
  [ ! -e "$journal" ] || fail "gone live pane retained a stale journal"

  setup_live_case thread-disappeared
  attempt=$(run_live prepare task '$no-mistakes') || fail "thread-disappeared prepare failed"
  write_active_status RUN-DISAPPEARED "$CASE_HEAD" 019f4d4d-5dc0-75c1-8efe-adf4531bd733
  run_live confirm task "$attempt" || fail "thread-disappeared initial create failed"
  write_no_active_status RUN-DISAPPEARED "$CASE_HEAD"
  run_live reconcile task || fail "active thread disappearance cleanup failed"
  [ ! -e "$CASE_STATE/task.nm-live" ] || fail "disappeared active thread retained a companion journal"
  assert_grep 'pane close w-parent:p-view1 --session nm-herdr-lab' "$CASE_HERDR_LOG" "active thread disappearance did not clean the exact pane"

  setup_live_case binding-reuse
  attempt=$(run_live prepare task '$no-mistakes') || fail "binding reuse prepare failed"
  write_active_status RUN-BIND "$CASE_HEAD" 019f4d4d-5dc0-75c1-8efe-adf4531bd733
  run_live confirm task "$attempt" || fail "binding reuse initial create failed"
  mkdir -p "$CASE_DIR/reused-project"
  printf 'project=%s\n' "$CASE_DIR/reused-project" >> "$CASE_STATE/task.meta"
  run_live reconcile task >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] && [ "$(phase_of "$CASE_STATE/task.nm-live")" = quarantined ] || fail "task-id binding reuse was not quarantined"
  assert_no_grep 'pane close' "$CASE_HERDR_LOG" "binding mismatch authorized cleanup mutation"

  setup_live_case duplicate-pair
  attempt=$(run_live prepare task '$no-mistakes') || fail "first duplicate-pair prepare failed"
  write_active_status RUN-PAIR "$CASE_HEAD" 019f4d4d-5dc0-75c1-8efe-adf4531bd733
  run_live confirm task "$attempt" || fail "first duplicate-pair create failed"
  first_journal="$CASE_STATE/task.nm-live"
  printf 'runs: 0 runs yet in this repository\nhelp[1]:\n  - run no-mistakes\n' > "$CASE_NM_STATUS"
  cp "$CASE_STATE/task.meta" "$CASE_STATE/task2.meta"
  sed -i 's/^endpoint_task_id=task$/endpoint_task_id=task2/' "$CASE_STATE/task2.meta"
  second_attempt=$(run_live prepare task2 '$no-mistakes') || fail "second duplicate-pair prepare failed"
  write_active_status RUN-PAIR "$CASE_HEAD" 019f4d4d-5dc0-75c1-8efe-adf4531bd733
  if run_live confirm task2 "$second_attempt" >/dev/null 2>&1; then rc=0; else rc=$?; fi
  [ "$rc" -ne 0 ] && [ "$(phase_of "$CASE_STATE/task2.nm-live")" = quarantined ] || fail "duplicate run/session pair was not quarantined"
  [ -e "$first_journal" ] || fail "duplicate scan disturbed the authoritative first journal"

  setup_live_case metadata-gone
  attempt=$(run_live prepare task '$no-mistakes') || fail "metadata-gone prepare failed"
  write_active_status RUN-GONE "$CASE_HEAD" 019f4d4d-5dc0-75c1-8efe-adf4531bd733
  run_live confirm task "$attempt" || fail "metadata-gone initial create failed"
  rm -f "$CASE_STATE/task.meta"
  run_live reconcile task || fail "orphan companion cleanup failed"
  [ ! -e "$CASE_STATE/task.nm-live" ] || fail "orphan companion journal survived confirmed cleanup"
  pass "restart and authority matrix: unbound quarantine, bound launch recovery, gone or disappeared thread retirement, task-binding refusal, duplicate prevention, and orphan cleanup"
}

test_eligibility_axes_and_opt_out() {
  local spec harness message attempt rc
  for spec in 'codex|$no-mistakes' 'claude|/no-mistakes' 'grok|/no-mistakes' 'kimi|/no-mistakes'; do
    harness=${spec%%|*}; message=${spec#*|}
    setup_live_case "eligible-$harness" "$harness"
    attempt=$(run_live prepare task "$message") || fail "$harness canonical invocation was rejected"
    [ -n "$attempt" ] || fail "$harness canonical invocation was not eligible"
    run_live cancel task "$attempt" || fail "$harness prepared attempt could not cancel"
  done
  for spec in 'opencode|/no-mistakes' 'pi|/no-mistakes' 'pi-signed|/no-mistakes' 'muse|/no-mistakes' 'codex|please run no-mistakes'; do
    harness=${spec%%|*}; message=${spec#*|}
    setup_live_case "ineligible-$harness-$RANDOM" "$harness"
    attempt=$(run_live prepare task "$message") || fail "$harness ineligible invocation errored instead of no-op"
    [ -z "$attempt" ] && [ ! -e "$CASE_STATE/task.nm-live" ] || fail "$harness ineligible invocation prepared a journal"
  done
  setup_live_case scout codex scout
  [ -z "$(run_live prepare task '$no-mistakes')" ] || fail "scout triggered live view"
  setup_live_case secondmate codex secondmate
  [ -z "$(run_live prepare task '$no-mistakes')" ] || fail "secondmate triggered live view"
  setup_live_case direct codex ship direct-PR
  [ -z "$(run_live prepare task '$no-mistakes')" ] || fail "direct-PR mode triggered live view"
  for backend in tmux zellij orca cmux; do
    setup_live_case "runtime-$backend" codex ship no-mistakes "$backend"
    [ -z "$(run_live prepare task '$no-mistakes')" ] || fail "$backend runtime triggered the Herdr-only live view"
  done
  setup_live_case optout
  printf off > "$CASE_HOME/config/nm-live-view"
  [ -z "$(run_live prepare task '$no-mistakes')" ] || fail "private opt-out did not disable live view"
  setup_live_case duplicate-config
  printf 'agent: codex\nagent: codex\ncodex:\n  transport: app-server\n  app_server_endpoint: unix://%s\n' "$CASE_SOCKET" > "$CASE_HOME/.no-mistakes/config.yaml"
  run_live prepare task '$no-mistakes' >/dev/null 2>"$CASE_DIR/duplicate-config.err"; rc=$?
  [ "$rc" -ne 0 ] && [ ! -e "$CASE_STATE/task.nm-live" ] || fail "duplicate no-mistakes agent configuration was accepted"
  pass "trigger eligibility: exact canonical harness forms only, ship/no-mistakes/Herdr only, with default-on private opt-out"
}

make_send_fakes() {  # <dir>
  local fakebin=$1
  cat > "$fakebin/nm-live-hook" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOOK_LOG"
case "$1" in
  prepare) printf ATTEMPT ;;
  confirm) [ "${FM_HOOK_CONFIRM_FAIL:-0}" = 0 ] ;;
  cancel) : ;;
esac
SH
  chmod +x "$fakebin/nm-live-hook"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  send-keys) [ "${FM_SEND_FAIL:-0}" = 0 ] ;;
  display-message) printf '1\n' ;;
  capture-pane)
    if [ "${FM_NONEMPTY_VERDICT:-0}" = 1 ]; then printf 'still busy\n'
    else printf '╭──╮\n│  │\n╰──╯\n'
    fi
    ;;
esac
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/sleep"
}

test_fm_send_seam() {
  local dir fakebin home log rc
  dir="$TMP_ROOT/send"; mkdir -p "$dir/home/state"; home="$dir/home"; fakebin=$(fm_fakebin "$dir"); make_send_fakes "$fakebin"
  log="$dir/hook.log"; : > "$log"
  fm_write_meta "$home/state/task.meta" "window=s:fm-task" "kind=ship" "mode=no-mistakes" "harness=codex" "worktree=$dir/wt" "project=$dir/project"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_NM_LIVE_HELPER="$fakebin/nm-live-hook" \
    FM_HOOK_LOG="$log" FM_SEND_SETTLE=0 "$SEND" task '$no-mistakes' >/dev/null 2>"$dir/send.err" || fail "fm-send exact delivery failed"
  [ "$(cat "$log")" = "$(printf 'prepare task $no-mistakes\nconfirm task ATTEMPT')" ] || fail "fm-send did not prepare then confirm exactly once: $(cat "$log")"

  : > "$log"
  FM_SEND_FAIL=1 PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_NM_LIVE_HELPER="$fakebin/nm-live-hook" \
    FM_HOOK_LOG="$log" FM_SEND_SETTLE=0 "$SEND" task '$no-mistakes' >/dev/null 2>"$dir/fail.err"; rc=$?
  [ "$rc" -ne 0 ] || fail "backend delivery failure was reported successful"
  assert_grep 'cancel task ATTEMPT' "$log" "failed delivery did not cancel the prepared attempt"
  assert_no_grep 'confirm task' "$log" "failed delivery confirmed a live-view attempt"

  : > "$log"
  FM_NONEMPTY_VERDICT=1 PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_NM_LIVE_HELPER="$fakebin/nm-live-hook" \
    FM_HOOK_LOG="$log" FM_SEND_SETTLE=0 "$SEND" task '$no-mistakes' >/dev/null 2>"$dir/nonempty.err"; rc=$?
  [ "$rc" -ne 0 ] || fail "non-empty backend verdict was reported successful"
  assert_grep 'cancel task ATTEMPT' "$log" "non-empty backend verdict did not cancel the prepared attempt"
  assert_no_grep 'confirm task' "$log" "non-empty backend verdict confirmed a live-view attempt"

  : > "$log"
  FM_HOOK_CONFIRM_FAIL=1 PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_NM_LIVE_HELPER="$fakebin/nm-live-hook" \
    FM_HOOK_LOG="$log" FM_SEND_SETTLE=0 "$SEND" task '$no-mistakes' >/dev/null 2>"$dir/post.err"; rc=$?
  [ "$rc" -eq 0 ] || fail "post-delivery live-view failure made fm-send report the command unsent"
  assert_grep 'do not resend' "$dir/post.err" "post-delivery failure omitted no-resend warning"

  : > "$log"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_NM_LIVE_HELPER="$fakebin/nm-live-hook" \
    FM_HOOK_LOG="$log" "$SEND" task --key Enter >/dev/null 2>&1 || fail "fm-send key fixture failed"
  [ ! -s "$log" ] || fail "key path invoked the live-view hook"

  : > "$log"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_NM_LIVE_HELPER="$fakebin/nm-live-hook" \
    FM_HOOK_LOG="$log" "$SEND" missing '$no-mistakes' >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "unresolved task selector was delivered"
  [ ! -s "$log" ] || fail "unresolved task selector invoked the live-view hook"
  pass "fm-send seam: preflight never redelivers, exact empty confirms once, failures cancel, and post-delivery errors never claim unsent"
}

test_app_server_boundary
test_trigger_and_live_lifecycle
test_rejections_rotation_and_quarantine
test_run_attribution_matrix
test_restart_duplicate_and_binding_safety
test_eligibility_axes_and_opt_out
test_fm_send_seam

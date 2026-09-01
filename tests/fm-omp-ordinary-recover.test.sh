#!/usr/bin/env bash
# Deterministic admission, publication, handoff, and cleanup tests for the
# ordinary OMP/Herdr recovery entrypoint.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-omp-ordinary-recover)
RECOVER="$ROOT/bin/fm-omp-ordinary-recover.sh"
TASK_ID=recover-t1
LISTENER_PID=

cleanup() {
  [ -z "$LISTENER_PID" ] || kill -TERM "$LISTENER_PID" 2>/dev/null || true
  [ -z "$LISTENER_PID" ] || wait "$LISTENER_PID" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

make_fake_tools() { # <fixture-dir>
  local dir=$1 fakebin="$1/fakebin" node_bin
  node_bin=$(fm_test_realpath "$(command -v node)")
  mkdir -p "$fakebin"
  ln -s "$node_bin" "$fakebin/bun"
  cat > "$fakebin/omp" <<'JS'
#!/usr/bin/env bun
const args = process.argv.slice(2);
if (args.includes("--help")) {
  console.log("--model=<value>\n--thinking=<value>\n--auto-approve\n--session-dir=<value>\n-e, --extension=<value>\n-r, --resume=<value>");
  process.exit(0);
}
setInterval(() => {}, 1000);
JS
  chmod +x "$fakebin/omp"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = -axo ]; then
  printf '111 1\n'
  exit 0
fi
pid=
field=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -p) pid=$2; shift 2 ;;
    -o) field=$2; shift 2 ;;
    *) shift ;;
  esac
done
if [ "$pid" = 111 ]; then
  case "$field" in stat=) printf 'S\n' ;; *) printf 'bash\n' ;; esac
  exit 0
fi
[ "$pid" = "${FM_NODE_PID:-}" ] || exit 1
case "$field" in
  comm=) printf 'bun\n' ;;
  args=) printf '%s %s --session-dir %s\n' "$FM_NODE_BIN" "$FM_FAKE_OMP" "$FM_FAKE_SESSION_DIR" ;;
  stat=) printf 'S\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
set -u
/bin/mv "$@"
status=$?
[ "$status" -eq 0 ] || exit "$status"
if [ "${FM_FAKE_BREAK_PUBLISH:-0}" = 1 ] && [ "$#" -ge 2 ]; then
  argc=$#
  last=${!argc}
  prev_index=$((argc - 1))
  prev=${!prev_index}
  case "$prev:$last" in
    *.meta-recovery.*:"$FM_FAKE_META") printf 'window=broken\n' >> "$FM_FAKE_META" ;;
  esac
fi
SH
  chmod +x "$fakebin/mv"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
state=${FM_FAKE_HERDR_STATE:?}
log=${FM_FAKE_HERDR_LOG:?}
old_state=${FM_FAKE_OLD_STATE:-dead}
created=0
launched=0
closed=0
[ -f "$state/created" ] && created=1
[ -f "$state/launched" ] && launched=1
[ -f "$state/closed" ] && closed=1
{
  printf '%s' "${HERDR_SESSION:-}"
  for arg in "$@"; do printf '\x1f%s' "$arg"; done
  printf '\n'
} >> "$log"
command=${1:-}
subcommand=${2:-}
json_tabs() {
  if [ "$closed" = 1 ]; then
    if [ "$old_state" != missing ]; then
      printf '{"result":{"tabs":[{"tab_id":"oldtab","label":"fm-%s"}]}}\n' "$FM_FAKE_ID"
    else
      printf '{"result":{"tabs":[]}}\n'
    fi
  elif [ "$created" = 1 ]; then
    if [ "$old_state" != missing ]; then
      printf '{"result":{"tabs":[{"tab_id":"oldtab","label":"fm-%s"},{"tab_id":"newtab","label":"fm-%s"}]}}\n' "$FM_FAKE_ID" "$FM_FAKE_ID"
    else
      printf '{"result":{"tabs":[{"tab_id":"newtab","label":"fm-%s"}]}}\n' "$FM_FAKE_ID"
    fi
  elif [ "$old_state" != missing ]; then
    printf '{"result":{"tabs":[{"tab_id":"oldtab","label":"fm-%s"}]}}\n' "$FM_FAKE_ID"
  else
    printf '{"result":{"tabs":[]}}\n'
  fi
}
json_panes() {
  if [ "$closed" = 1 ]; then
    if [ "$old_state" != missing ]; then
      printf '{"result":{"panes":[{"tab_id":"oldtab","pane_id":"oldpane"}]}}\n'
    else
      printf '{"result":{"panes":[]}}\n'
    fi
  elif [ "$created" = 1 ]; then
    if [ "$old_state" != missing ]; then
      printf '{"result":{"panes":[{"tab_id":"oldtab","pane_id":"oldpane"},{"tab_id":"newtab","pane_id":"newpane"}]}}\n'
    else
      printf '{"result":{"panes":[{"tab_id":"newtab","pane_id":"newpane"}]}}\n'
    fi
  elif [ "$old_state" != missing ]; then
    printf '{"result":{"panes":[{"tab_id":"oldtab","pane_id":"oldpane"}]}}\n'
  else
    printf '{"result":{"panes":[]}}\n'
  fi
}
case "$command $subcommand" in
  "status --json") printf '{"client":{"version":"0.7.5","protocol":14},"server":{"running":true}}\n' ;;
  "session list") printf '{"sessions":[{"name":"s1","running":true,"socket_path":"/tmp/fm-test-herdr-s1.sock"}]}\n' ;;
  "tab list") json_tabs ;;
  "pane list") json_panes ;;
  "pane get")
    pane=${3:-}
    for ((i = 1; i <= $#; i++)); do
      [ "${!i}" != --pane ] || { j=$((i + 1)); pane=${!j}; break; }
    done
    pane=${pane#*:}
    if [ "$pane" = oldpane ] && [ "$old_state" != missing ]; then
      printf '{"result":{"pane":{"pane_id":"oldpane","tab_id":"oldtab","workspace_id":"w1"}}}\n'
    elif [ "$pane" = newpane ] && [ "$created" = 1 ] && [ "$closed" = 0 ]; then
      printf '{"result":{"pane":{"pane_id":"newpane","tab_id":"newtab","workspace_id":"w1"}}}\n'
    else
      printf '{"error":{"code":"pane_not_found"}}\n'
    fi
    ;;
  "agent get")
    pane=
    pane=${3:-}
    for ((i = 1; i <= $#; i++)); do
      [ "${!i}" != --pane ] || { j=$((i + 1)); pane=${!j}; break; }
    done
    pane=${pane#*:}
    if [ "$pane" = oldpane ] && [ "$old_state" = dead ]; then
      printf '{"error":{"code":"agent_not_found"}}\n'
    elif [ "$pane" = oldpane ] && [ "$old_state" = live ]; then
      printf '{"result":{"agent":{"agent_status":"working"}}}\n'
    elif [ "$pane" = oldpane ] && [ "$old_state" = unknown ]; then
      printf '{"result":{"agent":{"agent_status":"surprising"}}}\n'
    elif [ "$pane" = newpane ] && [ "$created" = 1 ] && [ "$closed" = 0 ] && [ "$launched" = 1 ]; then
      printf '{"result":{"agent":{"agent_status":"working"}}}\n'
    elif [ "$pane" = newpane ] && [ "$created" = 1 ] && [ "$closed" = 0 ]; then
      printf '{"error":{"code":"agent_not_found"}}\n'
    else
      printf '{"error":{"code":"pane_not_found"}}\n'
    fi
    ;;
  "tab create")
    [ "${FM_FAKE_CREATE_FAIL:-0}" = 1 ] && exit 1
    : > "$state/created"
    if [ "${FM_FAKE_CREATE_AMBIGUOUS:-0}" = 1 ]; then
      printf '{}\n'
    else
      printf '{"result":{"tab":{"tab_id":"newtab"},"root_pane":{"pane_id":"newpane"}}}\n'
    fi
    ;;
  "pane process-info")
    pane=
    for ((i = 1; i <= $#; i++)); do
      [ "${!i}" != --pane ] || { j=$((i + 1)); pane=${!j}; break; }
    done
    pane=${pane#*:}
    printf 'process-window=%s\n' "$(sed -n 's/^window=//p' "$FM_FAKE_META")" >> "$log"
    if [ "$pane" = newpane ] && [ "$launched" = 1 ]; then
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"newpane","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"pid":%s,"name":"node","argv0":"node"}]}}}\n' "$FM_NODE_PID" "$FM_NODE_PID" "$FM_NODE_PID"
    else
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"newpane","shell_pid":111,"foreground_process_group_id":111,"foreground_processes":[{"pid":111,"name":"bash","argv0":"bash"}]}}}\n'
    fi
    ;;
  "pane run")
    [ "${FM_FAKE_RUN_FAIL:-0}" = 1 ] && exit 1
    printf 'launch-window=%s\n' "$(sed -n 's/^window=//p' "$FM_FAKE_META")" >> "$log"
    if [ "${FM_FAKE_RACE_META:-0}" = 1 ]; then
      printf 'race=external\n' >> "$FM_FAKE_META"
    fi
    : > "$state/launched"
    if [ "${FM_FAKE_NO_READY:-0}" != 1 ]; then
      touch "$FM_FAKE_READY"
      mkdir -p "$FM_FAKE_DOORBELL.requests"
      printf '%s\n' "$FM_NODE_PID" > "$FM_FAKE_DOORBELL"
    fi
    ;;
  "pane close")
    [ "${FM_FAKE_CLOSE_FAIL:-0}" = 1 ] && exit 1
    : > "$state/closed"
    ;;
  "pane send-text"|"pane send-keys") exit 1 ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/herdr"
  printf '%s\n' "$node_bin"
}

make_fixture() { # <name>
  local name=$1 dir node_bin worktree project state tasktmp fake_omp
  dir="$TMP_ROOT/$name"
  project="$dir/project"
  worktree="$dir/worktree"
  state="$dir/home/state"
  tasktmp="$dir/tasktmp"
  mkdir -p "$state/$TASK_ID.inbox/handled" "$tasktmp/gotmp" "$tasktmp/omp-sessions" "$dir/fake-state"
  fm_git_worktree "$project" "$worktree" "fixture-$name"
  printf '{"type":"session","fixture":"%s"}\n' "$name" > "$tasktmp/omp-sessions/retained.jsonl"
  mkdir "$tasktmp/omp-sessions/retained"
  node_bin=$(make_fake_tools "$dir")
  fake_omp=$(fm_test_realpath "$dir/fakebin/omp")
  cat > "$state/$TASK_ID.omp-ext.ts" <<EOF
import { installTaskInboxDoorbell } from "fixture";
const OMP_READY="$state/$TASK_ID.omp-ready";
const OMP_DOORBELL_READY="$state/$TASK_ID.omp-doorbell-ready";
const taskInboxDoorbell = installTaskInboxDoorbell(omp, {
  inboxDir: "$state/$TASK_ID.inbox",
  readyMarker: OMP_DOORBELL_READY,
});
omp.on("session_start", () => touch(OMP_READY));
EOF
  : > "$state/$TASK_ID.omp-ready"
  printf '999\n' > "$state/$TASK_ID.omp-doorbell-ready"
  mkdir -p "$state/$TASK_ID.omp-doorbell-ready.requests"
  fm_write_meta "$state/$TASK_ID.meta" \
    'window=s1:oldpane' "endpoint_task_id=$TASK_ID" "worktree=$worktree" "project=$project" \
    'harness=omp' 'kind=ship' 'mode=no-mistakes' 'yolo=off' "tasktmp=$tasktmp" \
    'model=default' 'effort=low' "omp_bin=$fake_omp" "omp_bun=$node_bin" 'backend=herdr' \
    'herdr_session=s1' 'herdr_workspace_id=w1' 'herdr_tab_id=oldtab' 'herdr_pane_id=oldpane' \
    'branch=feature/recovery' 'validation=owned-run' 'pr=https://example.invalid/pr/87'
  printf '%s\n' "$dir"
}

start_listener() { # <fixture-dir>
  local dir=$1 marker
  marker="$dir/home/state/$TASK_ID.omp-doorbell-ready"
  MARKER="$marker" ACK="$marker.listener-ack" node --input-type=module <<'JS' &
import { readdirSync, renameSync, writeFileSync } from "node:fs";
const marker = process.env.MARKER;
process.on("SIGUSR2", () => {
  const dir = `${marker}.requests`;
  for (const name of readdirSync(dir).filter((entry) => entry.endsWith(".pending"))) {
    renameSync(`${dir}/${name}`, `${dir}/${name}.delivered`);
  }
  writeFileSync(process.env.ACK, "received\n");
});
setInterval(() => {}, 1000);
JS
  LISTENER_PID=$!
}

stop_listener() {
  [ -z "$LISTENER_PID" ] && return
  kill -TERM "$LISTENER_PID" 2>/dev/null || true
  wait "$LISTENER_PID" 2>/dev/null || true
  LISTENER_PID=
}

run_recover() { # <fixture-dir> <arguments...>
  local dir=$1
  shift
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_HERDR_PS_BIN=ps FM_FAKE_HERDR_STATE="$dir/fake-state" FM_FAKE_HERDR_LOG="$dir/herdr.log" \
    FM_FAKE_META="$dir/home/state/$TASK_ID.meta" FM_FAKE_ID="$TASK_ID" FM_FAKE_OMP="$dir/fakebin/omp" \
    FM_FAKE_SESSION_DIR="$dir/tasktmp/omp-sessions" FM_FAKE_READY="$dir/home/state/$TASK_ID.omp-ready" \
    FM_FAKE_DOORBELL="$dir/home/state/$TASK_ID.omp-doorbell-ready" FM_NODE_PID="$LISTENER_PID" \
    FM_NODE_BIN="$(fm_test_realpath "$(command -v node)")" FM_OMP_ORDINARY_RECOVER_READY_POLLS=4 \
    FM_OMP_ORDINARY_RECOVER_READY_INTERVAL=0.01 "$RECOVER" "$@"
}

filtered_metadata() { # <meta>
  grep -Ev '^(window|herdr_session|herdr_workspace_id|herdr_tab_id|herdr_pane_id)=' "$1"
}
test_check_is_read_only_and_requires_one_exact_session() {
  local dir before out status
  dir=$(make_fixture check)
  before=$(cat "$dir/home/state/$TASK_ID.meta")
  LISTENER_PID=77777
  out=$(run_recover "$dir" --check "$TASK_ID" 2>&1)
  status=$?
  expect_code 0 "$status" "detect-only ordinary OMP recovery admission"
  assert_contains "$out" 'checked: recover-t1 endpoint=s1:oldpane state=dead' "check did not report exact recovered endpoint admission"
  [ "$(cat "$dir/home/state/$TASK_ID.meta")" = "$before" ] || fail "check changed task metadata"
  assert_no_grep $'\x1f''tab'$'\x1f''create' "$dir/herdr.log" "check created a replacement endpoint"

  rm -f "$dir/tasktmp/omp-sessions/retained.jsonl"
  out=$(run_recover "$dir" --check "$TASK_ID" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "zero retained sessions passed admission"
  assert_contains "$out" 'does not prove one safe ordinary OMP/Herdr continuation' "zero-session refusal was not explicit"

  printf '{"type":"session"}\n' > "$dir/tasktmp/omp-sessions/a.jsonl"
  printf '{"type":"session"}\n' > "$dir/tasktmp/omp-sessions/b.jsonl"
  out=$(run_recover "$dir" --check "$TASK_ID" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "multiple retained sessions passed admission"
  rm -f "$dir/tasktmp/omp-sessions/a.jsonl" "$dir/tasktmp/omp-sessions/b.jsonl"
  ln -s /etc/hosts "$dir/tasktmp/omp-sessions/escaped.jsonl"
  out=$(run_recover "$dir" --check "$TASK_ID" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "symlinked retained session passed admission"
  pass "ordinary OMP recovery check is read-only and refuses zero, multiple, and escaping sessions"
}

test_check_refuses_live_ambiguous_and_unsupported_inputs() {
  local dir out status
  dir=$(make_fixture refusal)
  LISTENER_PID=77777
  out=$(FM_FAKE_OLD_STATE=live run_recover "$dir" --check "$TASK_ID" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "live endpoint passed recovery admission"
  out=$(FM_FAKE_OLD_STATE=unknown run_recover "$dir" --check "$TASK_ID" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "ambiguous endpoint passed recovery admission"
  sed -i 's/^backend=herdr$/backend=tmux/' "$dir/home/state/$TASK_ID.meta"
  out=$(run_recover "$dir" --check "$TASK_ID" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "unsupported backend passed recovery admission"
  sed -i 's/^backend=tmux$/backend=herdr/' "$dir/home/state/$TASK_ID.meta"
  sed -i 's/^kind=ship$/kind=secondmate/' "$dir/home/state/$TASK_ID.meta"
  out=$(run_recover "$dir" --check "$TASK_ID" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "secondmate metadata passed ordinary recovery admission"
  pass "ordinary OMP recovery check refuses live, ambiguous, unsupported, and non-ordinary inputs"
}

test_recovery_publishes_only_after_fresh_proof_and_hands_off_inbox() {
  local dir before_nonendpoint after_nonendpoint out status
  dir=$(make_fixture success)
  before_nonendpoint=$(filtered_metadata "$dir/home/state/$TASK_ID.meta")
  printf 'schema=fm-task-inbox.v1\nat=fixture\n--\nresume queued task\n' > "$dir/home/state/$TASK_ID.inbox/001.msg"
  start_listener "$dir"
  out=$(run_recover "$dir" "$TASK_ID" 2>&1)
  status=$?
  stop_listener
  [ "$status" = 0 ] || fail "ordinary OMP recovery transaction failed: $out"$'\n'"$(cat "$dir/herdr.log")"
  assert_contains "$out" 'recovered: recover-t1 endpoint=s1:newpane' "recovery did not report replacement endpoint"
  assert_grep 'window=s1:newpane' "$dir/home/state/$TASK_ID.meta" "recovery did not publish replacement window"
  assert_grep 'herdr_tab_id=newtab' "$dir/home/state/$TASK_ID.meta" "recovery did not publish response-derived tab"
  assert_grep 'herdr_pane_id=newpane' "$dir/home/state/$TASK_ID.meta" "recovery did not publish response-derived pane"
  after_nonendpoint=$(filtered_metadata "$dir/home/state/$TASK_ID.meta")
  [ "$after_nonendpoint" = "$before_nonendpoint" ] || fail "recovery changed non-endpoint metadata fields"
  assert_grep 'launch-window=s1:oldpane' "$dir/herdr.log" "replacement pane became metadata owner before launch proof"
  assert_grep 'process-window=s1:newpane' "$dir/herdr.log" "inbox handoff did not occur after replacement metadata publication"
  [ -f "$dir/home/state/$TASK_ID.omp-doorbell-ready.listener-ack" ] \
    || fail "published replacement did not programmatically ring the existing durable inbox"
  pass "ordinary OMP recovery obtains fresh proof, atomically publishes endpoint fields, and rings inbox afterward"
}

test_failures_restore_original_metadata_and_only_retire_new_endpoint() {
  local dir before out status
  dir=$(make_fixture readiness-failure)
  before=$(cat "$dir/home/state/$TASK_ID.meta")
  start_listener "$dir"
  out=$(FM_FAKE_NO_READY=1 run_recover "$dir" "$TASK_ID" 2>&1)
  status=$?
  stop_listener
  [ "$status" -ne 0 ] || fail "missing fresh readiness passed recovery"
  [ "$(cat "$dir/home/state/$TASK_ID.meta")" = "$before" ] || fail "readiness failure changed original metadata"
  [ -f "$dir/fake-state/closed" ] || fail "readiness failure did not retire its proven new endpoint"
  [ "$(cat "$dir/home/state/$TASK_ID.omp-doorbell-ready")" = 999 ] || fail "readiness failure did not restore historical doorbell marker"

  dir=$(make_fixture prelaunch-failure)
  before=$(cat "$dir/home/state/$TASK_ID.meta")
  LISTENER_PID=77777
  out=$(FM_FAKE_CREATE_FAIL=1 run_recover "$dir" "$TASK_ID" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "pre-launch create failure passed recovery"
  [ "$(cat "$dir/home/state/$TASK_ID.meta")" = "$before" ] || fail "pre-launch failure changed original metadata"
  [ ! -e "$dir/fake-state/closed" ] || fail "pre-launch failure closed a non-new endpoint"

  dir=$(make_fixture unprovable-cleanup)
  before=$(cat "$dir/home/state/$TASK_ID.meta")
  start_listener "$dir"
  out=$(FM_FAKE_NO_READY=1 FM_FAKE_CLOSE_FAIL=1 run_recover "$dir" "$TASK_ID" 2>&1)
  status=$?
  stop_listener
  [ "$status" -ne 0 ] || fail "unprovable cleanup passed recovery"
  [ "$(cat "$dir/home/state/$TASK_ID.meta")" = "$before" ] || fail "unprovable cleanup changed original metadata"
  assert_contains "$out" 's1:newpane' "unprovable cleanup did not name retained replacement endpoint"
  pass "ordinary OMP recovery failure preserves original state and retires only proven new endpoints"
}

test_races_and_post_publication_validation_restore_snapshot() {
  local dir before out status
  dir=$(make_fixture race)
  before=$(cat "$dir/home/state/$TASK_ID.meta")
  start_listener "$dir"
  out=$(FM_FAKE_RACE_META=1 run_recover "$dir" "$TASK_ID" 2>&1)
  status=$?
  stop_listener
  [ "$status" -ne 0 ] || fail "concurrent metadata change passed recovery"
  assert_grep 'window=s1:oldpane' "$dir/home/state/$TASK_ID.meta" "race overwrote original endpoint metadata"
  assert_grep 'race=external' "$dir/home/state/$TASK_ID.meta" "recovery discarded concurrent metadata evidence"
  [ -f "$dir/fake-state/closed" ] || fail "race did not retire the proven new endpoint"

  dir=$(make_fixture post-publication)
  before=$(cat "$dir/home/state/$TASK_ID.meta")
  start_listener "$dir"
  out=$(FM_FAKE_BREAK_PUBLISH=1 run_recover "$dir" "$TASK_ID" 2>&1)
  status=$?
  stop_listener
  [ "$status" -ne 0 ] || fail "post-publication validation injection passed recovery"
  [ "$(cat "$dir/home/state/$TASK_ID.meta")" = "$before" ] || fail "post-publication validation failure did not restore metadata snapshot"
  [ -f "$dir/fake-state/closed" ] || fail "post-publication validation failure did not retire new endpoint"
  pass "ordinary OMP recovery refuses metadata races and restores publication failures atomically"
}

test_check_is_read_only_and_requires_one_exact_session
test_check_refuses_live_ambiguous_and_unsupported_inputs
test_recovery_publishes_only_after_fresh_proof_and_hands_off_inbox
test_failures_restore_original_metadata_and_only_retire_new_endpoint
test_races_and_post_publication_validation_restore_snapshot

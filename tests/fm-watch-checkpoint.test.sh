#!/usr/bin/env bash
# Tests for bounded foreground watcher checkpoints used by Codex supervision.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-checkpoint)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

test_quiet_checkpoint_exits_124_cleanly() {
  local home out err status
  home=$(make_home quiet)
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "quiet checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" "quiet checkpoint line missing"
  assert_absent "$home/state/.watch.lock/pid" "watch lock pid survived quiet checkpoint timeout"
  pass "quiet checkpoint exits 124 with a clean checkpoint line and no live lock"
}

test_signal_passes_through_and_exits_zero() {
  local home out err status drained
  home=$(make_home signal)
  out="$home/out.txt"
  err="$home/err.txt"
  (
    sleep 1
    printf 'done: synthetic wake\n' > "$home/state/demo.status"
  ) &
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 8 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "signal checkpoint exit"
  assert_contains "$(cat "$out")" "signal:" "signal wake was not passed through"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" $'\tsignal\tdemo.status\t' "signal wake was not queued durably"
  pass "checkpoint passes through a real watcher wake and leaves the queue for drain"
}

test_registered_check_uses_preserved_watcher_environment() {
  local home out err status
  home=$(make_home check-env)
  out="$home/out.txt"
  err="$home/err.txt"
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
  cat > "$home/state/env-check.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'env check fired with FM_CHECK_INTERVAL=%s\n' "${FM_CHECK_INTERVAL:-missing}"
SH
  chmod 0700 "$home/state/env-check.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" env-check >/dev/null \
    || fail "could not register checkpoint custom check"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "check checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "check wake was not passed through"
  assert_contains "$(cat "$out")" "FM_CHECK_INTERVAL=1" "watcher environment was not preserved"
  pass "checkpoint preserves watcher environment for registered custom checks"
}

test_existing_singleton_watcher_is_not_success() {
  local home out err status
  home=$(make_home singleton)
  out="$home/out.txt"
  err="$home/err.txt"
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$$" > "$home/state/.watch.lock/pid"
  status=0
  FM_HOME="$home" FM_GUARD_GRACE=300 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "singleton checkpoint exit"
  assert_contains "$(cat "$out")" "watcher: already running" "singleton watcher output was not passed through"
  assert_contains "$(cat "$err")" "outside this foreground checkpoint" "singleton watcher failure was not explained"
  pass "checkpoint rejects an existing watcher singleton as unowned"
}

test_linked_child_with_parent_secondmate_home_is_inert() {
  command -v tmux >/dev/null 2>&1 || {
    printf 'skip: tmux not found (linked child checkpoint topology)\n'
    return 0
  }
  local result
  if ! result=$( (
    set -u
    local_home="$TMP_ROOT/linked-secondmate-home"
    local_child="$TMP_ROOT/linked-secondmate-child"
    local_shim="$TMP_ROOT/linked-secondmate-shim"
    local_socket="fm-checkpoint-linked-child-$$"
    local_pane=
    local_status=0
    local_out="$TMP_ROOT/linked-child.out"
    local_err="$TMP_ROOT/linked-child.err"
    local_git_dir=
    local_common_dir=
    # Invoked indirectly by the EXIT and signal traps below.
    # shellcheck disable=SC2329
    cleanup_linked_child() {
      tmux -L "$local_socket" kill-server >/dev/null 2>&1 || true
    }
    trap cleanup_linked_child EXIT INT TERM

    mkdir -p "$local_home" "$local_shim"
    git -C "$ROOT" ls-files -z | (cd "$ROOT" && tar --null --files-from=- -cf -) \
      | tar -C "$local_home" -xf -
    git -C "$local_home" init --quiet
    git -C "$local_home" add -A
    git -C "$local_home" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
      commit --quiet -m fixture
    mkdir -p "$local_home/state"
    printf 'fixture-secondmate\n' > "$local_home/.fm-secondmate-home"
    git -C "$local_home" worktree add --quiet -b "fm/checkpoint-linked-child-$$" "$local_child"
    local_git_dir=$(git -C "$local_child" rev-parse --git-dir)
    local_common_dir=$(git -C "$local_child" rev-parse --git-common-dir)
    [ "$local_git_dir" != "$local_common_dir" ] \
      || { printf 'fixture child is not a linked worktree\n' >&2; exit 1; }
    [ -f "$local_home/.fm-secondmate-home" ] && [ ! -L "$local_home/.fm-secondmate-home" ] \
      || { printf 'fixture parent marker is not genuine\n' >&2; exit 1; }
    [ ! -e "$local_child/.fm-secondmate-home" ] \
      || { printf 'linked child unexpectedly inherited the secondmate marker\n' >&2; exit 1; }

    cat > "$local_shim/tmux" <<SH
#!/usr/bin/env bash
exec "$(command -v tmux)" -L "$local_socket" "\$@"
SH
    chmod +x "$local_shim/tmux"
    "$local_shim/tmux" new-session -d -s linked-child -c "$local_child" -x 180 -y 40
    local_pane=$("$local_shim/tmux" display-message -p -t linked-child '#{pane_id}')
    cat > "$local_home/state/child.meta" <<META
window=$local_pane
kind=ship
mode=local-only
META
    printf 'working: child is running\n' > "$local_home/state/child.status"

    env -u TMUX PATH="$local_shim:$PATH" FM_HOME="$local_home" FM_BACKEND=tmux TMUX_PANE="$local_pane" \
      FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      "$local_child/bin/fm-watch-checkpoint.sh" --seconds 1 >"$local_out" 2>"$local_err" || local_status=$?
    [ "$local_status" -eq 124 ] \
      || { cat "$local_out" "$local_err" >&2; printf 'linked child checkpoint was not a normal no-op\n' >&2; exit 1; }
    [ ! -e "$local_home/state/.self-supervise" ] \
      || { printf 'linked child checkpoint started parent self-supervision\n' >&2; exit 1; }
    [ ! -e "$local_home/state/.self-supervise-target" ] \
      || { printf 'linked child checkpoint retargeted parent self-supervision\n' >&2; exit 1; }
  ) 2>&1); then
    fail "linked child checkpoint using its parent FM_HOME must be inert: $result"
  fi
  pass "checkpoint leaves a genuine secondmate parent untouched from its linked child worktree"
}

test_quiet_checkpoint_exits_124_cleanly
test_signal_passes_through_and_exits_zero
test_registered_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
test_linked_child_with_parent_secondmate_home_is_inert

#!/usr/bin/env bash
# fm-send strict target resolution and key delivery reporting.
#
# A send that cannot be tied to a recorded task/lane or to an explicit
# well-formed backend target must fail loudly. These tests pin the historical
# silent-fallback failures: missing FM_HOME, unresolved selectors, prefixless
# herdr pane ids, dead explicit endpoints, and the healthy exact/fm-id paths.
# They also verify that a key send reports whether delivery actually succeeded.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
CONFIGURATION="$ROOT/docs/configuration.md"
TMP_ROOT=$(fm_test_tmproot fm-send-strict)

make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    printf 'send-keys target=%s literal=%s arg=%s\n' "$target" "$literal" "${1:-}" >> "$FM_TMUX_LOG"
    # FM_FAKE_TMUX_SEND_KEY_FAIL names one key whose delivery fails, so the
    # --key exit contract can be driven both ways from the same stub.
    if [ "$literal" = 0 ] && [ -n "${FM_FAKE_TMUX_SEND_KEY_FAIL:-}" ] \
      && [ "${1:-}" = "$FM_FAKE_TMUX_SEND_KEY_FAIL" ]; then
      exit 1
    fi
    exit 0 ;;
  display-message)
    target=
    cursor=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        *cursor_y*) cursor=1; shift ;;
        *) shift ;;
      esac
    done
    if [ -n "${FM_FAKE_TMUX_DEAD_TARGET:-}" ] && [ "$target" = "$FM_FAKE_TMUX_DEAD_TARGET" ]; then
      exit 1
    fi
    [ "$cursor" = 1 ] && { printf '1\n'; exit 0; }
    printf '%%1\n'
    exit 0 ;;
  capture-pane)
    printf '╭────╮\n│    │\n╰────╯\n'
    exit 0 ;;
  list-windows)
    printf 'foreign:%s\n' "${FM_FAKE_TMUX_WINDOW:-fm-lost}"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_HERDR_LOG"
case "${1:-} ${2:-}" in
  "status --json") printf '{"client":{"version":"0.7.5","protocol":16},"server":{"running":true}}\n' ;;
  "pane get") printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${3:-}" ;;
  "pane send-keys") : ;;
esac
SH
  chmod +x "$fb/herdr"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

setup_home() {  # <name> -> echoes home dir
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

test_exact_lane_id_send_still_works() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/exact"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home exact); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/mpf-lane-m8.meta" "window=sess:fm-mpf-lane-m8" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" mpf-lane-m8 "lost dispatch" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "exact task id send should succeed when metadata exists"
  got=$(cat "$log")
  assert_contains "$got" "target=sess:fm-mpf-lane-m8 literal=1 arg=lost dispatch" "exact id should type literal text to the meta target"
  assert_contains "$got" "target=sess:fm-mpf-lane-m8 literal=0 arg=Enter" "exact id should submit with Enter"
  pass "fm-send strict: exact task/lane ids resolve through home metadata"
}

test_home_argument_selects_task_home_without_ambient_fallback() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/home-argument"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home homearg); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/home-lane.meta" "window=sess:fm-home-lane" "kind=ship"

  env -u FM_HOME PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" --home "$home" home-lane "explicit home" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "--home should select the task home without ambient FM_HOME"
  got=$(cat "$log")
  assert_contains "$got" "target=sess:fm-home-lane literal=1 arg=explicit home" "--home should resolve the selector through its own state"
  assert_contains "$got" "target=sess:fm-home-lane literal=0 arg=Enter" "--home task send should submit with Enter"
  pass "fm-send --home: explicit argument selects the task home without ambient fallback"
}

test_home_argument_rejects_missing_and_unsafe_values() {
  local dir fb home err log rc
  dir="$TMP_ROOT/home-invalid"; mkdir -p "$dir/relative-home/state" "$dir/no-state"
  fb=$(make_stubs "$dir"); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  home=$(setup_home missing-target)

  env -u FM_HOME PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$dir" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" --home >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "--home without a value should fail"
  assert_contains "$(cat "$err")" "--home requires an absolute firstmate home" "missing --home value should be explicit"

  (cd "$dir" && env -u FM_HOME PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$dir" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" --home relative-home sess:win "hello" >/dev/null 2>"$err"); rc=$?
  [ "$rc" -ne 0 ] || fail "relative --home should fail even when the directory exists"
  assert_contains "$(cat "$err")" "must be an absolute path" "relative --home diagnostic should explain the safe shape"

  env -u FM_HOME PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$dir" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" --home --key Enter >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "option-looking --home value should fail"
  assert_contains "$(cat "$err")" "--home requires an absolute firstmate home" "option-looking --home value should be treated as missing"

  env -u FM_HOME PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$dir" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" "--home=$home" sess:win "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "joined --home=value syntax should fail"
  assert_contains "$(cat "$err")" "use '--home <absolute-firstmate-home>'" "joined --home syntax should point to the one supported shape"

  env -u FM_HOME PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$dir" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" --home "$home" --home "$home" sess:win "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "duplicate --home should fail"
  assert_contains "$(cat "$err")" "--home may be provided only once" "duplicate --home diagnostic should be explicit"

  env -u FM_HOME PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$dir" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" --home "$home" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "--home without a target should fail"
  assert_contains "$(cat "$err")" "target is required" "missing target diagnostic should be explicit"

  env -u FM_HOME PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$dir" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" --home "$dir/not-present" sess:win "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "nonexistent --home should fail"
  assert_contains "$(cat "$err")" "is not a directory" "nonexistent --home diagnostic should name the missing directory"

  env -u FM_HOME PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$dir" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" --home "$dir/no-state" sess:win "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "--home without state should fail"
  assert_contains "$(cat "$err")" "state dir '$dir/no-state/state' is missing" "missing state diagnostic should name the selected home"
  [ ! -s "$log" ] || fail "invalid --home still attempted a send"$'\n'"$(cat "$log")"
  pass "fm-send --home: malformed, unsafe, missing, and incomplete homes fail before target resolution"
}

test_home_argument_takes_precedence_over_ambient_home() {
  local dir fb ambient selected err log rc got
  dir="$TMP_ROOT/home-precedence"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ambient=$(setup_home ambient); selected=$(setup_home selected)
  err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$ambient/state/shared.meta" "window=ambient:fm-shared" "kind=ship"
  fm_write_meta "$selected/state/shared.meta" "window=selected:fm-shared" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$ambient" FM_STATE_OVERRIDE="$ambient/state" FM_ROOT_OVERRIDE="$selected" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" --home "$selected" shared "selected home" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "--home should take precedence over ambient FM_HOME"
  got=$(cat "$log")
  assert_contains "$got" "target=selected:fm-shared literal=1 arg=selected home" "--home should resolve through the selected home"
  assert_not_contains "$got" "target=ambient:fm-shared" "ambient FM_HOME or FM_STATE_OVERRIDE must not override --home"
  pass "fm-send --home: argument precedence is explicit and ambient home state cannot redirect the send"
}

test_home_argument_supports_secondmate_home_callers() {
  local dir fb primary second err log rc got
  dir="$TMP_ROOT/home-secondmate"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); primary=$(setup_home primary-caller); second=$(setup_home second-caller)
  err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  printf '%s\n' domain > "$second/.fm-secondmate-home"
  fm_write_meta "$primary/state/child.meta" "window=primary:fm-child" "kind=ship"
  fm_write_meta "$second/state/child.meta" "window=second:fm-child" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$primary" FM_ROOT_OVERRIDE="$second" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" --home "$second" child "secondmate steer" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "a secondmate-shaped home should be accepted by --home"
  got=$(cat "$log")
  assert_contains "$got" "target=second:fm-child literal=1 arg=secondmate steer" "secondmate caller should resolve only its selected child metadata"
  assert_not_contains "$got" "target=primary:fm-child" "secondmate caller must not fall back to the ambient primary home"
  pass "fm-send --home: secondmate-home callers retain home-scoped selector routing"
}

test_help_documents_home_argument_contract() {
  local out err rc configuration
  out="$TMP_ROOT/help.out"; err="$TMP_ROOT/help.err"
  env -u FM_HOME "$SEND" --help >"$out" 2>"$err"; rc=$?
  expect_code 0 "$rc" "--help should not require a home"
  assert_contains "$(cat "$out")" "fm-send.sh --home <absolute-firstmate-home>" "help should show the approval-prefix-shaped invocation"
  assert_contains "$(cat "$out")" "takes precedence over FM_HOME and operational-directory overrides" "help should define argument precedence"
  assert_contains "$(cat "$out")" "never falls back to the repo root" "help should retain the no-ambient-fallback contract"
  configuration=$(cat "$CONFIGURATION")
  assert_contains "$configuration" "See \`bin/fm-send.sh --help\` for the exact argument shape, validation, precedence, and fallback contract." \
    "operator guidance should point exact home mechanics to the helper-owned help"
  assert_not_contains "$configuration" "It must be the first argument" \
    "operator guidance should not duplicate helper-owned home mechanics"
  [ ! -s "$err" ] || fail "--help should not write an error"$'\n'"$(cat "$err")"
  pass "fm-send help: exact home mechanics have one inspectable owner"
}

test_unset_fm_home_fails() {
  local dir fb err log rc
  dir="$TMP_ROOT/nohome"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  env -u FM_HOME PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$dir" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" sess:win "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "unset FM_HOME should fail"
  assert_contains "$(cat "$err")" "FM_HOME is not set" "unset FM_HOME diagnostic should be explicit"
  [ ! -s "$log" ] || fail "unset FM_HOME still attempted a send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unset FM_HOME fails before target resolution"
}

test_unresolvable_target_does_not_tmux_fallback() {
  local dir fb home err log rc
  dir="$TMP_ROOT/unresolved"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home unresolved); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_FAKE_TMUX_WINDOW=lost-target FM_SEND_SETTLE=0 \
    "$SEND" lost-target "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "unresolvable target should fail"
  assert_contains "$(cat "$err")" "not resolvable" "unresolvable diagnostic should be loud"
  assert_contains "$(cat "$err")" "metadata window/terminal lookup" "unresolvable diagnostic should name the attempted lookup"
  assert_contains "$(cat "$err")" "backend=none" "unresolvable diagnostic should name that no backend was assumed"
  [ ! -s "$log" ] || fail "unresolvable target fell through to tmux send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unresolvable selectors do not fall back to tmux"
}

test_prefixless_herdr_pane_id_fails() {
  local dir fb home err log rc
  dir="$TMP_ROOT/herdr-pane"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home herdr); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/nudge.meta" \
    "window=default:wB:p2" "backend=herdr" "herdr_session=default" "herdr_pane_id=wB:p2" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" wB:p2 "nudge" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "prefixless herdr pane id should fail"
  assert_contains "$(cat "$err")" "matches herdr_pane_id" "herdr pane diagnostic should name the meta match"
  assert_contains "$(cat "$err")" "expected <herdr-session>:<pane-id>" "herdr pane diagnostic should show expected shape"
  assert_contains "$(cat "$err")" "default:wB:p2" "herdr pane diagnostic should show the canonical target"
  [ ! -s "$log" ] || fail "prefixless herdr pane id fell through to tmux send"$'\n'"$(cat "$log")"
  pass "fm-send strict: prefixless herdr pane ids are rejected before tmux fallback"
}

test_unmatched_single_colon_target_must_exist() {
  local dir fb home err log rc
  dir="$TMP_ROOT/dead-explicit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home deadexplicit); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_FAKE_TMUX_DEAD_TARGET=sess:missing FM_SEND_SETTLE=0 \
    "$SEND" sess:missing "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "dead explicit tmux-shaped target should fail"
  assert_contains "$(cat "$err")" "not a live tmux endpoint" "dead explicit target diagnostic should name the assumed backend"
  assert_contains "$(cat "$err")" "backend=tmux" "dead explicit target diagnostic should name the tried backend"
  [ ! -s "$log" ] || fail "dead explicit target still attempted a send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unmatched single-colon explicit targets must verify live before sending"
}

test_fm_prefixed_herdr_session_is_an_explicit_target() {
  local dir fb home err log herdr_log rc
  dir="$TMP_ROOT/fm-remote-explicit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home fmremote); err="$dir/send.err"; log="$dir/tmux.log"; herdr_log="$dir/herdr.log"
  : > "$log"
  : > "$herdr_log"

  env -u FM_HOME PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_HERDR_LOG="$herdr_log" FM_SEND_SETTLE=0 \
    "$SEND" --home "$home" fm-remote:w1:p2 --key Enter >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "an fm-prefixed Herdr session target should be accepted with --home"
  assert_grep 'pane get w1:p2 --session fm-remote' "$herdr_log" "fm-prefixed Herdr target was not verified in its session"
  assert_grep 'pane send-keys w1:p2 enter --session fm-remote' "$herdr_log" "fm-prefixed Herdr target was not sent its key in its session"
  assert_no_grep '--session default' "$herdr_log" "fm-prefixed Herdr target fell back to the default session"
  pass "fm-send --home: fm-prefixed Herdr sessions remain explicit backend targets"
}

test_healthy_fm_id_send_still_works() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/healthy"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home healthy); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/lane-ok.meta" "window=sess:fm-lane-ok" "kind=ship" "harness=codex"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" fm-lane-ok "hello captain" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "healthy fm-id send should succeed"
  got=$(cat "$log")
  assert_contains "$got" "target=sess:fm-lane-ok literal=1 arg=hello captain" "healthy send should type literal text to the meta target"
  assert_contains "$got" "target=sess:fm-lane-ok literal=0 arg=Enter" "healthy send should submit with Enter"
  assert_contains "$(cat "$err")" "requested message WILL still be sent" "fm-send guard banner should keep send-specific continuation wording"
  pass "fm-send strict: healthy fm-<id> sends still type once and submit"
}

# A --key send is how firstmate interrupts a worker, so its exit status is the
# only signal that the interrupt actually landed.
# Reporting success for a key that was never delivered would leave supervision
# believing a runaway worker had been stopped, so the failing case must exit
# nonzero and name the key.
# Both directions are asserted from one stub so the failing case cannot go
# quietly vacuous if the key ever stops being delivered at all.
test_key_send_exit_status_follows_delivery() {
  local dir fb home err log rc
  dir="$TMP_ROOT/key-exit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home keyexit); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/lane-key.meta" "window=sess:fm-lane-key" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" lane-key --key Escape >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "a delivered --key interrupt should report success"
  assert_contains "$(cat "$log")" "target=sess:fm-lane-key literal=0 arg=Escape" "the delivered case should send the named key"

  : > "$log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    FM_FAKE_TMUX_SEND_KEY_FAIL=Escape \
    "$SEND" lane-key --key Escape >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "an undelivered --key interrupt reported success"
  assert_contains "$(cat "$err")" "key 'Escape' not sent" "the undelivered case should name the key that failed"
  assert_contains "$(cat "$log")" "target=sess:fm-lane-key literal=0 arg=Escape" "the undelivered case should still have attempted the send"
  pass "fm-send --key: exit status follows delivery, and an undelivered key never reports success"
}

test_exact_lane_id_send_still_works
test_home_argument_selects_task_home_without_ambient_fallback
test_home_argument_rejects_missing_and_unsafe_values
test_home_argument_takes_precedence_over_ambient_home
test_home_argument_supports_secondmate_home_callers
test_help_documents_home_argument_contract
test_key_send_exit_status_follows_delivery
test_unset_fm_home_fails
test_unresolvable_target_does_not_tmux_fallback
test_prefixless_herdr_pane_id_fails
test_unmatched_single_colon_target_must_exist
test_fm_prefixed_herdr_session_is_an_explicit_target
test_healthy_fm_id_send_still_works

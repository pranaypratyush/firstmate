#!/usr/bin/env bash
# Deterministic behavior tests for explicit clean-commit ordinary-worker relaunch.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RELAUNCH="$ROOT/bin/fm-clean-commit-relaunch.sh"
TMP_ROOT=$(fm_test_tmproot fm-clean-commit-relaunch)

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows)
    case "${FM_ENDPOINT_STATE:-missing}" in
      missing) exit 0 ;;
      unreadable) echo 'temporary inventory error' >&2; exit 1 ;;
      *) printf '%s\n' 'fm-source'; exit 0 ;;
    esac
    ;;
  display-message)
    case "$*" in
      *'#{pane_current_path}'*) printf '%s\n' "${FM_DEST_WORKTREE:?}" ;;
      *'#{pane_current_command}'*)
        case "${FM_ENDPOINT_STATE:-missing}" in
          alive) printf '%s\n' codex ;;
          dead) printf '%s\n' bash ;;
          ambiguous) printf '%s\n' strange-process ;;
          *) printf '%s\n' bash ;;
        esac
        ;;
      *) printf '%s\n' firstmate ;;
    esac
    ;;
  has-session|new-session) exit 0 ;;
  new-window)
    [ "${FM_DEST_FAIL:-0}" = 0 ] || exit 1
    [ -z "${FM_EXPECT_HANDOFF:-}" ] || [ -f "$FM_EXPECT_HANDOFF" ] || exit 1
    [ -z "${FM_EXPECT_INBOX:-}" ] || [ -f "$FM_EXPECT_INBOX" ] || exit 1
    sleep "${FM_NEW_WINDOW_DELAY:-0}"
    exit 0
    ;;
  send-keys)
    for arg in "$@"; do
      case "$arg" in
        *'fm-treehouse-get.sh'*' --ready-file '*)
          ready=${arg##* --ready-file }
          printf '%s\n' "${FM_DEST_WORKTREE:?}" > "$ready"
          ;;
      esac
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
  case "${FM_NM_CUSTODY:-none}" in
  active|parked)
    status=running
    [ "${FM_NM_CUSTODY:-none}" = active ] || status=awaiting_approval
    cat <<EOF
id: run-source
branch: fm/source
head: ${FM_SOURCE_COMMIT:?}
status: $status
EOF
    exit 0
    ;;
  unreadable)
    echo 'validation service unavailable' >&2
    exit 2
    ;;
  unknown)
    cat <<EOF
id: run-source
branch: fm/source
head: ${FM_SOURCE_COMMIT:?}
status: gibberish
EOF
    exit 0
    ;;
esac
echo 'no active run' >&2
exit 1
SH
  chmod +x "$fakebin/no-mistakes"
  printf '%s\n' "$fakebin"
}

make_case() {  # <name>
  local name=$1 dir home project source dest fakebin head
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  project="$dir/project"
  source="$dir/source"
  dest="$dir/destination"
  mkdir -p "$home/state" "$home/data/source" "$home/data/dest" "$home/config" "$home/projects"
  fm_git_init_commit "$project"
  git -C "$project" worktree add --quiet -b fm/source "$source"
  git -C "$source" config user.email test@example.invalid
  git -C "$source" config user.name 'Firstmate Test'
  printf 'preserved commit\n' > "$source/committed.txt"
  git -C "$source" add committed.txt
  git -C "$source" commit --quiet -m 'preserved worker commit'
  head=$(git -C "$source" rev-parse HEAD)
  if [ "$name" = same-physical-repository ]; then
    git -C "$project" worktree add --quiet -b pool-destination "$dest"
  else
    git clone --quiet "$project" "$dest"
  fi
  cat > "$home/data/source/brief.md" <<EOF
# source brief
EOF
  cat > "$home/data/dest/brief.md" <<EOF
# destination brief
Delivery contract: mode=no-mistakes
Implement the preserved committed work.

# Acceptance criteria
- AC1: Preserve and continue the committed source work.
EOF
  fm_write_meta "$home/state/source.meta" \
    'window=fm:fm-source' \
    'endpoint_task_id=source' \
    "worktree=$source" \
    "project=$project" \
    'harness=codex' \
    'kind=ship' \
    'mode=no-mistakes' \
    'yolo=off' \
    'tasktmp=/tmp/fm-source' \
    'model=default' \
    'effort=default'
  printf 'working: preserved worker state\n' > "$home/state/source.status"
  printf '{"source":"preserved"}\n' > "$home/data/source/evidence.jsonl"
  fakebin=$(make_fakebin "$dir/fake")
  printf '%s\n' "$dir|$home|$project|$source|$dest|$fakebin|$head"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR SOURCE_DIR DEST_DIR FAKEBIN_DIR SOURCE_HEAD <<EOF
$1
EOF
}

source_snapshot() {
  local out=$1
  {
    find "$HOME_DIR/state" -maxdepth 1 -type f -name 'source.*' -print | sort | xargs sha256sum
    find "$HOME_DIR/data/source" -maxdepth 1 -type f -print | sort | xargs sha256sum
    git -C "$SOURCE_DIR" status --porcelain --untracked-files=all
    git -C "$SOURCE_DIR" rev-parse HEAD 2>/dev/null || printf 'HEAD_UNREADABLE\n'
    git -C "$SOURCE_DIR" symbolic-ref --short HEAD
    git -C "$SOURCE_DIR" for-each-ref --format='%(refname) %(objectname)'
  } > "$out"
}

run_relaunch() {
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_SPAWN_NO_GUARD=1 IS_SANDBOX=1 \
    FM_DEST_WORKTREE="$DEST_DIR" FM_ENDPOINT_STATE="${FM_ENDPOINT_STATE_VALUE:-missing}" \
    FM_DEST_FAIL="${FM_DEST_FAIL_VALUE:-0}" FM_NEW_WINDOW_DELAY="${FM_NEW_WINDOW_DELAY_VALUE:-0}" \
    FM_NM_CUSTODY="${FM_NM_CUSTODY_VALUE:-none}" FM_SOURCE_COMMIT="$SOURCE_HEAD" \
    FM_EXPECT_HANDOFF="$HOME_DIR/data/dest/relaunch-handoff.json" \
    FM_EXPECT_INBOX="$HOME_DIR/state/dest.inbox/001.msg" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$RELAUNCH" "${1:-source}" "${2:-dest}" 2>&1
}

run_destination_spawn() {
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_SPAWN_NO_GUARD=1 IS_SANDBOX=1 \
    FM_DEST_WORKTREE="$DEST_DIR" PATH="$FAKEBIN_DIR:$PATH" \
    "$ROOT/bin/fm-spawn.sh" dest "$PROJECT_DIR" --mode no-mistakes --yolo off \
      --harness codex --backend tmux 2>&1
}

test_clean_committed_unpushed_success_preserves_source() {
  local rec out status
  rec=$(make_case success)
  read_case "$rec"
  source_snapshot "$CASE_DIR/before"
  out=$(run_relaunch)
  status=$?
  source_snapshot "$CASE_DIR/after"
  expect_code 0 "$status" 'clean committed source should relaunch'
  assert_contains "$out" 'relaunched source as dest' 'success did not identify handoff'
  cmp -s "$CASE_DIR/before" "$CASE_DIR/after" || fail 'successful relaunch changed source records or worktree state'
  [ ! -e "$HOME_DIR/state/.spawn-source.lock" ] || fail 'successful relaunch retained source serialization lock'
  [ "$(git -C "$DEST_DIR" rev-parse HEAD)" = "$SOURCE_HEAD" ] || fail 'destination did not start at exact source commit'
  [ "$(git -C "$DEST_DIR" symbolic-ref --short HEAD)" = fm/relaunch-dest ] || fail 'destination seed branch is missing or wrong'
  assert_grep "worktree=$DEST_DIR" "$HOME_DIR/state/dest.meta" 'normal spawn did not create destination task record'
  jq -e --arg head "$SOURCE_HEAD" '.source == "source" and .destination == "dest" and .source_commit == $head and .source_branch == "fm/source" and .delivery.mode == "no-mistakes" and .delivery.yolo == "off"' \
    "$HOME_DIR/data/dest/relaunch-handoff.json" >/dev/null || fail 'handoff did not bind preserved source identity'
  [ -f "$HOME_DIR/state/dest.inbox/001.msg" ] || fail 'destination did not receive its pre-spawn handoff inbox record'
  pass 'clean unpushed commit relaunches through a fresh destination while preserving the source'
}

test_dirty_staged_untracked_and_git_operation_refuse() {
  local kind rec out status operation
  for kind in dirty staged untracked operation operation-symlink; do
    rec=$(make_case "refuse-$kind")
    read_case "$rec"
    case "$kind" in
      dirty) printf 'dirty\n' >> "$SOURCE_DIR/README.md" ;;
      staged) printf 'staged\n' > "$SOURCE_DIR/staged.txt"; git -C "$SOURCE_DIR" add staged.txt ;;
      untracked) printf 'untracked\n' > "$SOURCE_DIR/untracked.txt" ;;
      operation)
        operation=$(git -C "$SOURCE_DIR" rev-parse --git-path rebase-merge)
        mkdir -p "$operation"
        ;;
      operation-symlink)
        operation=$(git -C "$SOURCE_DIR" rev-parse --git-path MERGE_HEAD)
        ln -s /dev/null "$operation"
        ;;
    esac
    source_snapshot "$CASE_DIR/before"
    out=$(run_relaunch)
    status=$?
    source_snapshot "$CASE_DIR/after"
    [ "$status" -ne 0 ] || fail "$kind source unexpectedly relaunched"
    cmp -s "$CASE_DIR/before" "$CASE_DIR/after" || fail "$kind refusal changed source state"
    [ ! -e "$HOME_DIR/state/dest.meta" ] || fail "$kind refusal allocated destination task state"
  done
  pass 'dirty, staged, untracked, and in-progress Git sources refuse without source mutation'
}

test_every_nonmissing_endpoint_verdict_refuses() {
  local verdict rec out status
  for verdict in alive dead ambiguous unreadable; do
    rec=$(make_case "endpoint-$verdict")
    read_case "$rec"
    source_snapshot "$CASE_DIR/before"
    FM_ENDPOINT_STATE_VALUE=$verdict out=$(run_relaunch)
    status=$?
    source_snapshot "$CASE_DIR/after"
    [ "$status" -ne 0 ] || fail "$verdict endpoint unexpectedly relaunched"
    cmp -s "$CASE_DIR/before" "$CASE_DIR/after" || fail "$verdict endpoint refusal changed source state"
    [ ! -e "$HOME_DIR/state/dest.meta" ] || fail "$verdict endpoint allocated a destination"
  done
  pass 'only an authoritatively missing endpoint admits relaunch'
}

test_collisions_and_repository_mismatch_refuse() {
  local rec out status foreign
  rec=$(make_case source-equals)
  read_case "$rec"
  source_snapshot "$CASE_DIR/before"
  out=$(run_relaunch source source)
  status=$?
  source_snapshot "$CASE_DIR/after"
  [ "$status" -ne 0 ] || fail 'source equals destination unexpectedly relaunched'
  cmp -s "$CASE_DIR/before" "$CASE_DIR/after" || fail 'source-equals refusal changed source state'

  rec=$(make_case destination-exists)
  read_case "$rec"
  : > "$HOME_DIR/state/dest.meta"
  FM_ENDPOINT_STATE_VALUE=missing out=$(run_relaunch)
  status=$?
  [ "$status" -ne 0 ] || fail 'existing destination unexpectedly relaunched'

  rec=$(make_case repository-mismatch)
  read_case "$rec"
  foreign="$CASE_DIR/foreign"
  fm_git_init_commit "$foreign"
  sed -i "s|^project=.*|project=$foreign|" "$HOME_DIR/state/source.meta"
  source_snapshot "$CASE_DIR/before"
  out=$(run_relaunch)
  status=$?
  source_snapshot "$CASE_DIR/after"
  [ "$status" -ne 0 ] || fail 'repository mismatch unexpectedly relaunched'
  cmp -s "$CASE_DIR/before" "$CASE_DIR/after" || fail 'repository mismatch changed source state'
  pass 'source/destination collisions and repository mismatch refuse before allocation'
}

test_destination_physical_repository_collision_refuses() {
  local rec out status
  rec=$(make_case same-physical-repository)
  read_case "$rec"
  source_snapshot "$CASE_DIR/before"
  FM_ENDPOINT_STATE_VALUE=missing out=$(run_relaunch)
  status=$?
  source_snapshot "$CASE_DIR/after"
  [ "$status" -ne 0 ] || fail 'same physical destination repository unexpectedly relaunched'
  cmp -s "$CASE_DIR/before" "$CASE_DIR/after" || fail 'same physical destination repository changed source state'
  [ ! -e "$HOME_DIR/state/dest.meta" ] || fail 'same physical destination repository allocated destination state'
  pass 'a destination sharing the source physical repository refuses before a new ref is created'
}

test_nonship_crosshome_and_identity_sources_refuse() {
  local shape rec out status
  for shape in scout secondmate crosshome identity malformed; do
    rec=$(make_case "source-$shape")
    read_case "$rec"
    case "$shape" in
      scout) sed -i 's/^kind=ship$/kind=scout/' "$HOME_DIR/state/source.meta" ;;
      secondmate) sed -i 's/^kind=ship$/kind=secondmate/' "$HOME_DIR/state/source.meta"; printf 'home=/foreign/home\n' >> "$HOME_DIR/state/source.meta" ;;
      crosshome) printf 'home=/foreign/home\n' >> "$HOME_DIR/state/source.meta" ;;
      identity) sed -i 's/^endpoint_task_id=source$/endpoint_task_id=another-task/' "$HOME_DIR/state/source.meta" ;;
      malformed) sed -i '/^harness=/d' "$HOME_DIR/state/source.meta" ;;
    esac
    source_snapshot "$CASE_DIR/before"
    FM_ENDPOINT_STATE_VALUE=missing out=$(run_relaunch)
    status=$?
    source_snapshot "$CASE_DIR/after"
    [ "$status" -ne 0 ] || fail "$shape source unexpectedly relaunched"
    cmp -s "$CASE_DIR/before" "$CASE_DIR/after" || fail "$shape source refusal changed source state"
    [ ! -e "$HOME_DIR/state/dest.meta" ] || fail "$shape source allocated destination state"
  done
  pass 'scout, secondmate, cross-home, malformed, and identity-mismatched sources refuse before allocation'
}

test_missing_source_branch_commit_refuses() {
  local rec out status
  rec=$(make_case missing-source-branch-commit)
  read_case "$rec"
  git -C "$SOURCE_DIR" update-ref -d refs/heads/fm/source
  source_snapshot "$CASE_DIR/before"
  FM_ENDPOINT_STATE_VALUE=missing out=$(run_relaunch)
  status=$?
  source_snapshot "$CASE_DIR/after"
  [ "$status" -ne 0 ] || fail 'source without a reachable branch commit unexpectedly relaunched'
  cmp -s "$CASE_DIR/before" "$CASE_DIR/after" || fail 'missing source branch commit refusal changed source state'
  [ ! -e "$HOME_DIR/state/dest.meta" ] || fail 'missing source branch commit allocated a destination'
  pass 'a source whose branch no longer reaches its exact HEAD refuses without mutation'
}

test_validation_custody_handoff_holds_destination() {
  local custody rec out status
  for custody in active parked; do
    rec=$(make_case "${custody}-validation")
    read_case "$rec"
    FM_ENDPOINT_STATE_VALUE=missing FM_NM_CUSTODY_VALUE=$custody out=$(run_relaunch)
    status=$?
    expect_code 0 "$status" "$custody validation source should relaunch onto a separate destination"
    assert_grep '<!-- fm-clean-commit-relaunch-custody-hold -->' "$HOME_DIR/data/dest/brief.md" \
      "$custody validation did not place destination custody hold in its brief"
    jq -e --arg custody "$custody" '.no_mistakes_custody.state == $custody and .no_mistakes_custody.run_id == "run-source" and .no_mistakes_custody.next_action == "firstmate-custody-decision-required"' \
      "$HOME_DIR/data/dest/relaunch-handoff.json" >/dev/null || fail "$custody validation custody was not structurally preserved"
  done
  pass 'active and parked no-mistakes custody is preserved and holds destination code mutation'
}

test_unreadable_validation_custody_refuses() {
  local custody rec out status
  for custody in unreadable unknown; do
    rec=$(make_case "$custody-validation")
    read_case "$rec"
    source_snapshot "$CASE_DIR/before"
    FM_ENDPOINT_STATE_VALUE=missing FM_NM_CUSTODY_VALUE=$custody out=$(run_relaunch)
    status=$?
    source_snapshot "$CASE_DIR/after"
    [ "$status" -ne 0 ] || fail "$custody validation custody unexpectedly relaunched"
    cmp -s "$CASE_DIR/before" "$CASE_DIR/after" || fail "$custody validation custody changed source state"
    [ ! -e "$HOME_DIR/state/dest.meta" ] || fail "$custody validation custody allocated a destination"
  done
  pass 'unreadable and unclassifiable no-mistakes custody refuse without source mutation'
}

test_missing_or_symlinked_source_brief_refuses() {
  local shape rec out status
  for shape in missing symlink; do
    rec=$(make_case "source-brief-$shape")
    read_case "$rec"
    case "$shape" in
      missing) rm "$HOME_DIR/data/source/brief.md" ;;
      symlink) rm "$HOME_DIR/data/source/brief.md"; ln -s /dev/null "$HOME_DIR/data/source/brief.md" ;;
    esac
    source_snapshot "$CASE_DIR/before"
    FM_ENDPOINT_STATE_VALUE=missing out=$(run_relaunch)
    status=$?
    source_snapshot "$CASE_DIR/after"
    [ "$status" -ne 0 ] || fail "$shape source brief unexpectedly relaunched"
    cmp -s "$CASE_DIR/before" "$CASE_DIR/after" || fail "$shape source brief refusal changed source state"
    [ ! -e "$HOME_DIR/state/dest.meta" ] || fail "$shape source brief allocated a destination"
  done
  pass 'missing and symlinked source briefs refuse without source mutation'
}

test_destination_failure_and_concurrent_admission_preserve_source() {
  local rec out status first second ordinary
  rec=$(make_case destination-failure)
  read_case "$rec"
  source_snapshot "$CASE_DIR/before"
  FM_ENDPOINT_STATE_VALUE=missing FM_DEST_FAIL_VALUE=1 out=$(run_relaunch)
  status=$?
  source_snapshot "$CASE_DIR/after"
  [ "$status" -ne 0 ] || fail 'destination spawn failure unexpectedly succeeded'
  cmp -s "$CASE_DIR/before" "$CASE_DIR/after" || fail 'destination failure changed source state'

  rec=$(make_case concurrent)
  read_case "$rec"
  FM_ENDPOINT_STATE_VALUE=missing FM_DEST_FAIL_VALUE=0 FM_NEW_WINDOW_DELAY_VALUE=2 FM_NM_CUSTODY_VALUE=none run_relaunch > "$CASE_DIR/first.out" 2>&1 &
  first=$!
  sleep 0.2
  ordinary=$(run_destination_spawn)
  status=$?
  [ "$status" -ne 0 ] || fail 'ordinary destination spawn bypassed relaunch reservation'
  assert_contains "$ordinary" 'another spawn is already creating task dest' \
    'ordinary destination spawn did not observe the relaunch reservation'
  FM_ENDPOINT_STATE_VALUE=missing FM_DEST_FAIL_VALUE=0 FM_NEW_WINDOW_DELAY_VALUE=0 second=$(run_relaunch)
  status=$?
  if ! wait "$first"; then
    sed -n '1,120p' "$CASE_DIR/first.out" >&2
    fail 'first concurrent relaunch should finish successfully'
  fi
  [ "$status" -ne 0 ] || fail 'second concurrent relaunch bypassed source serialization'
  assert_contains "$second" 'source task source is busy' 'concurrent refusal did not name source serialization'
  pass 'destination failures and concurrent admission preserve source ownership'
}

test_clean_committed_unpushed_success_preserves_source
test_dirty_staged_untracked_and_git_operation_refuse
test_every_nonmissing_endpoint_verdict_refuses
test_collisions_and_repository_mismatch_refuse
test_destination_physical_repository_collision_refuses
test_nonship_crosshome_and_identity_sources_refuse
test_missing_source_branch_commit_refuses
test_validation_custody_handoff_holds_destination
test_unreadable_validation_custody_refuses
test_missing_or_symlinked_source_brief_refuses
test_destination_failure_and_concurrent_admission_preserve_source

echo '# all fm-clean-commit-relaunch tests passed'

#!/usr/bin/env bash
# Interface-level regressions for adopting a pre-existing Git worktree through
# bin/fm-spawn.sh --existing-worktree and preserving it through teardown.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-existing-worktree)
REAL_GIT=$(command -v git)
fm_git_identity fmtest fmtest@example.invalid

make_fakebin() {
  local root=$1 fakebin
  fakebin=$(fm_fakebin "$root")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_ADOPT_TMUX_LOG:-}" ] || printf 'tmux %s\n' "$*" >> "$FM_ADOPT_TMUX_LOG"
case "$*" in
  display-message*"#{pid}:#{start_time}"*)
    printf '%s\n' "${FM_ADOPT_SERVER_IDENTITY:-4242:123456}"
    exit 0
    ;;
  display-message*"#{window_id}"*)
    case "$*" in
      *"-t %1"*) printf '%s\n' @1 ;;
      *"-t %777"*) printf '%s\n' "${FM_ADOPT_LIVE_WINDOW_ID:-@777}" ;;
      *)
        [ -n "${FM_ADOPT_WINDOW_STATE:-}" ] && [ -s "$FM_ADOPT_WINDOW_STATE" ] || exit 1
        printf '%s\n' @123
        ;;
    esac
    exit 0
    ;;
  *"#{session_name}"*)
    case "$*" in
      *"-t %777"*) printf '%s\n' "${FM_ADOPT_LIVE_SESSION:-firstmate}" ;;
      *) printf '%s\n' firstmate ;;
    esac
    exit 0
    ;;
  *"#{window_name}"*)
    case "$*" in
      *"-t %1"*) printf '%s\n' firstmate ;;
      *)
        if [ -n "${FM_ADOPT_WINDOW_STATE:-}" ] && [ -s "$FM_ADOPT_WINDOW_STATE" ]; then
          sed -n '1p' "$FM_ADOPT_WINDOW_STATE"
        fi
        ;;
    esac
    exit 0
    ;;
  *"#{pane_current_path}"*)
    case "$*" in
      *"-t %1"*) printf '%s\n' "${FM_ADOPT_BASE_PANE_PATH:-${FM_FAKE_PANE_PATH:-}}" ;;
      *"-t %777"*|*"-t @777"*) printf '%s\n' "${FM_ADOPT_LIVE_PANE_PATH:-${FM_FAKE_PANE_PATH:-}}" ;;
      *) printf '%s\n' "${FM_FAKE_PANE_PATH:-}" ;;
    esac
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf '%s\n' firstmate ;;
  list-windows)
    case "$*" in
      *"#{window_id}"*"#{window_panes}"*)
        [ "${FM_ADOPT_INVENTORY_ERROR:-0}" != 1 ] || exit 2
        printf '@1|firstmate|1\n'
        if [ -n "${FM_ADOPT_WINDOW_STATE:-}" ] && [ -s "$FM_ADOPT_WINDOW_STATE" ]; then
          [ "${FM_ADOPT_LIVE_SESSION:-firstmate}" = firstmate ] || exit 0
          while IFS= read -r listed_window; do
            [ -n "$listed_window" ] || continue
            printf '@777|%s|1\n' "$listed_window"
          done < "$FM_ADOPT_WINDOW_STATE"
        fi
        ;;
      *)
        [ -z "${FM_ADOPT_WINDOW_STATE:-}" ] || [ ! -s "$FM_ADOPT_WINDOW_STATE" ] || cat "$FM_ADOPT_WINDOW_STATE"
        ;;
    esac
    ;;
  list-panes)
    [ "${FM_ADOPT_INVENTORY_ERROR:-0}" != 1 ] || exit 2
    case "$*" in
      *"-t @123"*) printf '%%777\n' ;;
      *)
        printf '%%1\n'
        if [ -n "${FM_ADOPT_WINDOW_STATE:-}" ] && [ -s "$FM_ADOPT_WINDOW_STATE" ]; then
          printf '%%777\n'
        fi
        ;;
    esac
    ;;
  new-window)
    window=
    while [ "$#" -gt 0 ]; do
      if [ "$1" = -n ]; then window=${2:-}; break; fi
      shift
    done
    [ -z "${FM_ADOPT_WINDOW_STATE:-}" ] || printf '%s\n' "$window" > "$FM_ADOPT_WINDOW_STATE"
    printf '%s\n' @123
    ;;
  kill-window)
    [ "${FM_ADOPT_FAIL_KILL:-0}" != 1 ] || exit 1
    case "$*" in
      *'-t @123'*) ;;
      *) [ "${FM_ADOPT_NAME_KILL_FAIL:-0}" != 1 ] || exit 1 ;;
    esac
    [ -z "${FM_ADOPT_WINDOW_STATE:-}" ] || : > "$FM_ADOPT_WINDOW_STATE"
    ;;
  send-keys)
    if [ -n "${FM_ADOPT_SEND_COUNT:-}" ]; then
      count=0
      [ ! -s "$FM_ADOPT_SEND_COUNT" ] || count=$(cat "$FM_ADOPT_SEND_COUNT")
      count=$((count + 1))
      printf '%s\n' "$count" > "$FM_ADOPT_SEND_COUNT"
      [ "$count" != "${FM_ADOPT_FAIL_SEND_AT:-0}" ] || exit 1
    fi
    ;;
  *) : ;;
esac
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_ADOPT_TREEHOUSE_LOG:-}" ] || printf 'treehouse %s\n' "$*" >> "$FM_ADOPT_TREEHOUSE_LOG"
exit 0
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  for harness in pi pi-signed muse; do
    cat > "$fakebin/$harness" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  done
  chmod +x "$fakebin/tmux" "$fakebin/treehouse" "$fakebin/no-mistakes" \
    "$fakebin/pi" "$fakebin/pi-signed" "$fakebin/muse"
  printf '%s\n' "$fakebin"
}

setup_case() {  # <name> <task-id> <ship|scout>
  local name=$1 id=$2 kind=$3
  CASE="$TMP_ROOT/$name"
  HOME_DIR="$CASE/home"
  PROJ="$CASE/project"
  WT="$CASE/adopted-wt"
  TLOG="$CASE/tmux.log"
  TREELOG="$CASE/treehouse.log"
  WINDOW_STATE="$CASE/window.state"
  SEND_COUNT="$CASE/send.count"
  FAKEBIN=$(make_fakebin "$CASE/fakes")
  mkdir -p "$HOME_DIR/data/$id" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects"
  : > "$TLOG"
  : > "$TREELOG"
  : > "$WINDOW_STATE"
  : > "$SEND_COUNT"
  git init -q -b main "$PROJ"
  printf '%s\n' baseline > "$PROJ/base.txt"
  git -C "$PROJ" add base.txt
  git -C "$PROJ" commit -q -m baseline
  git -C "$PROJ" worktree add -q -b "recovered/$id" "$WT" main
  if [ "$kind" = ship ]; then
    printf '%s\n' 'Delivery contract: mode=local-only' > "$HOME_DIR/data/$id/brief.md"
  else
    printf '%s\n' 'scout brief' > "$HOME_DIR/data/$id/brief.md"
  fi
}

run_spawn_command() {
  local task_home=${FM_ADOPT_TASK_HOME:-$HOME_DIR}
  FM_ROOT_OVERRIDE='' FM_HOME="$task_home" \
    FM_STATE_OVERRIDE="$task_home/state" FM_DATA_OVERRIDE="$task_home/data" \
    FM_PROJECTS_OVERRIDE="$task_home/projects" FM_CONFIG_OVERRIDE="$task_home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' FM_FAKE_PANE_PATH="${FM_FAKE_PANE_PATH:-$WT}" \
    FM_ADOPT_TMUX_LOG="$TLOG" FM_ADOPT_TREEHOUSE_LOG="$TREELOG" \
    FM_ADOPT_WINDOW_STATE="$WINDOW_STATE" FM_ADOPT_SEND_COUNT="$SEND_COUNT" \
    FM_ADOPT_FAIL_SEND_AT="${FM_ADOPT_FAIL_SEND_AT:-0}" \
    FM_ADOPT_FAIL_KILL="${FM_ADOPT_FAIL_KILL:-0}" \
    FM_ADOPT_INVENTORY_ERROR="${FM_ADOPT_INVENTORY_ERROR:-0}" \
    FM_ADOPT_LIVE_PANE_PATH="${FM_ADOPT_LIVE_PANE_PATH:-}" \
    FM_ADOPT_LIVE_SESSION="${FM_ADOPT_LIVE_SESSION:-firstmate}" \
    FM_ADOPT_LIVE_WINDOW_ID="${FM_ADOPT_LIVE_WINDOW_ID:-@777}" \
    FM_ADOPT_SERVER_IDENTITY="${FM_ADOPT_SERVER_IDENTITY:-4242:123456}" \
    FM_ADOPT_BASE_PANE_PATH="${FM_ADOPT_BASE_PANE_PATH:-$PROJ}" \
    FM_ADOPT_GIT_COUNT="${FM_ADOPT_GIT_COUNT:-}" FM_ADOPT_GIT_MUTATE_AT="${FM_ADOPT_GIT_MUTATE_AT:-0}" \
    FM_ADOPT_MUTATE_WT="${FM_ADOPT_MUTATE_WT:-}" FM_ADOPT_REAL_GIT="$REAL_GIT" \
    PATH="$FAKEBIN:$PATH" \
    "$SPAWN" "$@" 2>&1
}

run_spawn() {  # <id> <ship|scout> <existing-path> [extra args...]
  local id=$1 kind=$2 existing=$3
  shift 3
  local project_arg=${FM_ADOPT_PROJECT_ARG:-$PROJ}
  local -a args
  args=("$id" "$project_arg" --harness codex --backend tmux --existing-worktree "$existing")
  if [ "$kind" = scout ]; then
    args+=(--scout)
  else
    args+=(--mode local-only --yolo off)
  fi
  run_spawn_command "${args[@]}" "$@"
}

run_teardown() {
  local task_home=${FM_ADOPT_TASK_HOME:-$HOME_DIR}
  FM_ROOT_OVERRIDE='' FM_HOME="$task_home" \
    FM_STATE_OVERRIDE="$task_home/state" FM_DATA_OVERRIDE="$task_home/data" \
    FM_PROJECTS_OVERRIDE="$task_home/projects" FM_CONFIG_OVERRIDE="$task_home/config" \
    FM_TEARDOWN_GUARD_DONE=1 FM_ADOPT_TMUX_LOG="$TLOG" \
    FM_ADOPT_TREEHOUSE_LOG="$TREELOG" FM_ADOPT_WINDOW_STATE="$WINDOW_STATE" \
    FM_FAKE_PANE_PATH="${FM_ADOPT_FAKE_PANE_PATH:-$WT}" \
    FM_ADOPT_NAME_KILL_FAIL="${FM_ADOPT_NAME_KILL_FAIL:-0}" \
    FM_ADOPT_SEND_COUNT="$SEND_COUNT" PATH="$FAKEBIN:$PATH" \
    "$TEARDOWN" "$@" 2>&1
}

assert_no_endpoint_created() {
  assert_no_grep 'tmux new-window ' "$TLOG" "refused adoption created an endpoint"
}

test_safe_ship_adoption_preserves_git_state() {
  local id=adopt-safe-ship-a1 out status branch head index_before index_after
  setup_case safe-ship "$id" ship
  printf '%s\n' staged > "$WT/staged.txt"
  git -C "$WT" add staged.txt
  printf '%s\n' modified >> "$WT/base.txt"
  printf '%s\n' untracked > "$WT/untracked.txt"
  branch=$(git -C "$WT" symbolic-ref --short HEAD)
  head=$(git -C "$WT" rev-parse HEAD)
  index_before=$(git -C "$WT" ls-files --stage)

  out=$(run_spawn "$id" ship "$WT")
  status=$?
  expect_code 0 "$status" "safe adopted ship should spawn"
  assert_contains "$out" "spawned $id" "safe adopted ship did not report success"
  assert_grep "worktree=$WT" "$HOME_DIR/state/$id.meta" "meta omitted exact adopted path"
  assert_grep 'worktree_ownership=adopted' "$HOME_DIR/state/$id.meta" "meta omitted adopted ownership"
  assert_grep "adopted_branch=$branch" "$HOME_DIR/state/$id.meta" "meta omitted intake branch"
  assert_grep "adopted_head=$head" "$HOME_DIR/state/$id.meta" "meta omitted intake HEAD"
  assert_grep '# Adopted worktree setup override' "$HOME_DIR/state/$id.adopted-brief.md" "spawn did not generate the adopted setup contract"
  assert_grep 'Do not create, checkout, or switch branches' "$HOME_DIR/state/$id.adopted-brief.md" "adopted setup does not forbid branch changes"
  assert_grep "expected_path='$WT'" "$HOME_DIR/state/$id.adopted-brief.md" "adopted setup omitted exact path verification"
  assert_grep "expected_branch='$branch'" "$HOME_DIR/state/$id.adopted-brief.md" "adopted setup omitted exact branch verification"
  assert_grep "expected_head='$head'" "$HOME_DIR/state/$id.adopted-brief.md" "adopted setup omitted exact HEAD verification"
  assert_grep "-c $WT" "$TLOG" "tmux endpoint did not start in the adopted worktree"
  assert_no_grep 'treehouse ' "$TREELOG" "safe adoption invoked Treehouse"
  [ "$(git -C "$WT" symbolic-ref --short HEAD)" = "$branch" ] || fail "spawn switched the adopted branch"
  [ "$(git -C "$WT" rev-parse HEAD)" = "$head" ] || fail "spawn changed adopted HEAD"
  index_after=$(git -C "$WT" ls-files --stage)
  [ "$index_after" = "$index_before" ] || fail "spawn changed the adopted index"
  [ "$(tail -n 1 "$WT/base.txt")" = modified ] || fail "spawn changed an existing working-tree edit"
  [ "$(cat "$WT/untracked.txt")" = untracked ] || fail "spawn changed an untracked file"
  pass "fm-spawn adopts a named-branch ship and preserves branch, HEAD, index, and working files"
}

test_safe_scout_adoption_has_non_discard_contract() {
  local id=adopt-safe-scout-b2 out status
  setup_case safe-scout "$id" scout
  out=$(run_spawn "$id" scout "$WT")
  status=$?
  expect_code 0 "$status" "safe adopted scout should spawn"
  assert_grep 'kind=scout' "$HOME_DIR/state/$id.meta" "adopted scout metadata lost scout kind"
  assert_grep 'scratch work in the adopted worktree is not automatically discarded' "$HOME_DIR/state/$id.adopted-brief.md" "adopted scout brief still implies teardown discard"
  assert_no_grep 'treehouse ' "$TREELOG" "adopted scout invoked Treehouse"
  pass "fm-spawn preserves scout semantics while explicitly retaining adopted scratch state"
}

test_input_and_ownership_refusals_precede_endpoint() {
  local id out status foreign foreign_wt symlink

  id=adopt-relative-c3
  setup_case relative "$id" ship
  out=$(run_spawn "$id" ship 'relative/worktree'); status=$?
  expect_code 1 "$status" "relative adoption path should refuse"
  assert_contains "$out" 'requires an exact absolute path' "relative refusal was not explicit"
  assert_no_endpoint_created

  id=adopt-subdir-d4
  setup_case subdir "$id" ship
  mkdir -p "$WT/sub"
  out=$(run_spawn "$id" ship "$WT/sub"); status=$?
  expect_code 1 "$status" "worktree subdirectory should refuse"
  assert_contains "$out" 'did not yield an isolated worktree' "subdirectory refusal lacked root evidence"
  assert_no_endpoint_created

  id=adopt-primary-e5
  setup_case primary "$id" ship
  out=$(run_spawn "$id" ship "$PROJ"); status=$?
  expect_code 1 "$status" "primary checkout should refuse"
  assert_contains "$out" 'did not yield an isolated worktree' "primary refusal lacked isolation evidence"
  assert_no_endpoint_created

  id=adopt-foreign-f6
  setup_case foreign "$id" ship
  foreign="$CASE/foreign"
  foreign_wt="$CASE/foreign-wt"
  git init -q -b main "$foreign"
  git -C "$foreign" commit -q --allow-empty -m baseline
  git -C "$foreign" worktree add -q -b foreign/adopt "$foreign_wt" main
  out=$(run_spawn "$id" ship "$foreign_wt"); status=$?
  expect_code 1 "$status" "foreign common directory should refuse"
  assert_contains "$out" "does not belong to the requested project's Git common directory" "foreign-repo refusal lacked common-directory evidence"
  assert_no_endpoint_created

  id=adopt-symlink-g7
  setup_case symlink "$id" ship
  symlink="$CASE/adopted-link"
  ln -s "$WT" "$symlink"
  out=$(run_spawn "$id" ship "$symlink"); status=$?
  expect_code 1 "$status" "non-physical symlink spelling should refuse"
  assert_contains "$out" 'must use the exact physical worktree path' "symlink refusal did not name the exact path contract"
  assert_no_endpoint_created

  id=adopt-claimed-h8
  setup_case claimed "$id" ship
  fm_write_meta "$HOME_DIR/state/other-task.meta" "worktree=$WT"
  out=$(run_spawn "$id" ship "$WT"); status=$?
  expect_code 1 "$status" "durably claimed worktree should refuse"
  assert_contains "$out" 'already claimed by durable task other-task' "claim refusal did not name the owner"
  assert_no_endpoint_created

  id=adopt-detached-i9
  setup_case detached "$id" ship
  git -C "$WT" checkout -q --detach
  out=$(run_spawn "$id" ship "$WT"); status=$?
  expect_code 1 "$status" "detached adoption should refuse"
  assert_contains "$out" 'requires a named current branch' "detached refusal did not name the branch requirement"
  assert_no_endpoint_created

  id=adopt-project-newline-j0
  setup_case project-newline "$id" ship
  local newline_project="$CASE/project"$'\n''unsafe' newline_wt="$CASE/project-newline-wt"
  git init -q -b main "$newline_project"
  printf '%s\n' baseline > "$newline_project/base.txt"
  git -C "$newline_project" add base.txt
  git -C "$newline_project" commit -q -m baseline
  git -C "$newline_project" worktree add -q -b "recovered/$id" "$newline_wt" main
  PROJ=$newline_project
  WT=$newline_wt
  out=$(run_spawn "$id" ship "$WT"); status=$?
  expect_code 1 "$status" "newline-bearing requested project should refuse"
  assert_contains "$out" 'requested project path must not contain a newline' "project-newline refusal did not name the metadata-safety boundary"
  assert_no_endpoint_created
  assert_absent "$HOME_DIR/state/$id.meta" "project-newline refusal published malformed metadata"

  pass "fm-spawn refuses non-exact, primary, foreign, symlinked, claimed, detached, and metadata-unsafe identities before endpoint creation"
}

test_live_claims_and_ambiguous_tmux_inventory_refuse() {
  local id out status
  id=adopt-live-claim-h9
  setup_case live-claim "$id" ship
  printf '%s\n' fm-other-task > "$WINDOW_STATE"
  out=$(FM_ADOPT_LIVE_PANE_PATH="$WT" run_spawn "$id" ship "$WT"); status=$?
  expect_code 1 "$status" "live different-task worktree claim should refuse"
  assert_contains "$out" 'already claimed by live tmux task other-task' "live claim refusal did not identify the different task"
  assert_no_endpoint_created
  assert_absent "$HOME_DIR/state/$id.meta" "live claim refusal published metadata"

  id=adopt-cross-session-claim-j0
  setup_case cross-session-live-claim "$id" ship
  printf '%s\n' fm-cross-session-task > "$WINDOW_STATE"
  out=$(FM_ADOPT_LIVE_SESSION=other-session FM_ADOPT_LIVE_PANE_PATH="$WT" run_spawn "$id" ship "$WT"); status=$?
  expect_code 1 "$status" "live different-session worktree claim should refuse"
  assert_contains "$out" 'already claimed by live tmux task cross-session-task' "cross-session claim refusal did not identify the different task"
  assert_no_endpoint_created
  assert_absent "$HOME_DIR/state/$id.meta" "cross-session claim refusal published metadata"

  id=adopt-renamed-occupancy-k1
  setup_case renamed-live-occupancy "$id" ship
  mkdir -p "$WT/active/subdir"
  printf '%s\n' lost-task-name > "$WINDOW_STATE"
  out=$(FM_ADOPT_LIVE_PANE_PATH="$WT/active/subdir" run_spawn "$id" ship "$WT"); status=$?
  expect_code 1 "$status" "renamed metadata-free worktree descendant occupancy should refuse"
  assert_contains "$out" 'live tmux task inventory is ambiguous (occupancy:' "renamed occupancy refusal did not explain the fail-closed boundary"
  assert_no_endpoint_created
  assert_absent "$HOME_DIR/state/$id.meta" "renamed occupancy refusal published metadata"

  id=adopt-inventory-ambiguous-i0
  setup_case inventory-ambiguous "$id" ship
  out=$(FM_ADOPT_INVENTORY_ERROR=1 run_spawn "$id" ship "$WT"); status=$?
  expect_code 1 "$status" "unreadable live tmux inventory should refuse"
  assert_contains "$out" 'live tmux task inventory is ambiguous' "inventory refusal did not explain the fail-closed boundary"
  assert_no_endpoint_created
  assert_absent "$HOME_DIR/state/$id.meta" "ambiguous inventory refusal published metadata"
  pass "fm-spawn refuses same-session and cross-session live claims plus renamed or unreadable tmux occupancy"
}

test_incompatible_modes_refuse_before_endpoint() {
  local id out status backend
  id=adopt-mode-j1
  setup_case modes "$id" ship

  out=$(run_spawn_command "$id" --secondmate --harness codex --existing-worktree "$WT"); status=$?
  expect_code 1 "$status" "secondmate adoption should refuse"
  assert_contains "$out" 'ordinary ship and scout tasks only' "secondmate refusal was not explicit"

  for backend in orca herdr zellij cmux; do
    out=$(run_spawn "$id" ship "$WT" --backend "$backend"); status=$?
    expect_code 1 "$status" "$backend adoption should refuse"
    assert_contains "$out" 'currently supports backend=tmux only' "$backend refusal was not explicit"
  done

  out=$(run_spawn "$id" ship "$WT" --harness claude); status=$?
  expect_code 1 "$status" "worktree-writing harness should refuse"
  assert_contains "$out" 'is not adoption-safe' "harness refusal did not name the safety boundary"

  out=$(run_spawn_command "$id=$PROJ" --harness codex --backend tmux --mode local-only --yolo off \
    --existing-worktree "$WT"); status=$?
  expect_code 1 "$status" "batch adoption should refuse"
  assert_contains "$out" 'cannot be shared by batch dispatch' "batch refusal was not explicit"
  assert_no_endpoint_created
  pass "fm-spawn rejects secondmate, non-tmux, unsafe-harness, and batch adoption modes"
}

test_adoption_safe_harnesses_preserve_worktree_end_to_end() {
  local harness id out status branch head index_before index_after status_before status_after
  for harness in codex pi pi-signed muse; do
    id="adopt-safe-harness-${harness//[^A-Za-z0-9]/-}"
    setup_case "safe-harness-$harness" "$id" ship
    mkdir -p "$HOME_DIR/xdg-config/muse" "$HOME_DIR/xdg-data"
    printf '%s\n' '{"credential":"fixture"}' > "$HOME_DIR/xdg-config/muse/auth.json"
    printf '%s\n' staged > "$WT/staged.txt"
    git -C "$WT" add staged.txt
    printf '%s\n' modified >> "$WT/base.txt"
    printf '%s\n' untracked > "$WT/untracked.txt"
    branch=$(git -C "$WT" symbolic-ref --short HEAD)
    head=$(git -C "$WT" rev-parse HEAD)
    index_before=$(git -C "$WT" ls-files --stage)
    status_before=$(git -C "$WT" status --porcelain)
    out=$(XDG_CONFIG_HOME="$HOME_DIR/xdg-config" XDG_DATA_HOME="$HOME_DIR/xdg-data" \
      run_spawn "$id" ship "$WT" --harness "$harness")
    status=$?
    expect_code 0 "$status" "$harness adoption should complete through metadata publication and brief delivery"
    assert_contains "$out" "spawned $id" "$harness adoption did not report success"
    assert_grep "harness=$harness" "$HOME_DIR/state/$id.meta" "$harness adoption published the wrong harness identity"
    assert_grep 'worktree_ownership=adopted' "$HOME_DIR/state/$id.meta" "$harness adoption omitted adopted ownership"
    [ "$(git -C "$WT" symbolic-ref --short HEAD)" = "$branch" ] || fail "$harness adoption switched branches"
    [ "$(git -C "$WT" rev-parse HEAD)" = "$head" ] || fail "$harness adoption changed HEAD"
    index_after=$(git -C "$WT" ls-files --stage)
    status_after=$(git -C "$WT" status --porcelain)
    [ "$index_after" = "$index_before" ] || fail "$harness adoption changed the index"
    [ "$status_after" = "$status_before" ] || fail "$harness adoption changed working-tree contents"
    assert_no_grep 'treehouse ' "$TREELOG" "$harness adoption allocated or leased another worktree"
  done
  pass "codex, pi, pi-signed, and muse complete adoption without changing Git or working-tree state"
}

test_retireable_secondmate_home_requires_discoverable_project() {
  local id out status project wt

  id=adopt-sm-project-outside-l1
  setup_case secondmate-project-outside "$id" ship
  printf '%s\n' parent-secondmate > "$HOME_DIR/.fm-secondmate-home"
  wt="$HOME_DIR/adopted-inside-home"
  git -C "$PROJ" worktree add -q -b "recovered/$id-inside" "$wt" main
  WT=$wt
  out=$(run_spawn "$id" ship "$WT"); status=$?
  expect_code 1 "$status" "secondmate-home adoption from an outside project should refuse"
  assert_contains "$out" 'retireable secondmate home' "outside-project refusal did not name the retirement boundary"
  assert_contains "$out" 'direct checkout under' "outside-project refusal did not name the discoverable layout"
  assert_no_endpoint_created
  assert_absent "$HOME_DIR/state/$id.meta" "outside-project refusal published metadata"

  id=adopt-sm-project-hidden-m2
  setup_case secondmate-project-hidden "$id" ship
  printf '%s\n' parent-secondmate > "$HOME_DIR/.fm-secondmate-home"
  project="$HOME_DIR/repos/project"
  wt="$CASE/outside-adopted-wt"
  mkdir -p "$(dirname "$project")"
  git init -q -b main "$project"
  printf '%s\n' baseline > "$project/base.txt"
  git -C "$project" add base.txt
  git -C "$project" commit -q -m baseline
  git -C "$project" worktree add -q -b "recovered/$id" "$wt" main
  PROJ=$project
  WT=$wt
  out=$(run_spawn "$id" ship "$WT"); status=$?
  expect_code 1 "$status" "secondmate-home adoption from an undiscoverable home project should refuse"
  assert_contains "$out" 'retireable secondmate home' "undiscoverable-project refusal did not name the retirement boundary"
  assert_contains "$out" 'direct checkout under' "undiscoverable-project refusal did not name the discoverable layout"
  assert_no_endpoint_created
  assert_absent "$HOME_DIR/state/$id.meta" "undiscoverable-project refusal published metadata"
  pass "retireable secondmate homes adopt only from direct registered project checkouts"
}

test_endpoint_cwd_mismatch_is_cleaned_without_meta() {
  local id=adopt-cwd-mismatch-k2 out status
  setup_case cwd-mismatch "$id" ship
  out=$(FM_FAKE_PANE_PATH="$PROJ" run_spawn_command \
    "$id" "$PROJ" --harness codex --backend tmux --existing-worktree "$WT" \
    --mode local-only --yolo off)
  status=$?
  expect_code 1 "$status" "endpoint cwd mismatch should refuse"
  assert_contains "$out" 'endpoint did not start in the exact worktree' "cwd mismatch refusal lacked exact evidence"
  assert_grep 'tmux kill-window -t @123' "$TLOG" "failed adopted endpoint was not cleaned up by stable id"
  assert_absent "$HOME_DIR/state/$id.meta" "cwd mismatch published task metadata"
  assert_absent "$HOME_DIR/state/$id.adopted-brief.md" "cwd mismatch retained a new adoption addendum"
  pass "fm-spawn cleans a mismatched endpoint and publishes no durable adoption claim"
}

test_recovery_reuses_claim_and_recaptures_head() {
  local id=adopt-recovery-l2 out status new_head meta_before brief_before
  setup_case recovery "$id" ship
  run_spawn "$id" ship "$WT" >/dev/null
  printf '%s\n' recovered-progress > "$WT/progress.txt"
  git -C "$WT" add progress.txt
  git -C "$WT" commit -q -m progress
  new_head=$(git -C "$WT" rev-parse HEAD)
  {
    printf '%s\n' 'pr=https://example.invalid/pull/42'
    printf '%s\n' "pr_head=$(git -C "$WT" rev-parse HEAD)"
    printf '%s\n' 'x_request=relay-42'
  } >> "$HOME_DIR/state/$id.meta"
  meta_before="$CASE/meta.before"
  brief_before="$CASE/brief.before"
  cp "$HOME_DIR/state/$id.meta" "$meta_before"
  cp "$HOME_DIR/state/$id.adopted-brief.md" "$brief_before"
  : > "$TLOG"

  out=$(run_spawn "$id" ship "$WT"); status=$?
  expect_code 1 "$status" "recovery should refuse while the prior endpoint still exists"
  assert_contains "$out" 'already exists' "live-window recovery refusal was not explicit"
  cmp -s "$meta_before" "$HOME_DIR/state/$id.meta" || fail "failed recovery changed durable metadata"
  cmp -s "$brief_before" "$HOME_DIR/state/$id.adopted-brief.md" || fail "failed recovery desynchronized the adopted addendum"

  : > "$WINDOW_STATE"

  out=$(run_spawn "$id" ship "$WT")
  status=$?
  expect_code 0 "$status" "same-task adopted recovery should relaunch"
  assert_contains "$out" "spawned $id" "adopted recovery did not report success"
  assert_grep "adopted_head=$new_head" "$HOME_DIR/state/$id.meta" "recovery did not record the relaunch intake HEAD"
  assert_grep "expected_head='$new_head'" "$HOME_DIR/state/$id.adopted-brief.md" "recovery addendum did not verify the relaunch HEAD"
  assert_grep 'pr=https://example.invalid/pull/42' "$HOME_DIR/state/$id.meta" "recovery discarded the durable PR URL"
  assert_grep "pr_head=$new_head" "$HOME_DIR/state/$id.meta" "recovery discarded the durable PR head"
  assert_grep 'x_request=relay-42' "$HOME_DIR/state/$id.meta" "recovery discarded durable Relay linkage"
  [ "$(grep -c '^pr=' "$HOME_DIR/state/$id.meta")" -eq 1 ] || fail "recovery duplicated the durable PR field"
  assert_no_grep 'treehouse ' "$TREELOG" "adopted recovery allocated another worktree"

  git -C "$WT" checkout -q -b "wrong/$id"
  : > "$TLOG"
  out=$(run_spawn "$id" ship "$WT"); status=$?
  expect_code 1 "$status" "same-task recovery on a switched branch should refuse"
  assert_contains "$out" 'does not prove the same adopted worktree, project, and branch' "branch-drift recovery refusal lacked ownership evidence"
  assert_no_endpoint_created
  pass "fm-spawn recovery reuses its durable adopted claim, recaptures HEAD, and refuses branch drift"
}

test_identity_change_before_publication_refuses_atomically() {
  local id=adopt-identity-race-m3 out status git_count old_head
  setup_case identity-race "$id" ship
  git_count="$CASE/git-worktree-list.count"
  old_head=$(git -C "$WT" rev-parse HEAD)
  cat > "$FAKEBIN/git" <<'SH'
#!/usr/bin/env bash
set -u
if printf '%s\n' "$*" | grep -q 'worktree list'; then
  count=0
  [ -z "${FM_ADOPT_GIT_COUNT:-}" ] || [ ! -s "$FM_ADOPT_GIT_COUNT" ] || count=$(cat "$FM_ADOPT_GIT_COUNT")
  count=$((count + 1))
  [ -z "${FM_ADOPT_GIT_COUNT:-}" ] || printf '%s\n' "$count" > "$FM_ADOPT_GIT_COUNT"
  if [ "$count" = "${FM_ADOPT_GIT_MUTATE_AT:-0}" ]; then
    "$FM_ADOPT_REAL_GIT" -C "$FM_ADOPT_MUTATE_WT" commit -q --allow-empty -m external-race
  fi
fi
exec "$FM_ADOPT_REAL_GIT" "$@"
SH
  chmod +x "$FAKEBIN/git"

  out=$(FM_ADOPT_GIT_COUNT="$git_count" FM_ADOPT_GIT_MUTATE_AT=4 FM_ADOPT_MUTATE_WT="$WT" \
    run_spawn "$id" ship "$WT")
  status=$?
  expect_code 1 "$status" "identity change immediately before publication should refuse"
  assert_contains "$out" 'identity changed during metadata publication' "publication refusal did not name the final identity gate"
  [ "$(git -C "$WT" rev-parse HEAD)" != "$old_head" ] || fail "identity-race fixture did not advance HEAD"
  assert_absent "$HOME_DIR/state/$id.meta" "identity mismatch published adopted metadata"
  assert_absent "$HOME_DIR/state/$id.adopted-brief.md" "identity mismatch retained an unmatched addendum"
  assert_grep 'tmux kill-window -t @123' "$TLOG" "identity mismatch did not remove the endpoint by stable id"
  pass "fm-spawn revalidates complete adopted identity immediately before atomic metadata publication"
}

test_post_publication_send_failures_are_retryable() {
  local fail_at id out status before_retry
  for fail_at in 1 2 3; do
    id="adopt-send-fail-${fail_at}-n4"
    setup_case "send-fail-$fail_at" "$id" ship
    out=$(FM_ADOPT_FAIL_SEND_AT="$fail_at" run_spawn "$id" ship "$WT")
    status=$?
    expect_code 1 "$status" "post-publication send $fail_at should fail the first spawn"
    assert_present "$HOME_DIR/state/$id.meta" "send failure $fail_at lost the durable recovery claim"
    assert_present "$HOME_DIR/state/$id.adopted-brief.md" "send failure $fail_at lost its aligned addendum"
    [ ! -s "$WINDOW_STATE" ] || fail "send failure $fail_at left an endpoint that would collide with retry"
    assert_grep 'tmux kill-window -t @123' "$TLOG" "send failure $fail_at was not cleaned by stable id"
    : > "$SEND_COUNT"
    out=$(run_spawn "$id" ship "$WT")
    status=$?
    expect_code 0 "$status" "send failure $fail_at did not permit a same-id retry"
    assert_contains "$out" "spawned $id" "send failure $fail_at retry did not launch"
  done

  id=adopt-send-kill-fail-n5
  setup_case send-kill-fail "$id" ship
  out=$(FM_ADOPT_FAIL_SEND_AT=1 FM_ADOPT_FAIL_KILL=1 run_spawn "$id" ship "$WT")
  status=$?
  expect_code 1 "$status" "post-publication send plus endpoint-cleanup failure should fail the first spawn"
  assert_present "$HOME_DIR/state/$id.meta" "send plus cleanup failure lost the durable recovery claim"
  assert_grep 'adopted_delivery=pending' "$HOME_DIR/state/$id.meta" "send plus cleanup failure did not retain pending delivery state"
  assert_grep 'adopted_window_id=@123' "$HOME_DIR/state/$id.meta" "send plus cleanup failure did not retain the stable endpoint id"
  assert_grep 'adopted_tmux_server_identity=4242:123456' "$HOME_DIR/state/$id.meta" "send plus cleanup failure did not bind the stable id to its tmux server"
  [ -s "$WINDOW_STATE" ] || fail "endpoint-cleanup failure fixture did not retain the colliding live window"

  before_retry=$(grep -c 'tmux new-window ' "$TLOG")
  out=$(run_spawn "$id" ship "$WT")
  status=$?
  expect_code 1 "$status" "same-name different-window-id occupancy should refuse pending retry"
  assert_contains "$out" "already claimed by live tmux task $id" "same-name different-window-id refusal lost the live claimant"
  [ "$(grep -c 'tmux new-window ' "$TLOG")" -eq "$before_retry" ] \
    || fail "same-name different-window-id refusal created a replacement endpoint"

  printf '%s\n' lost-task-name > "$WINDOW_STATE"
  : > "$SEND_COUNT"
  out=$(FM_ADOPT_LIVE_WINDOW_ID=@123 run_spawn "$id" ship "$WT")
  status=$?
  expect_code 0 "$status" "send plus cleanup failure did not permit a collision-free same-id retry"
  assert_grep 'adopted_delivery=complete' "$HOME_DIR/state/$id.meta" "successful retry did not complete durable delivery state"
  [ "$(grep -c 'tmux new-window ' "$TLOG")" -eq 2 ] || fail "same-id retry did not replace the failed endpoint exactly once"
  pass "fm-spawn keeps post-publication failures durable and collision-free even when initial endpoint cleanup fails"
}

test_teardown_retires_task_without_returning_adopted_worktree() {
  local id=adopt-teardown-l3 out status branch head origin
  setup_case teardown "$id" ship
  origin="$CASE/origin.git"
  git init -q --bare "$origin"
  git -C "$PROJ" remote add origin "$origin"
  git -C "$PROJ" push -q origin main
  git -C "$WT" push -q -u origin "recovered/$id"
  run_spawn "$id" ship "$WT" >/dev/null
  branch=$(git -C "$WT" symbolic-ref --short HEAD)
  head=$(git -C "$WT" rev-parse HEAD)
  : > "$TREELOG"

  out=$(run_teardown "$id")
  status=$?
  expect_code 0 "$status" "landed adopted ship teardown should complete"
  assert_contains "$out" "teardown $id complete" "adopted teardown did not report completion"
  assert_absent "$HOME_DIR/state/$id.meta" "adopted teardown retained task metadata"
  assert_absent "$HOME_DIR/state/$id.adopted-brief.md" "adopted teardown retained its launch addendum"
  assert_present "$WT" "adopted teardown removed the external worktree"
  [ "$(git -C "$WT" symbolic-ref --short HEAD)" = "$branch" ] || fail "adopted teardown detached or switched the branch"
  [ "$(git -C "$WT" rev-parse HEAD)" = "$head" ] || fail "adopted teardown changed HEAD"
  assert_no_grep 'treehouse ' "$TREELOG" "adopted teardown returned or mutated the Treehouse lease"
  assert_grep 'tmux kill-window ' "$TLOG" "adopted teardown did not close the ordinary endpoint"
  pass "fm-teardown retires landed adopted task state and endpoint without reclaiming the worktree"
}

test_teardown_closes_renamed_adopted_endpoint_by_stable_id() {
  local id=adopt-teardown-renamed-l4 out status origin
  setup_case teardown-renamed "$id" ship
  origin="$CASE/origin.git"
  git init -q --bare "$origin"
  git -C "$PROJ" remote add origin "$origin"
  git -C "$PROJ" push -q origin main
  git -C "$WT" push -q -u origin "recovered/$id"
  run_spawn "$id" ship "$WT" >/dev/null
  printf '%s\n' renamed-after-publication > "$WINDOW_STATE"
  : > "$TLOG"

  out=$(FM_ADOPT_NAME_KILL_FAIL=1 run_teardown "$id")
  status=$?
  expect_code 0 "$status" "renamed adopted endpoint should close by its stable id"
  assert_contains "$out" "teardown $id complete" "renamed adopted endpoint teardown did not complete"
  [ ! -s "$WINDOW_STATE" ] || fail "renamed adopted endpoint survived after its metadata was retired"
  assert_grep 'tmux kill-window -t @123' "$TLOG" "renamed adopted endpoint was not closed by stable id"
  assert_absent "$HOME_DIR/state/$id.meta" "renamed adopted endpoint teardown retained metadata"
  assert_present "$WT" "renamed adopted endpoint teardown removed the external worktree"
  pass "fm-teardown closes the exact renamed adopted endpoint before retiring durable state"
}

test_teardown_does_not_reap_external_worktree_processes() {
  local id=adopt-external-process-p5 out status external_pid origin
  setup_case external-process "$id" ship
  origin="$CASE/origin.git"
  git init -q --bare "$origin"
  git -C "$PROJ" remote add origin "$origin"
  git -C "$PROJ" push -q origin main
  git -C "$WT" push -q -u origin "recovered/$id"
  run_spawn "$id" ship "$WT" >/dev/null
  (cd "$WT" && sleep 60) &
  external_pid=$!
  cat > "$FAKEBIN/lsof" <<SH
#!/usr/bin/env bash
printf 'p%s\nfcwd\nn%s\n' '$external_pid' '$WT'
SH
  chmod +x "$FAKEBIN/lsof"

  out=$(run_teardown "$id")
  status=$?
  expect_code 0 "$status" "adopted teardown should ignore external worktree-rooted processes"
  if ! kill -0 "$external_pid" 2>/dev/null; then
    fail "adopted teardown killed an external process rooted in the leased worktree"
  fi
  kill "$external_pid" 2>/dev/null || true
  wait "$external_pid" 2>/dev/null || true
  assert_present "$WT" "external-process teardown removed the adopted worktree"
  pass "fm-teardown never scans or reaps arbitrary processes by adopted-worktree cwd"
}

test_adopted_teardown_preserves_index_lock() {
  local id=adopt-index-lock-q6 out status origin lock
  setup_case index-lock "$id" ship
  origin="$CASE/origin.git"
  git init -q --bare "$origin"
  git -C "$PROJ" remote add origin "$origin"
  git -C "$PROJ" push -q origin main
  git -C "$WT" push -q -u origin "recovered/$id"
  run_spawn "$id" ship "$WT" >/dev/null
  lock=$(git -C "$WT" rev-parse --git-path index.lock)
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  cat > "$FAKEBIN/lsof" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$FAKEBIN/lsof"
  : > "$TLOG"

  out=$(FM_STALE_WORKTREE_LOCK_AGE_SECS=0 FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 \
    run_teardown "$id")
  status=$?
  expect_code 1 "$status" "adopted teardown should refuse on an external index.lock"
  assert_contains "$out" 'adopted worktree git lock' "adopted lock refusal did not name external ownership"
  assert_present "$lock" "adopted teardown removed the external index.lock"
  assert_present "$HOME_DIR/state/$id.meta" "adopted lock refusal erased task metadata"
  assert_no_grep 'tmux kill-window ' "$TLOG" "adopted lock refusal closed the endpoint before safety completed"

  out=$(run_teardown "$id" --force)
  status=$?
  expect_code 1 "$status" "forced adopted teardown should still preserve an external index.lock"
  assert_present "$lock" "forced adopted teardown removed the external index.lock"
  assert_present "$HOME_DIR/state/$id.meta" "forced adopted lock refusal erased task metadata"
  pass "fm-teardown preserves and refuses on an adopted worktree index.lock"
}

test_symlinked_project_identity_is_canonical_and_teardown_safe() {
  local id=adopt-project-link-r7 out status origin project_link project_real
  setup_case project-link "$id" ship
  project_link="$CASE/project-link"
  ln -s "$PROJ" "$project_link"
  project_real=$(cd "$PROJ" && pwd -P)
  out=$(FM_ADOPT_PROJECT_ARG="$project_link" run_spawn "$id" ship "$WT"); status=$?
  expect_code 0 "$status" "symlink-spelled project adoption should succeed"
  assert_grep "project=$project_real" "$HOME_DIR/state/$id.meta" "adoption did not publish canonical project identity"
  origin="$CASE/origin.git"
  git init -q --bare "$origin"
  git -C "$PROJ" remote add origin "$origin"
  git -C "$PROJ" push -q origin main
  git -C "$WT" push -q -u origin "recovered/$id"

  out=$(run_teardown "$id")
  status=$?
  expect_code 0 "$status" "canonical project identity should remain teardown-safe"
  assert_present "$WT" "symlink-project teardown removed the adopted worktree"
  assert_absent "$HOME_DIR/state/$id.meta" "symlink-project teardown retained task metadata"
  pass "fm-spawn canonicalizes adopted project identity for later teardown"
}

test_forced_secondmate_retirement_refuses_adopted_descendants() {
  local placement parent child sm_home child_project child_wt branch head out status
  for placement in inside-home outside-home; do
    parent="adopt-parent-${placement}-s8"
    child="adopt-child-${placement}-t9"
    setup_case "secondmate-$placement" "$parent" ship
    sm_home="$CASE/secondmate-home"
    child_project="$sm_home/projects/project"
    if [ "$placement" = inside-home ]; then
      child_wt="$sm_home/projects/adopted-worktree"
    else
      child_wt="$CASE/outside-adopted-worktree"
    fi
    mkdir -p "$sm_home/state" "$sm_home/data" "$sm_home/config" "$sm_home/projects"
    printf '%s\n' "$parent" > "$sm_home/.fm-secondmate-home"
    git init -q -b main "$child_project"
    git -C "$child_project" commit -q --allow-empty -m baseline
    git -C "$child_project" worktree add -q -b "recovered/$child" "$child_wt" main
    branch=$(git -C "$child_wt" symbolic-ref --short HEAD)
    head=$(git -C "$child_wt" rev-parse HEAD)
    fm_write_meta "$sm_home/state/$child.meta" \
      "window=firstmate:fm-$child" \
      "endpoint_task_id=$child" \
      "worktree=$child_wt" \
      "project=$child_project" \
      'harness=codex' \
      'kind=ship' \
      'mode=local-only' \
      'worktree_ownership=adopted' \
      "adopted_branch=$branch" \
      "adopted_head=$head" \
      'adopted_window_id=@123' \
      'adopted_tmux_server_identity=4242:123456' \
      'adopted_delivery=complete'
    fm_write_meta "$HOME_DIR/state/$parent.meta" \
      "window=firstmate:fm-$parent" \
      "endpoint_task_id=$parent" \
      "worktree=$sm_home" \
      "project=$sm_home" \
      'harness=codex' \
      'kind=secondmate' \
      'mode=secondmate' \
      "home=$sm_home"
    : > "$TLOG"
    : > "$TREELOG"

    out=$(run_teardown "$parent" --force)
    status=$?
    expect_code 1 "$status" "forced secondmate retirement should refuse an $placement adopted descendant"
    assert_contains "$out" "adopted descendant $child" "secondmate refusal did not identify the $placement adopted descendant"
    assert_present "$HOME_DIR/state/$parent.meta" "secondmate refusal erased the parent record for $placement"
    assert_present "$sm_home/state/$child.meta" "secondmate refusal erased the child record for $placement"
    assert_present "$sm_home" "secondmate refusal removed the parent home for $placement"
    assert_present "$child_wt" "secondmate refusal removed the adopted worktree for $placement"
    git -C "$child_wt" status --porcelain >/dev/null \
      || fail "secondmate refusal broke the adopted worktree Git common-dir dependency for $placement"
    assert_no_grep 'tmux kill-window ' "$TLOG" "secondmate refusal closed an endpoint before the adopted descendant preflight"
    assert_no_grep 'treehouse ' "$TREELOG" "secondmate refusal returned a home or worktree for $placement"
  done
  pass "forced secondmate retirement preserves inside-home and outside-home adopted descendants and their Git common directories"
}

test_completed_adopted_descendant_still_blocks_secondmate_retirement() {
  local placement parent child sm_home child_project child_wt origin branch head out status
  for placement in inside-home outside-home; do
    parent="adopt-complete-parent-${placement}-u0"
    child="adopt-complete-child-${placement}-v1"
    setup_case "completed-secondmate-$placement" "$parent" ship
    sm_home="$CASE/secondmate-home"
    child_project="$sm_home/projects/project"
    origin="$CASE/origin.git"
    if [ "$placement" = inside-home ]; then
      child_wt="$sm_home/projects/adopted-worktree"
    else
      child_wt="$CASE/outside-adopted-worktree"
    fi
    mkdir -p "$sm_home/state" "$sm_home/data/$child" "$sm_home/config" "$sm_home/projects"
    printf '%s\n' "$parent" > "$sm_home/.fm-secondmate-home"
    printf '%s\n' 'Delivery contract: mode=local-only' > "$sm_home/data/$child/brief.md"
    git init -q -b main "$child_project"
    git -C "$child_project" commit -q --allow-empty -m baseline
    git init -q --bare "$origin"
    git -C "$child_project" remote add origin "$origin"
    git -C "$child_project" push -q origin main
    git -C "$child_project" worktree add -q -b "recovered/$child" "$child_wt" main
    git -C "$child_wt" push -q -u origin "recovered/$child"
    branch=$(git -C "$child_wt" symbolic-ref --short HEAD)
    head=$(git -C "$child_wt" rev-parse HEAD)
    fm_write_meta "$sm_home/state/$child.meta" \
      "window=firstmate:fm-$child" \
      "endpoint_task_id=$child" \
      "worktree=$child_wt" \
      "project=$child_project" \
      'harness=codex' \
      'kind=ship' \
      'mode=local-only' \
      'worktree_ownership=adopted' \
      "adopted_branch=$branch" \
      "adopted_head=$head" \
      'adopted_window_id=@123' \
      'adopted_tmux_server_identity=4242:123456' \
      'adopted_delivery=complete'
    fm_write_meta "$HOME_DIR/state/$parent.meta" \
      "window=firstmate:fm-$parent" \
      "endpoint_task_id=$parent" \
      "worktree=$sm_home" \
      "project=$sm_home" \
      'harness=codex' \
      'kind=secondmate' \
      'mode=secondmate' \
      "home=$sm_home"
    printf '%s\n' "fm-$child" > "$WINDOW_STATE"

    out=$(FM_ADOPT_TASK_HOME="$sm_home" FM_ADOPT_FAKE_PANE_PATH="$child_wt" run_teardown "$child")
    status=$?
    expect_code 0 "$status" "ordinary teardown should complete for a landed $placement adopted descendant"
    assert_absent "$sm_home/state/$child.meta" "ordinary teardown retained completed child metadata for $placement"
    assert_present "$child_wt" "ordinary teardown removed the $placement adopted worktree"
    git -C "$child_wt" status --porcelain >/dev/null \
      || fail "ordinary teardown broke the adopted worktree before parent retirement for $placement"

    : > "$TLOG"
    : > "$TREELOG"
    printf '%s\n' "fm-$parent" > "$WINDOW_STATE"
    out=$(run_teardown "$parent" --force)
    status=$?
    expect_code 1 "$status" "forced parent retirement should refuse a completed $placement linked worktree dependency"
    assert_contains "$out" 'linked Git worktree dependency' "completed-descendant refusal did not name the Git dependency for $placement"
    assert_present "$HOME_DIR/state/$parent.meta" "completed-descendant refusal erased the parent record for $placement"
    assert_present "$sm_home" "completed-descendant refusal removed the parent home for $placement"
    assert_present "$child_wt" "completed-descendant refusal removed the adopted worktree for $placement"
    git -C "$child_wt" status --porcelain >/dev/null \
      || fail "completed-descendant refusal broke the Git common-directory dependency for $placement"
    assert_no_grep 'tmux kill-window ' "$TLOG" "completed-descendant refusal closed the parent endpoint for $placement"
    assert_no_grep 'treehouse ' "$TREELOG" "completed-descendant refusal returned a home or worktree for $placement"
  done
  pass "completed adopted descendants still block recursive retirement after task metadata cleanup"
}

test_safe_ship_adoption_preserves_git_state
test_safe_scout_adoption_has_non_discard_contract
test_input_and_ownership_refusals_precede_endpoint
test_live_claims_and_ambiguous_tmux_inventory_refuse
test_incompatible_modes_refuse_before_endpoint
test_adoption_safe_harnesses_preserve_worktree_end_to_end
test_retireable_secondmate_home_requires_discoverable_project
test_endpoint_cwd_mismatch_is_cleaned_without_meta
test_recovery_reuses_claim_and_recaptures_head
test_identity_change_before_publication_refuses_atomically
test_post_publication_send_failures_are_retryable
test_teardown_retires_task_without_returning_adopted_worktree
test_teardown_closes_renamed_adopted_endpoint_by_stable_id
test_teardown_does_not_reap_external_worktree_processes
test_adopted_teardown_preserves_index_lock
test_symlinked_project_identity_is_canonical_and_teardown_safe
test_forced_secondmate_retirement_refuses_adopted_descendants
test_completed_adopted_descendant_still_blocks_secondmate_retirement

echo "# all existing-worktree adoption tests passed"

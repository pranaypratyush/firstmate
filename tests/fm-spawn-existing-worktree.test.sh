#!/usr/bin/env bash
# Interface-level regressions for adopting a pre-existing Git worktree through
# bin/fm-spawn.sh --existing-worktree and preserving it through teardown.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-existing-worktree)
fm_git_identity fmtest fmtest@example.invalid

make_fakebin() {
  local root=$1 fakebin
  fakebin=$(fm_fakebin "$root")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_ADOPT_TMUX_LOG:-}" ] || printf 'tmux %s\n' "$*" >> "$FM_ADOPT_TMUX_LOG"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf '%s\n' firstmate ;;
  new-window) printf '%s\n' @adopted ;;
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
  chmod +x "$fakebin/tmux" "$fakebin/treehouse" "$fakebin/no-mistakes"
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
  FAKEBIN=$(make_fakebin "$CASE/fakes")
  mkdir -p "$HOME_DIR/data/$id" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects"
  : > "$TLOG"
  : > "$TREELOG"
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

run_spawn() {  # <id> <ship|scout> <existing-path> [extra args...]
  local id=$1 kind=$2 existing=$3
  shift 3
  local -a args
  args=("$id" "$PROJ" --harness codex --backend tmux --existing-worktree "$existing")
  if [ "$kind" = scout ]; then
    args+=(--scout)
  else
    args+=(--mode local-only --yolo off)
  fi
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' FM_FAKE_PANE_PATH="$WT" \
    FM_ADOPT_TMUX_LOG="$TLOG" FM_ADOPT_TREEHOUSE_LOG="$TREELOG" \
    PATH="$FAKEBIN:$PATH" \
    "$SPAWN" "${args[@]}" "$@" 2>&1
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

  pass "fm-spawn refuses non-exact, primary, foreign, symlinked, claimed, and detached worktrees before endpoint creation"
}

test_incompatible_modes_refuse_before_endpoint() {
  local id out status
  id=adopt-mode-j1
  setup_case modes "$id" ship

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_SPAWN_NO_GUARD=1 PATH="$FAKEBIN:$PATH" \
    "$SPAWN" "$id" --secondmate --harness codex --existing-worktree "$WT" 2>&1); status=$?
  expect_code 1 "$status" "secondmate adoption should refuse"
  assert_contains "$out" 'ordinary ship and scout tasks only' "secondmate refusal was not explicit"

  out=$(run_spawn "$id" ship "$WT" --backend orca); status=$?
  expect_code 1 "$status" "Orca adoption should refuse"
  assert_contains "$out" 'currently supports backend=tmux only' "Orca refusal was not explicit"

  out=$(run_spawn "$id" ship "$WT" --harness claude); status=$?
  expect_code 1 "$status" "worktree-writing harness should refuse"
  assert_contains "$out" 'is not adoption-safe' "harness refusal did not name the safety boundary"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_SPAWN_NO_GUARD=1 PATH="$FAKEBIN:$PATH" \
    "$SPAWN" "$id=$PROJ" --harness codex --backend tmux --mode local-only --yolo off \
    --existing-worktree "$WT" 2>&1); status=$?
  expect_code 1 "$status" "batch adoption should refuse"
  assert_contains "$out" 'cannot be shared by batch dispatch' "batch refusal was not explicit"
  assert_no_endpoint_created
  pass "fm-spawn rejects secondmate, Orca, unsafe-harness, and batch adoption modes"
}

test_endpoint_cwd_mismatch_is_cleaned_without_meta() {
  local id=adopt-cwd-mismatch-k2 out status
  setup_case cwd-mismatch "$id" ship
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' \
    FM_FAKE_PANE_PATH="$PROJ" FM_ADOPT_TMUX_LOG="$TLOG" FM_ADOPT_TREEHOUSE_LOG="$TREELOG" \
    PATH="$FAKEBIN:$PATH" "$SPAWN" "$id" "$PROJ" --harness codex --backend tmux \
    --existing-worktree "$WT" --mode local-only --yolo off 2>&1)
  status=$?
  expect_code 1 "$status" "endpoint cwd mismatch should refuse"
  assert_contains "$out" 'endpoint did not start in the exact worktree' "cwd mismatch refusal lacked exact evidence"
  assert_grep 'tmux kill-window ' "$TLOG" "failed adopted endpoint was not cleaned up"
  assert_absent "$HOME_DIR/state/$id.meta" "cwd mismatch published task metadata"
  assert_absent "$HOME_DIR/state/$id.adopted-brief.md" "cwd mismatch retained a new adoption addendum"
  pass "fm-spawn cleans a mismatched endpoint and publishes no durable adoption claim"
}

test_recovery_reuses_claim_and_recaptures_head() {
  local id=adopt-recovery-l2 out status new_head
  setup_case recovery "$id" ship
  run_spawn "$id" ship "$WT" >/dev/null
  printf '%s\n' recovered-progress > "$WT/progress.txt"
  git -C "$WT" add progress.txt
  git -C "$WT" commit -q -m progress
  new_head=$(git -C "$WT" rev-parse HEAD)
  : > "$TLOG"

  out=$(run_spawn "$id" ship "$WT")
  status=$?
  expect_code 0 "$status" "same-task adopted recovery should relaunch"
  assert_contains "$out" "spawned $id" "adopted recovery did not report success"
  assert_grep "adopted_head=$new_head" "$HOME_DIR/state/$id.meta" "recovery did not record the relaunch intake HEAD"
  assert_grep "expected_head='$new_head'" "$HOME_DIR/state/$id.adopted-brief.md" "recovery addendum did not verify the relaunch HEAD"
  assert_no_grep 'treehouse ' "$TREELOG" "adopted recovery allocated another worktree"

  git -C "$WT" checkout -q -b "wrong/$id"
  : > "$TLOG"
  out=$(run_spawn "$id" ship "$WT"); status=$?
  expect_code 1 "$status" "same-task recovery on a switched branch should refuse"
  assert_contains "$out" 'does not prove the same adopted worktree, project, and branch' "branch-drift recovery refusal lacked ownership evidence"
  assert_no_endpoint_created
  pass "fm-spawn recovery reuses its durable adopted claim, recaptures HEAD, and refuses branch drift"
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

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_TEARDOWN_GUARD_DONE=1 \
    FM_ADOPT_TMUX_LOG="$TLOG" FM_ADOPT_TREEHOUSE_LOG="$TREELOG" \
    PATH="$FAKEBIN:$PATH" "$TEARDOWN" "$id" 2>&1)
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

test_safe_ship_adoption_preserves_git_state
test_safe_scout_adoption_has_non_discard_contract
test_input_and_ownership_refusals_precede_endpoint
test_incompatible_modes_refuse_before_endpoint
test_endpoint_cwd_mismatch_is_cleaned_without_meta
test_recovery_reuses_claim_and_recaptures_head
test_teardown_retires_task_without_returning_adopted_worktree

echo "# all existing-worktree adoption tests passed"

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
# shellcheck source=bin/fm-adopted-worktree-lib.sh
. "$ROOT/bin/fm-adopted-worktree-lib.sh"

make_fakebin() {
  local root=$1 fakebin
  fakebin=$(fm_fakebin "$root")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_ADOPT_TMUX_LOG:-}" ] || printf 'tmux %s\n' "$*" >> "$FM_ADOPT_TMUX_LOG"
case "$*" in
  display-message*"#{pid}:#{start_time}"*)
    if [ -n "${FM_ADOPT_SERVER_IDENTITY_STATE:-}" ] && [ -s "$FM_ADOPT_SERVER_IDENTITY_STATE" ]; then
      cat "$FM_ADOPT_SERVER_IDENTITY_STATE"
    else
      printf '%s\n' "${FM_ADOPT_SERVER_IDENTITY:-4242:123456}"
    fi
    exit 0
    ;;
  display-message*"#{socket_path}"*)
    if [ -n "${FM_ADOPT_SERVER_LOCATOR_STATE:-}" ] && [ -s "$FM_ADOPT_SERVER_LOCATOR_STATE" ]; then
      cat "$FM_ADOPT_SERVER_LOCATOR_STATE"
    else
      printf '%s\n' '/tmp/fm-adopt-tmux.sock'
    fi
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
  display-message*"#{session_name}"*)
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
      *"#{window_id}|#{window_name}"*)
        if [ -n "${FM_ADOPT_WINDOW_STATE:-}" ] && [ -s "$FM_ADOPT_WINDOW_STATE" ]; then
          while IFS= read -r listed_window; do
            [ -n "$listed_window" ] || continue
            printf '@123|%s\n' "$listed_window"
          done < "$FM_ADOPT_WINDOW_STATE"
        fi
        ;;
      *"#{window_id}|#{session_name}|#{@firstmate_adoption_token}"*)
        if [ -n "${FM_ADOPT_WINDOW_STATE:-}" ] && [ -s "$FM_ADOPT_WINDOW_STATE" ] \
           && [ -n "${FM_ADOPT_PROVISIONAL_TOKEN_STATE:-}" ] \
           && [ -s "$FM_ADOPT_PROVISIONAL_TOKEN_STATE" ]; then
          printf '@123|firstmate|%s\n' "$(cat "$FM_ADOPT_PROVISIONAL_TOKEN_STATE")"
        fi
        ;;
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
    provisional_token=
    while [ "$#" -gt 0 ]; do
      if [ "$1" = -n ]; then window=${2:-}; break; fi
      shift
    done
    for arg in "$@"; do
      if [ "$arg" = @firstmate_adoption_token ]; then
        provisional_token_next=1
      elif [ "${provisional_token_next:-0}" = 1 ]; then
        provisional_token=$arg
        provisional_token_next=0
      fi
    done
    [ -z "${FM_ADOPT_WINDOW_STATE:-}" ] || printf '%s\n' "$window" > "$FM_ADOPT_WINDOW_STATE"
    [ -z "${FM_ADOPT_PROVISIONAL_TOKEN_STATE:-}" ] \
      || printf '%s\n' "$provisional_token" > "$FM_ADOPT_PROVISIONAL_TOKEN_STATE"
    printf '%s\n' @123
    if [ "${FM_ADOPT_SIGKILL_AFTER_CREATE:-0}" = 1 ]; then
      spawn_pid=$(ps -o ppid= -p "$PPID" | tr -d '[:space:]')
      case "$spawn_pid" in ''|*[!0-9]*) exit 2 ;; esac
      kill -KILL "$spawn_pid"
      sleep 0.1
    fi
    ;;
  rename-window)
    [ -z "${FM_ADOPT_WINDOW_STATE:-}" ] || printf '%s\n' "${4:-}" > "$FM_ADOPT_WINDOW_STATE"
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
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
state=${FM_ADOPT_HERDR_STATE:?}
log=${FM_ADOPT_HERDR_LOG:?}
socket=${FM_ADOPT_HERDR_SOCKET:?}
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for arg in "$@"; do printf '\x1f%s' "$arg"; done
  printf '\n'
} >> "$log"

jq_state() { jq "$@" "$state"; }
save_state() { local tmp="$state.tmp.$$"; cat > "$tmp" && mv "$tmp" "$state"; }
cmd=${1:-}; sub=${2:-}; workspace=; label=; cwd=
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --workspace) workspace=${args[$((i + 1))]:-} ;;
    --label) label=${args[$((i + 1))]:-} ;;
    --cwd) cwd=${args[$((i + 1))]:-} ;;
  esac
done

case "$cmd $sub" in
  "status --json")
    printf '%s\n' '{"client":{"version":"0.7.5","protocol":17},"server":{"running":true,"version":"0.7.5","protocol":17}}'
    ;;
  "session list")
    if [ "${FM_ADOPT_HERDR_DUP_SESSION:-0}" = 1 ]; then
      printf '{"sessions":[{"name":"%s","running":true,"socket_path":"%s"},{"name":"%s","running":true,"socket_path":"%s.duplicate"}]}\n' \
        "${HERDR_SESSION:-fmtest}" "$socket" "${HERDR_SESSION:-fmtest}" "$socket"
    else
      printf '{"sessions":[{"name":"%s","running":true,"socket_path":"%s"}]}\n' \
        "${HERDR_SESSION:-fmtest}" "$socket"
    fi
    ;;
  "workspace list")
    jq_state '. as $s | {result:{type:"workspace_list",workspaces:[$s.workspaces[] | . + {focused:(.workspace_id == $s.focused_workspace),active_tab_id:(if .workspace_id == $s.focused_workspace then $s.focused_tab else null end)}]}}'
    ;;
  "workspace create")
    n=$(jq_state -r '.next'); workspace="w$n"; seeded=$((n + 1)); tab="$workspace:t$seeded"; pane="$workspace:p$seeded"
    jq_state --arg w "$workspace" --arg label "$label" --arg cwd "$cwd" \
      --arg tab "$tab" --arg pane "$pane" \
      '.workspaces += [{workspace_id:$w,label:$label}]
       | .tabs += [{tab_id:$tab,label:"1",workspace_id:$w,pane_id:$pane,cwd:$cwd}]
       | .next += 2' | save_state
    printf '{"result":{"workspace":{"workspace_id":"%s","label":"%s"},"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' \
      "$workspace" "$label" "$tab" "$pane"
    ;;
  "tab list")
    jq_state --arg w "$workspace" '. as $s | {result:{tabs:[$s.tabs[] | select(.workspace_id == $w) | . + {focused:(.tab_id == $s.focused_tab)}]}}'
    ;;
  "tab get")
    tab=${3:-}
    jq_state --arg t "$tab" '{result:{tab:([.tabs[] | select(.tab_id == $t)][0] // null)}}'
    ;;
  "tab create")
    n=$(jq_state -r '.next'); tab="$workspace:t$n"; pane="$workspace:p$n"
    jq_state --arg w "$workspace" --arg label "$label" --arg cwd "$cwd" \
      --arg tab "$tab" --arg pane "$pane" \
      '.tabs += [{tab_id:$tab,label:$label,workspace_id:$w,pane_id:$pane,cwd:$cwd}] | .next += 1' | save_state
    if [ -n "${FM_ADOPT_HERDR_CREATE_GATE:-}" ]; then
      : > "$FM_ADOPT_HERDR_CREATE_GATE.started"
      tries=0
      while [ ! -e "$FM_ADOPT_HERDR_CREATE_GATE.release" ] && [ "$tries" -lt 500 ]; do
        sleep 0.01
        tries=$((tries + 1))
      done
      [ -e "$FM_ADOPT_HERDR_CREATE_GATE.release" ] || exit 1
    fi
    if [ "${FM_ADOPT_HERDR_PARTIAL_CREATE:-0}" = 1 ]; then
      printf '{"result":{"tab":{"tab_id":"%s"}}}\n' "$tab"
    else
      printf '{"result":{"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' "$tab" "$pane"
    fi
    ;;
  "tab focus")
    tab=${3:-}
    jq_state --arg t "$tab" '([.tabs[] | select(.tab_id == $t)][0]) as $tab | .focused_tab=$t | .focused_workspace=$tab.workspace_id' | save_state
    ;;
  "pane list")
    jq_state --arg w "$workspace" '{result:{panes:[.tabs[] | select(.workspace_id == $w) | {pane_id,tab_id,workspace_id}]}}'
    ;;
  "pane get")
    pane=${3:-}
    if [ "$(jq_state -r --arg p "$pane" '[.tabs[] | select(.pane_id == $p)] | length')" = 1 ]; then
      jq_state --arg p "$pane" '{result:{pane:([.tabs[] | select(.pane_id == $p)][0] | {pane_id,tab_id,workspace_id,cwd,foreground_cwd:.cwd})}}'
    else
      printf '%s\n' '{"error":{"code":"pane_not_found"}}'
    fi
    ;;
  "pane run")
    :
    ;;
  "pane send-text")
    pane=${3:-}; text=${4:-}
    jq_state --arg p "$pane" --arg text "$text" '.pending[$p]=$text' | save_state
    ;;
  "pane send-keys")
    pane=${3:-}; key=${4:-}
    if [ "$key" = enter ]; then
      pending=$(jq_state -r --arg p "$pane" '.pending[$p] // empty')
      case "$pending" in
        codex\ *)
          if [ "${FM_ADOPT_HERDR_FOCUS_ON_ENTER:-0}" = 1 ]; then
            jq_state --arg p "$pane" \
              '([.tabs[] | select(.pane_id == $p)][0]) as $tab | .focused_tab=$tab.tab_id | .focused_workspace=$tab.workspace_id' | save_state
          fi
          if [ "${FM_ADOPT_HERDR_NO_AGENT:-0}" != 1 ]; then
            agent=${FM_ADOPT_HERDR_AGENT_OVERRIDE:-codex}
            jq_state --arg p "$pane" --arg agent "$agent" \
              '.agent_status[$p]="working" | .agent[$p]=$agent | del(.pending[$p])' | save_state
          fi
          ;;
      esac
    fi
    ;;
  "pane close")
    pane=${3:-}
    jq_state --arg p "$pane" \
      '.tabs |= [.[] | select(.pane_id != $p)]
       | .tabs as $tabs
       | .workspaces |= [.[] | . as $w | select([$tabs[] | select(.workspace_id == $w.workspace_id)] | length > 0)]
       | del(.agent_status[$p]) | del(.agent[$p]) | del(.pending[$p])' | save_state
    ;;
  "agent get")
    pane=${3:-}; status=$(jq_state -r --arg p "$pane" '.agent_status[$p] // empty')
    if [ -n "$status" ]; then
      agent=$(jq_state -r --arg p "$pane" '.agent[$p] // "codex"')
      printf '{"result":{"agent":{"agent":"%s","agent_status":"%s"}}}\n' "$agent" "$status"
    else
      printf '{"error":{"code":"agent_not_found","message":"agent target %s not found"}}\n' "$pane"
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
  chmod +x "$fakebin/tmux" "$fakebin/herdr" "$fakebin/treehouse" "$fakebin/no-mistakes" \
    "$fakebin/pi" "$fakebin/pi-signed" "$fakebin/muse"
  printf '%s\n' "$fakebin"
}

setup_case() {  # <name> <task-id> <ship|scout> [project-suffix] [worktree-suffix]
  local name=$1 id=$2 kind=$3 project_suffix=${4:-} worktree_suffix=${5:-}
  CASE="$TMP_ROOT/$name"
  HOME_DIR="$CASE/home"
  PROJ="$CASE/project$project_suffix"
  WT="$CASE/adopted-wt$worktree_suffix"
  TLOG="$CASE/tmux.log"
  TREELOG="$CASE/treehouse.log"
  WINDOW_STATE="$CASE/window.state"
  SERVER_IDENTITY_STATE="$CASE/server-identity.state"
  SERVER_LOCATOR_STATE="$CASE/server-locator.state"
  PROVISIONAL_TOKEN_STATE="$CASE/provisional-token.state"
  SEND_COUNT="$CASE/send.count"
  HERDR_STATE="$CASE/herdr-state.json"
  HERDR_LOG="$CASE/herdr.log"
  HERDR_SOCKET="$CASE/socket/herdr.sock"
  FAKEBIN=$(make_fakebin "$CASE/fakes")
  mkdir -p "$HOME_DIR/data/$id" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects"
  : > "$TLOG"
  : > "$TREELOG"
  : > "$WINDOW_STATE"
  printf '%s\n' '4242:123456' > "$SERVER_IDENTITY_STATE"
  printf '%s\n' '/tmp/fm-adopt-tmux-a.sock' > "$SERVER_LOCATOR_STATE"
  : > "$PROVISIONAL_TOKEN_STATE"
  : > "$SEND_COUNT"
  mkdir -p "$(dirname "$HERDR_SOCKET")"
  : > "$HERDR_LOG"
  git init -q -b main "$PROJ"
  printf '%s\n' baseline > "$PROJ/base.txt"
  git -C "$PROJ" add base.txt
  git -C "$PROJ" commit -q -m baseline
  git -C "$PROJ" worktree add -q -b "recovered/$id" "$WT" main
  printf '%s\n' "{\"next\":2,\"workspaces\":[{\"workspace_id\":\"w1\",\"label\":\"launcher\"}],\"tabs\":[{\"tab_id\":\"w1:t1\",\"label\":\"launcher\",\"workspace_id\":\"w1\",\"pane_id\":\"w1:p1\",\"cwd\":\"$PROJ\"}],\"agent_status\":{},\"agent\":{},\"pending\":{},\"focused_workspace\":\"w1\",\"focused_tab\":\"w1:t1\"}" > "$HERDR_STATE"
  printf '%s\n' off > "$HOME_DIR/config/herdr-presentation-spaces"
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
    FM_ADOPT_SERVER_IDENTITY_STATE="$SERVER_IDENTITY_STATE" \
    FM_ADOPT_SERVER_LOCATOR_STATE="$SERVER_LOCATOR_STATE" \
    FM_ADOPT_PROVISIONAL_TOKEN_STATE="$PROVISIONAL_TOKEN_STATE" \
    FM_ADOPT_SIGKILL_AFTER_CREATE="${FM_ADOPT_SIGKILL_AFTER_CREATE:-0}" \
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

run_spawn_herdr() {  # <id> <ship|scout> <existing-path> [extra args...]
  local id=$1 kind=$2 existing=$3
  shift 3
  local project_arg=${FM_ADOPT_PROJECT_ARG:-$PROJ}
  local -a args
  args=("$id" "$project_arg" --harness codex --backend herdr --existing-worktree "$existing")
  if [ "$kind" = scout ]; then
    args+=(--scout)
  else
    args+=(--mode local-only --yolo off)
  fi
  HERDR_ENV=1 HERDR_PANE_ID=w1:p1 HERDR_SESSION=fmtest HERDR_SOCKET_PATH="$HERDR_SOCKET" \
    FM_ADOPT_HERDR_STATE="$HERDR_STATE" FM_ADOPT_HERDR_LOG="$HERDR_LOG" \
    FM_ADOPT_HERDR_SOCKET="$HERDR_SOCKET" \
    FM_ADOPT_HERDR_DUP_SESSION="${FM_ADOPT_HERDR_DUP_SESSION:-0}" \
    FM_ADOPT_HERDR_PARTIAL_CREATE="${FM_ADOPT_HERDR_PARTIAL_CREATE:-0}" \
    FM_ADOPT_HERDR_NO_AGENT="${FM_ADOPT_HERDR_NO_AGENT:-0}" \
    FM_ADOPT_HERDR_AGENT_OVERRIDE="${FM_ADOPT_HERDR_AGENT_OVERRIDE:-}" \
    FM_ADOPT_HERDR_FOCUS_ON_ENTER="${FM_ADOPT_HERDR_FOCUS_ON_ENTER:-0}" \
    FM_ADOPT_HERDR_CREATE_GATE="${FM_ADOPT_HERDR_CREATE_GATE:-}" \
    FM_ADOPTED_HERDR_AGENT_POLLS=2 FM_ADOPTED_HERDR_AGENT_INTERVAL=0 \
    run_spawn_command "${args[@]}" "$@"
}

run_teardown_herdr() {
  local task_home=${FM_ADOPT_TASK_HOME:-$HOME_DIR}
  FM_ROOT_OVERRIDE='' FM_HOME="$task_home" \
    FM_STATE_OVERRIDE="$task_home/state" FM_DATA_OVERRIDE="$task_home/data" \
    FM_PROJECTS_OVERRIDE="$task_home/projects" FM_CONFIG_OVERRIDE="$task_home/config" \
    FM_TEARDOWN_GUARD_DONE=1 HERDR_ENV=1 HERDR_PANE_ID=w1:p1 \
    HERDR_SESSION=fmtest HERDR_SOCKET_PATH="$HERDR_SOCKET" \
    FM_ADOPT_HERDR_STATE="$HERDR_STATE" FM_ADOPT_HERDR_LOG="$HERDR_LOG" \
    FM_ADOPT_HERDR_SOCKET="${FM_ADOPT_HERDR_SOCKET:-$HERDR_SOCKET}" PATH="$FAKEBIN:$PATH" \
    "$TEARDOWN" "$@" 2>&1
}

run_teardown() {
  local task_home=${FM_ADOPT_TASK_HOME:-$HOME_DIR}
  FM_ROOT_OVERRIDE='' FM_HOME="$task_home" \
    FM_STATE_OVERRIDE="$task_home/state" FM_DATA_OVERRIDE="$task_home/data" \
    FM_PROJECTS_OVERRIDE="$task_home/projects" FM_CONFIG_OVERRIDE="$task_home/config" \
    FM_TEARDOWN_GUARD_DONE=1 FM_ADOPT_TMUX_LOG="$TLOG" \
    FM_ADOPT_TREEHOUSE_LOG="$TREELOG" FM_ADOPT_WINDOW_STATE="$WINDOW_STATE" \
    FM_ADOPT_SERVER_LOCATOR_STATE="$SERVER_LOCATOR_STATE" \
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

test_herdr_adoption_publishes_verified_identity_and_preserves_worktree() {
  local id=adopt-herdr-safe-b3 out status branch head index_before index_after task_pane
  setup_case herdr-safe "$id" ship
  printf '%s\n' staged > "$WT/staged.txt"
  git -C "$WT" add staged.txt
  printf '%s\n' modified >> "$WT/base.txt"
  printf '%s\n' untracked > "$WT/untracked.txt"
  branch=$(git -C "$WT" symbolic-ref --short HEAD)
  head=$(git -C "$WT" rev-parse HEAD)
  index_before=$(git -C "$WT" ls-files --stage)

  out=$(run_spawn_herdr "$id" ship "$WT")
  status=$?
  expect_code 0 "$status" "safe adopted Herdr ship should spawn"
  assert_contains "$out" "spawned $id" "safe adopted Herdr ship did not report success"
  assert_grep 'backend=herdr' "$HOME_DIR/state/$id.meta" "Herdr adoption omitted backend identity"
  assert_grep 'adopted_delivery=complete' "$HOME_DIR/state/$id.meta" "Herdr adoption published metadata before endpoint completion"
  assert_grep "adopted_herdr_socket_identity=$HERDR_SOCKET" "$HOME_DIR/state/$id.meta" "Herdr adoption omitted exact socket identity"
  assert_grep 'adopted_herdr_parent_workspace_id=w1' "$HOME_DIR/state/$id.meta" "Herdr adoption omitted exact launcher workspace"
  assert_grep 'herdr_workspace_id=w1' "$HOME_DIR/state/$id.meta" "flat Herdr adoption did not remain in the exact parent workspace"
  assert_grep 'adopted_herdr_agent=codex' "$HOME_DIR/state/$id.meta" "Herdr adoption omitted response-verified agent identity"
  assert_grep 'phase=agent' "$HOME_DIR/state/$id.adopted-endpoint" "Herdr endpoint transaction did not reach the agent phase"
  task_pane=$(sed -n 's/^herdr_pane_id=//p' "$HOME_DIR/state/$id.meta")
  [ "$(jq -r --arg p "$task_pane" --arg wt "$WT" '[.tabs[] | select(.pane_id == $p and .cwd == $wt)] | length' "$HERDR_STATE")" = 1 ] \
    || fail "Herdr task pane was not created in the exact adopted worktree"
  [ "$(jq -r '.focused_tab' "$HERDR_STATE")" = w1:t1 ] || fail "successful Herdr adoption changed the captain's active tab"
  [ "$(git -C "$WT" symbolic-ref --short HEAD)" = "$branch" ] || fail "Herdr adoption switched the adopted branch"
  [ "$(git -C "$WT" rev-parse HEAD)" = "$head" ] || fail "Herdr adoption changed adopted HEAD"
  index_after=$(git -C "$WT" ls-files --stage)
  [ "$index_after" = "$index_before" ] || fail "Herdr adoption changed the adopted index"
  [ "$(tail -n 1 "$WT/base.txt")" = modified ] || fail "Herdr adoption changed an existing worktree edit"
  [ "$(cat "$WT/untracked.txt")" = untracked ] || fail "Herdr adoption changed an untracked file"
  assert_no_grep 'treehouse ' "$TREELOG" "Herdr adoption invoked Treehouse"
  pass "fm-spawn adopts through Herdr only after exact endpoint/agent verification and preserves Git state and focus"
}

test_herdr_endpoint_journal_is_atomic_strict_and_forward_only() {
  local dir journal token=1234567890123456789012
  dir="$TMP_ROOT/herdr-journal"; mkdir -p "$dir/home" "$dir/worktree"
  journal="$dir/task.adopted-endpoint"
  fm_adopted_endpoint_journal_create \
    "$journal" task-journal "$token" "$dir/home" fmtest "$dir/herdr.sock" \
    w1 flat w1 fm-task-journal "$dir/worktree" \
    || fail "valid Herdr endpoint journal create failed"
  assert_grep 'phase=creating' "$journal" "Herdr endpoint journal did not begin before creation"
  if fm_adopted_endpoint_journal_create \
    "$journal" task-journal other-token "$dir/home" fmtest "$dir/herdr.sock" \
    w1 flat w1 fm-task-journal "$dir/worktree"; then
    fail "Herdr endpoint journal create overwrote an existing transaction"
  fi
  if fm_adopted_endpoint_journal_advance "$journal" "$token" agent w1 w1:t2 w1:p2 codex; then
    fail "Herdr endpoint journal skipped the response-derived endpoint phase"
  fi
  fm_adopted_endpoint_journal_advance "$journal" "$token" endpoint w1 w1:t2 w1:p2 "" \
    || fail "Herdr endpoint journal did not commit endpoint identity"
  if fm_adopted_endpoint_journal_advance "$journal" wrong-token agent w1 w1:t2 w1:p2 codex; then
    fail "Herdr endpoint journal advanced under the wrong attempt token"
  fi
  fm_adopted_endpoint_journal_advance "$journal" "$token" agent w1 w1:t2 w1:p2 codex \
    || fail "Herdr endpoint journal did not commit agent identity"
  if fm_adopted_endpoint_journal_advance "$journal" "$token" endpoint w1 w1:t2 w1:p2 ""; then
    fail "Herdr endpoint journal regressed after agent identity publication"
  fi
  fm_adopted_endpoint_journal_load "$journal" || fail "complete Herdr endpoint journal did not reload"
  [ "$FM_ADOPTED_ENDPOINT_PHASE:$FM_ADOPTED_ENDPOINT_AGENT" = agent:codex ] \
    || fail "complete Herdr endpoint journal reloaded contradictory identity"
  printf '%s\n' 'agent=duplicate' >> "$journal"
  if fm_adopted_endpoint_journal_load "$journal"; then
    fail "Herdr endpoint journal accepted duplicate identity fields"
  fi
  pass "Herdr endpoint journal publication is no-overwrite, strict, token-bound, and forward-only"
}

test_herdr_projected_adoption_keeps_authority_exact_and_focus_stable() {
  local id=adopt-herdr-projected-b4 out status parent workspace pane
  setup_case herdr-projected "$id" ship
  printf '%s\n' on > "$HOME_DIR/config/herdr-presentation-spaces"
  jq '(.workspaces[] | select(.workspace_id == "w1") | .label)="firstmate"' \
    "$HERDR_STATE" > "$HERDR_STATE.tmp" && mv "$HERDR_STATE.tmp" "$HERDR_STATE"

  out=$(run_spawn_herdr "$id" ship "$WT"); status=$?
  expect_code 0 "$status" "projected adopted Herdr ship should spawn"
  assert_contains "$out" "spawned $id" "projected Herdr adoption did not report success"
  parent=$(sed -n 's/^adopted_herdr_parent_workspace_id=//p' "$HOME_DIR/state/$id.meta")
  workspace=$(sed -n 's/^herdr_workspace_id=//p' "$HOME_DIR/state/$id.meta")
  pane=$(sed -n 's/^herdr_pane_id=//p' "$HOME_DIR/state/$id.meta")
  [ "$parent" = w1 ] || fail "projected Herdr adoption changed the exact launcher parent"
  [ "$workspace" != "$parent" ] || fail "projected Herdr adoption did not isolate presentation from its parent"
  assert_grep 'layout=projected' "$HOME_DIR/state/$id.adopted-endpoint" "projected Herdr adoption did not record its presentation layout"
  assert_grep "parent_workspace_id=$parent" "$HOME_DIR/state/$id.adopted-endpoint" "projected Herdr transaction lost task authority's parent"
  assert_grep "workspace_id=$workspace" "$HOME_DIR/state/$id.adopted-endpoint" "projected Herdr transaction lost endpoint authority"
  assert_grep "pane_id=$pane" "$HOME_DIR/state/$id.adopted-endpoint" "projected Herdr transaction lost pane authority"
  assert_grep 'version=2' "$HOME_DIR/state/$id.herdr-presentation" "projected Herdr adoption did not bind its presentation journal"
  [ "$(jq --arg w "$workspace" --arg p "$pane" --arg wt "$WT" \
    '[.tabs[] | select(.workspace_id == $w and .pane_id == $p and .cwd == $wt)] | length' "$HERDR_STATE")" = 1 ] \
    || fail "projected Herdr endpoint did not remain in the exact adopted worktree"
  [ "$(jq --arg w "$workspace" '[.tabs[] | select(.workspace_id == $w)] | length' "$HERDR_STATE")" = 1 ] \
    || fail "projected Herdr presentation did not converge to one authoritative task pane"
  [ "$(jq -r '.focused_tab' "$HERDR_STATE")" = w1:t1 ] || fail "projected Herdr adoption changed the captain's active tab"
  assert_no_grep 'treehouse ' "$TREELOG" "projected Herdr adoption invoked Treehouse"
  pass "optional Herdr presentation keeps exact endpoint/worktree authority separate and preserves active focus"
}

test_herdr_identity_and_live_claim_refusals_precede_creation() {
  local id out status
  id=adopt-herdr-ambiguous-c4
  setup_case herdr-ambiguous "$id" ship
  out=$(FM_ADOPT_HERDR_DUP_SESSION=1 run_spawn_herdr "$id" ship "$WT"); status=$?
  expect_code 1 "$status" "duplicate running Herdr session identity should refuse"
  assert_contains "$out" "could not resolve the exact socket" "duplicate-session refusal did not name exact runtime identity"
  [ "$(jq --arg label "fm-$id" '[.tabs[] | select(.label == $label)] | length' "$HERDR_STATE")" = 0 ] \
    || fail "ambiguous Herdr identity created an endpoint"
  assert_absent "$HOME_DIR/state/$id.meta" "ambiguous Herdr identity published metadata"
  assert_absent "$HOME_DIR/state/$id.adopted-endpoint" "ambiguous Herdr identity published an endpoint transaction"
  [ "$(jq -r '.focused_tab' "$HERDR_STATE")" = w1:t1 ] || fail "ambiguous Herdr identity changed focus"

  id=adopt-herdr-live-claim-c5
  setup_case herdr-live-claim "$id" ship
  jq --arg wt "$WT" \
    '.workspaces += [{workspace_id:"w2",label:"duplicate"}]
     | .tabs += [{tab_id:"w2:t7",label:"fm-other-task",workspace_id:"w2",pane_id:"w2:p7",cwd:$wt}]' \
    "$HERDR_STATE" > "$HERDR_STATE.tmp" && mv "$HERDR_STATE.tmp" "$HERDR_STATE"
  out=$(run_spawn_herdr "$id" ship "$WT"); status=$?
  expect_code 1 "$status" "a live Herdr task occupying the worktree should refuse"
  assert_contains "$out" "already claimed by live herdr task other-task" "Herdr live claim refusal did not name the exact owner"
  [ "$(jq --arg label "fm-$id" '[.tabs[] | select(.label == $label)] | length' "$HERDR_STATE")" = 0 ] \
    || fail "Herdr live claim refusal created an endpoint"
  assert_absent "$HOME_DIR/state/$id.meta" "Herdr live claim refusal published metadata"
  [ "$(jq -r '.focused_tab' "$HERDR_STATE")" = w1:t1 ] || fail "Herdr live claim refusal changed focus"
  pass "Herdr adoption refuses ambiguous runtime identity and exact live worktree claims before mutation"
}

test_herdr_partial_create_fails_closed_without_duplicate_or_guessed_cleanup() {
  local id=adopt-herdr-partial-d6 out status creates
  setup_case herdr-partial "$id" ship
  out=$(FM_ADOPT_HERDR_PARTIAL_CREATE=1 run_spawn_herdr "$id" ship "$WT"); status=$?
  expect_code 1 "$status" "partial Herdr endpoint response should refuse"
  assert_contains "$out" "incomplete response identity" "partial Herdr response refusal lacked response-derived evidence"
  assert_absent "$HOME_DIR/state/$id.meta" "partial Herdr response published metadata"
  assert_grep 'phase=creating' "$HOME_DIR/state/$id.adopted-endpoint" "partial Herdr response lost its fail-closed creation marker"
  assert_no_grep $'pane\x1fclose' "$HERDR_LOG" "partial Herdr response guessed an endpoint to close"
  creates=$(grep -c $'\x1ftab\x1fcreate' "$HERDR_LOG")

  out=$(run_spawn_herdr "$id" ship "$WT"); status=$?
  expect_code 1 "$status" "retry after identity-less Herdr creation should fail closed"
  assert_contains "$out" "no complete response-derived identity" "partial-create retry did not explain duplicate prevention"
  [ "$(grep -c $'\x1ftab\x1fcreate' "$HERDR_LOG")" -eq "$creates" ] \
    || fail "partial-create retry duplicated the Herdr endpoint"
  assert_absent "$HOME_DIR/state/$id.meta" "partial-create retry published metadata"
  [ "$(jq -r '.focused_tab' "$HERDR_STATE")" = w1:t1 ] || fail "partial-create refusal or retry changed focus"
  pass "partial Herdr creation keeps a creation marker, grants no guessed cleanup authority, and cannot duplicate on retry"
}

test_herdr_exact_endpoint_resume_never_duplicates() {
  local id=adopt-herdr-resume-e7 out status task_pane creates
  setup_case herdr-resume "$id" ship
  out=$(FM_ADOPT_HERDR_NO_AGENT=1 FM_ADOPT_HERDR_FOCUS_ON_ENTER=1 \
    run_spawn_herdr "$id" ship "$WT"); status=$?
  expect_code 1 "$status" "interrupted Herdr launch fixture should fail before agent publication"
  assert_absent "$HOME_DIR/state/$id.meta" "interrupted Herdr launch published incomplete metadata"
  assert_grep 'phase=endpoint' "$HOME_DIR/state/$id.adopted-endpoint" "interrupted Herdr launch lost its exact endpoint identity"
  task_pane=$(sed -n 's/^pane_id=//p' "$HOME_DIR/state/$id.adopted-endpoint")
  [ -n "$task_pane" ] || fail "interrupted Herdr launch journal omitted the pane id"
  [ "$(jq --arg p "$task_pane" '[.tabs[] | select(.pane_id == $p)] | length' "$HERDR_STATE")" = 1 ] \
    || fail "interrupted Herdr launch did not retain the exact journal-bound pane"
  creates=$(grep -c $'\x1ftab\x1fcreate' "$HERDR_LOG")
  jq '.focused_workspace="w1" | .focused_tab="w1:t1"' "$HERDR_STATE" > "$HERDR_STATE.tmp" \
    && mv "$HERDR_STATE.tmp" "$HERDR_STATE"

  out=$(run_spawn_herdr "$id" ship "$WT"); status=$?
  expect_code 0 "$status" "retry should resume the exact journal-bound Herdr endpoint"
  assert_contains "$out" "spawned $id" "exact Herdr endpoint retry did not complete"
  [ "$(grep -c $'\x1ftab\x1fcreate' "$HERDR_LOG")" -eq "$creates" ] \
    || fail "exact Herdr endpoint retry created a duplicate pane"
  assert_grep "herdr_pane_id=$task_pane" "$HOME_DIR/state/$id.meta" "retry did not publish the exact resumed pane"
  assert_grep 'phase=agent' "$HOME_DIR/state/$id.adopted-endpoint" "exact retry did not commit the agent identity"
  [ "$(jq -r '.focused_tab' "$HERDR_STATE")" = w1:t1 ] || fail "exact Herdr retry changed the captain's active tab"
  pass "an interrupted Herdr launch resumes its exact journal-bound endpoint without duplicate panes"
}

test_herdr_stale_transaction_refuses_without_mutation() {
  local id=adopt-herdr-stale-f8 out status creates
  setup_case herdr-stale "$id" ship
  run_spawn_herdr "$id" ship "$WT" >/dev/null
  sed 's/^pane_id=.*/pane_id=w1:p-stale/' "$HOME_DIR/state/$id.adopted-endpoint" \
    > "$HOME_DIR/state/$id.adopted-endpoint.tmp"
  mv "$HOME_DIR/state/$id.adopted-endpoint.tmp" "$HOME_DIR/state/$id.adopted-endpoint"
  creates=$(grep -c $'\x1ftab\x1fcreate' "$HERDR_LOG")
  out=$(run_spawn_herdr "$id" ship "$WT"); status=$?
  expect_code 1 "$status" "stale Herdr transaction should refuse recovery"
  assert_contains "$out" "no longer matches its exact transaction identity" "stale Herdr transaction refusal lacked exact identity evidence"
  [ "$(grep -c $'\x1ftab\x1fcreate' "$HERDR_LOG")" -eq "$creates" ] \
    || fail "stale Herdr transaction recovery created another endpoint"
  assert_present "$HOME_DIR/state/$id.meta" "stale Herdr transaction refusal erased durable metadata"
  [ "$(jq -r '.focused_tab' "$HERDR_STATE")" = w1:t1 ] || fail "stale Herdr transaction refusal changed focus"
  pass "stale Herdr metadata/transaction identity fails closed without endpoint or focus mutation"
}

test_herdr_secondmate_home_caller_uses_its_exact_home_and_parent() {
  local id=adopt-herdr-secondmate-g9 out status direct_project direct_wt home_real
  setup_case herdr-secondmate "$id" ship
  printf '%s\n' secondmate-parent > "$HOME_DIR/.fm-secondmate-home"
  direct_project="$HOME_DIR/projects/project"
  direct_wt="$CASE/secondmate-adopted-wt"
  git init -q -b main "$direct_project"
  printf '%s\n' baseline > "$direct_project/base.txt"
  git -C "$direct_project" add base.txt
  git -C "$direct_project" commit -q -m baseline
  git -C "$direct_project" worktree add -q -b "recovered/$id" "$direct_wt" main
  PROJ=$direct_project
  WT=$direct_wt
  jq --arg cwd "$PROJ" '(.tabs[] | select(.pane_id == "w1:p1") | .cwd)=$cwd' \
    "$HERDR_STATE" > "$HERDR_STATE.tmp" && mv "$HERDR_STATE.tmp" "$HERDR_STATE"
  home_real=$(cd "$HOME_DIR" && pwd -P)

  out=$(run_spawn_herdr "$id" ship "$WT"); status=$?
  expect_code 0 "$status" "ordinary worker in a secondmate home should adopt through Herdr"
  assert_contains "$out" "spawned $id" "secondmate-home Herdr adoption did not report success"
  assert_grep "home=$home_real" "$HOME_DIR/state/$id.adopted-endpoint" "Herdr adoption journal did not bind the secondmate home"
  assert_grep 'parent_workspace_id=w1' "$HOME_DIR/state/$id.adopted-endpoint" "secondmate-home adoption did not bind its launcher's exact parent"
  assert_grep "worktree=$WT" "$HOME_DIR/state/$id.meta" "secondmate-home adoption published the wrong worktree"
  assert_no_grep 'treehouse ' "$TREELOG" "secondmate-home Herdr adoption invoked Treehouse"
  pass "an ordinary worker launched by a secondmate home adopts through that exact home and launcher parent"
}

test_concurrent_same_task_herdr_adoption_creates_once() {
  local id=adopt-herdr-concurrent-h0 gate first_out second_out status first_pid i
  setup_case herdr-concurrent "$id" ship
  gate="$CASE/create-gate"
  first_out="$CASE/first.out"
  FM_ADOPT_HERDR_CREATE_GATE="$gate" run_spawn_herdr "$id" ship "$WT" > "$first_out" 2>&1 &
  first_pid=$!
  i=0
  while [ ! -e "$gate.started" ] && [ "$i" -lt 500 ]; do sleep 0.01; i=$((i + 1)); done
  [ -e "$gate.started" ] || { touch "$gate.release"; wait "$first_pid" || true; fail "concurrent Herdr fixture did not reach endpoint creation"; }
  second_out=$(run_spawn_herdr "$id" ship "$WT"); status=$?
  expect_code 1 "$status" "concurrent same-task Herdr spawn should refuse behind the task lock"
  assert_contains "$second_out" "another spawn is already creating task $id" "concurrent Herdr refusal did not name the task lock"
  touch "$gate.release"
  wait "$first_pid" || fail "the lock-owning Herdr spawn did not complete"
  [ "$(grep -c $'\x1ftab\x1fcreate' "$HERDR_LOG")" -eq 1 ] || fail "concurrent same-task Herdr attempts created more than one endpoint"
  assert_grep 'adopted_delivery=complete' "$HOME_DIR/state/$id.meta" "the lock-owning Herdr spawn did not publish complete identity"
  [ "$(jq -r '.focused_tab' "$HERDR_STATE")" = w1:t1 ] || fail "concurrent Herdr attempts changed focus"
  pass "concurrent same-task Herdr adoption is serialized before creation and produces one endpoint"
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

  id=adopt-inverse-primary-e6
  setup_case inverse-primary "$id" ship
  out=$(FM_ADOPT_PROJECT_ARG="$WT" FM_ADOPT_BASE_PANE_PATH="$CASE" run_spawn "$id" ship "$PROJ"); status=$?
  expect_code 1 "$status" "linked worktree project argument must not make the primary checkout adoptable"
  assert_contains "$out" 'requested project is not the canonical primary Git worktree' "inverse primary refusal lacked canonical-project evidence"
  assert_no_endpoint_created
  assert_absent "$HOME_DIR/state/$id.meta" "inverse primary refusal published metadata"

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

  id=adopt-project-tab-j1
  setup_case project-tab "$id" ship $'\tunsafe'
  out=$(run_spawn "$id" ship "$WT"); status=$?
  expect_code 1 "$status" "tab-bearing requested project should refuse"
  assert_contains "$out" 'requested project path must not contain a tab' "project-tab refusal did not name the metadata-safety boundary"
  assert_no_endpoint_created
  assert_absent "$HOME_DIR/state/$id.meta" "project-tab refusal published malformed metadata"

  id=adopt-worktree-tab-j2
  setup_case worktree-tab "$id" ship '' $'\tunsafe'
  out=$(run_spawn "$id" ship "$WT"); status=$?
  expect_code 1 "$status" "tab-bearing adopted worktree should refuse"
  assert_contains "$out" '--existing-worktree path must not contain a tab' "worktree-tab refusal did not name the metadata-safety boundary"
  assert_no_endpoint_created
  assert_absent "$HOME_DIR/state/$id.meta" "worktree-tab refusal published malformed metadata"

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

test_cross_home_dead_durable_claim_refuses() {
  local first_id=adopt-home-a-k2 second_id=adopt-home-b-k3 home_b out status
  setup_case cross-home-dead-claim "$first_id" ship
  run_spawn "$first_id" ship "$WT" >/dev/null \
    || fail "cross-home fixture could not publish the first durable adoption"
  assert_present "$HOME_DIR/state/$first_id.meta" "cross-home fixture lost the first home's durable metadata"
  : > "$WINDOW_STATE"
  : > "$TLOG"

  home_b="$CASE/home-b"
  mkdir -p "$home_b/data/$second_id" "$home_b/state" "$home_b/config" "$home_b/projects"
  printf '%s\n' 'Delivery contract: mode=local-only' > "$home_b/data/$second_id/brief.md"
  out=$(FM_ADOPT_TASK_HOME="$home_b" run_spawn "$second_id" ship "$WT")
  status=$?
  expect_code 1 "$status" "a second home should refuse another home's dead durable adoption claim"
  assert_contains "$out" "already claimed by durable Firstmate task $first_id" "cross-home refusal did not identify the durable owner"
  assert_no_endpoint_created
  assert_absent "$home_b/state/$second_id.meta" "cross-home refusal published duplicate task metadata"
  assert_present "$HOME_DIR/state/$first_id.meta" "cross-home refusal changed the original durable owner"
  pass "fm-spawn enforces adopted-worktree durable claims across Firstmate homes after endpoint death"
}

test_incompatible_modes_refuse_before_endpoint() {
  local id out status backend
  id=adopt-mode-j1
  setup_case modes "$id" ship

  out=$(run_spawn_command "$id" --secondmate --harness codex --existing-worktree "$WT"); status=$?
  expect_code 1 "$status" "secondmate adoption should refuse"
  assert_contains "$out" 'ordinary ship and scout tasks only' "secondmate refusal was not explicit"

  for backend in orca zellij cmux; do
    out=$(run_spawn "$id" ship "$WT" --backend "$backend"); status=$?
    expect_code 1 "$status" "$backend adoption should refuse"
    assert_contains "$out" 'supports backend=tmux or backend=herdr only' "$backend refusal was not explicit"
  done

  out=$(run_spawn "$id" ship "$WT" --harness claude); status=$?
  expect_code 1 "$status" "worktree-writing harness should refuse"
  assert_contains "$out" 'is not adoption-safe' "harness refusal did not name the safety boundary"

  out=$(run_spawn_command "$id=$PROJ" --harness codex --backend tmux --mode local-only --yolo off \
    --existing-worktree "$WT"); status=$?
  expect_code 1 "$status" "batch adoption should refuse"
  assert_contains "$out" 'cannot be shared by batch dispatch' "batch refusal was not explicit"
  assert_no_endpoint_created
  pass "fm-spawn rejects secondmate, unsupported-backend, unsafe-harness, and batch adoption modes"
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

test_endpoint_cwd_mismatch_refuses_unbound_cleanup() {
  local id=adopt-cwd-mismatch-k2 out status
  setup_case cwd-mismatch "$id" ship
  out=$(FM_FAKE_PANE_PATH="$PROJ" run_spawn_command \
    "$id" "$PROJ" --harness codex --backend tmux --existing-worktree "$WT" \
    --mode local-only --yolo off)
  status=$?
  expect_code 1 "$status" "endpoint cwd mismatch should refuse"
  assert_contains "$out" 'endpoint did not start in the exact worktree' "cwd mismatch refusal lacked exact evidence"
  assert_contains "$out" 'failed to retire adopted task endpoint @123 safely after spawn refusal (cwd-identity)' "cwd mismatch did not surface the fail-closed cleanup boundary"
  assert_no_grep 'tmux kill-window -t @123' "$TLOG" "cwd-mismatched abort cleanup killed an endpoint it could not bind to the adopted worktree"
  [ -s "$WINDOW_STATE" ] || fail "cwd-mismatched endpoint was removed despite failed identity binding"
  assert_absent "$HOME_DIR/state/$id.meta" "cwd mismatch published task metadata"
  assert_absent "$HOME_DIR/state/$id.adopted-brief.md" "cwd mismatch retained a new adoption addendum"
  : > "$WINDOW_STATE"
  out=$(run_spawn "$id" ship "$WT")
  status=$?
  expect_code 0 "$status" "same-task recovery should reuse a preserved pre-publication global claim"
  assert_contains "$out" "spawned $id" "preserved pre-publication claim did not support same-task recovery"
  pass "fm-spawn refuses to kill a cwd-mismatched endpoint during abort cleanup"
}

test_unresolved_prepublication_endpoint_blocks_duplicate_retry() {
  local id=adopt-unresolved-endpoint-k3 out status new_windows kills common claim
  setup_case unresolved-endpoint "$id" ship
  out=$(FM_FAKE_PANE_PATH="$PROJ" run_spawn "$id" ship "$WT")
  status=$?
  expect_code 1 "$status" "pre-publication cwd mismatch should refuse"
  assert_contains "$out" 'failed to retire adopted task endpoint @123 safely after spawn refusal (cwd-identity)' \
    "pre-publication fixture did not preserve an unresolved endpoint"
  assert_absent "$HOME_DIR/state/$id.meta" "unresolved pre-publication fixture unexpectedly published metadata"
  common=$(git -C "$PROJ" rev-parse --path-format=absolute --git-common-dir)
  claim=$(find "$common/firstmate-adopted-worktree-claims-v1" -type f -name '*.claim' -print -quit)
  [ -n "$claim" ] || fail "unresolved pre-publication fixture did not retain its durable global claim"
  assert_grep 'endpoint_state=bound' "$claim" "unresolved pre-publication claim did not bind an endpoint generation"
  assert_grep 'endpoint_window_id=@123' "$claim" "unresolved pre-publication claim lost the stable endpoint id"
  assert_grep 'endpoint_server_identity=4242:123456' "$claim" "unresolved pre-publication claim lost the tmux server identity"
  assert_grep 'endpoint_session=firstmate' "$claim" "unresolved pre-publication claim lost the tmux session"
  printf '%s\n' lost-old-endpoint > "$WINDOW_STATE"

  out=$(FM_FAKE_PANE_PATH="$PROJ" run_spawn "$id" ship "$WT")
  status=$?
  expect_code 1 "$status" "same-task retry must refuse when the exact preserved endpoint cannot be retired"
  assert_contains "$out" 'pending adopted endpoint @123 could not be retired safely before retry (cwd-identity)' \
    "same-task retry did not bind its refusal to the preserved endpoint"
  new_windows=$(grep -c 'tmux new-window ' "$TLOG" || true)
  kills=$(grep -c 'tmux kill-window ' "$TLOG" || true)
  [ "$new_windows" -eq 1 ] || fail "unresolved endpoint retry created a duplicate endpoint (new_windows=$new_windows)"
  [ "$kills" -eq 0 ] || fail "unresolved endpoint retry killed an endpoint without exact identity (kills=$kills)"
  assert_absent "$HOME_DIR/state/$id.meta" "unresolved endpoint retry published replacement metadata"
  pass "fm-spawn persists unresolved pre-publication endpoint identity and refuses duplicate retry"
}

test_cross_server_retry_refuses_unproven_original_endpoint() {
  local id=adopt-cross-server-k5 out status old_window new_windows kills common claim
  setup_case cross-server "$id" ship
  run_spawn "$id" ship "$WT" >/dev/null \
    || fail "cross-server fixture could not publish its server-A adoption"
  common=$(git -C "$PROJ" rev-parse --path-format=absolute --git-common-dir)
  claim=$(find "$common/firstmate-adopted-worktree-claims-v1" -type f -name '*.claim' -print -quit)
  assert_grep 'endpoint_server_locator=/tmp/fm-adopt-tmux-a.sock' "$claim" \
    "server-A claim did not persist its exact tmux socket locator"
  assert_grep 'adopted_tmux_server_locator=/tmp/fm-adopt-tmux-a.sock' "$HOME_DIR/state/$id.meta" \
    "server-A metadata did not persist its exact tmux socket locator"
  old_window=$(cat "$WINDOW_STATE")
  : > "$WINDOW_STATE"
  printf '%s\n' '9001:654321' > "$SERVER_IDENTITY_STATE"
  printf '%s\n' '/tmp/fm-adopt-tmux-b.sock' > "$SERVER_LOCATOR_STATE"

  out=$(run_spawn "$id" ship "$WT")
  status=$?
  expect_code 1 "$status" "server-B retry must refuse while server-A endpoint absence is unproven"
  assert_contains "$out" 'bound tmux server locator differs from the current server; recovery refused' \
    "cross-server retry did not name the exact server-locator boundary"
  [ "$old_window" = "fm-$id" ] || fail "cross-server fixture lost server A's live endpoint marker"
  new_windows=$(grep -c 'tmux new-window ' "$TLOG" || true)
  kills=$(grep -c 'tmux kill-window ' "$TLOG" || true)
  [ "$new_windows" -eq 1 ] || fail "cross-server retry created a duplicate endpoint on server B (new_windows=$new_windows)"
  [ "$kills" -eq 0 ] || fail "cross-server retry killed an endpoint through the wrong server (kills=$kills)"
  assert_present "$HOME_DIR/state/$id.meta" "cross-server retry erased server A's durable metadata"
  pass "fm-spawn refuses cross-server recovery without proof about the bound original endpoint"
}

test_sigkill_creation_gap_recovers_provisional_endpoint() {
  local id=adopt-sigkill-gap-k6 first_out first_rc retry_out retry_status
  local common claim new_windows kills
  setup_case sigkill-gap "$id" ship
  first_out="$CASE/first.out"
  first_rc="$CASE/first.rc"
  (
    FM_ADOPT_SIGKILL_AFTER_CREATE=1 run_spawn "$id" ship "$WT" > "$first_out"
    printf '%s\n' "$?" > "$first_rc"
  ) 2>/dev/null
  [ -s "$first_rc" ] || fail "SIGKILL fixture did not report the killed spawn status"
  expect_code 137 "$(cat "$first_rc")" "spawn should be SIGKILLed immediately after endpoint creation"
  assert_absent "$HOME_DIR/state/$id.meta" "SIGKILL gap unexpectedly published local task metadata"
  [ -s "$WINDOW_STATE" ] || fail "SIGKILL gap did not leave the created endpoint live"
  common=$(git -C "$PROJ" rev-parse --path-format=absolute --git-common-dir)
  claim=$(find "$common/firstmate-adopted-worktree-claims-v1" -type f -name '*.claim' -print -quit)
  [ -n "$claim" ] || fail "SIGKILL gap lost the durable global claim"
  assert_grep 'endpoint_state=creating' "$claim" "SIGKILL gap did not retain the creation transaction"
  assert_grep 'endpoint_server_locator=/tmp/fm-adopt-tmux-a.sock' "$claim" \
    "SIGKILL gap claim lost its exact tmux socket locator"
  assert_grep 'endpoint_provisional_token=' "$claim" "SIGKILL gap claim cannot rediscover the created endpoint"
  assert_grep "endpoint_provisional_token=$(cat "$PROVISIONAL_TOKEN_STATE")" "$claim" \
    "SIGKILL gap claim token does not identify the created endpoint"

  retry_out=$(FM_ADOPT_LIVE_WINDOW_ID=@123 run_spawn "$id" ship "$WT")
  retry_status=$?
  expect_code 0 "$retry_status" "same-task retry should reconcile and replace the provisional endpoint"
  assert_contains "$retry_out" "spawned $id" "SIGKILL gap retry did not relaunch"
  new_windows=$(grep -c 'tmux new-window ' "$TLOG" || true)
  kills=$(grep -c 'tmux kill-window ' "$TLOG" || true)
  [ "$new_windows" -eq 2 ] || fail "SIGKILL recovery did not create exactly one replacement (new_windows=$new_windows)"
  [ "$kills" -eq 1 ] || fail "SIGKILL recovery did not retire exactly the provisional endpoint (kills=$kills)"
  assert_present "$HOME_DIR/state/$id.meta" "SIGKILL recovery did not publish task metadata"
  pass "fm-spawn recovers a SIGKILL between endpoint creation and durable stable-id binding"
}

test_teardown_serializes_against_same_id_recovery() {
  local id=adopt-teardown-generation-k4 ready release teardown_out teardown_rc_file
  local teardown_pid spawn_out spawn_status teardown_status new_windows
  setup_case teardown-generation "$id" ship
  run_spawn "$id" ship "$WT" >/dev/null \
    || fail "teardown-generation fixture could not publish its initial adoption"
  ready="$CASE/teardown.ready"
  release="$CASE/teardown.release"
  teardown_out="$CASE/teardown.out"
  teardown_rc_file="$CASE/teardown.rc"
  cat > "$FAKEBIN/git" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${FM_ADOPT_TEARDOWN_PAUSE_READY:-}" ] \
   && printf '%s\n' "$*" | grep -q 'worktree list'; then
  : > "$FM_ADOPT_TEARDOWN_PAUSE_READY"
  while [ ! -e "$FM_ADOPT_TEARDOWN_PAUSE_RELEASE" ]; do sleep 0.05; done
fi
exec "$FM_ADOPT_REAL_GIT" "$@"
SH
  chmod +x "$FAKEBIN/git"

  (
    FM_ADOPT_TEARDOWN_PAUSE_READY="$ready" \
      FM_ADOPT_TEARDOWN_PAUSE_RELEASE="$release" \
      FM_ADOPT_REAL_GIT="$REAL_GIT" run_teardown "$id" > "$teardown_out"
    printf '%s\n' "$?" > "$teardown_rc_file"
  ) &
  teardown_pid=$!
  for _ in $(seq 1 200); do
    [ -e "$ready" ] && break
    sleep 0.05
  done
  if [ ! -e "$ready" ]; then
    : > "$release"
    wait "$teardown_pid" || true
    fail "teardown-generation fixture did not pause after reading task identity"
  fi

  spawn_out=$(run_spawn "$id" ship "$WT")
  spawn_status=$?
  : > "$release"
  wait "$teardown_pid" || true
  teardown_status=$(cat "$teardown_rc_file")

  expect_code 1 "$spawn_status" "same-ID recovery must not publish while teardown owns the task generation"
  assert_contains "$spawn_out" "another spawn is already creating task $id" \
    "concurrent recovery did not refuse on the shared task-generation lock"
  [ "$teardown_status" -eq 0 ] || fail "serialized teardown should complete after the pause clears (output: $(cat "$teardown_out"))"
  assert_absent "$HOME_DIR/state/$id.meta" "serialized teardown retained its retired generation metadata"
  new_windows=$(grep -c 'tmux new-window ' "$TLOG" || true)
  [ "$new_windows" -eq 1 ] || fail "concurrent recovery created a replacement endpoint during teardown (new_windows=$new_windows)"
  pass "fm-teardown serializes old-generation retirement against same-ID recovery publication"
}

test_teardown_refuses_spawn_generation_in_progress() {
  local id=adopt-spawn-first-k7 ready release spawn_out spawn_rc teardown_out teardown_rc
  local spawn_pid teardown_pid teardown_finished=0 new_windows
  setup_case spawn-first "$id" ship
  ready="$CASE/spawn.ready"
  release="$CASE/spawn.release"
  spawn_out="$CASE/spawn.out"
  spawn_rc="$CASE/spawn.rc"
  teardown_out="$CASE/teardown.out"
  teardown_rc="$CASE/teardown.rc"
  cat > "$FAKEBIN/git" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${FM_ADOPT_SPAWN_PAUSE_READY:-}" ] \
   && printf '%s\n' "$*" | grep -q 'worktree list'; then
  : > "$FM_ADOPT_SPAWN_PAUSE_READY"
  while [ ! -e "$FM_ADOPT_SPAWN_PAUSE_RELEASE" ]; do sleep 0.05; done
fi
exec "$FM_ADOPT_REAL_GIT" "$@"
SH
  chmod +x "$FAKEBIN/git"

  (
    FM_ADOPT_SPAWN_PAUSE_READY="$ready" FM_ADOPT_SPAWN_PAUSE_RELEASE="$release" \
      FM_ADOPT_REAL_GIT="$REAL_GIT" run_spawn "$id" ship "$WT" > "$spawn_out"
    printf '%s\n' "$?" > "$spawn_rc"
  ) &
  spawn_pid=$!
  for _ in $(seq 1 200); do
    [ -e "$ready" ] && break
    sleep 0.05
  done
  if [ ! -e "$ready" ]; then
    : > "$release"
    wait "$spawn_pid" || true
    fail "spawn-first fixture did not pause while holding the task generation lock"
  fi

  (
    run_teardown "$id" > "$teardown_out"
    printf '%s\n' "$?" > "$teardown_rc"
  ) &
  teardown_pid=$!
  for _ in $(seq 1 40); do
    if [ -s "$teardown_rc" ]; then teardown_finished=1; break; fi
    sleep 0.05
  done
  : > "$release"
  wait "$spawn_pid" || true
  wait "$teardown_pid" || true

  [ "$teardown_finished" -eq 1 ] || fail "teardown waited across the in-progress spawn generation"
  expect_code 1 "$(cat "$teardown_rc")" "teardown must refuse rather than cross a spawn generation boundary"
  assert_contains "$(cat "$teardown_out")" "task lifecycle is already creating $id" \
    "spawn-first teardown refusal did not name the generation owner"
  expect_code 0 "$(cat "$spawn_rc")" "spawn should complete after the teardown refusal"
  assert_present "$HOME_DIR/state/$id.meta" "spawn-first teardown erased the newly published generation"
  new_windows=$(grep -c 'tmux new-window ' "$TLOG" || true)
  [ "$new_windows" -eq 1 ] || fail "spawn-first race created or destroyed the wrong endpoint generation"
  pass "fm-teardown refuses an in-progress spawn instead of crossing its generation boundary"
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
  assert_contains "$out" 'existing adopted endpoint @123 is still live; recovery refused' \
    "live-window recovery refusal was not bound to the durable endpoint generation"
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

test_metadata_backed_legacy_claim_upgrades_on_recovery() {
  local id=adopt-legacy-claim-l3 common claim legacy out status
  setup_case legacy-claim "$id" ship
  run_spawn "$id" ship "$WT" >/dev/null \
    || fail "legacy-claim fixture could not publish its initial adoption"
  common=$(git -C "$PROJ" rev-parse --path-format=absolute --git-common-dir)
  claim=$(find "$common/firstmate-adopted-worktree-claims-v1" -type f -name '*.claim' -print -quit)
  [ -n "$claim" ] || fail "legacy-claim fixture did not publish a global claim"
  legacy="$CASE/legacy.claim"
  {
    printf '%s\n' 'version=1'
    grep -E '^(task|home|worktree|project)=' "$claim"
  } > "$legacy"
  mv -f -- "$legacy" "$claim"
  : > "$WINDOW_STATE"

  out=$(run_spawn "$id" ship "$WT")
  status=$?
  expect_code 0 "$status" "metadata-backed version-1 claim should upgrade during same-task recovery"
  assert_contains "$out" "spawned $id" "legacy claim recovery did not relaunch"
  assert_grep 'version=3' "$claim" "legacy claim recovery did not publish the current schema"
  assert_grep 'endpoint_state=bound' "$claim" "legacy claim recovery did not bind the replacement endpoint"
  pass "fm-spawn upgrades metadata-backed path-only claims without losing recovery"
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

test_abort_cleanup_refuses_reused_window_id_after_server_restart() {
  local id=adopt-abort-server-restart-m4 out status git_count
  setup_case abort-server-restart "$id" ship
  git_count="$CASE/git-worktree-list.count"
  cat > "$FAKEBIN/git" <<'SH'
#!/usr/bin/env bash
set -u
if printf '%s\n' "$*" | grep -q 'worktree list'; then
  count=0
  [ ! -s "$FM_ADOPT_GIT_COUNT" ] || count=$(cat "$FM_ADOPT_GIT_COUNT")
  count=$((count + 1))
  printf '%s\n' "$count" > "$FM_ADOPT_GIT_COUNT"
  if [ "$count" = "$FM_ADOPT_GIT_MUTATE_AT" ]; then
    "$FM_ADOPT_REAL_GIT" -C "$FM_ADOPT_MUTATE_WT" commit -q --allow-empty -m external-race
    printf '%s\n' '9001:654321' > "$FM_ADOPT_SERVER_IDENTITY_STATE"
    printf '%s\n' unrelated-reused-window > "$FM_ADOPT_WINDOW_STATE"
  fi
fi
exec "$FM_ADOPT_REAL_GIT" "$@"
SH
  chmod +x "$FAKEBIN/git"

  out=$(FM_ADOPT_GIT_COUNT="$git_count" FM_ADOPT_GIT_MUTATE_AT=4 FM_ADOPT_MUTATE_WT="$WT" \
    run_spawn "$id" ship "$WT")
  status=$?
  expect_code 1 "$status" "server restart during abort cleanup should preserve the reused window"
  assert_contains "$out" 'identity changed during metadata publication' "server-restart fixture did not reach pre-publication abort cleanup"
  [ "$(cat "$SERVER_IDENTITY_STATE")" = '9001:654321' ] || fail "server-restart fixture did not change the tmux server identity"
  [ "$(cat "$WINDOW_STATE")" = unrelated-reused-window ] \
    || fail "abort cleanup killed an unrelated window that reused the old stable id"
  assert_no_grep 'tmux kill-window -t @123' "$TLOG" "abort cleanup killed a reused window id after server restart"
  assert_absent "$HOME_DIR/state/$id.meta" "server-restart abort cleanup published task metadata"
  pass "fm-spawn abort cleanup binds stable window ids to their creation-time tmux server"
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
  local id=adopt-teardown-l3 next_id=adopt-after-teardown-l4 out status branch head origin home_b
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

  home_b="$CASE/home-b"
  mkdir -p "$home_b/data/$next_id" "$home_b/state" "$home_b/config" "$home_b/projects"
  printf '%s\n' 'Delivery contract: mode=local-only' > "$home_b/data/$next_id/brief.md"
  out=$(FM_ADOPT_TASK_HOME="$home_b" run_spawn "$next_id" ship "$WT")
  status=$?
  expect_code 0 "$status" "successful teardown should release the global claim for later cross-home adoption"
  assert_contains "$out" "spawned $next_id" "later cross-home adoption did not succeed after teardown"
  pass "fm-teardown retires landed adopted task state and endpoint without reclaiming the worktree"
}

test_herdr_teardown_retires_exact_endpoint_and_preserves_worktree() {
  local id=adopt-herdr-teardown-l5 out status origin branch head task_pane
  setup_case herdr-teardown "$id" ship
  origin="$CASE/origin.git"
  git init -q --bare "$origin"
  git -C "$PROJ" remote add origin "$origin"
  git -C "$PROJ" push -q origin main
  git -C "$WT" push -q -u origin "recovered/$id"
  run_spawn_herdr "$id" ship "$WT" >/dev/null
  branch=$(git -C "$WT" symbolic-ref --short HEAD)
  head=$(git -C "$WT" rev-parse HEAD)
  task_pane=$(sed -n 's/^herdr_pane_id=//p' "$HOME_DIR/state/$id.meta")
  : > "$TREELOG"

  out=$(run_teardown_herdr "$id"); status=$?
  expect_code 0 "$status" "landed adopted Herdr ship teardown should complete"
  assert_contains "$out" "teardown $id complete" "adopted Herdr teardown did not report completion"
  assert_absent "$HOME_DIR/state/$id.meta" "adopted Herdr teardown retained task metadata"
  assert_absent "$HOME_DIR/state/$id.adopted-endpoint" "adopted Herdr teardown retained endpoint transaction identity"
  assert_absent "$HOME_DIR/state/$id.adopted-brief.md" "adopted Herdr teardown retained its launch addendum"
  [ "$(jq --arg p "$task_pane" '[.tabs[] | select(.pane_id == $p)] | length' "$HERDR_STATE")" = 0 ] \
    || fail "adopted Herdr teardown left the exact worker pane"
  assert_present "$WT" "adopted Herdr teardown removed the external worktree"
  [ "$(git -C "$WT" symbolic-ref --short HEAD)" = "$branch" ] || fail "adopted Herdr teardown detached or switched the branch"
  [ "$(git -C "$WT" rev-parse HEAD)" = "$head" ] || fail "adopted Herdr teardown changed HEAD"
  assert_no_grep 'treehouse ' "$TREELOG" "adopted Herdr teardown returned or mutated the worktree lease"
  [ "$(jq -r '.focused_tab' "$HERDR_STATE")" = w1:t1 ] || fail "adopted Herdr teardown changed the captain's active tab"
  pass "fm-teardown closes the exact adopted Herdr endpoint and retires state without reclaiming the worktree or focus"
}

test_herdr_teardown_refuses_socket_reincarnation_and_changed_agent() {
  local id out status origin pane
  id=adopt-herdr-teardown-socket-l6
  setup_case herdr-teardown-socket "$id" ship
  origin="$CASE/origin.git"
  git init -q --bare "$origin"
  git -C "$PROJ" remote add origin "$origin"
  git -C "$PROJ" push -q origin main
  git -C "$WT" push -q -u origin "recovered/$id"
  run_spawn_herdr "$id" ship "$WT" >/dev/null
  pane=$(sed -n 's/^herdr_pane_id=//p' "$HOME_DIR/state/$id.meta")
  out=$(FM_ADOPT_HERDR_SOCKET="$HERDR_SOCKET.restarted" run_teardown_herdr "$id"); status=$?
  expect_code 1 "$status" "Herdr session socket reincarnation should refuse adopted teardown"
  assert_contains "$out" "session/socket identity changed" "socket-reincarnation refusal did not name server identity"
  assert_present "$HOME_DIR/state/$id.meta" "socket-reincarnation refusal erased task metadata"
  assert_present "$HOME_DIR/state/$id.adopted-endpoint" "socket-reincarnation refusal erased endpoint identity"
  [ "$(jq --arg p "$pane" '[.tabs[] | select(.pane_id == $p)] | length' "$HERDR_STATE")" = 1 ] \
    || fail "socket-reincarnation refusal closed the endpoint"
  [ "$(jq -r '.focused_tab' "$HERDR_STATE")" = w1:t1 ] || fail "socket-reincarnation refusal changed focus"

  id=adopt-herdr-teardown-agent-l7
  setup_case herdr-teardown-agent "$id" ship
  origin="$CASE/origin.git"
  git init -q --bare "$origin"
  git -C "$PROJ" remote add origin "$origin"
  git -C "$PROJ" push -q origin main
  git -C "$WT" push -q -u origin "recovered/$id"
  run_spawn_herdr "$id" ship "$WT" >/dev/null
  pane=$(sed -n 's/^herdr_pane_id=//p' "$HOME_DIR/state/$id.meta")
  jq --arg p "$pane" '.agent[$p]="muse"' "$HERDR_STATE" > "$HERDR_STATE.tmp" \
    && mv "$HERDR_STATE.tmp" "$HERDR_STATE"
  out=$(run_teardown_herdr "$id"); status=$?
  expect_code 1 "$status" "changed Herdr agent identity should refuse adopted teardown"
  assert_contains "$out" "could not be closed from its exact transaction identity" "changed-agent refusal did not name exact endpoint identity"
  assert_present "$HOME_DIR/state/$id.meta" "changed-agent refusal erased task metadata"
  assert_present "$HOME_DIR/state/$id.adopted-endpoint" "changed-agent refusal erased endpoint identity"
  [ "$(jq --arg p "$pane" '[.tabs[] | select(.pane_id == $p)] | length' "$HERDR_STATE")" = 1 ] \
    || fail "changed-agent refusal closed the endpoint"
  [ "$(jq -r '.focused_tab' "$HERDR_STATE")" = w1:t1 ] || fail "changed-agent refusal changed focus"
  pass "adopted Herdr teardown fails closed across server reincarnation and changed agent identity"
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

test_teardown_refuses_without_exact_global_claim() {
  local id=adopt-missing-global-claim-p6 out status origin common claim
  setup_case missing-global-claim "$id" ship
  origin="$CASE/origin.git"
  git init -q --bare "$origin"
  git -C "$PROJ" remote add origin "$origin"
  git -C "$PROJ" push -q origin main
  git -C "$WT" push -q -u origin "recovered/$id"
  run_spawn "$id" ship "$WT" >/dev/null
  common=$(git -C "$PROJ" rev-parse --path-format=absolute --git-common-dir)
  claim=$(find "$common/firstmate-adopted-worktree-claims-v1" -type f -name '*.claim' -print -quit)
  [ -n "$claim" ] || fail "missing-claim fixture did not publish a global claim"
  rm -f -- "$claim"
  : > "$TLOG"

  out=$(run_teardown "$id")
  status=$?
  expect_code 1 "$status" "adopted teardown should refuse when its global claim is missing"
  assert_contains "$out" 'global claim is absent' "missing global claim refusal did not name the ownership gap"
  assert_present "$HOME_DIR/state/$id.meta" "missing global claim refusal erased local metadata"
  [ -s "$WINDOW_STATE" ] || fail "missing global claim refusal removed the live endpoint"
  assert_no_grep 'tmux kill-window ' "$TLOG" "missing global claim refusal closed the endpoint"
  assert_present "$WT" "missing global claim refusal removed the adopted worktree"
  pass "fm-teardown preserves endpoint and state when global adopted ownership is missing"
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
  local placement parent child sm_home child_project child_wt out status
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
    mkdir -p "$sm_home/state" "$sm_home/data/$child" "$sm_home/config" "$sm_home/projects"
    printf '%s\n' "$parent" > "$sm_home/.fm-secondmate-home"
    printf '%s\n' 'Delivery contract: mode=local-only' > "$sm_home/data/$child/brief.md"
    git init -q -b main "$child_project"
    git -C "$child_project" commit -q --allow-empty -m baseline
    git -C "$child_project" worktree add -q -b "recovered/$child" "$child_wt" main
    FM_ADOPT_TASK_HOME="$sm_home" FM_ADOPT_PROJECT_ARG="$child_project" \
      FM_FAKE_PANE_PATH="$child_wt" run_spawn "$child" ship "$child_wt" >/dev/null \
      || fail "forced-retirement fixture could not publish the $placement adopted child"
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
  local placement parent child sm_home child_project child_wt origin out status
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
    FM_ADOPT_TASK_HOME="$sm_home" FM_ADOPT_PROJECT_ARG="$child_project" \
      FM_FAKE_PANE_PATH="$child_wt" run_spawn "$child" ship "$child_wt" >/dev/null \
      || fail "completed-descendant fixture could not publish the $placement adopted child"
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
test_herdr_adoption_publishes_verified_identity_and_preserves_worktree
test_herdr_endpoint_journal_is_atomic_strict_and_forward_only
test_herdr_projected_adoption_keeps_authority_exact_and_focus_stable
test_herdr_identity_and_live_claim_refusals_precede_creation
test_herdr_partial_create_fails_closed_without_duplicate_or_guessed_cleanup
test_herdr_exact_endpoint_resume_never_duplicates
test_herdr_stale_transaction_refuses_without_mutation
test_herdr_secondmate_home_caller_uses_its_exact_home_and_parent
test_concurrent_same_task_herdr_adoption_creates_once
test_input_and_ownership_refusals_precede_endpoint
test_live_claims_and_ambiguous_tmux_inventory_refuse
test_cross_home_dead_durable_claim_refuses
test_incompatible_modes_refuse_before_endpoint
test_adoption_safe_harnesses_preserve_worktree_end_to_end
test_retireable_secondmate_home_requires_discoverable_project
test_endpoint_cwd_mismatch_refuses_unbound_cleanup
test_teardown_serializes_against_same_id_recovery
test_teardown_refuses_spawn_generation_in_progress
test_unresolved_prepublication_endpoint_blocks_duplicate_retry
test_cross_server_retry_refuses_unproven_original_endpoint
test_sigkill_creation_gap_recovers_provisional_endpoint
test_recovery_reuses_claim_and_recaptures_head
test_metadata_backed_legacy_claim_upgrades_on_recovery
test_identity_change_before_publication_refuses_atomically
test_abort_cleanup_refuses_reused_window_id_after_server_restart
test_post_publication_send_failures_are_retryable
test_teardown_retires_task_without_returning_adopted_worktree
test_herdr_teardown_retires_exact_endpoint_and_preserves_worktree
test_herdr_teardown_refuses_socket_reincarnation_and_changed_agent
test_teardown_closes_renamed_adopted_endpoint_by_stable_id
test_teardown_does_not_reap_external_worktree_processes
test_teardown_refuses_without_exact_global_claim
test_adopted_teardown_preserves_index_lock
test_symlinked_project_identity_is_canonical_and_teardown_safe
test_forced_secondmate_retirement_refuses_adopted_descendants
test_completed_adopted_descendant_still_blocks_secondmate_retirement

echo "# all existing-worktree adoption tests passed"

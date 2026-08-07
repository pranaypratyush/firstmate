#!/usr/bin/env bash
# Guarded real-Herdr smoke for adopting one disposable, pre-existing Git
# worktree through the complete spawn, metadata, and teardown lifecycle.
# Every Herdr call, including calls made by production adapters, is routed
# through the named-session lab helper and its default-fleet tripwire.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER='/home/pranay/wd/firstmate/bin/fm-herdr-lab.sh'

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
field() { sed -n "s/^$2=//p" "$1"; }
shell_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

command -v herdr >/dev/null 2>&1 || { echo 'skip: herdr not found'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }
command -v codex >/dev/null 2>&1 || { echo 'skip: codex not found for adopted-agent registration'; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

REAL_PATH=$PATH
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-adopt-e2e.XXXXXX")
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-adopt-existing-worktree-herdr) \
  || { rm -rf "$TMP_ROOT"; fail 'could not generate a guarded Herdr lab name'; }
export HERDR_LAB_HELPER HERDR_LAB_SESSION REAL_PATH

CLEANED=0
cleanup_all() {
  local status=0
  [ "$CLEANED" -eq 0 ] || return 0
  CLEANED=1
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=$?
  rm -rf "$TMP_ROOT"
  return "$status"
}
trap cleanup_all EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail 'could not provision the guarded Herdr lab'

lab() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

FAKEBIN="$TMP_ROOT/fakebin"
HERDR_CALL_LOG="$TMP_ROOT/herdr-calls.log"
TREEHOUSE_CALL_LOG="$TMP_ROOT/treehouse-calls.log"
mkdir -p "$FAKEBIN"
: > "$HERDR_CALL_LOG"
: > "$TREEHOUSE_CALL_LOG"
export HERDR_CALL_LOG TREEHOUSE_CALL_LOG

# Production's session-independent version reads and its explicitly targeted
# calls both arrive here.
# Strip only the adapter's exact trailing session pair, reject every other
# caller-supplied session flag, and let the lab helper append the real pair.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
{
  for arg in "$@"; do printf '%s\t' "$arg"; done
  printf '\n'
} >> "$HERDR_CALL_LOG"
args=("$@")
count=${#args[@]}
if [ "$count" -ge 2 ] \
   && [ "${args[$((count - 2))]}" = --session ] \
   && [ "${args[$((count - 1))]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$((count - 2))]" "args[$((count - 1))]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 97 ;; esac
done
exec env PATH="$REAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH

cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TREEHOUSE_CALL_LOG"
exit 99
SH

cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKEBIN/herdr" "$FAKEBIN/treehouse" "$FAKEBIN/no-mistakes"

HOME_DIR="$TMP_ROOT/home"
PROJECT="$TMP_ROOT/project"
WORKTREE="$TMP_ROOT/adopted-worktree"
ORIGIN="$TMP_ROOT/origin.git"
TASK=herdr-adopt-smoke
mkdir -p "$HOME_DIR/data/$TASK" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects"
printf '%s\n' on > "$HOME_DIR/config/herdr-presentation-spaces"
cat > "$HOME_DIR/data/$TASK/brief.md" <<EOF
# Guarded Herdr adoption smoke
Delivery contract: mode=local-only
Do not modify the repository.
Confirm the current physical path is $WORKTREE, then wait for supervision.
EOF

git init -q -b main "$PROJECT"
printf '%s\n' baseline > "$PROJECT/base.txt"
git -C "$PROJECT" add base.txt
git -C "$PROJECT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -q -m baseline
git -C "$PROJECT" worktree add -q -b "smoke/$TASK" "$WORKTREE" main
git init -q --bare "$ORIGIN"
git -C "$PROJECT" remote add origin "$ORIGIN"
git -C "$PROJECT" push -q origin main
git -C "$WORKTREE" push -q -u origin "smoke/$TASK"
BRANCH_BEFORE=$(git -C "$WORKTREE" symbolic-ref --short HEAD)
HEAD_BEFORE=$(git -C "$WORKTREE" rev-parse HEAD)
STATUS_BEFORE=$(git -C "$WORKTREE" status --porcelain)

make_workspace() {
  local out
  out=$(lab workspace create --cwd "$PROJECT" --label "$1" --no-focus) || return 1
  printf '%s' "$out" | jq -r \
    '[.result.workspace.workspace_id,.result.tab.tab_id,.result.root_pane.pane_id] | @tsv'
}

IFS=$'\t' read -r LAUNCHER_WORKSPACE LAUNCHER_TAB LAUNCHER_PANE <<EOF
$(make_workspace firstmate)
EOF
IFS=$'\t' read -r CAPTAIN_WORKSPACE CAPTAIN_TAB CAPTAIN_PANE <<EOF
$(make_workspace captain-active)
EOF
[ -n "$LAUNCHER_WORKSPACE" ] && [ -n "$LAUNCHER_TAB" ] && [ -n "$LAUNCHER_PANE" ] \
  && [ -n "$CAPTAIN_WORKSPACE" ] && [ -n "$CAPTAIN_TAB" ] && [ -n "$CAPTAIN_PANE" ] \
  || fail 'could not create isolated launcher and captain workspaces'
lab tab focus "$CAPTAIN_TAB" >/dev/null || fail 'could not focus the captain control tab'
FOCUS_BEFORE=$(lab workspace list | jq -r \
  '[.result.workspaces[] | select(.focused == true) | [.workspace_id,.active_tab_id] | @tsv] | if length == 1 then .[0] else empty end')
[ "$FOCUS_BEFORE" = "$CAPTAIN_WORKSPACE"$'\t'"$CAPTAIN_TAB" ] || fail 'captain control focus was not exact before spawn'

SPAWN_OUT="$TMP_ROOT/spawn.out"
SPAWN_ERR="$TMP_ROOT/spawn.err"
SPAWN_RC="$TMP_ROOT/spawn.rc"
SPAWN_INNER="env PATH=$(shell_quote "$FAKEBIN:$REAL_PATH") HERDR_LAB_HELPER=$(shell_quote "$HERDR_LAB_HELPER") HERDR_LAB_SESSION=$(shell_quote "$HERDR_LAB_SESSION") REAL_PATH=$(shell_quote "$REAL_PATH") HERDR_CALL_LOG=$(shell_quote "$HERDR_CALL_LOG") TREEHOUSE_CALL_LOG=$(shell_quote "$TREEHOUSE_CALL_LOG") FM_HOME=$(shell_quote "$HOME_DIR") FM_ROOT_OVERRIDE=$(shell_quote "$ROOT") FM_SPAWN_NO_GUARD=1 $(shell_quote "$ROOT/bin/fm-spawn.sh") $(shell_quote "$TASK") $(shell_quote "$PROJECT") --harness codex --backend herdr --existing-worktree $(shell_quote "$WORKTREE") --mode local-only --yolo off >$(shell_quote "$SPAWN_OUT") 2>$(shell_quote "$SPAWN_ERR"); printf '%s\\n' \"\$?\" >$(shell_quote "$SPAWN_RC")"
SPAWN_COMMAND="bash -lc $(shell_quote "$SPAWN_INNER")"
lab pane run "$LAUNCHER_PANE" "$SPAWN_COMMAND" >/dev/null \
  || fail 'could not start fm-spawn inside the exact launcher pane'

attempt=0
while [ ! -s "$SPAWN_RC" ] && [ "$attempt" -lt 600 ]; do
  sleep 0.1
  attempt=$((attempt + 1))
done
[ -s "$SPAWN_RC" ] || fail "fm-spawn did not finish within the bounded lab wait
spawn stdout: $(cat "$SPAWN_OUT" 2>/dev/null)
spawn stderr: $(cat "$SPAWN_ERR" 2>/dev/null)
launcher pane: $(lab pane read "$LAUNCHER_PANE" --source recent --lines 200 2>/dev/null)"
[ "$(cat "$SPAWN_RC")" = 0 ] \
  || fail "fm-spawn failed in the guarded lab: $(cat "$SPAWN_ERR" 2>/dev/null)"

META="$HOME_DIR/state/$TASK.meta"
JOURNAL="$HOME_DIR/state/$TASK.adopted-endpoint"
PRESENTATION="$HOME_DIR/state/$TASK.herdr-presentation"
[ -f "$META" ] && [ -f "$JOURNAL" ] && [ -f "$PRESENTATION" ] \
  || fail 'successful lab spawn did not publish complete task and presentation identity'
PANE=$(field "$META" herdr_pane_id)
TAB=$(field "$META" herdr_tab_id)
WORKSPACE=$(field "$META" herdr_workspace_id)
SOCKET=$(lab session list --json | jq -r --arg session "$HERDR_LAB_SESSION" \
  '.sessions[] | select(.name == $session and .running == true) | .socket_path')
[ "$(field "$META" backend)" = herdr ] || fail 'lab metadata omitted backend=herdr'
[ "$(field "$META" adopted_delivery)" = complete ] || fail 'lab metadata published an incomplete delivery'
[ "$(field "$META" adopted_herdr_parent_workspace_id)" = "$LAUNCHER_WORKSPACE" ] \
  || fail 'lab metadata did not bind the launcher exact parent workspace'
[ "$(field "$META" adopted_herdr_socket_identity)" = "$SOCKET" ] \
  || fail 'lab metadata did not bind the exact running named-session socket'
[ "$(field "$META" adopted_herdr_agent)" = codex ] || fail 'lab metadata did not bind the native Codex agent identity'
[ "$(field "$JOURNAL" phase)" = agent ] || fail 'lab endpoint transaction did not reach the agent phase'
[ "$(field "$JOURNAL" pane_id)" = "$PANE" ] || fail 'lab transaction and metadata disagree about the pane'
[ "$(field "$JOURNAL" parent_workspace_id)" = "$LAUNCHER_WORKSPACE" ] || fail 'lab transaction lost the exact parent workspace'
[ "$(field "$JOURNAL" worktree)" = "$WORKTREE" ] || fail 'lab transaction lost the adopted worktree'
[ "$WORKSPACE" != "$LAUNCHER_WORKSPACE" ] || fail 'forced presentation did not create a separate visual workspace'

PANE_JSON=$(lab pane get "$PANE") || fail 'could not inspect the recorded lab worker pane'
[ "$(printf '%s' "$PANE_JSON" | jq -r '.result.pane.foreground_cwd')" = "$WORKTREE" ] \
  || fail 'the real Herdr worker is not in the exact adopted worktree'
printf '%s' "$PANE_JSON" | jq -e --arg pane "$PANE" --arg tab "$TAB" --arg workspace "$WORKSPACE" \
  '.result.pane.pane_id == $pane and .result.pane.tab_id == $tab and .result.pane.workspace_id == $workspace' >/dev/null \
  || fail 'recorded workspace/tab/pane identity does not match the real endpoint'
AGENT_JSON=$(lab agent get "$PANE") || fail 'could not inspect the native lab agent registration'
printf '%s' "$AGENT_JSON" | jq -e \
  '.result.agent.agent == "codex" and (.result.agent.agent_status | IN("working","idle","done","blocked"))' >/dev/null \
  || fail 'the real endpoint did not carry the recorded native Codex identity'
FOCUS_AFTER_SPAWN=$(lab workspace list | jq -r \
  '[.result.workspaces[] | select(.focused == true) | [.workspace_id,.active_tab_id] | @tsv] | if length == 1 then .[0] else empty end')
[ "$FOCUS_AFTER_SPAWN" = "$FOCUS_BEFORE" ] || fail 'successful adopted spawn changed the captain control focus'
[ ! -s "$TREEHOUSE_CALL_LOG" ] || fail 'adopted Herdr spawn invoked Treehouse'
[ "$(git -C "$WORKTREE" symbolic-ref --short HEAD)" = "$BRANCH_BEFORE" ] || fail 'spawn changed the adopted branch'
[ "$(git -C "$WORKTREE" rev-parse HEAD)" = "$HEAD_BEFORE" ] || fail 'spawn changed adopted HEAD'
[ "$(git -C "$WORKTREE" status --porcelain)" = "$STATUS_BEFORE" ] || fail 'spawn changed adopted worktree contents'

env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH \
  PATH="$FAKEBIN:$REAL_PATH" HERDR_SESSION="$HERDR_LAB_SESSION" \
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_TEARDOWN_GUARD_DONE=1 \
  "$ROOT/bin/fm-teardown.sh" "$TASK" > "$TMP_ROOT/teardown.out" 2> "$TMP_ROOT/teardown.err" \
  || fail "fm-teardown failed in the guarded lab: $(cat "$TMP_ROOT/teardown.err" 2>/dev/null)"
[ ! -e "$META" ] && [ ! -e "$JOURNAL" ] && [ ! -e "$PRESENTATION" ] \
  || fail 'lab teardown retained task or endpoint journals'
if lab pane get "$PANE" >/dev/null 2>&1; then
  fail 'lab teardown left the exact worker pane alive'
fi
[ -d "$WORKTREE" ] || fail 'lab teardown removed the adopted worktree'
[ "$(git -C "$WORKTREE" symbolic-ref --short HEAD)" = "$BRANCH_BEFORE" ] || fail 'teardown changed the adopted branch'
[ "$(git -C "$WORKTREE" rev-parse HEAD)" = "$HEAD_BEFORE" ] || fail 'teardown changed adopted HEAD'
[ "$(git -C "$WORKTREE" status --porcelain)" = "$STATUS_BEFORE" ] || fail 'teardown changed adopted worktree contents'
FOCUS_AFTER_TEARDOWN=$(lab workspace list | jq -r \
  '[.result.workspaces[] | select(.focused == true) | [.workspace_id,.active_tab_id] | @tsv] | if length == 1 then .[0] else empty end')
[ "$FOCUS_AFTER_TEARDOWN" = "$FOCUS_BEFORE" ] || fail 'adopted teardown changed the captain control focus'
[ ! -s "$TREEHOUSE_CALL_LOG" ] || fail 'adopted Herdr teardown invoked Treehouse'

cleanup_all || fail 'guarded Herdr lab teardown or default-fleet tripwire failed'
pass 'real named-session Herdr adoption binds exact launcher/worktree/agent identity, preserves focus, and tears down without reclaiming the worktree'

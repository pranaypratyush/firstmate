#!/usr/bin/env bash
# Private behavioral E2E for the same-home successor after a bounded Codex checkpoint.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
LAUNCH="$ROOT/bin/fm-afk-launch.sh"
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }

REAL_TMUX=$(command -v tmux)
SOCKET="fm-secondmate-self-supervision-$$"
WORK=
SHIM=
SECOND_HOME=
SECOND_PANE=
SUBMITTED=
SECOND_NEXT_PANE=
NEXT_SUBMITTED=

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

cleanup() {
  if [ -n "${SECOND_HOME:-}" ]; then
    env -u TMUX -u TMUX_PANE PATH="${SHIM:-/nonexistent}:$PATH" FM_HOME="$SECOND_HOME" \
      "$LAUNCH" stop-self-supervise >/dev/null 2>&1 || true
  fi
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf "${WORK:-}" "${SHIM:-}" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-secondmate-self-supervision.XXXXXX")
SECOND_HOME="$WORK/secondmate"
mkdir -p "$SECOND_HOME/state"
printf 'fixture-secondmate\n' > "$SECOND_HOME/.fm-secondmate-home"
SUBMITTED="$WORK/submitted.log"
: > "$SUBMITTED"

SHIM=$(mktemp -d "${TMPDIR:-/tmp}/fm-secondmate-self-supervision-shim.XXXXXX")
cat > "$SHIM/tmux" <<SHIM
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SHIM
chmod +x "$SHIM/tmux"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s primary -x 180 -y 40
"$REAL_TMUX" -L "$SOCKET" new-session -d -s secondmate -x 180 -y 40
SECOND_PANE=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t secondmate '#{pane_id}')
"$REAL_TMUX" -L "$SOCKET" new-window -d -n fm-child-c1 -t secondmate
CHILD_PANE=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t secondmate:fm-child-c1 '#{pane_id}')

LOOP="$WORK/idle-secondmate.sh"
cat > "$LOOP" <<'LOOP'
#!/usr/bin/env bash
log=$1
old_stty=$(stty -g 2>/dev/null || true)
[ -z "$old_stty" ] || stty -echo -icanon min 1 time 0 2>/dev/null || true
trap '[ -z "$old_stty" ] || stty "$old_stty" 2>/dev/null || true' EXIT INT TERM
line=
redraw() { printf '\r\033[K\xe2\x9d\xaf %s' "$line"; }
redraw
while IFS= read -r -n 1 char; do
  if [ -z "$char" ]; then
    printf '%s\n' "$line" >> "$log"
    line=
    redraw
  else
    line="${line}${char}"
    redraw
  fi
done
LOOP
chmod +x "$LOOP"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$SECOND_PANE" "bash '$LOOP' '$SUBMITTED'" Enter
sleep 1

cat > "$SECOND_HOME/state/child-c1.meta" <<META
window=$CHILD_PANE
kind=ship
mode=local-only
META
printf 'working: child is running\n' > "$SECOND_HOME/state/child-c1.status"

ENTRY="$WORK/self-supervise-entry.sh"
cat > "$ENTRY" <<ENTRY
#!/usr/bin/env bash
export PATH="$SHIM:\$PATH"
exec env FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \\
  FM_HOUSEKEEPING_TICK=1 FM_ESCALATE_BATCH_SECS=0 FM_STALE_ESCALATE_SECS=999999 \\
  FM_INJECT_CONFIRM_SLEEP=0.1 FM_INJECT_CONFIRM_RETRIES=5 FM_SELF_SUPERVISE_IDLE_EXIT_SECS=1 "$DAEMON"
ENTRY
chmod +x "$ENTRY"

# A quiet Codex checkpoint is the same-home lifecycle path that must replace its
# bounded foreground owner without another model turn.
checkpoint_out="$WORK/checkpoint.out"
checkpoint_err="$WORK/checkpoint.err"
checkpoint_status=0
env -u TMUX PATH="$SHIM:$PATH" FM_HOME="$SECOND_HOME" FM_BACKEND=tmux TMUX_PANE="$SECOND_PANE" \
  FM_AFK_LAUNCH_ENTRY="$ENTRY" \
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  "$CHECKPOINT" --seconds 1 >"$checkpoint_out" 2>"$checkpoint_err" || checkpoint_status=$?
[ "$checkpoint_status" -eq 124 ] || fail "bounded Codex checkpoint did not roll over cleanly: $(cat "$checkpoint_out" "$checkpoint_err")"
grep -F 'checkpoint: no actionable wake within 1s' "$checkpoint_out" >/dev/null \
  || fail "bounded checkpoint did not report its rollover"
[ -s "$SECOND_HOME/state/.self-supervise-target" ] \
  || fail "quiet Codex checkpoint did not establish a same-home successor"
grep -Fx $'tmux\t'"$SECOND_PANE" "$SECOND_HOME/state/.self-supervise-target" >/dev/null \
  || fail "same-home successor did not record the secondmate pane"

wait_for_injections() {
  local submitted=$1 wanted=$2 attempts=0 actual
  while [ "$attempts" -lt 160 ]; do
    actual=$(wc -l < "$submitted" | tr -d ' ')
    [ "$actual" -ge "$wanted" ] && return 0
    sleep 0.1
    attempts=$((attempts + 1))
  done
  return 1
}

meta_before=$(cat "$SECOND_HOME/state/child-c1.meta")
printf 'done: first child completion after rollover\n' >> "$SECOND_HOME/state/child-c1.status"
wait_for_injections "$SUBMITTED" 1 || fail "first child completion was not routed to the idle secondmate"
printf 'done: second child completion after rollover\n' >> "$SECOND_HOME/state/child-c1.status"
wait_for_injections "$SUBMITTED" 2 || fail "same-home successor stopped after the first child completion"

[ "$(cat "$SECOND_HOME/state/child-c1.meta")" = "$meta_before" ] \
  || fail "successor mutated child metadata instead of routing its events"
grep -q $'\342\201\243FIRSTMATE_OP: v1 away-supervisor:' "$SUBMITTED" \
  || fail "successor did not route a marked operational wake to the secondmate pane"

# The old detached owner remains live while the secondmate gets a new pane, so
# the next checkpoint must atomically transfer ownership before it can inject
# another child transition into the stale pane.
[ -s "$SECOND_HOME/state/.self-supervise-target" ] \
  || fail "pane rollover fixture lost the persisted old successor target"
printf 'working: child continues after pane rollover\n' > "$SECOND_HOME/state/child-c1.status"
NEXT_SUBMITTED="$WORK/submitted-next.log"
: > "$NEXT_SUBMITTED"
"$REAL_TMUX" -L "$SOCKET" new-session -d -s secondmate-next -x 180 -y 40
SECOND_NEXT_PANE=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t secondmate-next '#{pane_id}')
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$SECOND_NEXT_PANE" "bash '$LOOP' '$NEXT_SUBMITTED'" Enter
sleep 1
checkpoint_status=0
env -u TMUX PATH="$SHIM:$PATH" FM_HOME="$SECOND_HOME" FM_BACKEND=tmux TMUX_PANE="$SECOND_NEXT_PANE" \
  FM_AFK_LAUNCH_ENTRY="$ENTRY" \
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  "$CHECKPOINT" --seconds 1 >"$checkpoint_out" 2>"$checkpoint_err" || checkpoint_status=$?
[ "$checkpoint_status" -eq 124 ] || fail "pane-rollover checkpoint did not roll over cleanly: $(cat "$checkpoint_out" "$checkpoint_err")"
grep -Fx $'tmux\t'"$SECOND_NEXT_PANE" "$SECOND_HOME/state/.self-supervise-target" >/dev/null \
  || fail "same-home successor did not atomically retarget after pane rollover"
printf 'done: child completion after pane rollover\n' >> "$SECOND_HOME/state/child-c1.status"
wait_for_injections "$NEXT_SUBMITTED" 1 || fail "retargeted successor did not route to the current secondmate pane"
[ "$(wc -l < "$SUBMITTED" | tr -d ' ')" -eq 2 ] \
  || fail "stale successor target received a child completion after pane rollover"

rm -f "$SECOND_HOME/state/child-c1.meta"
attempts=0
while [ "$attempts" -lt 160 ]; do
  [ ! -e "$SECOND_HOME/state/.self-supervise" ] \
    && [ ! -e "$SECOND_HOME/state/.supervise-daemon.lock" ] \
    && break
  sleep 0.1
  attempts=$((attempts + 1))
done
[ ! -e "$SECOND_HOME/state/.self-supervise" ] \
  || fail "same-home successor did not clear its mode after child work ended"
[ ! -e "$SECOND_HOME/state/.supervise-daemon.lock" ] \
  || fail "same-home successor did not exit after child work ended"

pass "same-home successor survives two completions, retargets on pane rollover, and exits idle"

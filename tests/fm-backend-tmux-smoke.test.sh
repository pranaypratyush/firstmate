#!/usr/bin/env bash
# tests/fm-backend-tmux-smoke.test.sh - real tmux smoke test for the tmux
# session-provider adapter (bin/backends/tmux.sh), the P1 checklist item
# "run a real tmux smoke test (create session, send text + Enter, capture,
# list, kill)" from data/fm-backend-design-d7/report.md. Every other suite in
# this repo fakes tmux; this one is the one place that talks to a REAL tmux
# server, isolated on a private socket (`-L`) so it never touches the host's
# actual sessions.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

wait_for_capture_text() {  # <target> <text> [samples]
  local target=$1 text=$2 samples=${3:-100} out i=0
  while [ "$i" -lt "$samples" ]; do
    out=$(fm_backend_tmux_capture "$target" 200 2>/dev/null || true)
    case "$out" in
      *"$text"*) return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-backend-smoke-$$"
SHIM_DIR=
trap cleanup_all EXIT

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${SHIM_DIR:-}" ] && rm -rf "$SHIM_DIR"
}

# A `tmux` shim on PATH that transparently redirects every call to the private
# socket, so bin/backends/tmux.sh's bare `tmux ...` invocations never touch the
# host's real sessions.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-backend-smoke.XXXXXX")
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

SESSION="smoke"
WINDOW="fm-smoke1"
TARGET="$SESSION:$WINDOW"

# --- create session ----------------------------------------------------------

tmux new-session -d -s "$SESSION" -x 200 -y 50 \
  || fail "real tmux: new-session failed"
TASK_WID=$(fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME") \
  || fail "fm_backend_tmux_create_task failed to create the task window"
tmux list-windows -t "$SESSION" -F '#{window_name}' | grep -qx "$WINDOW" \
  || fail "created window is not visible in the real session"

# A second create for the SAME window name must refuse (mirrors fm-spawn.sh's
# duplicate-window guard).
if fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" 2>/dev/null; then
  fail "fm_backend_tmux_create_task should refuse an existing window name"
fi
pass "real tmux: fm_backend_tmux_create_task creates a window and refuses a duplicate"

# Adopted endpoint creation publishes its random token before issuing the tmux
# command queue. Prove the real server accepts that queue, exposes the exact
# socket locator, and can rediscover the stable id after a mutable-name loss.
ADOPTED_TOKEN=0123456789abcdef
ADOPTED_WID=$(fm_backend_tmux_create_adopted_task \
  "$SESSION" fm-provisional-adoption "$HOME" "$ADOPTED_TOKEN") \
  || fail "real tmux: provisional adopted endpoint creation failed"
ADOPTED_LOCATOR=$(fm_backend_tmux_server_locator "$ADOPTED_WID") \
  || fail "real tmux: adopted endpoint server locator was unavailable"
[ -S "$ADOPTED_LOCATOR" ] \
  || fail "real tmux: adopted endpoint locator did not identify the private server socket"
tmux rename-window -t "$ADOPTED_WID" lost-provisional-name \
  || fail "real tmux: could not remove the provisional endpoint name"
DISCOVERED_WID=$(fm_backend_tmux_window_id_for_provisional_token \
  "$SESSION" "$ADOPTED_TOKEN") \
  || fail "real tmux: provisional token could not rediscover the renamed endpoint"
[ "$DISCOVERED_WID" = "$ADOPTED_WID" ] \
  || fail "real tmux: provisional token resolved the wrong stable window id"
fm_backend_tmux_kill_window_id "$ADOPTED_WID" \
  || fail "real tmux: provisional endpoint cleanup failed"
pass "real tmux: adopted creation atomically exposes a socket-scoped provisional identity"

# --- send text + Enter -------------------------------------------------------

# A newly-created interactive shell can exist while its startup files still run
# foreground commands. Do not send C-c during that phase: on fish installations
# whose startup invokes tmux, the interrupt can exit the nascent task shell.
# First wait until the pane foreground is structurally a shell, then prove line
# editor readiness once with an output token absent from the submitted bytes.
SHELL_READY=false
for _ in $(seq 1 100); do
  pane_command=$(fm_backend_tmux_current_command "$TASK_WID" 2>/dev/null || true)
  if [ "$(fm_backend_tmux_classify_process_name "$pane_command")" = shell ]; then
    SHELL_READY=true
    break
  fi
  sleep 0.1
done
[ "$SHELL_READY" = true ] || fail "the tmux task shell did not become ready"
fm_backend_tmux_send_literal "$TASK_WID" "printf 'shell-%s\\n' ready" \
  || fail "the tmux task shell did not accept the readiness text"
fm_backend_tmux_send_key "$TASK_WID" Enter \
  || fail "the tmux task shell did not accept the readiness Enter"
wait_for_capture_text "$TASK_WID" "shell-ready" \
  || fail "the tmux task shell did not execute the readiness probe"

fm_backend_tmux_send_text_line "$TASK_WID" "cd /tmp && printf 'setup-%s\\n' ready"
wait_for_capture_text "$TASK_WID" "setup-ready" || fail "the tmux task shell did not complete setup"

fm_backend_tmux_send_text_line "$TARGET" "printf 'captain-on-deck-%s\\n' line" \
  || fail "fm_backend_tmux_send_text_line failed"
wait_for_capture_text "$TARGET" "captain-on-deck-line" \
  || fail "fm_backend_tmux_send_text_line did not execute"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_text_line"
case "$out" in
  *captain-on-deck-line*) : ;;
  *) fail "real tmux: fm_backend_tmux_send_text_line did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_text_line sends literal text and submits with Enter"

# --- send_literal + send_key(Enter), the two-step form fm-spawn.sh uses for the
# harness launch command (literal send, settle, then a separate Enter) --------

fm_backend_tmux_send_literal "$TARGET" "printf 'literal-then-key-%s\\n' captain" \
  || fail "fm_backend_tmux_send_literal failed"
fm_backend_tmux_send_key "$TARGET" Enter || fail "fm_backend_tmux_send_key Enter failed"
wait_for_capture_text "$TARGET" "literal-then-key-captain" \
  || fail "fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter did not execute"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_literal+send_key"
case "$out" in
  *literal-then-key-captain*) : ;;
  *) fail "real tmux: send_literal + send_key(Enter) did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter submit as two separate steps"

# --- capture bounds -----------------------------------------------------------
# Print enough numbered lines to overflow the pane's visible height, then
# confirm a small capture window (-S -N) surfaces only the RECENT tail (the
# earliest lines scroll out of a small window) while a large one reaches back
# far enough to still see the earliest line - the same -S -N bounding fm-peek.sh
# and fm-watch.sh rely on for a bounded, cheap pane read.
fm_backend_tmux_send_text_line "$TARGET" "awk 'BEGIN { for (i = 1; i <= 80; i++) print \"tag-line-\" i }'"
wait_for_capture_text "$TARGET" "tag-line-80" \
  || fail "the numbered output did not complete before capture"
small=$(fm_backend_tmux_capture "$TARGET" 3) || fail "fm_backend_tmux_capture (small window) failed"
case "$small" in
  *tag-line-1$'\n'*) fail "a 3-line capture should not still see the very first numbered line"$'\n'"$small" ;;
esac
case "$small" in
  *tag-line-80*) : ;;
  *) fail "a 3-line capture should still contain the most recent output"$'\n'"$small" ;;
esac
large=$(fm_backend_tmux_capture "$TARGET" 200) || fail "fm_backend_tmux_capture (large window) failed"
case "$large" in
  *tag-line-1$'\n'*) : ;;
  *) fail "a 200-line capture should reach back far enough to see the first numbered line"$'\n'"$large" ;;
esac
pass "real tmux: fm_backend_tmux_capture's -S -N bound trims old history for a small window and reaches it for a large one"

# --- resolve_bare_selector (live-window-listing) -----------------------------

resolved=$(fm_backend_tmux_resolve_bare_selector "$WINDOW") \
  || fail "fm_backend_tmux_resolve_bare_selector failed to find the live window"
[ "$resolved" = "$TARGET" ] || fail "fm_backend_tmux_resolve_bare_selector resolved to '$resolved', expected '$TARGET'"
pass "real tmux: fm_backend_tmux_resolve_bare_selector (list-live) finds the created window by name"

if fm_backend_tmux_resolve_bare_selector "no-such-window-xyz" 2>/dev/null; then
  fail "fm_backend_tmux_resolve_bare_selector should fail for a nonexistent window"
fi
pass "real tmux: fm_backend_tmux_resolve_bare_selector fails for a window that does not exist"

# --- exact cwd plus stable-id abort cleanup ---------------------------------

STABLE_CWD="$SHIM_DIR/adopted cwd"
CROSS_SESSION_CWD="$SHIM_DIR/cross session adopted cwd"
RENAMED_CWD="$SHIM_DIR/renamed adopted cwd"
RENAMED_PANE_CWD="$RENAMED_CWD/active/subdir"
PENDING_CWD="$SHIM_DIR/pending adopted cwd"
mkdir -p "$STABLE_CWD"
mkdir -p "$CROSS_SESSION_CWD"
mkdir -p "$RENAMED_PANE_CWD"
mkdir -p "$PENDING_CWD"
STABLE_CWD=$(cd "$STABLE_CWD" && pwd -P)
CROSS_SESSION_CWD=$(cd "$CROSS_SESSION_CWD" && pwd -P)
RENAMED_CWD=$(cd "$RENAMED_CWD" && pwd -P)
RENAMED_PANE_CWD=$(cd "$RENAMED_PANE_CWD" && pwd -P)
PENDING_CWD=$(cd "$PENDING_CWD" && pwd -P)
STABLE_WID=$(fm_backend_tmux_create_task "$SESSION" fm-adopted-cwd "$STABLE_CWD") \
  || fail "real tmux: could not create the stable-id cleanup fixture"
stable_path=
for _ in $(seq 1 100); do
  stable_path=$(fm_backend_tmux_current_path "$STABLE_WID" 2>/dev/null || true)
  [ "$stable_path" = "$STABLE_CWD" ] && break
  sleep 0.1
done
[ "$stable_path" = "$STABLE_CWD" ] \
  || fail "real tmux: stable window did not report its exact adopted cwd"
claim=$(fm_backend_tmux_worktree_claim "$SESSION" fm-new-adoption "$STABLE_CWD")
claim_status=$?
[ "$claim_status" -eq 1 ] && [ "$claim" = adopted-cwd ] \
  || fail "real tmux: live task CWD inventory did not identify the adopted-cwd claim"
if ! fm_backend_tmux_worktree_claim "$SESSION" fm-adopted-cwd "$STABLE_CWD"; then
  fail "real tmux: live task CWD inventory did not exclude the same task window"
fi
same_name_claim=$(fm_backend_tmux_worktree_claim \
  "$SESSION" fm-adopted-cwd "$STABLE_CWD" "$TASK_WID")
same_name_status=$?
[ "$same_name_status" -eq 1 ] && [ "$same_name_claim" = adopted-cwd ] \
  || fail "real tmux: stable-id inventory excluded a same-name different window: status=$same_name_status claim='$same_name_claim'"

CROSS_SESSION=smoke-other
tmux new-session -d -s "$CROSS_SESSION" -x 200 -y 50 \
  || fail "real tmux: could not create the cross-session claim fixture"
CROSS_WID=$(fm_backend_tmux_create_task "$CROSS_SESSION" fm-cross-session "$CROSS_SESSION_CWD") \
  || fail "real tmux: could not create the cross-session task window"
cross_path=
for _ in $(seq 1 100); do
  cross_path=$(fm_backend_tmux_current_path "$CROSS_WID" 2>/dev/null || true)
  [ "$cross_path" = "$CROSS_SESSION_CWD" ] && break
  sleep 0.1
done
[ "$cross_path" = "$CROSS_SESSION_CWD" ] \
  || fail "real tmux: cross-session task did not report its exact adopted cwd"
cross_claim=$(fm_backend_tmux_worktree_claim "$SESSION" fm-new-adoption "$CROSS_SESSION_CWD")
cross_status=$?
[ "$cross_status" -eq 1 ] && [ "$cross_claim" = cross-session ] \
  || fail "real tmux: live claim inventory missed a different-session task at the exact adopted cwd"

RENAMED_WID=$(fm_backend_tmux_create_task "$SESSION" fm-before-rename "$RENAMED_PANE_CWD") \
  || fail "real tmux: could not create the renamed claim fixture"
renamed_path=
for _ in $(seq 1 100); do
  renamed_path=$(fm_backend_tmux_current_path "$RENAMED_WID" 2>/dev/null || true)
  [ "$renamed_path" = "$RENAMED_PANE_CWD" ] && break
  sleep 0.1
done
[ "$renamed_path" = "$RENAMED_PANE_CWD" ] \
  || fail "real tmux: renamed task fixture did not report its adopted-worktree descendant cwd"
tmux rename-window -t "$RENAMED_WID" lost-task-name \
  || fail "real tmux: could not remove the task-like name from the live claim fixture"
renamed_claim=$(fm_backend_tmux_worktree_claim "$SESSION" fm-new-adoption "$RENAMED_CWD")
renamed_status=$?
[ "$renamed_status" -eq 2 ] \
  || fail "real tmux: renamed metadata-free occupancy should be ambiguous, got status $renamed_status and '$renamed_claim'"
case "$renamed_claim" in
  occupancy:*) : ;;
  *) fail "real tmux: renamed metadata-free occupancy did not return a bounded occupancy reason: '$renamed_claim'" ;;
esac
pass "real tmux: adopted CWD inventory detects cross-session and same-name/different-id claims and refuses renamed metadata-free occupancy"

PENDING_WID=$(fm_backend_tmux_create_task "$SESSION" fm-pending-retry "$PENDING_CWD") \
  || fail "real tmux: could not create the pending-delivery recovery fixture"
pending_path=
for _ in $(seq 1 100); do
  pending_path=$(fm_backend_tmux_current_path "$PENDING_WID" 2>/dev/null || true)
  [ "$pending_path" = "$PENDING_CWD" ] && break
  sleep 0.1
done
[ "$pending_path" = "$PENDING_CWD" ] \
  || fail "real tmux: pending-delivery fixture did not report its exact adopted cwd"
PENDING_SERVER_IDENTITY=$(fm_backend_tmux_server_identity "$PENDING_WID") \
  || fail "real tmux: pending-delivery fixture had no stable server identity"
restarted_refusal=$(fm_backend_tmux_retire_adopted_window \
  "$PENDING_WID" '999999999:1' "$SESSION" "$PENDING_CWD")
restarted_status=$?
[ "$restarted_status" -eq 2 ] && [ "$restarted_refusal" = server-mismatch ] \
  || fail "real tmux: cleanup did not refuse a stable id bound to another server lifetime"
tmux list-windows -t "$SESSION" -F '#{window_id}' | grep -Fqx "$PENDING_WID" \
  || fail "real tmux: server-mismatched cleanup removed the pending endpoint"
tmux split-window -d -t "$PENDING_WID" -c "$PENDING_CWD" \
  || fail "real tmux: could not add the unrelated second-pane safety fixture"
pending_refusal=$(fm_backend_tmux_retire_adopted_window \
  "$PENDING_WID" "$PENDING_SERVER_IDENTITY" "$SESSION" "$PENDING_CWD")
pending_status=$?
[ "$pending_status" -eq 2 ] && [ "$pending_refusal" = pane-count ] \
  || fail "real tmux: pending endpoint cleanup did not refuse a multi-pane window"
tmux list-windows -t "$SESSION" -F '#{window_id}' | grep -Fqx "$PENDING_WID" \
  || fail "real tmux: multi-pane pending endpoint cleanup removed the window"
extra_pane=$(tmux list-panes -t "$PENDING_WID" -F '#{pane_id}' | tail -1)
tmux kill-pane -t "$extra_pane" \
  || fail "real tmux: could not remove the second-pane safety fixture"
tmux rename-window -t "$PENDING_WID" lost-pending-name \
  || fail "real tmux: could not remove the pending endpoint's mutable name"
fm_backend_tmux_retire_adopted_window \
  "$PENDING_WID" "$PENDING_SERVER_IDENTITY" "$SESSION" "$PENDING_CWD" \
  || fail "real tmux: exact pending endpoint could not be retired by stable id"
if tmux list-windows -t "$SESSION" -F '#{window_id}' | grep -Fqx "$PENDING_WID"; then
  fail "real tmux: exact pending endpoint survived stable-id retirement"
fi
pass "real tmux: adopted endpoint cleanup refuses server-lifetime and multi-pane ambiguity, then retires a renamed bound window"

tmux rename-window -t "$STABLE_WID" fm-renamed-after-create \
  || fail "real tmux: could not simulate a lost task window name"
fm_backend_tmux_kill_window_id "$STABLE_WID" \
  || fail "real tmux: stable-id cleanup could not remove the renamed window"
if tmux list-windows -t "$SESSION" -F '#{window_id}' | grep -Fqx "$STABLE_WID"; then
  fail "real tmux: stable-id cleanup retained the renamed adopted window"
fi
tmux list-windows -t "$SESSION" -F '#{window_id}' | grep -Fqx "$TASK_WID" \
  || fail "real tmux: stable-id cleanup removed the independent control window"
pass "real tmux: adopted task creation reports exact cwd, live claims, and stable-id cleanup after a lost name"

# --- kill and recovery-grade missing-window classification ------------------

fm_backend_tmux_kill "$TARGET"
if tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$WINDOW"; then
  fail "fm_backend_tmux_kill did not remove the window"
fi
state=$(fm_backend_agent_state tmux "$TARGET")
[ "$state" = missing ] \
  || fail "a real missing window in a readable session should classify as missing, got '$state'"
# Best-effort contract: killing an already-gone window must not error.
fm_backend_tmux_kill "$TARGET" || fail "fm_backend_tmux_kill on an already-dead target must stay best-effort (never fail)"
pass "real tmux: kill removes the window and the readable session inventory authoritatively classifies it missing"

cleanup_all
trap - EXIT

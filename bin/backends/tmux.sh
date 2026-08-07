#!/usr/bin/env bash
# bin/backends/tmux.sh - the tmux session-provider adapter.
#
# Reference backend (AGENTS.md section 8; data/fm-backend-design-d7). P1 moves
# the tmux command sequences that fm-send.sh, fm-peek.sh, fm-watch.sh,
# fm-spawn.sh, and fm-teardown.sh already ran inline into named functions
# here, running the EXACT same commands in the EXACT same order, so the
# default (tmux, `backend=` absent) path stays byte-identical. Sourced only
# through bin/fm-backend.sh's fm_backend_source, never directly.
#
# Worktree acquisition (running `treehouse get` inside the pane, and polling
# its cwd) is unchanged by this extraction: P1 scopes only the session
# provider, not the worktree provider, so fm-spawn.sh still drives that part
# inline with these same send/current-path primitives.
#
# The verified composer/busy-detection and verify-and-retry-submit primitives
# already live in bin/fm-tmux-lib.sh, shared with the away-mode daemon
# (bin/fm-supervise-daemon.sh); this adapter sources that file and re-exports
# its submit core under the backend's naming convention rather than
# duplicating it, so the two consumers cannot drift apart.
# shellcheck source=bin/fm-tmux-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-session-lock-lib.sh"

# fm_backend_tmux_resolve_bare_selector: the live-window-listing fallback for a
# selector that is neither an explicit target nor a task selector routed
# through meta - an ad hoc window name with no recorded task. Mirrors the
# `tmux list-windows -a ... | grep` pipeline that used to live inline in
# fm-send.sh's and fm-peek.sh's own (until now duplicated) resolve().
fm_backend_tmux_resolve_bare_selector() {  # <name>
  local name=$1
  tmux list-windows -a -F '#{session_name}:#{window_name}' | grep -m1 ":$name\$" \
    || { echo "error: no window named $name" >&2; return 1; }
}

# fm_backend_tmux_capture: bounded plain-text pane capture. Mirrors
# fm-peek.sh's and fm-watch.sh's `tmux capture-pane -p -t "$T" -S -"$N"`.
fm_backend_tmux_capture() {  # <target> <lines>
  tmux capture-pane -p -t "$1" -S -"$2"
}

# fm_backend_tmux_send_key: one named key. Mirrors fm-send.sh's --key path:
# `tmux display-message -p -t "$T" '#{pane_id}' >/dev/null`, then
# `tmux send-keys -t "$T" "$2"`.
fm_backend_tmux_send_key() {  # <target> <key>
  tmux display-message -p -t "$1" '#{pane_id}' >/dev/null
  tmux send-keys -t "$1" "$2"
}

# fm_backend_tmux_send_text_submit: type <text> into <target> once, then
# submit with Enter, retried (Enter only, never retyped) until the composer
# clears. Re-exports fm_tmux_submit_core (bin/fm-tmux-lib.sh) verbatim; see
# that file for the composer-verification contract and echoed verdicts.
fm_backend_tmux_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle>
  fm_tmux_submit_core "$@"
}

# fm_backend_tmux_container_ensure: reuse the current tmux session when
# firstmate itself runs inside tmux, else ensure a dedicated detached
# "firstmate" session exists. Mirrors fm-spawn.sh's container-ensure block;
# prints the resolved session name.
fm_backend_tmux_container_ensure() {
  if [ -n "${TMUX:-}" ]; then
    tmux display-message -p '#S'
  else
    tmux has-session -t firstmate 2>/dev/null || tmux new-session -d -s firstmate
    printf 'firstmate'
  fi
}

# fm_backend_tmux_create_task: create the task's window in <proj-abs>,
# refusing an existing <window-name> in <session>. Mirrors fm-spawn.sh's
# duplicate-check-then-new-window sequence, including the exact error text
# (session:window, matching how fm-spawn.sh composed its own $T). Prints the
# created window's stable window id on stdout for the caller to target.
#
# Robustness (fm-spawn tmux window handling under a non-default captain config):
#   - Capture a STABLE window id with -P -F '#{window_id}', and let tmux append
#     at the next free index by targeting the session with a trailing colon
#     ("$ses:"), so a non-default base-index (e.g. base-index 1) cannot collide.
#   - PIN the window name by disabling automatic-rename and allow-rename on the
#     new window: the captain's tmux may rename the window away from fm-<id> once
#     treehouse cd's into the worktree, which would break name-based targeting.
# The returned window id lets callers target the window even if its name is ever
# lost, so worktree discovery cannot fall back to the active client's window.
fm_backend_tmux_create_task() {  # <session> <window-name> <proj-abs> -> prints window id
  local ses=$1 wname=$2 proj_abs=$3 wid
  if tmux list-windows -t "$ses" -F '#{window_name}' | grep -qx "$wname"; then
    echo "error: window $ses:$wname already exists" >&2
    return 1
  fi
  wid=$(tmux new-window -dP -F '#{window_id}' -t "$ses:" -n "$wname" -c "$proj_abs") || return 1
  tmux set-window-option -t "$wid" automatic-rename off 2>/dev/null || true
  tmux set-window-option -t "$wid" allow-rename off 2>/dev/null || true
  printf '%s\n' "$wid"
}

fm_backend_tmux_provisional_token_valid() {  # <16-lowercase-hex>
  case "${1:-}" in *[!0-9a-f]*|'') return 1 ;; esac
  [ "${#1}" -eq 16 ]
}

# Create the adopted window and install its pre-published transaction token in
# one tmux command queue before the client returns. The token therefore survives
# a caller SIGKILL before the stable window id reaches durable claim storage.
fm_backend_tmux_create_adopted_task() {  # <session> <window-name> <proj-abs> <token>
  local ses=$1 wname=$2 proj_abs=$3 token=$4 wid
  fm_backend_tmux_provisional_token_valid "$token" || return 1
  if tmux list-windows -t "$ses" -F '#{window_name}' | grep -qx "$wname"; then
    echo "error: window $ses:$wname already exists" >&2
    return 1
  fi
  wid=$(tmux new-window -dP -F '#{window_id}' -t "$ses:" -n "$wname" -c "$proj_abs" \
    \; set-window-option -t "=$ses:=$wname" @firstmate_adoption_token "$token" \
    \; set-window-option -t "=$ses:=$wname" automatic-rename off \
    \; set-window-option -t "=$ses:=$wname" allow-rename off) || return 1
  fm_backend_tmux_window_id_valid "$wid" || return 1
  printf '%s\n' "$wid"
}

fm_backend_tmux_window_id_for_provisional_token() {  # <session> <token>
  local expected_session=$1 token=$2 inventory line window_id session found=
  fm_backend_tmux_provisional_token_valid "$token" || return 2
  inventory=$(tmux list-windows -a -F '#{window_id}|#{session_name}|#{@firstmate_adoption_token}' 2>/dev/null) \
    || return 2
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    window_id=${line%%|*}
    [ "$line" != "$window_id" ] || return 2
    line=${line#*|}
    session=${line%%|*}
    [ "$line" != "$session" ] || return 2
    [ "${line#*|}" != "$token" ] || {
      fm_backend_tmux_window_id_valid "$window_id" || return 2
      [ "$session" = "$expected_session" ] || return 2
      [ -z "$found" ] || return 2
      found=$window_id
    }
  done <<EOF
$inventory
EOF
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

# fm_backend_tmux_current_path: the live pane's current working directory, or
# empty on any tmux error. Mirrors fm-spawn.sh's worktree-discovery poll:
# `tmux display-message -p -t "$T" '#{pane_current_path}'`.
fm_backend_tmux_current_path() {  # <target>
  tmux display-message -p -t "$1" '#{pane_current_path}' 2>/dev/null
}

fm_backend_tmux_window_id_valid() {  # <window-id>
  case "${1:-}" in
    @|@*[!0-9]*|'') return 1 ;;
    @*) return 0 ;;
    *) return 1 ;;
  esac
}

fm_backend_tmux_path_within_worktree() {  # <path> <worktree>
  case "$1" in
    "$2"|"$2"/*) return 0 ;;
    *) return 1 ;;
  esac
}

fm_backend_tmux_server_identity_valid() {  # <pid:start-time>
  case "${1:-}" in
    :*|*:|*:*:*|*[!0-9:]*) return 1 ;;
    *:*) return 0 ;;
    *) return 1 ;;
  esac
}

fm_backend_tmux_server_locator_valid() {  # <absolute-socket-path>
  case "${1:-}" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$1" in *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
}

# A server locator distinguishes concurrently live tmux servers even when the
# caller's ambient `tmux` client can see only one of them.
fm_backend_tmux_server_locator() {  # <target>
  local locator
  locator=$(tmux display-message -p -t "$1" '#{socket_path}' 2>/dev/null) || return 1
  fm_backend_tmux_server_locator_valid "$locator" || return 1
  printf '%s\n' "$locator"
}

# A stable window id is meaningful only inside one tmux server lifetime. Bind
# it to the server process and start epoch so a restarted server cannot make an
# old pending-delivery record authoritative over a newly reused @<id>.
fm_backend_tmux_server_identity() {  # <target>
  local identity pid started
  identity=$(tmux display-message -p -t "$1" '#{pid}:#{start_time}' 2>/dev/null) || return 1
  pid=${identity%%:*}
  started=${identity#*:}
  [ "$identity" != "$started" ] || return 1
  fm_backend_tmux_server_identity_valid "$pid:$started" || return 1
  printf '%s\n' "$identity"
}

# fm_backend_tmux_worktree_claim: inspect every live pane on the tmux server
# while an adoption caller holds its home-wide claim lock. The caller's exact
# session/window pair is excluded only after the live inventory resolves it
# through a stable pane id; a same-named window in another session is never the
# caller. Returns 0 with no output when clear, 1 printing the other task id when
# an fm-<task-id> pane has the worktree-root-or-descendant physical cwd, and 2 printing a bounded
# reason when inventory or cwd cannot be proven or an unlabelled pane occupies
# the worktree root or one of its descendants.
fm_backend_tmux_worktree_claim() {  # <session> <own-window-name> <worktree> [own-window-id]
  local own_session=$1 own_window=$2 worktree=$3 own_window_id=${4:-} inventory pane_id
  local pane_session pane_window_id window_name pane_path pane_real seen=$'\n'
  [ -z "$own_window_id" ] || fm_backend_tmux_window_id_valid "$own_window_id" || {
    printf '%s\n' own-window-id
    return 2
  }
  if ! inventory=$(LC_ALL=C tmux list-panes -a -F '#{pane_id}' 2>/dev/null); then
    printf '%s\n' inventory
    return 2
  fi
  [ -n "$inventory" ] || {
    printf '%s\n' empty-inventory
    return 2
  }
  while IFS= read -r pane_id || [ -n "$pane_id" ]; do
    case "$pane_id" in
      %|%*[!0-9]*|'') printf '%s\n' pane-id; return 2 ;;
      %*) ;;
      *) printf '%s\n' pane-id; return 2 ;;
    esac
    case "$seen" in
      *$'\n'"$pane_id"$'\n'*) printf '%s\n' duplicate-pane-id; return 2 ;;
    esac
    seen="$seen$pane_id"$'\n'
    pane_session=$(tmux display-message -p -t "$pane_id" '#{session_name}' 2>/dev/null) || {
      printf 'session:%s\n' "$pane_id"
      return 2
    }
    if [ -n "$own_window_id" ]; then
      pane_window_id=$(tmux display-message -p -t "$pane_id" '#{window_id}' 2>/dev/null) || {
        printf 'window-id:%s\n' "$pane_id"
        return 2
      }
      fm_backend_tmux_window_id_valid "$pane_window_id" || {
        printf 'window-id:%s\n' "$pane_id"
        return 2
      }
      if [ "$pane_session" = "$own_session" ] && [ "$pane_window_id" = "$own_window_id" ]; then
        continue
      fi
    fi
    window_name=$(tmux display-message -p -t "$pane_id" '#{window_name}' 2>/dev/null) || {
      printf 'window:%s\n' "$pane_id"
      return 2
    }
    [ -n "$pane_session" ] && [ -n "$window_name" ] || {
      printf 'pane-record:%s\n' "$pane_id"
      return 2
    }
    case "$pane_session$window_name" in
      *$'\n'*|*$'\r'*|*$'\t'*) printf 'pane-record:%s\n' "$pane_id"; return 2 ;;
    esac
    if [ -z "$own_window_id" ] \
       && [ "$pane_session" = "$own_session" ] && [ "$window_name" = "$own_window" ]; then
      continue
    fi
    pane_path=$(fm_backend_tmux_current_path "$pane_id") || {
      printf 'cwd:%s\n' "$pane_id"
      return 2
    }
    [ -n "$pane_path" ] || {
      printf 'cwd:%s\n' "$pane_id"
      return 2
    }
    pane_real=$(cd -- "$pane_path" 2>/dev/null && pwd -P) || {
      printf 'cwd:%s\n' "$pane_id"
      return 2
    }
    if fm_backend_tmux_path_within_worktree "$pane_real" "$worktree"; then
        case "$window_name" in
          fm-) printf '%s\n' task-window; return 2 ;;
          fm-*) printf '%s\n' "${window_name#fm-}"; return 1 ;;
          *) printf 'occupancy:%s:%s\n' "$pane_session" "$pane_id"; return 2 ;;
        esac
    fi
  done <<EOF
$inventory
EOF
}

# fm_backend_tmux_send_text_line: send one line of TEXT then Enter, with no
# composer verification - used for the fixed spawn-time commands
# (`treehouse get`, the GOTMPDIR export) that already ran this exact sequence
# inline in fm-spawn.sh. Mirrors `tmux send-keys -t "$T" "<text>" Enter`.
fm_backend_tmux_send_text_line() {  # <target> <text>
  tmux send-keys -t "$1" "$2" Enter
}

# fm_backend_tmux_send_literal: send TEXT as literal bytes with no
# submission - the caller sends Enter separately (fm-spawn.sh's launch-command
# send pauses between the literal send and Enter for the harness to settle).
# Mirrors `tmux send-keys -t "$T" -l "<text>"`.
fm_backend_tmux_send_literal() {  # <target> <text>
  tmux send-keys -t "$1" -l "$2"
}

# fm_backend_tmux_kill: remove one explicitly named task window, best-effort.
# Empty, omitted, and malformed targets return nonzero before invoking tmux so
# tmux can never interpret an empty target as the caller's current window.
fm_backend_tmux_kill() {  # <target>
  local target=${1:-} session window
  case "$target" in
    *:*)
      session=${target%%:*}
      window=${target#*:}
      ;;
    *) return 1 ;;
  esac
  case "$session:$window" in
    :*|*:|*:*:*) return 1 ;;
  esac
  tmux kill-window -t "=$session:=$window" 2>/dev/null || true
}

# fm_backend_tmux_kill_window_id: low-level removal of one exact stable id.
# Safety-sensitive callers first bind that id to the expected server lifetime,
# session, pane shape, and CWD through fm_backend_tmux_retire_adopted_window.
# This primitive never falls back to a session/name selector and returns the
# real tmux status so its validated caller can surface failure.
fm_backend_tmux_kill_window_id() {  # <window-id>
  local window_id=${1:-}
  fm_backend_tmux_window_id_valid "$window_id" || return 1
  tmux kill-window -t "$window_id"
}

# fm_backend_tmux_inspect_adopted_window: prove whether a durable adopted
# endpoint is `live` with its exact server lifetime, session, sole pane, and
# physical worktree-root-or-descendant CWD, or `missing` from a still-readable
# matching server. Unreadable inventory or any mismatch fails closed with a
# bounded reason on stdout.
fm_backend_tmux_inspect_adopted_window() {  # <window-id> <server-identity> <session> <worktree>
  local window_id=$1 expected_server=$2 expected_session=$3 worktree=$4
  local actual_server actual_id inventory actual_session panes pane_id pane_path pane_real
  fm_backend_tmux_window_id_valid "$window_id" || { printf '%s\n' window-id; return 2; }
  fm_backend_tmux_server_identity_valid "$expected_server" \
    || { printf '%s\n' expected-server-identity; return 2; }
  actual_server=$(fm_backend_tmux_server_identity "$expected_session") || {
    printf '%s\n' server-identity
    return 2
  }
  [ "$actual_server" = "$expected_server" ] || {
    printf '%s\n' server-mismatch
    return 2
  }
  if ! actual_id=$(tmux display-message -p -t "$window_id" '#{window_id}' 2>/dev/null); then
    inventory=$(tmux list-windows -a -F '#{window_id}' 2>/dev/null) || {
      printf '%s\n' window-inventory
      return 2
    }
    if printf '%s\n' "$inventory" | grep -Fxq "$window_id"; then
      printf '%s\n' window-unreadable
      return 2
    fi
    printf '%s\n' missing
    return 0
  fi
  [ "$actual_id" = "$window_id" ] || {
    printf '%s\n' window-identity
    return 2
  }
  actual_session=$(tmux display-message -p -t "$window_id" '#{session_name}' 2>/dev/null) || {
    printf '%s\n' session
    return 2
  }
  [ "$actual_session" = "$expected_session" ] || {
    printf '%s\n' endpoint-identity
    return 2
  }
  panes=$(tmux list-panes -t "$window_id" -F '#{pane_id}' 2>/dev/null) || {
    printf '%s\n' pane-inventory
    return 2
  }
  pane_id=$(printf '%s\n' "$panes" | grep -E '^%[0-9]+$' || true)
  [ -n "$pane_id" ] && [ "$(printf '%s\n' "$pane_id" | wc -l | tr -d '[:space:]')" -eq 1 ] \
    && [ "$pane_id" = "$panes" ] || {
      printf '%s\n' pane-count
      return 2
    }
  pane_path=$(fm_backend_tmux_current_path "$pane_id") || {
    printf '%s\n' cwd
    return 2
  }
  pane_real=$(cd -- "$pane_path" 2>/dev/null && pwd -P) || {
    printf '%s\n' cwd
    return 2
  }
  fm_backend_tmux_path_within_worktree "$pane_real" "$worktree" || {
    printf '%s\n' cwd-identity
    return 2
  }
  printf '%s\n' live
}

# fm_backend_tmux_retire_adopted_window: remove one endpoint only after the
# shared inspector proves its complete durable identity. A missing endpoint is
# already clear; a live endpoint is removed by stable id.
fm_backend_tmux_retire_adopted_window() {  # <window-id> <server-identity> <session> <worktree>
  local window_id=$1 state
  if state=$(fm_backend_tmux_inspect_adopted_window "$@"); then
    :
  else
    printf '%s\n' "$state"
    return 2
  fi
  [ "$state" = missing ] && return 0
  [ "$state" = live ] || { printf '%s\n' window-state; return 2; }
  fm_backend_tmux_kill_window_id "$window_id" || {
    printf '%s\n' window-kill
    return 2
  }
}

# fm_backend_tmux_current_command: <target>'s live foreground process name -
# tmux's own `#{pane_current_command}`, already resolved from the pty's
# foreground process group (verified empirically with real tmux 3.6a: a
# harness invoked interactively stays the reported command even while it
# shells out to subcommands that do not take over the pty - e.g. `bash -c
# "sleep 30"` alone reports "sleep" because bash execs directly into it, but
# a persisting parent script running `sleep` as a child reports the PARENT's
# own name throughout; the value reverts to the shell's own name only once
# the foreground command actually exits). Empty on any tmux error.
fm_backend_tmux_current_command() {  # <target>
  tmux display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null
}

# fm_backend_tmux_classify_process_name: the single owner of the process-name
# vocabulary shared by every liveness signal below - `agent` for a verified
# harness, `shell` for an idle login/interactive shell, `other` for anything
# else. Keeping one classifier means the two independent name sources can never
# drift into disagreeing about what a given name means.
fm_backend_tmux_classify_process_name() {  # <path> [argv0] -> agent|shell|other
  local path=$1 argv0=${2:-} base
  base=${path##*/}
  base=${base#-}
  case "$base" in
    # muse is anchored rather than globbed like its neighbours: its installed
    # binary is muse-bin-<version> (the launcher execs it, so the version is the
    # live process name and changes on every auto-update), and unlike `claude` or
    # `codex` the substring `muse` is a common English fragment - a *muse* glob
    # would classify musescore or amuse as a live agent pane. The install path
    # cannot carry it either: ~/.local/bin/muse-bin-<version> has no `muse` path
    # COMPONENT, so the fm_harness_path_name fallback below never fires for it.
    muse|muse-bin-*) printf 'agent' ;;
    *claude*|*codex*|*opencode*|*grok*|*kimi*|pi|pi-signed|pi-launcher|Pi) printf 'agent' ;;
    zsh|bash|sh|dash|ash|ksh|mksh|tcsh|csh|fish) printf 'shell' ;;
    *)
      if fm_harness_path_name "$path" >/dev/null || fm_harness_path_name "$argv0" >/dev/null; then
        printf 'agent'
      else
        printf 'other'
      fi
      ;;
  esac
}

# fm_backend_tmux_foreground_comms: the kernel-side names of every process in
# <target>'s pane tty foreground process group, one full value per line.
# Empty on any failure.
#
# This is the foreground-process-group half of the liveness probe, and it exists
# because `#{pane_current_command}` and `ps -o comm=` expose different name
# fields whose roles vary by platform. On macOS the tmux field can carry a
# harness-rewritten title (Claude Code 2.1.220 reports `2.1.220`) while `comm`
# retains executable identity; the portable Linux regression observes the
# reverse for its version-named executable. Reading both `comm` and argv[0]
# preserves an identifying install path without making either platform's field
# assignment load-bearing.
#
# Scoping to the foreground process group rather than to the pane's descendants
# is what keeps the probe honest in the other direction: a harness-named process
# left running in the background of an otherwise idle pane is deliberately NOT
# reported, so a genuinely agent-free pane still classifies `dead`. It also
# reports every member of a multi-process launcher (the Pi Launcher path runs a
# `pi-signed` wrapper and a `pi` engine in one group), so no launcher needs its
# own special case here.
#
# Like fm_backend_tmux_current_command this is a RAW pane read: tmux answers an
# absent target from the client's active window rather than failing, so callers
# must confirm exact window membership first, exactly as the classifier below
# does, or they will describe some other pane entirely.
fm_backend_tmux_foreground_comms() {  # <target>
  local target=$1 tty pid pgid tpgid comm
  tty=$(tmux display-message -p -t "$target" '#{pane_tty}' 2>/dev/null) || return 0
  [ -n "$tty" ] || return 0
  LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null \
    | while read -r pid pgid tpgid comm; do
        [ -n "$comm" ] || continue
        [ "$pgid" = "$tpgid" ] || continue
        printf '%s\n' "$comm"
      done
}

fm_backend_tmux_foreground_argv0s() {  # <target>
  local target=$1 tty pid pgid tpgid comm args argv0
  tty=$(tmux display-message -p -t "$target" '#{pane_tty}' 2>/dev/null) || return 0
  [ -n "$tty" ] || return 0
  LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null \
    | while read -r pid pgid tpgid comm; do
        [ -n "$comm" ] || continue
        [ "$pgid" = "$tpgid" ] || continue
        args=$(LC_ALL=C ps -p "$pid" -o args= 2>/dev/null) || continue
        args=${args#"${args%%[![:space:]]*}"}
        argv0=${args%%[[:space:]]*}
        [ -n "$argv0" ] && printf '%s\n' "$argv0"
      done
}

# fm_backend_tmux_agent_state: recovery-grade harness-agent state for one
# recorded target. See bin/fm-backend.sh's fm_backend_agent_state for the
# shared state vocabulary and docs/tmux-backend.md "Agent liveness probe" for
# the empirical basis. Tmux silently falls back to the active window when a
# named target is absent, so the exact recorded window must appear in a
# successful session inventory before its foreground command can be trusted.
# An omitted window or a definitive missing-session/server response is
# `missing`; any other inventory or pane read failure is `unreadable`, so a
# transient tmux problem never licenses a duplicate.
#
# The verdict combines two independent name sources rather than trusting either
# alone. Either source naming a verified harness is enough for `alive`, because
# a false `dead` is the one outcome that can launch a duplicate agent onto a
# live worktree, while the foreground process group - when it is readable - is
# authoritative for the negative verdicts, since it is the only source that can
# distinguish a truly idle pane from a rewritten process title.
fm_backend_tmux_agent_state() {  # <target>
  local target=$1 comm session window windows inventory_status
  local foreground argv0s name fg_seen=0 fg_shell=0 fg_other=0
  case "$target" in
    *:*:*|'':*|*:'') printf 'unreadable'; return 0 ;;
    *:*) ;;
    *) printf 'unreadable'; return 0 ;;
  esac
  session=${target%%:*}
  window=${target#*:}
  if windows=$(LC_ALL=C tmux list-windows -t "$session" -F '#{window_name}' 2>&1); then
    inventory_status=0
  else
    inventory_status=$?
  fi
  if [ "$inventory_status" -ne 0 ]; then
    case "$windows" in
      *"can't find session:"*|*"no server running on "*|*"error connecting to "*" (No such file or directory)"|*"error connecting to "*" (Connection refused)")
        printf 'missing'
        ;;
      *)
        printf 'unreadable'
        ;;
    esac
    return 0
  fi
  if ! printf '%s\n' "$windows" | grep -Fqx "$window"; then
    printf 'missing'
    return 0
  fi

  foreground=$(fm_backend_tmux_foreground_comms "$target")
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    fg_seen=1
    case "$(fm_backend_tmux_classify_process_name "$name")" in
      agent) printf 'alive'; return 0 ;;
      shell) fg_shell=1 ;;
      *) fg_other=1 ;;
    esac
  done <<EOF
$foreground
EOF

  argv0s=$(fm_backend_tmux_foreground_argv0s "$target")
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ "$(fm_backend_tmux_classify_process_name '' "$name")" = agent ]; then
      printf 'alive'
      return 0
    fi
  done <<EOF
$argv0s
EOF

  comm=$(fm_backend_tmux_current_command "$target") || {
    printf 'unreadable'
    return 0
  }
  if [ "$(fm_backend_tmux_classify_process_name "$comm")" = agent ]; then
    printf 'alive'
    return 0
  fi

  # A readable foreground process group settles the negative verdicts: only a
  # group that is nothing but shells is confidently agent-free.
  if [ "$fg_seen" -eq 1 ]; then
    if [ "$fg_other" -eq 0 ] && [ "$fg_shell" -eq 1 ]; then
      printf 'dead'
    else
      printf 'ambiguous'
    fi
    return 0
  fi

  case "$comm" in
    '') printf 'unreadable'; return 0 ;;
  esac
  case "$(fm_backend_tmux_classify_process_name "$comm")" in
    shell) printf 'dead' ;;
    *) printf 'ambiguous' ;;
  esac
}

# Backward-compatible three-state view for callers that only need a yes/no
# agent verdict. The detailed state contract is owned by fm_backend_agent_state.
fm_backend_tmux_agent_alive() {  # <target>
  case "$(fm_backend_tmux_agent_state "$1")" in
    alive) printf 'alive' ;;
    dead|missing) printf 'dead' ;;
    *) printf 'unknown' ;;
  esac
}

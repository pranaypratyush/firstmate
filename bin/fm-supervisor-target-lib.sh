#!/usr/bin/env bash
# fm-supervisor-target-lib.sh - the single owner of supervisor-pane discovery.
#
# The away-mode daemon (bin/fm-supervise-daemon.sh) must know which pane runs
# firstmate itself, both to inject escalations into it and, for the daemon, to
# validate that target at startup. The script-owned away launcher
# (bin/fm-afk-launch.sh) must resolve the SAME captain pane BEFORE it creates a
# separate, non-visible terminal for the daemon, so it can pass that pane in as
# FM_SUPERVISOR_TARGET (otherwise the daemon, running in its own terminal, would
# auto-discover its OWN pane and inject there instead of into the captain's).
#
# Because both callers need the identical resolution, it lives here once. The
# function names and precedence are unchanged from when this logic lived inline
# in bin/fm-supervise-daemon.sh, so its unit tests (tests/fm-daemon.test.sh)
# keep exercising the same names after the daemon sources this file.

# Default supervisor pane target/backend when nothing is configured or detected.
# "firstmate:0" is a tmux session:window name, so the bare fallback (nothing
# configured, nothing detected) assumes tmux - matching the daemon's pre-herdr
# behavior byte-for-byte when run outside both tmux and herdr.
FM_SUPERVISOR_TARGET_DEFAULT="firstmate:0"
FM_SUPERVISOR_BACKEND_DEFAULT="tmux"

# discover_supervisor_target: resolve the pane running firstmate. Priority:
#   1. FM_SUPERVISOR_TARGET env (explicit override) - may be a tmux target or a
#      herdr "<session>:<pane-id>" target (paired with discover_supervisor_backend
#      to know which).
#   2. $TMUX_PANE - tmux sets this in every pane's environment; inherited by a
#      process launched from firstmate's own pane.
#   3. $HERDR_ENV=1 + $HERDR_PANE_ID - herdr injects both into every process it
#      manages a pane for; compose the "<session>:<pane-id>" target from
#      $HERDR_SESSION (defaulting to "default", mirroring bin/backends/herdr.sh's
#      fm_backend_herdr_session) and $HERDR_PANE_ID. Checked after $TMUX_PANE so a
#      tmux pane nested inside herdr still resolves to tmux, matching
#      fm_backend_detect's innermost-first rule.
#   4. FM_SUPERVISOR_TARGET_DEFAULT - legacy tmux fallback (may not resolve if the
#      session is named differently). Returns 1 so the caller can warn.
discover_supervisor_target() {
  if [ -n "${FM_SUPERVISOR_TARGET:-}" ]; then
    printf '%s' "$FM_SUPERVISOR_TARGET"
    return 0
  fi
  if [ -n "${TMUX_PANE:-}" ]; then
    printf '%s' "$TMUX_PANE"
    return 0
  fi
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf '%s:%s' "${HERDR_SESSION:-default}" "$HERDR_PANE_ID"
    return 0
  fi
  printf '%s' "$FM_SUPERVISOR_TARGET_DEFAULT"
  return 1
}

# discover_supervisor_backend: resolve the supervisor pane's BACKEND, independent
# of the target string so an explicit FM_SUPERVISOR_TARGET override still knows
# which primitives (tmux vs herdr) to dispatch through. Priority mirrors
# discover_supervisor_target and bin/fm-backend.sh's fm_backend_detect:
#   1. FM_SUPERVISOR_BACKEND env (explicit override).
#   2. $TMUX_PANE set - tmux.
#   3. $HERDR_ENV=1 (with $HERDR_PANE_ID present) - herdr.
#   4. FM_SUPERVISOR_BACKEND_DEFAULT (tmux) - matches the target fallback. Returns 1.
discover_supervisor_backend() {
  if [ -n "${FM_SUPERVISOR_BACKEND:-}" ]; then
    printf '%s' "$FM_SUPERVISOR_BACKEND"
    return 0
  fi
  if [ -n "${TMUX_PANE:-}" ]; then
    printf 'tmux'
    return 0
  fi
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf 'herdr'
    return 0
  fi
  printf '%s' "$FM_SUPERVISOR_BACKEND_DEFAULT"
  return 1
}

# fm_supervisor_target_same_home_binding <backend> <target> <home>
#
# Prove a same-home successor target is live in the selected secondmate home
# and return its backend-native incarnation. The caller persists the output
# beside the target and rechecks it before delivery, so a present recycled pane
# cannot replace or receive work for an older successor. This library expects
# bin/fm-backend.sh to have been sourced first.
fm_supervisor_target_same_home_binding() {
  local backend=$1 target=$2 home=$3 home_real path path_real pane pane_number pid info session
  home_real=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P) || return 1
  fm_backend_target_exists "$backend" "$target" || return 1
  case "$backend" in
    tmux)
      fm_backend_source tmux || return 1
      path=$(fm_backend_tmux_current_path "$target") || return 1
      pane=$(tmux display-message -p -t "$target" '#{pane_id}' 2>/dev/null) || return 1
      pid=$(tmux display-message -p -t "$target" '#{pane_pid}' 2>/dev/null) || return 1
      case "$pane" in %*) ;; *) return 1 ;; esac
      pane_number=${pane#%}
      case "$pane_number" in ''|*[!0-9]*) return 1 ;; esac
      case "$pid" in ''|*[!0-9]*) return 1 ;; esac
      ;;
    herdr)
      fm_backend_source herdr || return 1
      fm_backend_herdr_parse_target "$target" || return 1
      session=$FM_BACKEND_HERDR_SESSION
      pane=$FM_BACKEND_HERDR_PANE
      info=$(fm_backend_herdr_cli "$session" pane get "$pane" 2>/dev/null) || return 1
      path=$(printf '%s' "$info" | jq -er --arg pane "$pane" '
        .result.pane as $p
        | select(($p.pane_id // "") == $pane)
        | ($p.foreground_cwd // empty)
      ' 2>/dev/null) || return 1
      info=$(fm_backend_herdr_cli "$session" pane process-info --pane "$pane" 2>/dev/null) || return 1
      pid=$(printf '%s' "$info" | jq -er --arg pane "$pane" '
        .result.process_info as $p
        | select(($p.pane_id // "") == $pane)
        | ($p.shell_pid | select(type == "number" and . > 1) | floor)
      ' 2>/dev/null) || return 1
      case "$pid" in *[!0-9]*|'') return 1 ;; esac
      ;;
    *) return 1 ;;
  esac
  path_real=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || return 1
  [ "$path_real" = "$home_real" ] || return 1
  printf '%s:%s:%s' "$backend" "$pane" "$pid"
}

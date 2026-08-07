#!/usr/bin/env bash
# Own the Firstmate no-mistakes live Codex companion state machine.
#
# Usage:
#   fm-nm-live.sh prepare <task-id> <exact-message>
#   fm-nm-live.sh confirm <task-id> <attempt-id>
#   fm-nm-live.sh cancel <task-id> <attempt-id>
#   fm-nm-live.sh reconcile <task-id>
#   fm-nm-live.sh reconcile-all
#   fm-nm-live.sh cleanup <task-id>
#   fm-nm-live.sh render-command <endpoint> <session-id>
#   fm-nm-live.sh classify-process-info <pane-id> <endpoint> <session-id>
#
# `prepare` is a pre-delivery operation.
# It recognizes only an exact canonical no-mistakes skill invocation for an
# eligible Herdr kind=ship, mode=no-mistakes task, validates the task binding,
# exact parent workspace, configured no-mistakes Codex App Server transport,
# and managed App Server endpoint, then publishes state/<id>.nm-live at mode
# 0600 without creating a Herdr tab.
# It prints an attempt id only when it prepared an eligible invocation.
# `confirm` is the only transition that records successful delivery, and then
# performs a bounded series of idempotent reconciliation passes so a transient
# active thread identity cannot fall between normal watcher cycles.
# It never sends or synthesizes the skill invocation.
#
# This file is the single owner of eligibility, branch-plus-head run binding,
# active_steps[].session_id attribution, the private journal state machine,
# duplicate prevention, Herdr companion creation, restart reconciliation,
# thread rotation, quarantine, and focus-safe cleanup.
# Callers in fm-send, fm-watch, fm-session-start, and fm-teardown invoke only
# the verbs above.
# Herdr labels are diagnostic only and are never lookup or cleanup authority.
# Every Herdr mutation uses the exact recorded session and structured ids.
# No path stops or restarts Codex/no-mistakes, closes a Herdr workspace, routes
# Firstmate input to the companion pane, or handles approvals through it.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
NM_TIMEOUT=${FM_NM_LIVE_STATUS_TIMEOUT:-5}
CAPTURE_TIMEOUT=${FM_NM_LIVE_CAPTURE_TIMEOUT:-5}
CAPTURE_POLL=${FM_NM_LIVE_CAPTURE_POLL:-0.1}
PREPARED_TTL=${FM_NM_LIVE_PREPARED_TTL:-300}
APP_SERVER_HELPER=${FM_NM_LIVE_APP_SERVER_HELPER:-$SCRIPT_DIR/fm-codex-app-server.sh}

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//; $d'
}

warn() { printf 'fm-nm-live: %s\n' "$*" >&2; }

valid_task_id() { [[ ${1:-} =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }
valid_uuid() { [[ ${1:-} =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; }
valid_atom() { [[ -n ${1:-} && ! ${1:-} =~ [[:space:]] ]]; }

real_dir() { (cd "$1" 2>/dev/null && pwd -P); }

hash_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print "sha256:" $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print "sha256:" $1}'
  else
    cksum | awk '{print "cksum:" $1 ":" $2}'
  fi
}

new_attempt_id() {
  local value
  value=$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | base64 | tr '+/' '-_' | tr -d '=\r\n') || return 1
  [ "${#value}" -eq 22 ] || return 1
  case "$value" in *[!A-Za-z0-9_-]*) return 1 ;; esac
  printf '%s' "$value"
}

journal_path() { printf '%s/%s.nm-live' "$STATE" "$1"; }
task_lock_path() { printf '%s/.%s.nm-live.lock' "$STATE" "$1"; }

journal_field() {  # <journal> <key>
  local count
  count=$(grep -c "^$2=" "$1" 2>/dev/null || true)
  [ "$count" -eq 1 ] || return 1
  grep "^$2=" "$1" | cut -d= -f2-
}

journal_clear_globals() {
  J_VERSION=1 J_TASK_ID= J_ATTEMPT_ID= J_PHASE= J_HOME_REAL= J_TASK_BINDING=
  J_WORKTREE_REAL= J_BRANCH= J_HEAD= J_DELIVERY_CONFIRMED_AT=
  J_BASELINE_RUN_ID= J_BASELINE_SESSION_ID= J_RUN_ID= J_RUN_HEAD= J_SESSION_ID=
  J_PENDING_RUN_ID= J_PENDING_RUN_HEAD= J_PENDING_SESSION_ID= J_SESSION_SEEN_AT=
  J_CODEX_STATUS= J_CODEX_BACKEND= J_CODEX_SOCKET_PATH= J_CODEX_ENDPOINT=
  J_CODEX_CLI_VERSION= J_CODEX_APP_SERVER_VERSION= J_CODEX_MANAGED_VERSION=
  J_HERDR_SESSION= J_HERDR_PARENT_WORKSPACE_ID= J_HERDR_TAB_ID= J_HERDR_PANE_ID=
  J_HERDR_LABEL= J_LAUNCH_STATE=not-started J_CREATED_AT= J_TERMINAL_SEEN_AT=
  J_LAST_ERROR=
}

journal_load() {  # <journal> <expected-task-id>
  local journal=$1 expected=$2 mode key value lines
  journal_clear_globals
  [ -f "$journal" ] && [ ! -L "$journal" ] || return 1
  if [ "$(uname 2>/dev/null)" = Darwin ]; then mode=$(stat -f %Lp "$journal" 2>/dev/null)
  else mode=$(stat -c %a "$journal" 2>/dev/null)
  fi
  mode=${mode#0}
  [ "$mode" = 600 ] || return 1
  lines=$(wc -l < "$journal" 2>/dev/null | tr -d '[:space:]')
  [ "$lines" = 38 ] || return 1
  while IFS='|' read -r key value; do
    value=$(journal_field "$journal" "$value") || return 1
    printf -v "$key" '%s' "$value"
  done <<'EOF'
J_VERSION|version
J_TASK_ID|task_id
J_ATTEMPT_ID|attempt_id
J_PHASE|phase
J_HOME_REAL|home_real
J_TASK_BINDING|task_binding
J_WORKTREE_REAL|worktree_real
J_BRANCH|branch_at_trigger
J_HEAD|head_at_trigger
J_DELIVERY_CONFIRMED_AT|delivery_confirmed_at
J_BASELINE_RUN_ID|baseline_run_id
J_BASELINE_SESSION_ID|baseline_session_id
J_RUN_ID|run_id
J_RUN_HEAD|run_head
J_SESSION_ID|session_id
J_PENDING_RUN_ID|pending_run_id
J_PENDING_RUN_HEAD|pending_run_head
J_PENDING_SESSION_ID|pending_session_id
J_SESSION_SEEN_AT|session_seen_at
J_CODEX_STATUS|codex_status
J_CODEX_BACKEND|codex_backend
J_CODEX_SOCKET_PATH|codex_socket_path
J_CODEX_ENDPOINT|codex_endpoint
J_CODEX_CLI_VERSION|codex_cli_version
J_CODEX_APP_SERVER_VERSION|codex_app_server_version
J_CODEX_MANAGED_VERSION|codex_managed_version
J_HERDR_SESSION|herdr_session
J_HERDR_PARENT_WORKSPACE_ID|herdr_parent_workspace_id
J_HERDR_TAB_ID|herdr_tab_id
J_HERDR_PANE_ID|herdr_pane_id
J_HERDR_LABEL|herdr_label
J_LAUNCH_STATE|launch_state
J_CREATED_AT|created_at
J_TERMINAL_SEEN_AT|terminal_seen_at
J_LAST_ERROR|last_error
J_RESERVED_1|reserved_1
J_RESERVED_2|reserved_2
J_RESERVED_3|reserved_3
EOF
  [ "$J_VERSION" = 1 ] && [ "$J_TASK_ID" = "$expected" ] || return 1
  valid_task_id "$J_TASK_ID" || return 1
  case "$J_ATTEMPT_ID" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
  case "$J_PHASE" in
    prepared|delivery-confirmed|waiting-run|creating|live|thread-complete|cleanup-deferred|quarantined) ;;
    *) return 1 ;;
  esac
  case "$J_LAUNCH_STATE" in not-started|submitted) ;; *) return 1 ;; esac
  case "$J_HOME_REAL:$J_WORKTREE_REAL" in /*:/*) ;; *) return 1 ;; esac
  return 0
}

journal_value_safe() { case "$1" in *$'\n'*|*$'\r'*) return 1 ;; esac; }

journal_write() {  # <journal>
  local journal=$1 tmp value
  for value in \
    "$J_TASK_ID" "$J_ATTEMPT_ID" "$J_PHASE" "$J_HOME_REAL" "$J_TASK_BINDING" \
    "$J_WORKTREE_REAL" "$J_BRANCH" "$J_HEAD" "$J_DELIVERY_CONFIRMED_AT" \
    "$J_BASELINE_RUN_ID" "$J_BASELINE_SESSION_ID" "$J_RUN_ID" "$J_RUN_HEAD" \
    "$J_SESSION_ID" "$J_PENDING_RUN_ID" "$J_PENDING_RUN_HEAD" "$J_PENDING_SESSION_ID" \
    "$J_SESSION_SEEN_AT" "$J_CODEX_STATUS" "$J_CODEX_BACKEND" "$J_CODEX_SOCKET_PATH" \
    "$J_CODEX_ENDPOINT" "$J_CODEX_CLI_VERSION" "$J_CODEX_APP_SERVER_VERSION" \
    "$J_CODEX_MANAGED_VERSION" "$J_HERDR_SESSION" "$J_HERDR_PARENT_WORKSPACE_ID" \
    "$J_HERDR_TAB_ID" "$J_HERDR_PANE_ID" "$J_HERDR_LABEL" "$J_LAUNCH_STATE" \
    "$J_CREATED_AT" "$J_TERMINAL_SEEN_AT" "$J_LAST_ERROR"; do
    journal_value_safe "$value" || return 1
  done
  mkdir -p "$STATE" || return 1
  tmp=$(umask 077; mktemp "$STATE/.${J_TASK_ID}.nm-live.XXXXXX") || return 1
  chmod 0600 "$tmp" || { rm -f "$tmp"; return 1; }
  if ! {
    printf 'version=1\n'
    printf 'task_id=%s\n' "$J_TASK_ID"
    printf 'attempt_id=%s\n' "$J_ATTEMPT_ID"
    printf 'phase=%s\n' "$J_PHASE"
    printf 'home_real=%s\n' "$J_HOME_REAL"
    printf 'task_binding=%s\n' "$J_TASK_BINDING"
    printf 'worktree_real=%s\n' "$J_WORKTREE_REAL"
    printf 'branch_at_trigger=%s\n' "$J_BRANCH"
    printf 'head_at_trigger=%s\n' "$J_HEAD"
    printf 'delivery_confirmed_at=%s\n' "$J_DELIVERY_CONFIRMED_AT"
    printf 'baseline_run_id=%s\n' "$J_BASELINE_RUN_ID"
    printf 'baseline_session_id=%s\n' "$J_BASELINE_SESSION_ID"
    printf 'run_id=%s\n' "$J_RUN_ID"
    printf 'run_head=%s\n' "$J_RUN_HEAD"
    printf 'session_id=%s\n' "$J_SESSION_ID"
    printf 'pending_run_id=%s\n' "$J_PENDING_RUN_ID"
    printf 'pending_run_head=%s\n' "$J_PENDING_RUN_HEAD"
    printf 'pending_session_id=%s\n' "$J_PENDING_SESSION_ID"
    printf 'session_seen_at=%s\n' "$J_SESSION_SEEN_AT"
    printf 'codex_status=%s\n' "$J_CODEX_STATUS"
    printf 'codex_backend=%s\n' "$J_CODEX_BACKEND"
    printf 'codex_socket_path=%s\n' "$J_CODEX_SOCKET_PATH"
    printf 'codex_endpoint=%s\n' "$J_CODEX_ENDPOINT"
    printf 'codex_cli_version=%s\n' "$J_CODEX_CLI_VERSION"
    printf 'codex_app_server_version=%s\n' "$J_CODEX_APP_SERVER_VERSION"
    printf 'codex_managed_version=%s\n' "$J_CODEX_MANAGED_VERSION"
    printf 'herdr_session=%s\n' "$J_HERDR_SESSION"
    printf 'herdr_parent_workspace_id=%s\n' "$J_HERDR_PARENT_WORKSPACE_ID"
    printf 'herdr_tab_id=%s\n' "$J_HERDR_TAB_ID"
    printf 'herdr_pane_id=%s\n' "$J_HERDR_PANE_ID"
    printf 'herdr_label=%s\n' "$J_HERDR_LABEL"
    printf 'launch_state=%s\n' "$J_LAUNCH_STATE"
    printf 'created_at=%s\n' "$J_CREATED_AT"
    printf 'terminal_seen_at=%s\n' "$J_TERMINAL_SEEN_AT"
    printf 'last_error=%s\n' "$J_LAST_ERROR"
    printf 'reserved_1=\nreserved_2=\nreserved_3=\n'
  } > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$journal"
}

task_binding() {  # <meta> <home-real> <worktree-real>
  local meta=$1 home_real=$2 worktree_real=$3 key project project_real
  project=$(fm_meta_get "$meta" project)
  project_real=$(real_dir "$project") || return 1
  {
    printf 'home=%s\nworktree=%s\nproject=%s\n' "$home_real" "$worktree_real" "$project_real"
    for key in endpoint_task_id kind mode backend window herdr_session herdr_workspace_id herdr_tab_id herdr_pane_id; do
      printf '%s=%s\n' "$key" "$(fm_meta_get "$meta" "$key")"
    done
  } | hash_text
}

live_view_preference() {
  local file="$CONFIG/nm-live-view" value
  [ -f "$file" ] || { printf 'on'; return 0; }
  value=$(tr -d '[:space:]' < "$file" 2>/dev/null | tr '[:upper:]' '[:lower:]') || value=
  case "$value" in
    off) printf 'off' ;;
    ''|on) printf 'on' ;;
    *) warn "$file has unrecognized value '$value'; the default-on no-mistakes live view remains enabled (write 'off' to opt out)"; printf 'on' ;;
  esac
}

canonical_invocation() {  # <harness> <message>
  case "$1:$2" in
    codex:'$no-mistakes') return 0 ;;
    claude:/no-mistakes|grok:/no-mistakes|kimi:/no-mistakes) return 0 ;;
    *) return 1 ;;
  esac
}

yaml_unquote() {
  local value=$1
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  case "$value" in
    \"*\") value=${value#\"}; value=${value%\"} ;;
    \'*\') value=${value#\'}; value=${value%\'} ;;
  esac
  printf '%s' "$value"
}

no_mistakes_config_snapshot() {
  local file=${FM_NM_LIVE_NM_CONFIG:-$HOME/.no-mistakes/config.yaml} rows agent transport endpoint key
  [ -f "$file" ] && [ ! -L "$file" ] || {
    warn "no-mistakes global config is missing at $file; configure agent: codex and codex.transport: app-server before delivery"
    return 1
  }
  rows=$(awk '
    /^[^[:space:]#][^:]*:/ {
      top=$0
      sub(/:.*/, "", top)
      in_codex=(top == "codex")
    }
    /^[[:space:]]*#/ { next }
    /^agent:[[:space:]]*/ {
      value=$0; sub(/^agent:[[:space:]]*/, "", value); sub(/[[:space:]]+#.*$/, "", value)
      print "agent=" value
    }
    in_codex && /^[[:space:]]+transport:[[:space:]]*/ {
      value=$0; sub(/^[[:space:]]+transport:[[:space:]]*/, "", value); sub(/[[:space:]]+#.*$/, "", value)
      print "transport=" value
    }
    in_codex && /^[[:space:]]+app_server_endpoint:[[:space:]]*/ {
      value=$0; sub(/^[[:space:]]+app_server_endpoint:[[:space:]]*/, "", value); sub(/[[:space:]]+#.*$/, "", value)
      print "endpoint=" value
    }
  ' "$file") || return 1
  for key in agent transport endpoint; do
    [ "$(printf '%s\n' "$rows" | grep -c "^$key=")" -eq 1 ] || {
      warn "no-mistakes global config must define exactly one $key value for the live companion"
      return 1
    }
  done
  agent=$(printf '%s\n' "$rows" | sed -n 's/^agent=//p' | tail -1)
  transport=$(printf '%s\n' "$rows" | sed -n 's/^transport=//p' | tail -1)
  endpoint=$(printf '%s\n' "$rows" | sed -n 's/^endpoint=//p' | tail -1)
  agent=$(yaml_unquote "$agent")
  transport=$(yaml_unquote "$transport")
  endpoint=$(yaml_unquote "$endpoint")
  [ "$agent" = codex ] || { warn "no-mistakes must use the singular configured agent 'codex' for exact companion attribution (found '${agent:-unset}')"; return 1; }
  [ "$transport" = app-server ] || { warn "no-mistakes codex.transport must be 'app-server' for the live companion (found '${transport:-unset}')"; return 1; }
  case "$endpoint" in unix://|unix:///*) ;; *) warn "no-mistakes codex.app_server_endpoint is not an absolute local Unix endpoint: ${endpoint:-unset}"; return 1 ;; esac
  NM_CONFIG_ENDPOINT=$endpoint
}

eligible_snapshot() {  # <task-id> <message>
  local id=$1 message=$2 meta backend kind mode harness endpoint_task home_real wt_real branch head binding
  ELIGIBLE=0
  valid_task_id "$id" || return 0
  [ "$(live_view_preference)" = on ] || return 0
  meta="$STATE/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  kind=$(fm_meta_get "$meta" kind)
  mode=$(fm_meta_get "$meta" mode)
  backend=$(fm_backend_of_meta "$meta")
  harness=$(fm_meta_get "$meta" harness)
  [ "$kind" = ship ] && [ "$mode" = no-mistakes ] && [ "$backend" = herdr ] || return 0
  canonical_invocation "$harness" "$message" || return 0
  fm_backend_validate_task_endpoint "$meta" "$id" >/dev/null || return 1
  endpoint_task=$(fm_meta_get "$meta" endpoint_task_id)
  [ "$endpoint_task" = "$id" ] || { warn "task $id has no exact endpoint task binding"; return 1; }
  home_real=$(real_dir "$FM_HOME") || { warn "could not resolve Firstmate home $FM_HOME"; return 1; }
  wt_real=$(real_dir "$(fm_meta_get "$meta" worktree)") || { warn "could not resolve task $id worktree"; return 1; }
  branch=$(git -C "$wt_real" symbolic-ref --quiet --short HEAD 2>/dev/null) || { warn "task $id worktree is detached; refusing live-thread attribution"; return 1; }
  head=$(git -C "$wt_real" rev-parse HEAD 2>/dev/null) || { warn "task $id worktree HEAD is unreadable"; return 1; }
  binding=$(task_binding "$meta" "$home_real" "$wt_real") || return 1
  ELIGIBLE=1
  E_META=$meta E_HOME_REAL=$home_real E_WORKTREE_REAL=$wt_real E_BRANCH=$branch E_HEAD=$head E_BINDING=$binding E_HARNESS=$harness
}

resolve_parent() {  # uses E_META/E_HOME_REAL
  local presentation="$STATE/$J_TASK_ID.herdr-presentation" session parent workspace
  session=$(fm_meta_get "$E_META" herdr_session)
  valid_atom "$session" || { warn "task $J_TASK_ID has a malformed Herdr session"; return 1; }
  parent=
  fm_backend_source herdr || return 1
  if [ -e "$presentation" ] || [ -L "$presentation" ]; then
    if ! fm_backend_herdr_projection_journal_snapshot "$presentation" "$J_TASK_ID" \
      || [ "$FM_BACKEND_HERDR_JOURNAL_VERSION" != 2 ] \
      || [ "$FM_BACKEND_HERDR_JOURNAL_HOME" != "$E_HOME_REAL" ] \
      || [ "$FM_BACKEND_HERDR_JOURNAL_SESSION" != "$session" ]; then
      warn "task $J_TASK_ID has an invalid or mismatched Herdr presentation parent binding"
      return 1
    fi
    parent=$FM_BACKEND_HERDR_JOURNAL_PARENT_WORKSPACE_ID
  else
    workspace=$(fm_meta_get "$E_META" herdr_workspace_id)
    parent=$workspace
  fi
  valid_atom "$parent" || { warn "task $J_TASK_ID has no exact Herdr parent workspace"; return 1; }
  [ "$(fm_backend_herdr_workspace_presence_state "$session" "$parent")" = present ] || {
    warn "task $J_TASK_ID parent workspace $parent is not uniquely present in Herdr session $session"
    return 1
  }
  J_HERDR_SESSION=$session
  J_HERDR_PARENT_WORKSPACE_ID=$parent
}

app_server_snapshot() {
  local json
  no_mistakes_config_snapshot || return 1
  json=$($APP_SERVER_HELPER ensure) || return 1
  J_CODEX_STATUS=$(printf '%s' "$json" | jq -er '.status') || return 1
  J_CODEX_BACKEND=$(printf '%s' "$json" | jq -er '.backend') || return 1
  J_CODEX_SOCKET_PATH=$(printf '%s' "$json" | jq -er '.socket_path') || return 1
  J_CODEX_ENDPOINT=$(printf '%s' "$json" | jq -er '.endpoint') || return 1
  J_CODEX_CLI_VERSION=$(printf '%s' "$json" | jq -r '.cli_version // ""') || return 1
  J_CODEX_APP_SERVER_VERSION=$(printf '%s' "$json" | jq -r '.app_server_version // ""') || return 1
  J_CODEX_MANAGED_VERSION=$(printf '%s' "$json" | jq -r '.managed_codex_version // ""') || return 1
  [ "$J_CODEX_BACKEND" = pid ] || return 1
  if [ "$NM_CONFIG_ENDPOINT" != unix:// ] && [ "$NM_CONFIG_ENDPOINT" != "$J_CODEX_ENDPOINT" ]; then
    warn "no-mistakes codex.app_server_endpoint $NM_CONFIG_ENDPOINT does not match managed endpoint $J_CODEX_ENDPOINT"
    return 1
  fi
}

baseline_snapshot() {
  local rc
  if fm_nm_attributed_status "$J_WORKTREE_REAL" "$J_BRANCH" "$NM_TIMEOUT"; then
    J_BASELINE_RUN_ID=$FM_NM_ATTRIBUTED_ID
    run_is_terminal && return 0
    exact_active_session
    rc=$?
    case "$rc" in
      0) J_BASELINE_SESSION_ID=$ACTIVE_SESSION ;;
      1) ;;
      *) return 1 ;;
    esac
  else
    rc=$?
    [ "$rc" -eq 1 ] || return 1
  fi
}

prepare() {  # <task-id> <message>
  local id=$1 message=$2 lock journal attempt now
  eligible_snapshot "$id" "$message" || return 1
  [ "$ELIGIBLE" = 1 ] || return 0
  lock=$(task_lock_path "$id")
  fm_lock_acquire_wait "$lock" || return 1
  journal=$(journal_path "$id")
  if [ -e "$journal" ] || [ -L "$journal" ]; then
    warn "task $id already has a no-mistakes live-view attempt; reconcile or clean it before another invocation"
    fm_lock_release "$lock"
    return 1
  fi
  journal_clear_globals
  attempt=$(new_attempt_id) || { fm_lock_release "$lock"; return 1; }
  now=$(date +%s)
  J_TASK_ID=$id J_ATTEMPT_ID=$attempt J_PHASE=prepared J_HOME_REAL=$E_HOME_REAL
  J_TASK_BINDING=$E_BINDING J_WORKTREE_REAL=$E_WORKTREE_REAL J_BRANCH=$E_BRANCH J_HEAD=$E_HEAD
  J_CREATED_AT=$now
  resolve_parent || { fm_lock_release "$lock"; return 1; }
  app_server_snapshot || { fm_lock_release "$lock"; return 1; }
  baseline_snapshot || { warn "could not establish an unambiguous pre-delivery no-mistakes baseline"; fm_lock_release "$lock"; return 1; }
  if ! journal_write "$journal"; then
    fm_lock_release "$lock"
    return 1
  fi
  fm_lock_release "$lock"
  printf '%s' "$attempt"
}

cancel() {  # <task-id> <attempt-id>
  local id=$1 attempt=$2 lock journal
  valid_task_id "$id" || return 1
  lock=$(task_lock_path "$id")
  fm_lock_acquire_wait "$lock" || return 1
  journal=$(journal_path "$id")
  if journal_load "$journal" "$id" && [ "$J_ATTEMPT_ID" = "$attempt" ] && [ "$J_PHASE" = prepared ]; then
    rm -f "$journal"
  fi
  fm_lock_release "$lock"
}

confirm() {  # <task-id> <attempt-id>
  local id=$1 attempt=$2 lock journal
  valid_task_id "$id" || return 1
  lock=$(task_lock_path "$id")
  fm_lock_acquire_wait "$lock" || return 1
  journal=$(journal_path "$id")
  if ! journal_load "$journal" "$id" || [ "$J_ATTEMPT_ID" != "$attempt" ] || [ "$J_PHASE" != prepared ]; then
    warn "task $id live-view confirmation does not match its prepared attempt"
    fm_lock_release "$lock"
    return 1
  fi
  J_PHASE=delivery-confirmed
  J_DELIVERY_CONFIRMED_AT=$(date +%s)
  J_LAST_ERROR=
  journal_write "$journal" || { fm_lock_release "$lock"; return 1; }
  fm_lock_release "$lock"
  capture_after_delivery "$id"
}

current_binding_matches() {
  local meta="$STATE/$J_TASK_ID.meta" home_real wt_real binding
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 2
  home_real=$(real_dir "$FM_HOME") || return 1
  wt_real=$(real_dir "$(fm_meta_get "$meta" worktree)") || return 1
  binding=$(task_binding "$meta" "$home_real" "$wt_real") || return 1
  [ "$binding" = "$J_TASK_BINDING" ] || return 1
  [ "$(fm_meta_get "$meta" kind)" = ship ] \
    && [ "$(fm_meta_get "$meta" mode)" = no-mistakes ] \
    && [ "$(fm_backend_of_meta "$meta")" = herdr ]
}

run_is_terminal() {
  [ -n "$FM_NM_ATTRIBUTED_OUTCOME" ] && return 0
  case "$FM_NM_ATTRIBUTED_STATUS" in completed|failed|cancelled|aborted|terminal) return 0 ;; esac
  return 1
}

exact_active_session() {  # sets ACTIVE_SESSION; 0 one, 1 none, 2 malformed/multiple
  local sessions count rc
  ACTIVE_SESSION=
  sessions=$(fm_nm_active_session_ids "$FM_NM_ATTRIBUTED_OUT")
  rc=$?
  [ "$rc" -eq 0 ] || return 2
  count=$(printf '%s\n' "$sessions" | sed '/^$/d' | wc -l | tr -d ' ')
  case "$count" in
    0) return 1 ;;
    1) ACTIVE_SESSION=$(printf '%s\n' "$sessions" | sed '/^$/d') ;;
    *) return 2 ;;
  esac
  valid_uuid "$ACTIVE_SESSION" || return 2
  return 0
}

pair_claimed_elsewhere() {  # <task-id> <run-id> <session-id>
  local id=$1 run=$2 session=$3 other other_id other_run other_session other_phase
  for other in "$STATE"/*.nm-live; do
    [ -f "$other" ] && [ ! -L "$other" ] || continue
    other_id=${other##*/}; other_id=${other_id%.nm-live}
    [ "$other_id" != "$id" ] || continue
    other_run=$(journal_field "$other" run_id 2>/dev/null || true)
    other_session=$(journal_field "$other" session_id 2>/dev/null || true)
    other_phase=$(journal_field "$other" phase 2>/dev/null || true)
    [ "$other_run" = "$run" ] && [ "$other_session" = "$session" ] || continue
    [ -n "$other_phase" ] && return 0
  done
  return 1
}

shell_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\"'\\\"'/g")"; }

companion_command() {
  printf 'exec codex --remote %s resume %s' "$(shell_quote "$J_CODEX_ENDPOINT")" "$(shell_quote "$J_SESSION_ID")"
}

companion_process_info_matches() {  # <json> <pane-id> <endpoint> <session-id>
  printf '%s' "$1" | jq -e --arg pane "$2" --arg endpoint "$3" --arg session "$4" '
    .result.type == "pane_process_info"
    and .result.process_info.pane_id == $pane
    and any(.result.process_info.foreground_processes[]?;
      (((.name // "") | split("/") | last) == "codex")
      and ((.argv // []) as $argv
        | ($argv | length) == 5
        and (($argv[0] | split("/") | last) == "codex")
        and $argv[1] == "--remote"
        and $argv[2] == $endpoint
        and $argv[3] == "resume"
        and $argv[4] == $session))
  ' >/dev/null 2>&1
}

pane_live_state() {  # prints codex|idle|dead|unknown
  local presence info
  presence=$(fm_backend_herdr_pane_presence_state "$J_HERDR_SESSION" "$J_HERDR_PANE_ID")
  case "$presence" in dead) printf dead; return 0 ;; present) ;; *) printf unknown; return 0 ;; esac
  info=$(fm_backend_herdr_cli "$J_HERDR_SESSION" pane process-info --pane "$J_HERDR_PANE_ID" 2>/dev/null) || { printf unknown; return 0; }
  if companion_process_info_matches "$info" "$J_HERDR_PANE_ID" "$J_CODEX_ENDPOINT" "$J_SESSION_ID"; then
    printf codex
  elif fm_backend_herdr_pane_idle_shell_pid "$J_HERDR_SESSION" "$J_HERDR_PANE_ID" >/dev/null 2>&1; then
    printf idle
  else
    printf unknown
  fi
}

acquire_session_lock() {
  SESSION_LOCK=$(fm_backend_herdr_presentation_session_lock_path "$J_HERDR_SESSION" 2>/dev/null) || return 1
  fm_lock_try_acquire "$SESSION_LOCK"
}

release_session_lock() { [ -z "${SESSION_LOCK:-}" ] || fm_lock_release "$SESSION_LOCK" || true; SESSION_LOCK=; }

recorded_companion_binding_matches() {
  local pane_info tab_info
  pane_info=$(fm_backend_herdr_cli "$J_HERDR_SESSION" pane get "$J_HERDR_PANE_ID" 2>/dev/null) || return 1
  printf '%s' "$pane_info" | jq -e \
    --arg pane "$J_HERDR_PANE_ID" \
    --arg tab "$J_HERDR_TAB_ID" \
    --arg workspace "$J_HERDR_PARENT_WORKSPACE_ID" '
      .result.pane.pane_id == $pane
      and .result.pane.tab_id == $tab
      and .result.pane.workspace_id == $workspace
    ' >/dev/null 2>&1 || return 1
  tab_info=$(fm_backend_herdr_cli "$J_HERDR_SESSION" tab get "$J_HERDR_TAB_ID" 2>/dev/null) || return 1
  printf '%s' "$tab_info" | jq -e \
    --arg tab "$J_HERDR_TAB_ID" \
    --arg workspace "$J_HERDR_PARENT_WORKSPACE_ID" '
      .result.tab.tab_id == $tab
      and .result.tab.workspace_id == $workspace
    ' >/dev/null 2>&1
}

launch_companion_preserving_focus() {  # <focus-snapshot> <context>; session lock held
  local focus_before=$1 context=$2 command focus_after rc
  command=$(companion_command)
  fm_backend_herdr_cli "$J_HERDR_SESSION" pane run "$J_HERDR_PANE_ID" "$command" >/dev/null 2>&1
  rc=$?
  focus_after=$(fm_backend_herdr_projection_focus_snapshot "$J_HERDR_SESSION" 2>/dev/null || true)
  if [ "$rc" -ne 0 ] || [ "$focus_after" != "$focus_before" ]; then
    fm_backend_herdr_projection_focus_restore "$J_HERDR_SESSION" "$focus_before" "$context" >/dev/null 2>&1 || true
    return 1
  fi
}

create_companion() {  # task lock held, journal loaded and attributed
  local journal out focus_before focus_after tab pane short_run rc
  journal=$(journal_path "$J_TASK_ID")
  pair_claimed_elsewhere "$J_TASK_ID" "$J_RUN_ID" "$J_SESSION_ID" && {
    J_PHASE=quarantined J_LAST_ERROR="run/session pair is already claimed by another task journal"
    journal_write "$journal"
    return 1
  }
  valid_atom "$J_HERDR_SESSION" && valid_atom "$J_HERDR_PARENT_WORKSPACE_ID" || return 1
  [ "$(fm_backend_herdr_workspace_presence_state "$J_HERDR_SESSION" "$J_HERDR_PARENT_WORKSPACE_ID")" = present ] || {
    J_PHASE=quarantined J_LAST_ERROR="recorded parent workspace is absent or ambiguous"
    journal_write "$journal"
    return 1
  }
  acquire_session_lock || { J_LAST_ERROR="Herdr presentation lock is unavailable"; journal_write "$journal"; return 1; }
  focus_before=$(fm_backend_herdr_projection_focus_snapshot "$J_HERDR_SESSION") || {
    release_session_lock
    J_PHASE=quarantined J_LAST_ERROR="could not capture exact pre-create focus"
    journal_write "$journal"
    return 1
  }
  short_run=${J_RUN_ID:0:12}
  J_HERDR_LABEL="VIEW ONLY nm-$J_TASK_ID-$short_run"
  J_PHASE=creating J_HERDR_TAB_ID= J_HERDR_PANE_ID= J_LAUNCH_STATE=not-started J_LAST_ERROR=
  journal_write "$journal" || { release_session_lock; return 1; }
  out=$(fm_backend_herdr_cli "$J_HERDR_SESSION" tab create \
    --workspace "$J_HERDR_PARENT_WORKSPACE_ID" \
    --cwd "$STATE" \
    --label "$J_HERDR_LABEL" \
    --no-focus 2>/dev/null)
  rc=$?
  focus_after=$(fm_backend_herdr_projection_focus_snapshot "$J_HERDR_SESSION" 2>/dev/null || true)
  if [ "$rc" -ne 0 ]; then
    fm_backend_herdr_projection_focus_restore "$J_HERDR_SESSION" "$focus_before" "no-mistakes companion create" >/dev/null 2>&1 || true
    release_session_lock
    J_PHASE=quarantined J_LAST_ERROR="Herdr tab creation response was ambiguous"
    journal_write "$journal"
    return 1
  fi
  tab=$(printf '%s' "$out" | jq -er '.result.tab.tab_id | select(type == "string" and length > 0)' 2>/dev/null) || tab=
  pane=$(printf '%s' "$out" | jq -er '.result.root_pane.pane_id | select(type == "string" and length > 0)' 2>/dev/null) || pane=
  if ! valid_atom "$tab" || ! valid_atom "$pane"; then
    if [ "$focus_after" != "$focus_before" ]; then
      fm_backend_herdr_projection_focus_restore "$J_HERDR_SESSION" "$focus_before" "no-mistakes companion create" >/dev/null 2>&1 || true
    fi
    release_session_lock
    J_PHASE=quarantined J_LAST_ERROR="Herdr tab creation returned incomplete exact ids"
    journal_write "$journal"
    return 1
  fi
  J_HERDR_TAB_ID=$tab J_HERDR_PANE_ID=$pane
  if ! journal_write "$journal"; then
    if [ "$focus_after" != "$focus_before" ]; then
      fm_backend_herdr_projection_focus_restore "$J_HERDR_SESSION" "$focus_before" "no-mistakes companion create" >/dev/null 2>&1 || true
    fi
    release_session_lock
    return 1
  fi
  if [ "$focus_after" != "$focus_before" ]; then
    fm_backend_herdr_projection_focus_restore "$J_HERDR_SESSION" "$focus_before" "no-mistakes companion create" >/dev/null 2>&1 || true
    release_session_lock
    J_PHASE=quarantined J_LAST_ERROR="Herdr tab creation did not preserve exact focus"
    journal_write "$journal"
    return 1
  fi
  if ! launch_companion_preserving_focus "$focus_before" "no-mistakes companion launch"; then
    release_session_lock
    J_PHASE=quarantined J_LAST_ERROR="Herdr pane launch response or focus preservation was ambiguous"
    journal_write "$journal"
    return 1
  fi
  release_session_lock
  J_LAUNCH_STATE=submitted J_PHASE=live J_LAST_ERROR=
  journal_write "$journal"
}

promote_pending_after_close() {
  if [ -n "$J_PENDING_SESSION_ID" ]; then
    J_RUN_ID=$J_PENDING_RUN_ID J_RUN_HEAD=$J_PENDING_RUN_HEAD J_SESSION_ID=$J_PENDING_SESSION_ID
    J_PENDING_RUN_ID= J_PENDING_RUN_HEAD= J_PENDING_SESSION_ID=
    J_HERDR_TAB_ID= J_HERDR_PANE_ID= J_LAUNCH_STATE=not-started
    J_PHASE=waiting-run J_LAST_ERROR=
    journal_write "$(journal_path "$J_TASK_ID")"
  else
    rm -f "$(journal_path "$J_TASK_ID")"
  fi
}

close_companion() {  # task lock held; returns 0 retired/promoted, 1 deferred/quarantined
  local journal presence before active_tab info target_tab target_ws
  journal=$(journal_path "$J_TASK_ID")
  if [ -z "$J_HERDR_PANE_ID" ]; then
    promote_pending_after_close
    return 0
  fi
  acquire_session_lock || { J_PHASE=cleanup-deferred J_LAST_ERROR="Herdr presentation lock is unavailable"; journal_write "$journal"; return 1; }
  presence=$(fm_backend_herdr_pane_presence_state "$J_HERDR_SESSION" "$J_HERDR_PANE_ID")
  if [ "$presence" = dead ]; then
    release_session_lock
    promote_pending_after_close
    return 0
  fi
  if [ "$presence" != present ]; then
    release_session_lock
    J_PHASE=quarantined J_LAST_ERROR="exact companion pane presence is ambiguous"
    journal_write "$journal"
    return 1
  fi
  before=$(fm_backend_herdr_projection_focus_snapshot "$J_HERDR_SESSION") || {
    release_session_lock
    J_PHASE=cleanup-deferred J_LAST_ERROR="could not capture exact cleanup focus"
    journal_write "$journal"
    return 1
  }
  active_tab=${before#*$'\t'}
  info=$(fm_backend_herdr_cli "$J_HERDR_SESSION" pane get "$J_HERDR_PANE_ID" 2>/dev/null) || info=
  target_tab=$(printf '%s' "$info" | jq -r '.result.pane.tab_id // empty' 2>/dev/null)
  target_ws=$(printf '%s' "$info" | jq -r '.result.pane.workspace_id // empty' 2>/dev/null)
  if [ "$target_tab" != "$J_HERDR_TAB_ID" ] || [ "$target_ws" != "$J_HERDR_PARENT_WORKSPACE_ID" ]; then
    release_session_lock
    J_PHASE=quarantined J_LAST_ERROR="exact companion pane binding is ambiguous"
    journal_write "$journal"
    return 1
  fi
  if [ "$target_tab" = "$active_tab" ]; then
    release_session_lock
    J_PHASE=cleanup-deferred J_LAST_ERROR="companion is focused; cleanup deferred without focus mutation"
    journal_write "$journal"
    return 1
  fi
  if ! fm_backend_herdr_projection_close_pane_focus_preserving "$J_HERDR_SESSION" "$J_HERDR_PANE_ID"; then
    release_session_lock
    J_PHASE=quarantined J_LAST_ERROR="exact companion close response was ambiguous"
    journal_write "$journal"
    return 1
  fi
  release_session_lock
  promote_pending_after_close
}

recover_creating() {  # task lock held
  local state journal focus_before
  journal=$(journal_path "$J_TASK_ID")
  if [ -z "$J_HERDR_TAB_ID" ] || [ -z "$J_HERDR_PANE_ID" ]; then
    J_PHASE=quarantined J_LAST_ERROR="restart found an unbound Herdr creation attempt"
    journal_write "$journal"
    return 1
  fi
  acquire_session_lock || { J_LAST_ERROR="Herdr presentation lock is unavailable"; journal_write "$journal"; return 1; }
  if ! recorded_companion_binding_matches; then
    release_session_lock
    J_PHASE=quarantined J_LAST_ERROR="restart found an ambiguous recorded workspace/tab/pane binding"
    journal_write "$journal"
    return 1
  fi
  state=$(pane_live_state)
  case "$state" in
    codex)
      release_session_lock
      J_PHASE=live J_LAUNCH_STATE=submitted J_LAST_ERROR=
      journal_write "$journal"
      ;;
    idle)
      focus_before=$(fm_backend_herdr_projection_focus_snapshot "$J_HERDR_SESSION") || {
        release_session_lock
        J_PHASE=quarantined J_LAST_ERROR="could not capture exact pre-restart focus"
        journal_write "$journal"
        return 1
      }
      if launch_companion_preserving_focus "$focus_before" "no-mistakes companion restart launch"; then
        release_session_lock
        J_PHASE=live J_LAUNCH_STATE=submitted J_LAST_ERROR=
        journal_write "$journal"
      else
        release_session_lock
        J_PHASE=quarantined J_LAST_ERROR="restart launch response or focus preservation was ambiguous"
        journal_write "$journal"
        return 1
      fi
      ;;
    dead)
      release_session_lock
      J_PHASE=quarantined J_LAST_ERROR="bound pre-launch pane disappeared"
      journal_write "$journal"
      return 1
      ;;
    *)
      release_session_lock
      J_PHASE=quarantined J_LAST_ERROR="bound creating pane has ambiguous live state"
      journal_write "$journal"
      return 1
      ;;
  esac
}

reconcile_locked() {  # task lock held, journal already loaded
  local journal binding_rc attr_rc session_rc now state
  journal=$(journal_path "$J_TASK_ID")
  case "$J_PHASE" in
    quarantined) return 1 ;;
    prepared)
      now=$(date +%s)
      case "$J_CREATED_AT" in ''|*[!0-9]*) J_CREATED_AT=0 ;; esac
      if [ $((now - J_CREATED_AT)) -ge "$PREPARED_TTL" ]; then rm -f "$journal"; fi
      return 0
      ;;
    creating) recover_creating; return $? ;;
    thread-complete|cleanup-deferred) close_companion; return $? ;;
  esac

  current_binding_matches
  binding_rc=$?
  if [ "$binding_rc" -eq 2 ]; then
    if [ -n "$J_HERDR_PANE_ID" ]; then J_PHASE=thread-complete; J_TERMINAL_SEEN_AT=$(date +%s); journal_write "$journal"; close_companion
    else rm -f "$journal"
    fi
    return 0
  elif [ "$binding_rc" -ne 0 ]; then
    J_PHASE=quarantined J_LAST_ERROR="task binding changed or was reused"
    journal_write "$journal"
    return 1
  fi

  if [ -n "$J_RUN_ID" ]; then
    fm_nm_attributed_status "$J_WORKTREE_REAL" "$J_BRANCH" "$NM_TIMEOUT" "$J_RUN_ID"
    attr_rc=$?
  else
    fm_nm_attributed_status "$J_WORKTREE_REAL" "$J_BRANCH" "$NM_TIMEOUT"
    attr_rc=$?
  fi
  if [ "$attr_rc" -eq 2 ]; then
    if [ "$FM_NM_ATTRIBUTED_REASON" != query-failed ]; then
      J_PHASE=quarantined J_LAST_ERROR="no-mistakes returned a malformed attributed run"
      journal_write "$journal"
      return 1
    fi
    J_LAST_ERROR="no-mistakes status is temporarily unavailable"
    journal_write "$journal"
    return 1
  fi
  if [ "$attr_rc" -eq 1 ]; then
    if [ -n "$J_HERDR_PANE_ID" ]; then
      J_PHASE=thread-complete J_TERMINAL_SEEN_AT=$(date +%s) J_LAST_ERROR="attributed run no longer matches task code"
      journal_write "$journal"
      close_companion
    else
      J_PHASE=waiting-run J_LAST_ERROR=
      journal_write "$journal"
    fi
    return 0
  fi

  if run_is_terminal; then
    if [ -n "$J_HERDR_PANE_ID" ]; then
      J_PHASE=thread-complete J_TERMINAL_SEEN_AT=$(date +%s) J_LAST_ERROR=
      journal_write "$journal"
      close_companion
    elif [ "$FM_NM_ATTRIBUTED_ID" != "$J_BASELINE_RUN_ID" ]; then
      rm -f "$journal"
    else
      J_PHASE=waiting-run J_LAST_ERROR=
      journal_write "$journal"
    fi
    return 0
  fi

  if [ "$FM_NM_ATTRIBUTED_STATUS" = pending ]; then
    if [ -n "$J_HERDR_PANE_ID" ]; then
      J_PHASE=thread-complete J_TERMINAL_SEEN_AT=$(date +%s) J_LAST_ERROR="attributed run is no longer active"
      journal_write "$journal"
      close_companion
    else
      if [ -n "$J_RUN_ID" ] || [ "$FM_NM_ATTRIBUTED_ID" != "$J_BASELINE_RUN_ID" ]; then
        J_RUN_ID=$FM_NM_ATTRIBUTED_ID J_RUN_HEAD=$FM_NM_ATTRIBUTED_HEAD
      fi
      J_PHASE=waiting-run J_LAST_ERROR=
      journal_write "$journal"
    fi
    return 0
  fi

  exact_active_session
  session_rc=$?
  if [ "$session_rc" -eq 2 ]; then
    J_PHASE=quarantined J_LAST_ERROR="active_steps exposes malformed or multiple session_id values"
    journal_write "$journal"
    return 1
  elif [ "$session_rc" -eq 1 ]; then
    if [ -n "$J_HERDR_PANE_ID" ]; then
      J_PHASE=thread-complete J_TERMINAL_SEEN_AT=$(date +%s) J_LAST_ERROR=
      journal_write "$journal"
      close_companion
    else
      if [ -n "$J_RUN_ID" ] || [ "$FM_NM_ATTRIBUTED_ID" != "$J_BASELINE_RUN_ID" ]; then
        J_RUN_ID=$FM_NM_ATTRIBUTED_ID J_RUN_HEAD=$FM_NM_ATTRIBUTED_HEAD
      fi
      J_PHASE=waiting-run J_LAST_ERROR=
      journal_write "$journal"
    fi
    return 0
  fi

  if [ -z "$J_HERDR_PANE_ID" ]; then
    if [ "$FM_NM_ATTRIBUTED_ID" = "$J_BASELINE_RUN_ID" ] && [ "$ACTIVE_SESSION" = "$J_BASELINE_SESSION_ID" ]; then
      J_PHASE=waiting-run J_LAST_ERROR=
      journal_write "$journal"
      return 0
    fi
    J_RUN_ID=$FM_NM_ATTRIBUTED_ID J_RUN_HEAD=$FM_NM_ATTRIBUTED_HEAD J_SESSION_ID=$ACTIVE_SESSION
    J_SESSION_SEEN_AT=$(date +%s) J_PHASE=waiting-run J_LAST_ERROR=
    journal_write "$journal" || return 1
    create_companion
    return $?
  fi

  if [ "$FM_NM_ATTRIBUTED_ID" != "$J_RUN_ID" ] || [ "$ACTIVE_SESSION" != "$J_SESSION_ID" ]; then
    J_PENDING_RUN_ID=$FM_NM_ATTRIBUTED_ID J_PENDING_RUN_HEAD=$FM_NM_ATTRIBUTED_HEAD J_PENDING_SESSION_ID=$ACTIVE_SESSION
    J_PHASE=thread-complete J_TERMINAL_SEEN_AT=$(date +%s) J_LAST_ERROR=
    journal_write "$journal" || return 1
    close_companion
    return $?
  fi

  state=$(pane_live_state)
  case "$state" in
    codex)
      if ! recorded_companion_binding_matches; then
        J_PHASE=quarantined J_LAST_ERROR="live companion workspace/tab/pane binding is ambiguous"
        journal_write "$journal"
        return 1
      fi
      J_PHASE=live J_LAST_ERROR=
      journal_write "$journal"
      ;;
    dead) rm -f "$journal" ;;
    *) J_PHASE=quarantined J_LAST_ERROR="live companion pane state is ambiguous"; journal_write "$journal"; return 1 ;;
  esac
}

capture_after_delivery() {  # <task-id>
  local id=$1 deadline now phase rc
  case "$CAPTURE_TIMEOUT" in ''|*[!0-9]*) warn "FM_NM_LIVE_CAPTURE_TIMEOUT must be a non-negative integer"; return 1 ;; esac
  [[ $CAPTURE_POLL =~ ^[0-9]+([.][0-9]+)?$ ]] || { warn "FM_NM_LIVE_CAPTURE_POLL must be a non-negative number"; return 1; }
  now=$(date +%s)
  deadline=$((now + CAPTURE_TIMEOUT))
  while :; do
    reconcile "$id"
    rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    [ -f "$(journal_path "$id")" ] || return 0
    phase=$(journal_field "$(journal_path "$id")" phase 2>/dev/null) || return 1
    case "$phase" in delivery-confirmed|waiting-run) ;; *) return 0 ;; esac
    [ "$CAPTURE_TIMEOUT" -gt 0 ] || return 0
    now=$(date +%s)
    [ "$now" -le "$deadline" ] || return 0
    sleep "$CAPTURE_POLL"
  done
}

reconcile() {  # <task-id>
  local id=$1 lock journal rc
  valid_task_id "$id" || return 1
  lock=$(task_lock_path "$id")
  fm_lock_try_acquire "$lock" || return 0
  journal=$(journal_path "$id")
  if [ ! -e "$journal" ] && [ ! -L "$journal" ]; then fm_lock_release "$lock"; return 0; fi
  if ! journal_load "$journal" "$id"; then
    warn "$journal is malformed; leaving it quarantined in place"
    fm_lock_release "$lock"
    return 1
  fi
  fm_backend_source herdr || { fm_lock_release "$lock"; return 1; }
  reconcile_locked
  rc=$?
  fm_lock_release "$lock"
  return "$rc"
}

reconcile_all() {
  local journal id status=0
  mkdir -p "$STATE" || return 1
  for journal in "$STATE"/*.nm-live; do
    [ -e "$journal" ] || continue
    id=${journal##*/}; id=${id%.nm-live}
    reconcile "$id" || status=1
  done
  return "$status"
}

cleanup() {  # <task-id>
  local id=$1 lock journal rc
  valid_task_id "$id" || return 1
  lock=$(task_lock_path "$id")
  fm_lock_acquire_wait "$lock" || return 1
  journal=$(journal_path "$id")
  if [ ! -e "$journal" ] && [ ! -L "$journal" ]; then fm_lock_release "$lock"; return 0; fi
  if ! journal_load "$journal" "$id"; then
    warn "$journal is malformed; refusing cleanup without exact identity"
    fm_lock_release "$lock"
    return 1
  fi
  fm_backend_source herdr || { fm_lock_release "$lock"; return 1; }
  J_PENDING_RUN_ID= J_PENDING_RUN_HEAD= J_PENDING_SESSION_ID=
  J_PHASE=thread-complete J_TERMINAL_SEEN_AT=$(date +%s) J_LAST_ERROR=
  journal_write "$journal" || { fm_lock_release "$lock"; return 1; }
  close_companion
  rc=$?
  fm_lock_release "$lock"
  return "$rc"
}

render_command() {  # <endpoint> <session-id>
  case "$1" in unix:///*) ;; *) return 1 ;; esac
  case "$1" in *$'\n'*|*$'\r'*) return 1 ;; esac
  valid_uuid "$2" || return 1
  J_CODEX_ENDPOINT=$1 J_SESSION_ID=$2
  companion_command
}

classify_process_info() {  # <pane-id> <endpoint> <session-id>
  local info
  valid_atom "$1" || return 1
  case "$2" in unix:///*) ;; *) return 1 ;; esac
  case "$2" in *$'\n'*|*$'\r'*) return 1 ;; esac
  valid_uuid "$3" || return 1
  info=$(cat) || return 1
  companion_process_info_matches "$info" "$1" "$2" "$3"
}

command=${1:-}
case "$command" in
  render-command) [ "$#" -eq 3 ] || { usage >&2; exit 2; }; render_command "$2" "$3"; exit $? ;;
  classify-process-info) [ "$#" -eq 4 ] || { usage >&2; exit 2; }; classify_process_info "$2" "$3" "$4"; exit $? ;;
  -h|--help) usage; exit ;;
esac
mkdir -p "$STATE" || exit 1
case "$command" in
  prepare) [ "$#" -eq 3 ] || { usage >&2; exit 2; }; prepare "$2" "$3" ;;
  confirm) [ "$#" -eq 3 ] || { usage >&2; exit 2; }; confirm "$2" "$3" ;;
  cancel) [ "$#" -eq 3 ] || { usage >&2; exit 2; }; cancel "$2" "$3" ;;
  reconcile) [ "$#" -eq 2 ] || { usage >&2; exit 2; }; reconcile "$2" ;;
  reconcile-all) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; reconcile_all ;;
  cleanup) [ "$#" -eq 2 ] || { usage >&2; exit 2; }; cleanup "$2" ;;
  *) usage >&2; exit 2 ;;
esac

#!/usr/bin/env bash
# Recover one existing ordinary OMP ship or scout whose recorded Herdr endpoint
# is authoritatively missing or proven agent-free without allocating another
# worktree, changing task custody, or using fm-spawn.
#
# Usage:
#   fm-omp-ordinary-recover.sh --check <task-id>
#   fm-omp-ordinary-recover.sh <task-id>
#
# --check is read-only admission. It proves one ordinary direct child, exact
# Herdr/OMP identity, one retained direct-child tasktmp/omp-sessions JSONL file,
# an isolated recorded Git worktree, a task-bound external extension and inbox,
# and a recorded endpoint classified exactly missing or dead. Every ambiguous,
# unreadable, live, escaping, symlinked, or concurrently changed input refuses.
#
# The mutating form holds the existing task spawn and metadata lifecycle locks
# from admission through publication. It creates one unrecorded Herdr tab in the
# recorded workspace, resumes the exact retained OMP session with the existing
# task extension, and requires new session-start readiness plus a foreground
# process proof against recorded canonical OMP paths. Only then does it atomically
# replace window= and the four Herdr endpoint fields, retaining every other
# metadata line byte-for-byte. It rings the existing durable inbox only after
# that publication; it never redelivers instruction payloads itself.
#
# Before publication, failure removes only a response-derived replacement pane
# after proving that pane still belongs to this recovery. It restores historical
# readiness markers and leaves the original metadata, task worktree, session,
# extension, inbox, branch, and validation custody intact. An endpoint that
# cannot be proven safe to retire is named and preserved for inspection.
#
# This is the sole supported ordinary OMP/Herdr recovery entrypoint. Do not use
# fm-spawn for an existing task, manually launch a Herdr pane, or hand-edit task
# metadata: each can split task ownership or erase validation custody.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'
}

CHECK=0
case "${1:-}" in
  --check) CHECK=1; shift ;;
  -h|--help|help) usage; exit 0 ;;
esac
[ "$#" -eq 1 ] || { usage >&2; exit 2; }
ID=$1
case "$ID" in ''|*[!A-Za-z0-9._-]*) echo "REFUSED: invalid task id; preserving task state." >&2; exit 1 ;; esac

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"

refuse() {
  printf 'REFUSED: %s; preserving task state.\n' "$*" >&2
  return 1
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

file_digest() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

stdin_digest() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

physical_directory() { # <path>
  local path=$1
  [ -d "$path" ] && [ ! -L "$path" ] || return 1
  (cd "$path" 2>/dev/null && pwd -P)
}

physical_parent() { # <path>
  local path=$1
  (cd "$(dirname "$path")" 2>/dev/null && pwd -P)
}

git_common_directory() { # <git-worktree>
  local worktree=$1 common
  common=$(git -C "$worktree" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*) physical_directory "$common" ;;
    *) physical_directory "$worktree/$common" ;;
  esac
}

require_exact_meta() { # <key> <expected>
  local key=$1 expected=$2 value
  value=$(fm_backend_meta_exact_value "$META" "$key") || return 1
  [ "$value" = "$expected" ]
}

meta_count() { # <key>
  grep -c "^$1=" "$META" 2>/dev/null || true
}

metadata_syntax_valid() {
  [ -f "$META" ] && [ ! -L "$META" ] && [ -r "$META" ] || return 1
  [ -n "$(cat "$META" 2>/dev/null)" ] || return 1
  [ "$(tail -c 1 "$META" 2>/dev/null | od -An -tuC | tr -d '[:space:]')" = 10 ] || return 1
  LC_ALL=C grep -q $'\r' "$META" && return 1
  awk '/^[A-Za-z0-9_]+=/ { next } { exit 1 }' "$META"
}

validate_metadata() {
  metadata_syntax_valid || return 1
  require_exact_meta endpoint_task_id "$ID" || return 1
  require_exact_meta harness omp || return 1
  require_exact_meta backend herdr || return 1
  TASK_KIND=$(fm_backend_meta_exact_value "$META" kind) || return 1
  case "$TASK_KIND" in
    ship)
      MODE=$(fm_backend_meta_exact_value "$META" mode) || return 1
      case "$MODE" in no-mistakes|direct-PR|local-only) ;; *) return 1 ;; esac
      YOLO=$(fm_backend_meta_exact_value "$META" yolo) || return 1
      case "$YOLO" in on|off) ;; *) return 1 ;; esac
      ;;
    scout)
      [ "$(meta_count mode)" = 0 ] && [ "$(meta_count yolo)" = 0 ] || return 1
      ;;
    *) return 1 ;;
  esac
  [ "$(meta_count home)" = 0 ] && [ "$(meta_count projects)" = 0 ] || return 1
  PROJECT=$(fm_backend_meta_exact_value "$META" project) || return 1
  WORKTREE=$(fm_backend_meta_exact_value "$META" worktree) || return 1
  TASK_TMP=$(fm_backend_meta_exact_value "$META" tasktmp) || return 1
  OMP_BIN=$(fm_backend_meta_exact_value "$META" omp_bin) || return 1
  OMP_BUN=$(fm_backend_meta_exact_value "$META" omp_bun) || return 1
  fm_backend_validate_task_endpoint "$META" "$ID" || return 1
  [ "$FM_BACKEND_VALIDATED_BACKEND" = herdr ] || return 1
  OLD_TARGET=$FM_BACKEND_VALIDATED_TARGET
  HERDR_SESSION=$(fm_backend_meta_exact_value "$META" herdr_session) || return 1
  HERDR_WORKSPACE=$(fm_backend_meta_exact_value "$META" herdr_workspace_id) || return 1
  HERDR_TAB=$(fm_backend_meta_exact_value "$META" herdr_tab_id) || return 1
  HERDR_PANE=$(fm_backend_meta_exact_value "$META" herdr_pane_id) || return 1
  [ "$OLD_TARGET" = "$HERDR_SESSION:$HERDR_PANE" ] || return 1
  case "$TASK_TMP" in /*) ;; *) return 1 ;; esac
  fm_omp_process_identity_path_valid "$OMP_BIN" || return 1
  fm_omp_process_identity_path_valid "$OMP_BUN" || return 1
}

validate_worktree() {
  WORKTREE_REAL=$(physical_directory "$WORKTREE") || return 1
  PROJECT_REAL=$(physical_directory "$PROJECT") || return 1
  WORKTREE_TOP=$(git -C "$WORKTREE_REAL" rev-parse --show-toplevel 2>/dev/null) || return 1
  PROJECT_TOP=$(git -C "$PROJECT_REAL" rev-parse --show-toplevel 2>/dev/null) || return 1
  WORKTREE_TOP=$(physical_directory "$WORKTREE_TOP") || return 1
  PROJECT_TOP=$(physical_directory "$PROJECT_TOP") || return 1
  [ "$WORKTREE_TOP" = "$WORKTREE_REAL" ] && [ "$PROJECT_TOP" = "$PROJECT_REAL" ] || return 1
  [ "$WORKTREE_REAL" != "$PROJECT_REAL" ] || return 1
  WORKTREE_COMMON=$(git_common_directory "$WORKTREE_REAL") || return 1
  PROJECT_COMMON=$(git_common_directory "$PROJECT_REAL") || return 1
  [ "$WORKTREE_COMMON" = "$PROJECT_COMMON" ] || return 1
  WORKTREE_HEAD=$(git -C "$WORKTREE_REAL" rev-parse --verify HEAD 2>/dev/null) || return 1
  WORKTREE_STATUS=$(git -C "$WORKTREE_REAL" status --porcelain=v1 -z | stdin_digest) || return 1
}

validate_task_paths() {
  local session_support entry
  TASK_TMP_REAL=$(physical_directory "$TASK_TMP") || return 1
  GOTMP="$TASK_TMP_REAL/gotmp"
  GOTMP_REAL=$(physical_directory "$GOTMP") || return 1
  [ "$(physical_parent "$GOTMP_REAL")" = "$TASK_TMP_REAL" ] || return 1
  SESSION_DIR="$TASK_TMP_REAL/omp-sessions"
  SESSION_DIR_REAL=$(physical_directory "$SESSION_DIR") || return 1
  [ "$(physical_parent "$SESSION_DIR_REAL")" = "$TASK_TMP_REAL" ] || return 1
  shopt -s dotglob nullglob
  SESSION_ENTRIES=("$SESSION_DIR_REAL"/*)
  SESSION_FILES=("$SESSION_DIR_REAL"/*.jsonl)
  shopt -u dotglob nullglob
  [ "${#SESSION_FILES[@]}" = 1 ] || return 1
  SESSION_FILE=${SESSION_FILES[0]}
  [ -f "$SESSION_FILE" ] && [ ! -L "$SESSION_FILE" ] && [ -r "$SESSION_FILE" ] && [ -s "$SESSION_FILE" ] || return 1
  [ "$(physical_parent "$SESSION_FILE")" = "$SESSION_DIR_REAL" ] || return 1
  session_support=${SESSION_FILE%.jsonl}
  for entry in "${SESSION_ENTRIES[@]}"; do
    [ "$entry" = "$SESSION_FILE" ] && continue
    [ "$entry" = "$session_support" ] && [ -d "$entry" ] && [ ! -L "$entry" ] \
      && [ "$(physical_parent "$entry")" = "$SESSION_DIR_REAL" ] || return 1
  done
}

validate_extension_and_inbox() {
  EXTENSION="$STATE_REAL/$ID.omp-ext.ts"
  [ -f "$EXTENSION" ] && [ ! -L "$EXTENSION" ] && [ -r "$EXTENSION" ] || return 1
  grep -Fq "inboxDir: \"$STATE_REAL/$ID.inbox\"" "$EXTENSION" || return 1
  { grep -Fq "OMP_READY=\"$STATE_REAL/$ID.omp-ready\"" "$EXTENSION" \
    || grep -Fq "execFile(\"touch\", [\"$STATE_REAL/$ID.omp-ready\"])" "$EXTENSION"; } || return 1
  { grep -Fq "OMP_DOORBELL_READY=\"$STATE_REAL/$ID.omp-doorbell-ready\"" "$EXTENSION" \
    || grep -Fq "readyMarker: \"$STATE_REAL/$ID.omp-doorbell-ready\"" "$EXTENSION"; } || return 1
  grep -Fq 'omp.on("session_start"' "$EXTENSION" || return 1
  EXTENSION_DIGEST=$(file_digest "$EXTENSION") || return 1
  INBOX="$STATE_REAL/$ID.inbox"
  HANDLED="$INBOX/handled"
  physical_directory "$INBOX" >/dev/null && physical_directory "$HANDLED" >/dev/null || return 1
  READY_MARKER="$STATE_REAL/$ID.omp-ready"
  DOORBELL_MARKER="$STATE_REAL/$ID.omp-doorbell-ready"
  for marker in "$READY_MARKER" "$DOORBELL_MARKER"; do
    if [ -e "$marker" ] || [ -L "$marker" ]; then
      [ -f "$marker" ] && [ ! -L "$marker" ] && [ -r "$marker" ] || return 1
    fi
  done
  REQUEST_DIR="$DOORBELL_MARKER.requests"
  REQUEST_DIR_EXISTED=0
  if [ -e "$REQUEST_DIR" ] || [ -L "$REQUEST_DIR" ]; then
    REQUEST_DIR_EXISTED=1
    physical_directory "$REQUEST_DIR" >/dev/null || return 1
    shopt -s dotglob nullglob
    REQUEST_ENTRIES=("$REQUEST_DIR"/*)
    shopt -u dotglob nullglob
    for request in "${REQUEST_ENTRIES[@]}"; do
      [ -f "$request" ] && [ ! -L "$request" ] && [ -r "$request" ] || return 1
      case "${request##*/}" in
        *.pending|*.pending.processing.*) return 1 ;;
      esac
    done
  fi
}

validate_herdr_session() {
  local sessions
  sessions=$(fm_backend_herdr_cli "$HERDR_SESSION" session list --json 2>/dev/null) || return 1
  HERDR_SOCKET=$(printf '%s' "$sessions" | jq -r --arg name "$HERDR_SESSION" '
    [.sessions[]? | select(.name == $name and .running == true)
      | select((.socket_path | type) == "string" and (.socket_path | length) > 0)
      | .socket_path]
    | if length == 1 then .[0] else empty end
  ' 2>/dev/null) || return 1
  [ -n "$HERDR_SOCKET" ]
}

validate_omp_identity() {
  local identity runtime entry lookup resolved
  resolved=$("$SCRIPT_DIR/fm-omp-capabilities.sh" --binary "$OMP_BIN" --print-binary 2>/dev/null) || return 1
  resolved=$(fm_omp_process_resolve_path "$resolved") || return 1
  [ "$resolved" = "$OMP_BIN" ] || return 1
  identity=$(fm_omp_process_launch_identity "$OMP_BIN") || return 1
  runtime=$(printf '%s\n' "$identity" | sed -n '1p')
  entry=$(printf '%s\n' "$identity" | sed -n '2p')
  lookup=$(printf '%s\n' "$identity" | sed -n '3p')
  [ "$runtime" = "$OMP_BUN" ] && [ "$entry" = "$OMP_BIN" ] || return 1
  OMP_BUN_LOOKUP=$lookup
}
validate_old_endpoint() {
  local pane_state
  pane_state=$(fm_backend_herdr_pane_agent_state "$HERDR_SESSION" "$HERDR_PANE" 2>/dev/null || true)
  case "$pane_state" in
    dead) OLD_ENDPOINT_STATE=missing ;;
    no-agent) OLD_ENDPOINT_STATE=dead ;;
    *) return 1 ;;
  esac
}

capture_admission() {
  validate_metadata || return 1
  validate_worktree || return 1
  validate_task_paths || return 1
  validate_extension_and_inbox || return 1
  validate_herdr_session || return 1
  validate_omp_identity || return 1
  validate_old_endpoint || return 1
  META_DIGEST=$(file_digest "$META") || return 1
  INITIAL_SESSION_FILE=$SESSION_FILE
  INITIAL_OLD_TARGET=$OLD_TARGET
  INITIAL_OLD_STATE=$OLD_ENDPOINT_STATE
}

revalidate_before_publication() {
  validate_metadata || return 1
  [ "$OLD_TARGET" = "$INITIAL_OLD_TARGET" ] || return 1
  [ "$(file_digest "$META")" = "$META_DIGEST" ] || return 1
  validate_worktree || return 1
  [ "$WORKTREE_HEAD" = "$INITIAL_WORKTREE_HEAD" ] && [ "$WORKTREE_STATUS" = "$INITIAL_WORKTREE_STATUS" ] || return 1
  validate_task_paths || return 1
  [ "$SESSION_FILE" = "$INITIAL_SESSION_FILE" ] || return 1
  validate_extension_and_inbox || return 1
  [ "$EXTENSION_DIGEST" = "$INITIAL_EXTENSION_DIGEST" ] || return 1
  validate_old_endpoint || return 1
  [ "$OLD_ENDPOINT_STATE" = "$INITIAL_OLD_STATE" ] || return 1
}

prepare_fresh_markers() {
  local index=0 marker backup
  for marker in "$READY_MARKER" "$DOORBELL_MARKER"; do
    backup="$RECOVERY_TMP/marker-$index"
    if [ -e "$marker" ] || [ -L "$marker" ]; then
      [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
      mv -- "$marker" "$backup" || return 1
    fi
    index=$((index + 1))
  done
  MARKERS_PREPARED=1
}

restore_historical_markers() {
  local index=0 marker backup restore_status=0
  for marker in "$READY_MARKER" "$DOORBELL_MARKER"; do
    backup="$RECOVERY_TMP/marker-$index"
    if [ -e "$marker" ] || [ -L "$marker" ]; then
      if [ ! -f "$marker" ] || [ -L "$marker" ] || ! rm -f -- "$marker"; then
        printf 'error: recovery could not restore historical marker %s\n' "$marker" >&2
        restore_status=1
        index=$((index + 1))
        continue
      fi
    fi
    if [ -e "$backup" ]; then
      if ! mv -- "$backup" "$marker"; then
        printf 'error: recovery could not restore historical marker %s\n' "$marker" >&2
        restore_status=1
      fi
    fi
    index=$((index + 1))
  done
  if [ "$INITIAL_REQUEST_DIR_EXISTED" = 0 ] && [ -d "$REQUEST_DIR" ] && [ ! -L "$REQUEST_DIR" ]; then
    rmdir "$REQUEST_DIR" 2>/dev/null || {
      printf 'warning: recovery preserved newly-created doorbell request directory %s because it was not empty\n' "$REQUEST_DIR" >&2
      restore_status=1
    }
  fi
  return "$restore_status"
}

retire_new_endpoint() {
  [ -n "${NEW_TARGET:-}" ] || return 0
  fm_backend_herdr_recovery_endpoint_matches "$HERDR_SESSION" "$HERDR_WORKSPACE" "$NEW_TAB" "$NEW_PANE" "$RECOVERY_LABEL" \
    && fm_backend_herdr_explicit_close_pane_confirmed "$HERDR_SESSION" "$NEW_PANE" \
    && [ "$(fm_backend_herdr_pane_presence_state "$HERDR_SESSION" "$NEW_PANE")" = dead ]
}

restore_metadata_snapshot() {
  local staged
  [ "$META_REPLACED" -eq 1 ] || return 0
  staged=$(mktemp "$STATE_REAL/.${ID}.meta-restore.XXXXXX") || return 1
  if ! cp -- "$META_SNAPSHOT" "$staged" || ! mv -f -- "$staged" "$META"; then
    rm -f -- "$staged"
    return 1
  fi
  if ! cmp -s "$META" "$META_SNAPSHOT"; then
    return 1
  fi
  META_REPLACED=0
}

publish_replacement_metadata() {
  local staged
  revalidate_before_publication || return 1
  staged=$(mktemp "$STATE_REAL/.${ID}.meta-recovery.XXXXXX") || return 1
  if ! awk -v window="$NEW_TARGET" -v session="$HERDR_SESSION" -v workspace="$HERDR_WORKSPACE" \
    -v tab="$NEW_TAB" -v pane="$NEW_PANE" '
      /^window=/ { print "window=" window; next }
      /^herdr_session=/ { print "herdr_session=" session; next }
      /^herdr_workspace_id=/ { print "herdr_workspace_id=" workspace; next }
      /^herdr_tab_id=/ { print "herdr_tab_id=" tab; next }
      /^herdr_pane_id=/ { print "herdr_pane_id=" pane; next }
      { print }
    ' "$META_SNAPSHOT" > "$staged"; then
    rm -f -- "$staged"
    return 1
  fi
  if ! cmp -s "$META" "$META_SNAPSHOT" || ! mv -f -- "$staged" "$META"; then
    rm -f -- "$staged"
    return 1
  fi
  META_REPLACED=1
  fm_backend_validate_task_endpoint "$META" "$ID" \
    && [ "$FM_BACKEND_VALIDATED_BACKEND" = herdr ] \
    && [ "$FM_BACKEND_VALIDATED_TARGET" = "$NEW_TARGET" ]
}

launch_exact_session() {
  local launch path_guard='' bun_dir
  if [ -n "$OMP_BUN_LOOKUP" ]; then
    bun_dir=$(physical_directory "$(dirname "$OMP_BUN_LOOKUP")") || return 1
    case "$bun_dir" in *:*) return 1 ;; esac
    case "${PATH-}" in *::*|:*|*:) return 1 ;; esac
    path_guard="PATH=$(shell_quote "$bun_dir${PATH:+:$PATH}"); export PATH; FM_OMP_BUN_LOOKUP=\$(command -v bun) || exit 1; FM_OMP_BUN_RESOLVED=\$(readlink -f \"\$FM_OMP_BUN_LOOKUP\" 2>/dev/null || node -e 'const { realpathSync } = require(\"node:fs\"); process.stdout.write(realpathSync(process.argv[1]));' \"\$FM_OMP_BUN_LOOKUP\") || exit 1; [ \"\$FM_OMP_BUN_RESOLVED\" = $(shell_quote "$OMP_BUN") ] || exit 1; "
  fi
  launch="FM_OMP_TASK_INBOX_DIR=$(shell_quote "$INBOX") FM_OMP_TASK_DOORBELL_READY=$(shell_quote "$DOORBELL_MARKER") FM_OMP_BUN=$(shell_quote "$OMP_BUN") FM_OMP_BIN=$(shell_quote "$OMP_BIN") GOTMPDIR=$(shell_quote "$GOTMP_REAL") $(shell_quote "$OMP_BIN") --session-dir $(shell_quote "$SESSION_DIR_REAL") --resume $(shell_quote "$SESSION_FILE") --auto-approve -e $(shell_quote "$EXTENSION")"
  fm_backend_herdr_send_text_line "$NEW_TARGET" "/bin/bash -c $(shell_quote "$path_guard$launch")"
}

wait_for_fresh_recovery_proof() {
  local polls=${FM_OMP_ORDINARY_RECOVER_READY_POLLS:-120} interval=${FM_OMP_ORDINARY_RECOVER_READY_INTERVAL:-0.25} _
  case "$polls" in ''|*[!0-9]*|0) return 1 ;; esac
  for _ in $(seq 1 "$polls"); do
    if [ -f "$READY_MARKER" ] && [ ! -L "$READY_MARKER" ] \
      && [ -f "$DOORBELL_MARKER" ] && [ ! -L "$DOORBELL_MARKER" ] \
      && [ "$(fm_backend_herdr_agent_state "$NEW_TARGET" 2>/dev/null || true)" = alive ] \
      && fm_backend_herdr_omp_ready_process_matches "$NEW_TARGET" "$DOORBELL_MARKER" "$OMP_BUN" "$OMP_BIN"; then
      return 0
    fi
    sleep "$interval"
  done
  return 1
}

TASK_LOCK=
META_LOCK=
TASK_LOCK_HELD=0
META_LOCK_HELD=0
RECOVERY_TMP=
META_SNAPSHOT=
MARKERS_PREPARED=0
NEW_TARGET=
NEW_TAB=
NEW_PANE=
PUBLISHED=0
INITIAL_REQUEST_DIR_EXISTED=0
META_REPLACED=0

cleanup() {
  local status=$? metadata_restored=1
  trap - EXIT
  set +e
  if [ "$PUBLISHED" -ne 1 ]; then
    metadata_restored=1
    if ! restore_metadata_snapshot; then
      metadata_restored=0
      printf 'error: recovery could not restore original metadata after a failed replacement publication; preserving replacement endpoint %s\n' "$NEW_TARGET" >&2
    fi
    if [ "$metadata_restored" -eq 1 ] && [ -n "$NEW_TARGET" ]; then
      if retire_new_endpoint; then
        restore_historical_markers || true
      else
        printf 'error: recovery preserved unretired replacement endpoint %s because exact cleanup proof failed\n' "$NEW_TARGET" >&2
      fi
    elif [ "$metadata_restored" -eq 1 ] && [ "$MARKERS_PREPARED" -eq 1 ]; then
      restore_historical_markers || true
    fi
  fi
  if [ "$META_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$META_LOCK" || true
  fi
  if [ "$TASK_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$TASK_LOCK" || true
  fi
  [ -z "$RECOVERY_TMP" ] || rm -rf -- "$RECOVERY_TMP"
  exit "$status"
}
trap cleanup EXIT

STATE_REAL=$(physical_directory "$STATE") || { refuse "task state directory is unreadable or symlinked"; exit 1; }
META="$STATE_REAL/$ID.meta"
fm_backend_source herdr || { refuse "Herdr adapter could not load"; exit 1; }
fm_backend_herdr_version_check || { refuse "Herdr is not a verified runtime"; exit 1; }

if [ "$CHECK" -eq 1 ]; then
  capture_admission || { refuse "task $ID does not prove one safe ordinary OMP/Herdr continuation"; exit 1; }
  CHECK_META_DIGEST=$META_DIGEST
  CHECK_WORKTREE_HEAD=$WORKTREE_HEAD
  CHECK_WORKTREE_STATUS=$WORKTREE_STATUS
  CHECK_EXTENSION_DIGEST=$EXTENSION_DIGEST
  CHECK_SESSION_FILE=$SESSION_FILE
  CHECK_OLD_TARGET=$OLD_TARGET
  CHECK_OLD_STATE=$OLD_ENDPOINT_STATE
  CHECK_REQUEST_DIR_EXISTED=$REQUEST_DIR_EXISTED
  capture_admission || { refuse "task $ID changed while detect-only admission was running"; exit 1; }
  [ "$META_DIGEST" = "$CHECK_META_DIGEST" ] \
    && [ "$WORKTREE_HEAD" = "$CHECK_WORKTREE_HEAD" ] \
    && [ "$WORKTREE_STATUS" = "$CHECK_WORKTREE_STATUS" ] \
    && [ "$EXTENSION_DIGEST" = "$CHECK_EXTENSION_DIGEST" ] \
    && [ "$SESSION_FILE" = "$CHECK_SESSION_FILE" ] \
    && [ "$OLD_TARGET" = "$CHECK_OLD_TARGET" ] \
    && [ "$OLD_ENDPOINT_STATE" = "$CHECK_OLD_STATE" ] \
    && [ "$REQUEST_DIR_EXISTED" = "$CHECK_REQUEST_DIR_EXISTED" ] \
    || { refuse "task $ID changed while detect-only admission was running"; exit 1; }
  printf 'checked: %s endpoint=%s state=%s session=%s\n' "$ID" "$OLD_TARGET" "$OLD_ENDPOINT_STATE" "$SESSION_FILE"
  exit 0
fi

TASK_LOCK="$STATE_REAL/.spawn-$ID.lock"
META_LOCK=$(fm_meta_lock_path "$META") || { refuse "task $ID has no valid metadata lifecycle lock"; exit 1; }
if ! fm_lock_try_acquire "$TASK_LOCK"; then
  refuse "task $ID is already in a spawn or recovery transaction"
  exit 1
fi
TASK_LOCK_HELD=1
if ! fm_lock_try_acquire "$META_LOCK"; then
  refuse "task $ID metadata is being changed by another lifecycle operation"
  exit 1
fi
META_LOCK_HELD=1

RECOVERY_TMP=$(mktemp -d "$STATE_REAL/.${ID}.omp-recover.XXXXXX") || { refuse "could not stage recovery admission"; exit 1; }
chmod 0700 "$RECOVERY_TMP" || { refuse "could not protect recovery admission"; exit 1; }
capture_admission || { refuse "task $ID does not prove one safe ordinary OMP/Herdr continuation"; exit 1; }
INITIAL_WORKTREE_HEAD=$WORKTREE_HEAD
INITIAL_WORKTREE_STATUS=$WORKTREE_STATUS
INITIAL_EXTENSION_DIGEST=$EXTENSION_DIGEST
INITIAL_REQUEST_DIR_EXISTED=$REQUEST_DIR_EXISTED
META_SNAPSHOT="$RECOVERY_TMP/meta"
cp -- "$META" "$META_SNAPSHOT" || { refuse "could not snapshot task metadata"; exit 1; }
cmp -s "$META" "$META_SNAPSHOT" || { refuse "task metadata changed during recovery admission"; exit 1; }

RECOVERY_LABEL="fm-$ID"
set +e
created=$(fm_backend_herdr_create_recovery_task "$HERDR_SESSION" "$HERDR_WORKSPACE" "$RECOVERY_LABEL" \
  "$HERDR_TAB" "$HERDR_PANE" "$OLD_ENDPOINT_STATE" "$WORKTREE_REAL")
create_status=$?
set -e
if [ "$create_status" -ne 0 ]; then
  if [ "$create_status" -eq 2 ]; then
    printf 'error: recovery could not identify a newly-created endpoint in %s:%s for %s; it is preserved for inspection\n' \
      "$HERDR_SESSION" "$HERDR_WORKSPACE" "$RECOVERY_LABEL" >&2
  fi
  exit 1
fi
read -r NEW_TAB NEW_PANE <<EOF
$created
EOF
[ -n "$NEW_TAB" ] && [ -n "$NEW_PANE" ] || { printf 'error: recovery created an unnamed endpoint; preserving %s:%s for inspection\n' "$HERDR_SESSION" "$HERDR_WORKSPACE" >&2; exit 1; }
NEW_TARGET="$HERDR_SESSION:$NEW_PANE"

prepare_fresh_markers || { refuse "could not isolate historical OMP readiness markers"; exit 1; }
launch_exact_session || { printf 'error: recovery could not submit the exact retained OMP session to %s\n' "$NEW_TARGET" >&2; exit 1; }
wait_for_fresh_recovery_proof || { printf 'error: recovery did not obtain fresh OMP readiness and live-agent proof for %s\n' "$NEW_TARGET" >&2; exit 1; }
publish_replacement_metadata || { refuse "task inputs changed before endpoint publication"; exit 1; }
PUBLISHED=1
rm -f -- "$RECOVERY_TMP"/marker-0 "$RECOVERY_TMP"/marker-1
MARKERS_PREPARED=0

if record=$(fm_task_inbox_oldest_unhandled "$STATE_REAL" "$ID"); then
  if ! fm_task_inbox_ring herdr "$NEW_TARGET" "$record" "$RECOVERY_LABEL" omp "$OMP_BUN" "$OMP_BIN"; then
    printf 'warning: recovery published %s but could not ring its existing durable inbox; the retained instruction will be retried by ordinary supervision\n' "$NEW_TARGET" >&2
  fi
fi
printf 'recovered: %s endpoint=%s session=%s\n' "$ID" "$NEW_TARGET" "$SESSION_FILE"

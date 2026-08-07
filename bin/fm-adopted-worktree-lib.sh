#!/usr/bin/env bash
# Shared exact-identity mechanics for externally owned Git worktrees adopted by
# fm-spawn.sh and preserved by fm-teardown.sh.
#
# fm_adopted_worktree_snapshot <worktree-path> <project-root>
# validates one exact physical, registered, named-branch worktree belonging to
# the project's Git common directory and exports:
#   FM_ADOPTED_IDENTITY_WORKTREE=
#   FM_ADOPTED_IDENTITY_BRANCH=
#   FM_ADOPTED_IDENTITY_HEAD=
# On refusal it returns nonzero and sets FM_ADOPTED_IDENTITY_ERROR to one of:
# absolute, newline, tab, project-newline, project-tab, missing, resolve, nonphysical, project-root, project-primary, isolated,
# common-directory, inventory, registration, named-branch, or head.
# FM_ADOPTED_IDENTITY_DETAIL carries the resolved path, registration count, or
# other bounded detail needed for a caller-specific refusal.
#
# fm_adopted_worktree_identity_matches <worktree-path> <project-root>
#   <expected-path> <expected-branch> <expected-head-or-empty>
# reruns the complete snapshot and additionally requires the expected identity.
# An empty expected HEAD deliberately checks only the stable path/branch
# ownership identity used by teardown after a worker advances the branch.
#
# Cross-home durable ownership is stored under the project's canonical Git
# common directory. fm_adopted_claim_paths derives one collision-resistant
# record path per physical worktree plus its common-directory-scoped lock.
# Callers hold that lock from claim inspection/publication through their local
# metadata publication, and during teardown from exact endpoint retirement
# through local metadata plus claim retirement. Version 3 records also carry an
# endpoint_state=: `creating` fails closed across the tmux-create/publication
# gap and carries an atomically installed tmux window token, while `bound`
# records the exact server locator, window, server lifetime, and session that a
# retry must retire before creating another endpoint.
# Version 4 records bind the same cross-home ownership to Herdr; the separate
# token-bound endpoint journal below remains the exact Herdr transaction owner.
# Versions 1 and 2 are readable only for an exact metadata-backed upgrade. Every
# malformed, symbolic, missing, or mismatched record fails closed.
# Herdr adoption additionally keeps state/<id>.adopted-endpoint as a
# transaction journal.
# The task metadata remains unpublished until an exact Herdr agent is verified;
# this journal is the interruption-safe bridge between endpoint creation and
# that publication.

fm_adopted_file_sha256() {  # <regular-file>
  local file=$1 digest
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  if command -v shasum >/dev/null 2>&1; then
    digest=$(shasum -a 256 "$file" 2>/dev/null | awk '{print $1}') || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    digest=$(sha256sum "$file" 2>/dev/null | awk '{print $1}') || return 1
  else
    return 1
  fi
  [ "${#digest}" -eq 64 ] || return 1
  case "$digest" in *[!A-Fa-f0-9]*) return 1 ;; esac
  printf '%s\n' "$digest"
}

fm_adopted_worktree_snapshot() {  # <worktree-path> <project-root>
  local worktree=$1 project=$2 worktree_real project_real worktree_top project_top
  local worktree_common project_common project_git_dir inventory item listed listed_real registered=0

  FM_ADOPTED_IDENTITY_ERROR=
  FM_ADOPTED_IDENTITY_DETAIL=
  FM_ADOPTED_IDENTITY_WORKTREE=
  FM_ADOPTED_IDENTITY_BRANCH=
  FM_ADOPTED_IDENTITY_HEAD=

  case "$worktree" in
    /*) ;;
    *) FM_ADOPTED_IDENTITY_ERROR=absolute; FM_ADOPTED_IDENTITY_DETAIL=$worktree; return 1 ;;
  esac
  case "$worktree" in
    *$'\n'*|*$'\r'*) FM_ADOPTED_IDENTITY_ERROR=newline; return 1 ;;
    *$'\t'*) FM_ADOPTED_IDENTITY_ERROR=tab; return 1 ;;
  esac
  case "$project" in
    *$'\n'*|*$'\r'*) FM_ADOPTED_IDENTITY_ERROR='project-newline'; return 1 ;;
    *$'\t'*) FM_ADOPTED_IDENTITY_ERROR='project-tab'; return 1 ;;
  esac
  [ -d "$worktree" ] || { FM_ADOPTED_IDENTITY_ERROR=missing; FM_ADOPTED_IDENTITY_DETAIL=$worktree; return 1; }
  worktree_real=$(cd -- "$worktree" 2>/dev/null && pwd -P) || {
    FM_ADOPTED_IDENTITY_ERROR=resolve
    FM_ADOPTED_IDENTITY_DETAIL=$worktree
    return 1
  }
  [ "$worktree" = "$worktree_real" ] || {
    FM_ADOPTED_IDENTITY_ERROR=nonphysical
    FM_ADOPTED_IDENTITY_DETAIL=$worktree_real
    return 1
  }

  project_real=$(cd -- "$project" 2>/dev/null && pwd -P) || project_real=
  project_top=$(git -C "$project" rev-parse --show-toplevel 2>/dev/null || true)
  project_top=$(cd -- "$project_top" 2>/dev/null && pwd -P) || project_top=
  [ -n "$project_real" ] && [ "$project" = "$project_real" ] && [ "$project_real" = "$project_top" ] || {
    FM_ADOPTED_IDENTITY_ERROR='project-root'
    FM_ADOPTED_IDENTITY_DETAIL=$project_real
    return 1
  }

  project_common=$(git -C "$project" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  project_git_dir=$(git -C "$project" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)
  project_common=$(cd -- "$project_common" 2>/dev/null && pwd -P) || project_common=
  project_git_dir=$(cd -- "$project_git_dir" 2>/dev/null && pwd -P) || project_git_dir=
  [ -n "$project_common" ] && [ "$project_git_dir" = "$project_common" ] || {
    FM_ADOPTED_IDENTITY_ERROR='project-primary'
    FM_ADOPTED_IDENTITY_DETAIL=$project_git_dir
    return 1
  }

  worktree_top=$(git -C "$worktree" rev-parse --show-toplevel 2>/dev/null || true)
  worktree_top=$(cd -- "$worktree_top" 2>/dev/null && pwd -P) || worktree_top=
  [ "$worktree_real" = "$worktree_top" ] && [ "$worktree_real" != "$project_real" ] || {
    FM_ADOPTED_IDENTITY_ERROR=isolated
    FM_ADOPTED_IDENTITY_DETAIL=$worktree_top
    return 1
  }

  worktree_common=$(git -C "$worktree" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  worktree_common=$(cd -- "$worktree_common" 2>/dev/null && pwd -P) || worktree_common=
  [ -n "$project_common" ] && [ "$project_common" = "$worktree_common" ] || {
    FM_ADOPTED_IDENTITY_ERROR='common-directory'
    return 1
  }

  inventory=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-adopted-worktrees.XXXXXXXX") || {
    FM_ADOPTED_IDENTITY_ERROR=inventory
    return 1
  }
  if ! git -C "$project" worktree list --porcelain -z > "$inventory" 2>/dev/null; then
    rm -f -- "$inventory"
    FM_ADOPTED_IDENTITY_ERROR=inventory
    return 1
  fi
  while IFS= read -r -d '' item; do
    case "$item" in
      worktree\ *)
        listed=${item#worktree }
        listed_real=$(cd -- "$listed" 2>/dev/null && pwd -P) || listed_real=$listed
        [ "$listed_real" != "$worktree_real" ] || registered=$((registered + 1))
        ;;
    esac
  done < "$inventory"
  rm -f -- "$inventory"
  [ "$registered" -eq 1 ] || {
    FM_ADOPTED_IDENTITY_ERROR=registration
    FM_ADOPTED_IDENTITY_DETAIL=$registered
    return 1
  }

  FM_ADOPTED_IDENTITY_BRANCH=$(git -C "$worktree" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$FM_ADOPTED_IDENTITY_BRANCH" ] || { FM_ADOPTED_IDENTITY_ERROR=named-branch; return 1; }
  FM_ADOPTED_IDENTITY_HEAD=$(git -C "$worktree" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)
  [ -n "$FM_ADOPTED_IDENTITY_HEAD" ] || { FM_ADOPTED_IDENTITY_ERROR='head'; return 1; }
  FM_ADOPTED_IDENTITY_WORKTREE=$worktree_real
}

fm_adopted_claim_paths() {  # <canonical-primary-project> <physical-worktree>
  local project=$1 worktree=$2 common key
  FM_ADOPTED_CLAIM_DIR=
  # shellcheck disable=SC2034 # Sourced-library result consumed by callers.
  FM_ADOPTED_CLAIM_LOCK=
  # shellcheck disable=SC2034 # Sourced-library result consumed by callers.
  FM_ADOPTED_CLAIM_FILE=
  common=$(git -C "$project" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  common=$(cd -- "$common" 2>/dev/null && pwd -P) || common=
  [ -n "$common" ] || return 1
  key=$(printf '%s' "$worktree" | git -C "$project" hash-object --stdin 2>/dev/null) || return 1
  case "$key" in
    ''|*[!0-9a-fA-F]*) return 1 ;;
  esac
  FM_ADOPTED_CLAIM_DIR="$common/firstmate-adopted-worktree-claims-v1"
  # shellcheck disable=SC2034 # Sourced-library result consumed by callers.
  FM_ADOPTED_CLAIM_LOCK="$common/firstmate-adopted-worktree-claims-v1.lock"
  # shellcheck disable=SC2034 # Sourced-library result consumed by callers.
  FM_ADOPTED_CLAIM_FILE="$FM_ADOPTED_CLAIM_DIR/$key.claim"
}

fm_adopted_claim_registry_prepare() {  # uses FM_ADOPTED_CLAIM_DIR
  if [ -e "$FM_ADOPTED_CLAIM_DIR" ] || [ -L "$FM_ADOPTED_CLAIM_DIR" ]; then
    [ -d "$FM_ADOPTED_CLAIM_DIR" ] && [ ! -L "$FM_ADOPTED_CLAIM_DIR" ]
    return
  fi
  (umask 077; mkdir "$FM_ADOPTED_CLAIM_DIR")
}

fm_adopted_claim_read() {  # <claim-file>; returns 0 valid, 1 absent, 2 malformed
  local claim=$1 line_count version endpoint_state
  FM_ADOPTED_CLAIM_ERROR=
  FM_ADOPTED_CLAIM_TASK=
  FM_ADOPTED_CLAIM_HOME=
  FM_ADOPTED_CLAIM_WORKTREE=
  FM_ADOPTED_CLAIM_PROJECT=
  FM_ADOPTED_CLAIM_ENDPOINT_BACKEND=
  FM_ADOPTED_CLAIM_ENDPOINT_STATE=
  FM_ADOPTED_CLAIM_ENDPOINT_SERVER_LOCATOR=
  FM_ADOPTED_CLAIM_ENDPOINT_WINDOW_ID=
  FM_ADOPTED_CLAIM_ENDPOINT_SERVER_IDENTITY=
  FM_ADOPTED_CLAIM_ENDPOINT_SESSION=
  FM_ADOPTED_CLAIM_ENDPOINT_PROVISIONAL_TOKEN=
  if [ ! -e "$claim" ] && [ ! -L "$claim" ]; then
    FM_ADOPTED_CLAIM_ERROR=absent
    return 1
  fi
  if [ ! -f "$claim" ] || [ -L "$claim" ]; then
    FM_ADOPTED_CLAIM_ERROR=record
    return 2
  fi
  line_count=$(wc -l < "$claim" | tr -d '[:space:]')
  version=$(fm_backend_meta_exact_value "$claim" version 2>/dev/null || true)
  case "$version" in
    1) [ "$line_count" = 5 ] || { FM_ADOPTED_CLAIM_ERROR=shape; return 2; } ;;
    2|3) ;;
    4) [ "$line_count" = 7 ] || { FM_ADOPTED_CLAIM_ERROR=shape; return 2; } ;;
    *) FM_ADOPTED_CLAIM_ERROR=version; return 2 ;;
  esac
  FM_ADOPTED_CLAIM_TASK=$(fm_backend_meta_exact_value "$claim" task) \
    || { FM_ADOPTED_CLAIM_ERROR=task; return 2; }
  FM_ADOPTED_CLAIM_HOME=$(fm_backend_meta_exact_value "$claim" home) \
    || { FM_ADOPTED_CLAIM_ERROR=home; return 2; }
  FM_ADOPTED_CLAIM_WORKTREE=$(fm_backend_meta_exact_value "$claim" worktree) \
    || { FM_ADOPTED_CLAIM_ERROR=worktree; return 2; }
  FM_ADOPTED_CLAIM_PROJECT=$(fm_backend_meta_exact_value "$claim" project) \
    || { FM_ADOPTED_CLAIM_ERROR=project; return 2; }
  if [ "$version" = 1 ]; then
    FM_ADOPTED_CLAIM_ENDPOINT_BACKEND=tmux
    FM_ADOPTED_CLAIM_ENDPOINT_STATE=legacy
    return 0
  fi
  if [ "$version" = 4 ]; then
    FM_ADOPTED_CLAIM_ENDPOINT_BACKEND=$(fm_backend_meta_exact_value "$claim" endpoint_backend) \
      || { FM_ADOPTED_CLAIM_ERROR=endpoint-backend; return 2; }
    [ "$FM_ADOPTED_CLAIM_ENDPOINT_BACKEND" = herdr ] \
      || { FM_ADOPTED_CLAIM_ERROR=endpoint-backend; return 2; }
    endpoint_state=$(fm_backend_meta_exact_value "$claim" endpoint_state) \
      || { FM_ADOPTED_CLAIM_ERROR=endpoint-state; return 2; }
    [ "$endpoint_state" = journal ] \
      || { FM_ADOPTED_CLAIM_ERROR=endpoint-state; return 2; }
    FM_ADOPTED_CLAIM_ENDPOINT_STATE=$endpoint_state
    return 0
  fi
  FM_ADOPTED_CLAIM_ENDPOINT_BACKEND=tmux
  endpoint_state=$(fm_backend_meta_exact_value "$claim" endpoint_state) \
    || { FM_ADOPTED_CLAIM_ERROR=endpoint-state; return 2; }
  case "$endpoint_state" in
    creating)
      if [ "$version" = 3 ]; then
        [ "$line_count" = 9 ] || { FM_ADOPTED_CLAIM_ERROR=shape; return 2; }
        FM_ADOPTED_CLAIM_ENDPOINT_SERVER_LOCATOR=$(fm_backend_meta_exact_value "$claim" endpoint_server_locator) \
          || { FM_ADOPTED_CLAIM_ERROR=endpoint-locator; return 2; }
        FM_ADOPTED_CLAIM_ENDPOINT_SESSION=$(fm_backend_meta_exact_value "$claim" endpoint_session) \
          || { FM_ADOPTED_CLAIM_ERROR=endpoint-session; return 2; }
        FM_ADOPTED_CLAIM_ENDPOINT_PROVISIONAL_TOKEN=$(fm_backend_meta_exact_value "$claim" endpoint_provisional_token) \
          || { FM_ADOPTED_CLAIM_ERROR=endpoint-token; return 2; }
        fm_backend_tmux_server_locator_valid "$FM_ADOPTED_CLAIM_ENDPOINT_SERVER_LOCATOR" \
          || { FM_ADOPTED_CLAIM_ERROR=endpoint-locator; return 2; }
        case "$FM_ADOPTED_CLAIM_ENDPOINT_SESSION" in *$'\n'*|*$'\r'*|*$'\t'*) FM_ADOPTED_CLAIM_ERROR=endpoint-session; return 2 ;; esac
        case "$FM_ADOPTED_CLAIM_ENDPOINT_PROVISIONAL_TOKEN" in
          *[!0-9a-f]*|'') FM_ADOPTED_CLAIM_ERROR=endpoint-token; return 2 ;;
        esac
        [ "${#FM_ADOPTED_CLAIM_ENDPOINT_PROVISIONAL_TOKEN}" -eq 16 ] \
          || { FM_ADOPTED_CLAIM_ERROR=endpoint-token; return 2; }
      else
        [ "$line_count" = 6 ] || { FM_ADOPTED_CLAIM_ERROR=shape; return 2; }
        endpoint_state=legacy-creating
      fi
      ;;
    bound)
      if [ "$version" = 3 ]; then
        [ "$line_count" = 10 ] || { FM_ADOPTED_CLAIM_ERROR=shape; return 2; }
        FM_ADOPTED_CLAIM_ENDPOINT_SERVER_LOCATOR=$(fm_backend_meta_exact_value "$claim" endpoint_server_locator) \
          || { FM_ADOPTED_CLAIM_ERROR=endpoint-locator; return 2; }
        fm_backend_tmux_server_locator_valid "$FM_ADOPTED_CLAIM_ENDPOINT_SERVER_LOCATOR" \
          || { FM_ADOPTED_CLAIM_ERROR=endpoint-locator; return 2; }
      else
        [ "$line_count" = 9 ] || { FM_ADOPTED_CLAIM_ERROR=shape; return 2; }
        endpoint_state=legacy-bound
      fi
      FM_ADOPTED_CLAIM_ENDPOINT_WINDOW_ID=$(fm_backend_meta_exact_value "$claim" endpoint_window_id) \
        || { FM_ADOPTED_CLAIM_ERROR=endpoint-window; return 2; }
      FM_ADOPTED_CLAIM_ENDPOINT_SERVER_IDENTITY=$(fm_backend_meta_exact_value "$claim" endpoint_server_identity) \
        || { FM_ADOPTED_CLAIM_ERROR=endpoint-server; return 2; }
      FM_ADOPTED_CLAIM_ENDPOINT_SESSION=$(fm_backend_meta_exact_value "$claim" endpoint_session) \
        || { FM_ADOPTED_CLAIM_ERROR=endpoint-session; return 2; }
      fm_backend_tmux_window_id_valid "$FM_ADOPTED_CLAIM_ENDPOINT_WINDOW_ID" \
        || { FM_ADOPTED_CLAIM_ERROR=endpoint-window; return 2; }
      fm_backend_tmux_server_identity_valid "$FM_ADOPTED_CLAIM_ENDPOINT_SERVER_IDENTITY" \
        || { FM_ADOPTED_CLAIM_ERROR=endpoint-server; return 2; }
      case "$FM_ADOPTED_CLAIM_ENDPOINT_SESSION" in
        *$'\n'*|*$'\r'*|*$'\t'*) FM_ADOPTED_CLAIM_ERROR=endpoint-session; return 2 ;;
      esac
      ;;
    *) FM_ADOPTED_CLAIM_ERROR=endpoint-state; return 2 ;;
  esac
  FM_ADOPTED_CLAIM_ENDPOINT_STATE=$endpoint_state
}

fm_adopted_claim_matches() {  # <claim> <task> <home> <worktree> <project>
  local claim=$1 task=$2 home=$3 worktree=$4 project=$5 read_status
  if fm_adopted_claim_read "$claim"; then
    :
  else
    read_status=$?
    return "$read_status"
  fi
  if [ "$FM_ADOPTED_CLAIM_TASK" != "$task" ] \
     || [ "$FM_ADOPTED_CLAIM_HOME" != "$home" ] \
     || [ "$FM_ADOPTED_CLAIM_WORKTREE" != "$worktree" ] \
     || [ "$FM_ADOPTED_CLAIM_PROJECT" != "$project" ]; then
    # shellcheck disable=SC2034 # Sourced-library result consumed by callers.
    FM_ADOPTED_CLAIM_ERROR=ownership
    return 2
  fi
}

fm_adopted_claim_write() {  # <claim> <task> <home> <worktree> <project> <creating|bound> [locator window server session]
  local claim=$1 task=$2 home=$3 worktree=$4 project=$5 state=$6
  local locator=${7:-} window=${8:-} server=${9:-} session=${10:-} tmp claim_dir
  claim_dir=${claim%/*}
  case "$state" in
    creating)
      fm_backend_tmux_server_locator_valid "$locator" || return 1
      case "$window" in *[!0-9a-f]*|'') return 1 ;; esac
      [ "${#window}" -eq 16 ] || return 1
      case "$session" in ''|*$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
      ;;
    bound)
      fm_backend_tmux_server_locator_valid "$locator" || return 1
      fm_backend_tmux_window_id_valid "$window" || return 1
      fm_backend_tmux_server_identity_valid "$server" || return 1
      case "$session" in ''|*$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
      ;;
    *) return 1 ;;
  esac
  tmp=$(umask 077; mktemp "$claim_dir/.claim.XXXXXXXX") || return 1
  {
    printf '%s\n' 'version=3'
    printf 'task=%s\n' "$task"
    printf 'home=%s\n' "$home"
    printf 'worktree=%s\n' "$worktree"
    printf 'project=%s\n' "$project"
    printf 'endpoint_state=%s\n' "$state"
    if [ "$state" = creating ]; then
      printf 'endpoint_server_locator=%s\n' "$locator"
      printf 'endpoint_session=%s\n' "$session"
      printf 'endpoint_provisional_token=%s\n' "$window"
    else
      printf 'endpoint_server_locator=%s\n' "$locator"
      printf 'endpoint_window_id=%s\n' "$window"
      printf 'endpoint_server_identity=%s\n' "$server"
      printf 'endpoint_session=%s\n' "$session"
    fi
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  FM_ADOPTED_CLAIM_WRITE_TMP=$tmp
}

fm_adopted_claim_publish() {  # <claim> <task> <home> <worktree> <project> <locator> <session> <token>
  local claim=$1 locator=$6 session=$7 token=$8 tmp
  [ ! -e "$claim" ] && [ ! -L "$claim" ] || return 1
  fm_adopted_claim_write "$claim" "$2" "$3" "$4" "$5" creating \
    "$locator" "$token" '' "$session" || return 1
  tmp=$FM_ADOPTED_CLAIM_WRITE_TMP
  ln "$tmp" "$claim" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  rm -f -- "$tmp"
}

fm_adopted_claim_publish_herdr() {  # <claim> <task> <home> <worktree> <project>
  local claim=$1 task=$2 home=$3 worktree=$4 project=$5 tmp claim_dir
  [ ! -e "$claim" ] && [ ! -L "$claim" ] || return 1
  claim_dir=${claim%/*}
  tmp=$(umask 077; mktemp "$claim_dir/.claim.XXXXXXXX") || return 1
  {
    printf '%s\n' 'version=4'
    printf 'task=%s\n' "$task"
    printf 'home=%s\n' "$home"
    printf 'worktree=%s\n' "$worktree"
    printf 'project=%s\n' "$project"
    printf '%s\n' 'endpoint_backend=herdr'
    printf '%s\n' 'endpoint_state=journal'
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  ln "$tmp" "$claim" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  rm -f -- "$tmp"
}

fm_adopted_claim_mark_creating() {  # <claim> <task> <home> <worktree> <project> <locator> <session> <token>
  local claim=$1 locator=$6 session=$7 token=$8 tmp
  fm_adopted_claim_matches "$claim" "$2" "$3" "$4" "$5" || return 1
  fm_adopted_claim_write "$claim" "$2" "$3" "$4" "$5" creating \
    "$locator" "$token" '' "$session" || return 1
  tmp=$FM_ADOPTED_CLAIM_WRITE_TMP
  mv -f -- "$tmp" "$claim" || { rm -f -- "$tmp"; return 1; }
}

fm_adopted_claim_bind_endpoint() {  # <claim> <task> <home> <worktree> <project> <locator> <window> <server> <session>
  local claim=$1 task=$2 home=$3 worktree=$4 project=$5 locator=$6 window=$7 server=$8 session=$9 tmp
  fm_adopted_claim_matches "$claim" "$task" "$home" "$worktree" "$project" || return 1
  if [ "$FM_ADOPTED_CLAIM_ENDPOINT_STATE" = bound ]; then
    [ "$FM_ADOPTED_CLAIM_ENDPOINT_SERVER_LOCATOR" = "$locator" ] \
      && [ "$FM_ADOPTED_CLAIM_ENDPOINT_WINDOW_ID" = "$window" ] \
      && [ "$FM_ADOPTED_CLAIM_ENDPOINT_SERVER_IDENTITY" = "$server" ] \
      && [ "$FM_ADOPTED_CLAIM_ENDPOINT_SESSION" = "$session" ]
    return
  fi
  fm_adopted_claim_write "$claim" "$task" "$home" "$worktree" "$project" \
    bound "$locator" "$window" "$server" "$session" || return 1
  tmp=$FM_ADOPTED_CLAIM_WRITE_TMP
  mv -f -- "$tmp" "$claim" || { rm -f -- "$tmp"; return 1; }
}

fm_adopted_claim_remove_exact() {  # <claim> <task> <home> <worktree> <project>
  fm_adopted_claim_matches "$@" || return 1
  rm -f -- "$1"
}

fm_adopted_worktree_identity_matches() {  # <wt> <project> <path> <branch> <head-or-empty>
  local worktree=$1 project=$2 expected_path=$3 expected_branch=$4 expected_head=$5
  fm_adopted_worktree_snapshot "$worktree" "$project" || return 1
  if [ "$FM_ADOPTED_IDENTITY_WORKTREE" != "$expected_path" ] \
     || [ "$FM_ADOPTED_IDENTITY_BRANCH" != "$expected_branch" ] \
     || { [ -n "$expected_head" ] && [ "$FM_ADOPTED_IDENTITY_HEAD" != "$expected_head" ]; }; then
    # shellcheck disable=SC2034 # Sourced-library result consumed by callers.
    FM_ADOPTED_IDENTITY_ERROR='mismatch'
    # shellcheck disable=SC2034 # Sourced-library result consumed by callers.
    FM_ADOPTED_IDENTITY_DETAIL="path=$FM_ADOPTED_IDENTITY_WORKTREE branch=$FM_ADOPTED_IDENTITY_BRANCH head=$FM_ADOPTED_IDENTITY_HEAD"
    return 1
  fi
}

fm_adopted_endpoint_journal_load() {  # <journal>
  local journal=$1 line key value seen=$'\n' count=0
  FM_ADOPTED_ENDPOINT_VERSION=""
  FM_ADOPTED_ENDPOINT_BACKEND=""
  FM_ADOPTED_ENDPOINT_TASK_ID=""
  FM_ADOPTED_ENDPOINT_TOKEN=""
  FM_ADOPTED_ENDPOINT_PHASE=""
  FM_ADOPTED_ENDPOINT_HOME=""
  FM_ADOPTED_ENDPOINT_SESSION=""
  FM_ADOPTED_ENDPOINT_SOCKET=""
  FM_ADOPTED_ENDPOINT_PARENT_WORKSPACE_ID=""
  FM_ADOPTED_ENDPOINT_LAYOUT=""
  FM_ADOPTED_ENDPOINT_WORKSPACE_ID=""
  FM_ADOPTED_ENDPOINT_TAB_ID=""
  FM_ADOPTED_ENDPOINT_PANE_ID=""
  FM_ADOPTED_ENDPOINT_TASK_LABEL=""
  FM_ADOPTED_ENDPOINT_WORKTREE=""
  FM_ADOPTED_ENDPOINT_BRANCH=""
  FM_ADOPTED_ENDPOINT_HEAD=""
  FM_ADOPTED_ENDPOINT_BRIEF_SHA256=""
  FM_ADOPTED_ENDPOINT_AGENT=""
  [ -f "$journal" ] && [ ! -L "$journal" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    count=$((count + 1))
    case "$line" in
      *=*) key=${line%%=*}; value=${line#*=} ;;
      *) return 1 ;;
    esac
    case "$key$value" in *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
    case "$seen" in *$'\n'"$key"$'\n'*) return 1 ;; esac
    seen="$seen$key"$'\n'
    case "$key" in
      version) FM_ADOPTED_ENDPOINT_VERSION=$value ;;
      backend) FM_ADOPTED_ENDPOINT_BACKEND=$value ;;
      task_id) FM_ADOPTED_ENDPOINT_TASK_ID=$value ;;
      token) FM_ADOPTED_ENDPOINT_TOKEN=$value ;;
      phase) FM_ADOPTED_ENDPOINT_PHASE=$value ;;
      home) FM_ADOPTED_ENDPOINT_HOME=$value ;;
      session) FM_ADOPTED_ENDPOINT_SESSION=$value ;;
      socket) FM_ADOPTED_ENDPOINT_SOCKET=$value ;;
      parent_workspace_id) FM_ADOPTED_ENDPOINT_PARENT_WORKSPACE_ID=$value ;;
      layout) FM_ADOPTED_ENDPOINT_LAYOUT=$value ;;
      workspace_id) FM_ADOPTED_ENDPOINT_WORKSPACE_ID=$value ;;
      tab_id) FM_ADOPTED_ENDPOINT_TAB_ID=$value ;;
      pane_id) FM_ADOPTED_ENDPOINT_PANE_ID=$value ;;
      task_label) FM_ADOPTED_ENDPOINT_TASK_LABEL=$value ;;
      worktree) FM_ADOPTED_ENDPOINT_WORKTREE=$value ;;
      adopted_branch) FM_ADOPTED_ENDPOINT_BRANCH=$value ;;
      adopted_head) FM_ADOPTED_ENDPOINT_HEAD=$value ;;
      brief_sha256) FM_ADOPTED_ENDPOINT_BRIEF_SHA256=$value ;;
      agent) FM_ADOPTED_ENDPOINT_AGENT=$value ;;
      *) return 1 ;;
    esac
  done < "$journal"
  [ "$count" -eq 19 ] \
    && [ "$FM_ADOPTED_ENDPOINT_VERSION" = 2 ] \
    && [ "$FM_ADOPTED_ENDPOINT_BACKEND" = herdr ] \
    && [ -n "$FM_ADOPTED_ENDPOINT_TASK_ID" ] \
    && [ -n "$FM_ADOPTED_ENDPOINT_TOKEN" ] \
    && [ -n "$FM_ADOPTED_ENDPOINT_HOME" ] \
    && [ -n "$FM_ADOPTED_ENDPOINT_SESSION" ] \
    && [ -n "$FM_ADOPTED_ENDPOINT_SOCKET" ] \
    && [ -n "$FM_ADOPTED_ENDPOINT_PARENT_WORKSPACE_ID" ] \
    && [ -n "$FM_ADOPTED_ENDPOINT_TASK_LABEL" ] \
    && [ -n "$FM_ADOPTED_ENDPOINT_WORKTREE" ] \
    && [ -n "$FM_ADOPTED_ENDPOINT_BRANCH" ] \
    && [ -n "$FM_ADOPTED_ENDPOINT_HEAD" ] \
    && [ -n "$FM_ADOPTED_ENDPOINT_BRIEF_SHA256" ] || return 1
  case "$FM_ADOPTED_ENDPOINT_PHASE" in creating|endpoint|launching|agent) ;; *) return 1 ;; esac
  case "$FM_ADOPTED_ENDPOINT_LAYOUT" in flat|projected) ;; *) return 1 ;; esac
  [ "${#FM_ADOPTED_ENDPOINT_TOKEN}" -eq 22 ] || return 1
  case "$FM_ADOPTED_ENDPOINT_TOKEN" in *[!A-Za-z0-9_-]*) return 1 ;; esac
  case "$FM_ADOPTED_ENDPOINT_HOME" in /*) ;; *) return 1 ;; esac
  case "$FM_ADOPTED_ENDPOINT_SOCKET" in /*) ;; *) return 1 ;; esac
  [ "$FM_ADOPTED_ENDPOINT_TASK_LABEL" = "fm-$FM_ADOPTED_ENDPOINT_TASK_ID" ] || return 1
  for value in \
    "$FM_ADOPTED_ENDPOINT_TASK_ID" \
    "$FM_ADOPTED_ENDPOINT_SESSION" \
    "$FM_ADOPTED_ENDPOINT_PARENT_WORKSPACE_ID" \
    "$FM_ADOPTED_ENDPOINT_BRANCH" \
    "$FM_ADOPTED_ENDPOINT_WORKSPACE_ID" \
    "$FM_ADOPTED_ENDPOINT_TAB_ID" \
    "$FM_ADOPTED_ENDPOINT_PANE_ID" \
    "$FM_ADOPTED_ENDPOINT_AGENT"; do
    case "$value" in *[[:space:]]*) return 1 ;; esac
  done
  case "${#FM_ADOPTED_ENDPOINT_HEAD}" in 40|64) ;; *) return 1 ;; esac
  case "$FM_ADOPTED_ENDPOINT_HEAD" in *[!A-Fa-f0-9]*) return 1 ;; esac
  [ "${#FM_ADOPTED_ENDPOINT_BRIEF_SHA256}" -eq 64 ] || return 1
  case "$FM_ADOPTED_ENDPOINT_BRIEF_SHA256" in *[!A-Fa-f0-9]*) return 1 ;; esac
  case "$FM_ADOPTED_ENDPOINT_PHASE" in
    creating)
      [ -z "$FM_ADOPTED_ENDPOINT_TAB_ID$FM_ADOPTED_ENDPOINT_PANE_ID$FM_ADOPTED_ENDPOINT_AGENT" ] || return 1
      [ "$FM_ADOPTED_ENDPOINT_LAYOUT" != flat ] || [ -n "$FM_ADOPTED_ENDPOINT_WORKSPACE_ID" ] || return 1
      ;;
    endpoint|launching)
      [ -n "$FM_ADOPTED_ENDPOINT_WORKSPACE_ID" ] \
        && [ -n "$FM_ADOPTED_ENDPOINT_TAB_ID" ] \
        && [ -n "$FM_ADOPTED_ENDPOINT_PANE_ID" ] \
        && [ -z "$FM_ADOPTED_ENDPOINT_AGENT" ] || return 1
      ;;
    agent)
      [ -n "$FM_ADOPTED_ENDPOINT_WORKSPACE_ID" ] \
        && [ -n "$FM_ADOPTED_ENDPOINT_TAB_ID" ] \
        && [ -n "$FM_ADOPTED_ENDPOINT_PANE_ID" ] \
        && [ -n "$FM_ADOPTED_ENDPOINT_AGENT" ] || return 1
      case "$FM_ADOPTED_ENDPOINT_AGENT" in codex|pi|muse) ;; *) return 1 ;; esac
      ;;
  esac
}

fm_adopted_endpoint_journal_write_file() {  # <path> <task> <token> <phase> <home> <session> <socket> <parent> <layout> <workspace> <tab> <pane> <label> <worktree> <branch> <head> <brief-sha256> <agent>
  local path=$1 task=$2 token=$3 phase=$4 home=$5 session=$6 socket=$7 parent=$8
  local layout=$9 workspace=${10} tab=${11} pane=${12} label=${13} worktree=${14}
  local branch=${15} head=${16} brief_sha256=${17} agent=${18}
  {
    printf 'version=2\n'
    printf 'backend=herdr\n'
    printf 'task_id=%s\n' "$task"
    printf 'token=%s\n' "$token"
    printf 'phase=%s\n' "$phase"
    printf 'home=%s\n' "$home"
    printf 'session=%s\n' "$session"
    printf 'socket=%s\n' "$socket"
    printf 'parent_workspace_id=%s\n' "$parent"
    printf 'layout=%s\n' "$layout"
    printf 'workspace_id=%s\n' "$workspace"
    printf 'tab_id=%s\n' "$tab"
    printf 'pane_id=%s\n' "$pane"
    printf 'task_label=%s\n' "$label"
    printf 'worktree=%s\n' "$worktree"
    printf 'adopted_branch=%s\n' "$branch"
    printf 'adopted_head=%s\n' "$head"
    printf 'brief_sha256=%s\n' "$brief_sha256"
    printf 'agent=%s\n' "$agent"
  } > "$path"
  chmod 0600 "$path"
}

fm_adopted_endpoint_journal_create() {  # <journal> <task> <token> <home> <session> <socket> <parent> <layout> <workspace> <label> <worktree> <branch> <head> <brief-sha256>
  local journal=$1 task=$2 token=$3 home=$4 session=$5 socket=$6 parent=$7 layout=$8
  local workspace=$9 label=${10} worktree=${11} branch=${12} head=${13} brief_sha256=${14} tmp
  tmp=$(umask 077; mktemp "$(dirname "$journal")/.${task}.adopted-endpoint.XXXXXXXX") || return 1
  fm_adopted_endpoint_journal_write_file \
    "$tmp" "$task" "$token" creating "$home" "$session" "$socket" "$parent" \
    "$layout" "$workspace" "" "" "$label" "$worktree" \
    "$branch" "$head" "$brief_sha256" "" || {
      rm -f -- "$tmp"
      return 1
    }
  fm_adopted_endpoint_journal_load "$tmp" || {
    rm -f -- "$tmp"
    return 1
  }
  if ! ln "$tmp" "$journal" 2>/dev/null; then
    rm -f -- "$tmp"
    return 1
  fi
  rm -f -- "$tmp"
}

fm_adopted_endpoint_journal_advance() {  # <journal> <token> <phase> <workspace> <tab> <pane> <agent>
  local journal=$1 token=$2 phase=$3 workspace=$4 tab=$5 pane=$6 agent=$7 tmp current
  fm_adopted_endpoint_journal_load "$journal" || return 1
  [ "$FM_ADOPTED_ENDPOINT_TOKEN" = "$token" ] || return 1
  current=$FM_ADOPTED_ENDPOINT_PHASE
  case "$current:$phase" in
    creating:endpoint|endpoint:launching|launching:agent) ;;
    *) return 1 ;;
  esac
  tmp=$(umask 077; mktemp "$(dirname "$journal")/.${FM_ADOPTED_ENDPOINT_TASK_ID}.adopted-endpoint.XXXXXXXX") || return 1
  fm_adopted_endpoint_journal_write_file \
    "$tmp" "$FM_ADOPTED_ENDPOINT_TASK_ID" "$token" "$phase" \
    "$FM_ADOPTED_ENDPOINT_HOME" "$FM_ADOPTED_ENDPOINT_SESSION" \
    "$FM_ADOPTED_ENDPOINT_SOCKET" "$FM_ADOPTED_ENDPOINT_PARENT_WORKSPACE_ID" \
    "$FM_ADOPTED_ENDPOINT_LAYOUT" "$workspace" "$tab" "$pane" \
    "$FM_ADOPTED_ENDPOINT_TASK_LABEL" "$FM_ADOPTED_ENDPOINT_WORKTREE" \
    "$FM_ADOPTED_ENDPOINT_BRANCH" "$FM_ADOPTED_ENDPOINT_HEAD" \
    "$FM_ADOPTED_ENDPOINT_BRIEF_SHA256" "$agent" || {
      rm -f -- "$tmp"
      return 1
    }
  fm_adopted_endpoint_journal_load "$tmp" \
    && [ "$FM_ADOPTED_ENDPOINT_TOKEN" = "$token" ] \
    && [ "$FM_ADOPTED_ENDPOINT_PHASE" = "$phase" ] || {
      rm -f -- "$tmp"
      return 1
    }
  mv -f -- "$tmp" "$journal"
}

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
# through local metadata plus claim retirement. Claim records contain exactly
# version=, task=, home=, worktree=, and project=; every malformed, symbolic,
# missing, or mismatched record fails closed.

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
  local claim=$1 line_count
  FM_ADOPTED_CLAIM_ERROR=
  FM_ADOPTED_CLAIM_TASK=
  FM_ADOPTED_CLAIM_HOME=
  FM_ADOPTED_CLAIM_WORKTREE=
  FM_ADOPTED_CLAIM_PROJECT=
  if [ ! -e "$claim" ] && [ ! -L "$claim" ]; then
    FM_ADOPTED_CLAIM_ERROR=absent
    return 1
  fi
  if [ ! -f "$claim" ] || [ -L "$claim" ]; then
    FM_ADOPTED_CLAIM_ERROR=record
    return 2
  fi
  line_count=$(wc -l < "$claim" | tr -d '[:space:]')
  [ "$line_count" = 5 ] || { FM_ADOPTED_CLAIM_ERROR=shape; return 2; }
  [ "$(fm_backend_meta_exact_value "$claim" version 2>/dev/null || true)" = 1 ] \
    || { FM_ADOPTED_CLAIM_ERROR=version; return 2; }
  FM_ADOPTED_CLAIM_TASK=$(fm_backend_meta_exact_value "$claim" task) \
    || { FM_ADOPTED_CLAIM_ERROR=task; return 2; }
  FM_ADOPTED_CLAIM_HOME=$(fm_backend_meta_exact_value "$claim" home) \
    || { FM_ADOPTED_CLAIM_ERROR=home; return 2; }
  FM_ADOPTED_CLAIM_WORKTREE=$(fm_backend_meta_exact_value "$claim" worktree) \
    || { FM_ADOPTED_CLAIM_ERROR=worktree; return 2; }
  FM_ADOPTED_CLAIM_PROJECT=$(fm_backend_meta_exact_value "$claim" project) \
    || { FM_ADOPTED_CLAIM_ERROR=project; return 2; }
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

fm_adopted_claim_publish() {  # <claim> <task> <home> <worktree> <project>
  local claim=$1 task=$2 home=$3 worktree=$4 project=$5 tmp
  [ ! -e "$claim" ] && [ ! -L "$claim" ] || return 1
  tmp=$(umask 077; mktemp "$FM_ADOPTED_CLAIM_DIR/.claim.XXXXXXXX") || return 1
  {
    printf '%s\n' 'version=1'
    printf 'task=%s\n' "$task"
    printf 'home=%s\n' "$home"
    printf 'worktree=%s\n' "$worktree"
    printf 'project=%s\n' "$project"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  ln "$tmp" "$claim" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  rm -f -- "$tmp"
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

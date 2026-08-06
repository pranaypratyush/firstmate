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
# absolute, newline, missing, resolve, nonphysical, project-root, isolated,
# common-directory, inventory, registration, named-branch, or head.
# FM_ADOPTED_IDENTITY_DETAIL carries the resolved path, registration count, or
# other bounded detail needed for a caller-specific refusal.
#
# fm_adopted_worktree_identity_matches <worktree-path> <project-root>
#   <expected-path> <expected-branch> <expected-head-or-empty>
# reruns the complete snapshot and additionally requires the expected identity.
# An empty expected HEAD deliberately checks only the stable path/branch
# ownership identity used by teardown after a worker advances the branch.

fm_adopted_worktree_snapshot() {  # <worktree-path> <project-root>
  local worktree=$1 project=$2 worktree_real project_real worktree_top project_top
  local worktree_common project_common inventory item listed listed_real registered=0

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

  worktree_top=$(git -C "$worktree" rev-parse --show-toplevel 2>/dev/null || true)
  worktree_top=$(cd -- "$worktree_top" 2>/dev/null && pwd -P) || worktree_top=
  [ "$worktree_real" = "$worktree_top" ] && [ "$worktree_real" != "$project_real" ] || {
    FM_ADOPTED_IDENTITY_ERROR=isolated
    FM_ADOPTED_IDENTITY_DETAIL=$worktree_top
    return 1
  }

  project_common=$(git -C "$project" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  worktree_common=$(git -C "$worktree" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  project_common=$(cd -- "$project_common" 2>/dev/null && pwd -P) || project_common=
  worktree_common=$(cd -- "$worktree_common" 2>/dev/null && pwd -P) || worktree_common=
  [ -n "$project_common" ] && [ "$project_common" = "$worktree_common" ] || {
    FM_ADOPTED_IDENTITY_ERROR=common-directory
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

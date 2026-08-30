#!/usr/bin/env bash
# shellcheck disable=SC2034 # Public result globals are consumed by bin/fm-spawn.sh.
# Narrow ordinary-worker OMP recovery support for bin/fm-spawn.sh.
#
# Recovery is deliberately limited to a recorded ship/scout OMP worker whose
# exact tmux or Herdr endpoint is authoritatively missing. It preserves the
# leased worktree and durable OMP session, launches one replacement with
# --resume when an exact pointer exists, waits for turn_start, and only then
# atomically swaps endpoint metadata. Failed attempts clean only the exact
# replacement endpoint and recovery-owned sidecars.

fm_spawn_recovery_sha256() { # <file>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

fm_spawn_recovery_count() { # <meta> <key>
  grep -c "^$2=" "$1" 2>/dev/null || true
}

fm_spawn_recovery_exact() { # <meta> <key>
  local value
  value=$(fm_backend_meta_exact_value "$1" "$2") || return 1
  case "$value" in *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
  printf '%s\n' "$value"
}

fm_spawn_recovery_delivery_valid() { # <meta> <kind>
  local meta=$1 kind=$2 mode yolo
  case "$kind" in
    ship)
      mode=$(fm_spawn_recovery_exact "$meta" mode 2>/dev/null || true)
      yolo=$(fm_spawn_recovery_exact "$meta" yolo 2>/dev/null || true)
      case "$mode:$yolo" in
        no-mistakes:on|no-mistakes:off|direct-PR:on|direct-PR:off|local-only:on|local-only:off) return 0 ;;
      esac
      ;;
    scout)
      [ "$(fm_spawn_recovery_count "$meta" mode)" -eq 0 ] \
        && [ "$(fm_spawn_recovery_count "$meta" yolo)" -eq 0 ]
      return
      ;;
  esac
  return 1
}

fm_spawn_recovery_worktree_valid() { # <project> <worktree> <task-id>
  local project=$1 worktree=$2 id=$3 project_real worktree_real top inventory
  project_real=$(cd "$project" 2>/dev/null && pwd -P) || return 1
  worktree_real=$(cd "$worktree" 2>/dev/null && pwd -P) || return 1
  top=$(git -C "$worktree_real" rev-parse --show-toplevel 2>/dev/null || true)
  top=$(cd "$top" 2>/dev/null && pwd -P || true)
  [ -n "$top" ] && [ "$top" = "$worktree_real" ] && [ "$top" != "$project_real" ] || return 1
  inventory=$(cd "$project_real" && "$SCRIPT_DIR/fm-treehouse-command.sh" status --json 2>/dev/null) || return 1
  printf '%s\n' "$inventory" | jq -e --arg path "$worktree_real" --arg holder "fm-$id" '
    [ .[] | select(.path == $path) ] as $slots
    | ($slots | length) == 1
      and $slots[0].status == "leased"
      and $slots[0].lease_holder == $holder
      and (($slots[0].lease_id // "") | type == "string" and length > 0)
  ' >/dev/null 2>&1 || return 1
  FM_SPAWN_RECOVERY_PROJECT=$project_real
  FM_SPAWN_RECOVERY_WORKTREE=$worktree_real
}

fm_spawn_recovery_pointer_valid() { # <pointer> <session-dir> [required-session]
  local pointer=$1 session_dir=$2 required=${3:-} session parent
  [ -f "$pointer" ] && [ ! -L "$pointer" ] \
    && [ "$(wc -l < "$pointer" 2>/dev/null | tr -d '[:space:]')" = 1 ] \
    && [ "$(tail -c 1 "$pointer" 2>/dev/null | od -An -tuC | tr -d '[:space:]')" = 10 ] || return 1
  IFS= read -r session < "$pointer" || return 1
  case "$session" in "$session_dir"/*.jsonl) ;; *) return 1 ;; esac
  parent=$(cd "$(dirname "$session")" 2>/dev/null && pwd -P || true)
  [ "$parent" = "$session_dir" ] && [ -f "$session" ] && [ ! -L "$session" ] || return 1
  [ -z "$required" ] || [ "$session" = "$required" ] || return 1
  FM_SPAWN_RECOVERY_POINTER_SESSION=$session
}

fm_spawn_recovery_candidate_paths() { # <state> <task-id>
  FM_SPAWN_RECOVERY_INTENT="$1/$2.omp-replacement.intent"
  FM_SPAWN_RECOVERY_CANDIDATE="$1/$2.omp-replacement.meta"
  FM_SPAWN_RECOVERY_BASE="$1/$2.omp-replacement.base"
  FM_SPAWN_RECOVERY_NOTE="$1/$2.omp-replacement-brief"
  FM_SPAWN_RECOVERY_EXTENSION="$1/$2.omp-replacement-ext.ts"
  FM_SPAWN_RECOVERY_READY="$1/$2.omp-replacement-ready"
  FM_SPAWN_RECOVERY_STARTED="$1/$2.omp-replacement-started"
}

fm_spawn_recovery_preselect() { # <state> <data> <task-id>
  local state=$1 data=$2 id=$3 meta backend target kind harness project worktree tasktmp
  local model effort prewalk_count allow_count trace_count generation_count endpoint_state
  meta="$state/$id.meta"
  fm_spawn_recovery_candidate_paths "$state" "$id"
  [ -f "$meta" ] && [ ! -L "$meta" ] || {
    echo "error: OMP recovery requires regular recorded metadata for task $id; preserving task state" >&2
    return 1
  }
  fm_backend_validate_task_endpoint "$meta" "$id" || return 1
  backend=$FM_BACKEND_VALIDATED_BACKEND
  target=$FM_BACKEND_VALIDATED_TARGET
  case "$backend" in tmux|herdr) ;; *) echo "error: OMP recovery is verified only on tmux or Herdr; preserving task state" >&2; return 1 ;; esac
  harness=$(fm_spawn_recovery_exact "$meta" harness 2>/dev/null || true)
  [ "$harness" = omp ] || {
    echo "error: ordinary-worker recovery supports only recorded harness=omp tasks; preserving task state" >&2
    return 1
  }
  kind=$(fm_spawn_recovery_exact "$meta" kind 2>/dev/null || true)
  case "$kind" in ship|scout) ;; *) echo "error: OMP recovery refuses non-ordinary task kind=${kind:-unknown}; preserving task state" >&2; return 1 ;; esac
  fm_spawn_recovery_delivery_valid "$meta" "$kind" || {
    echo "error: OMP recovery found inconsistent recorded delivery identity for task $id; preserving task state" >&2
    return 1
  }
  project=$(fm_spawn_recovery_exact "$meta" project 2>/dev/null || true)
  worktree=$(fm_spawn_recovery_exact "$meta" worktree 2>/dev/null || true)
  fm_spawn_recovery_worktree_valid "$project" "$worktree" "$id" || {
    echo "error: OMP recovery could not prove task $id owns its exact leased isolated worktree; preserving task state" >&2
    return 1
  }
  tasktmp=$(fm_spawn_recovery_exact "$meta" tasktmp 2>/dev/null || true)
  [ "$tasktmp" = "/tmp/fm-$id" ] || {
    echo "error: OMP recovery found an unexpected task temp root for $id; preserving task state" >&2
    return 1
  }
  model=$(fm_spawn_recovery_exact "$meta" model 2>/dev/null || true)
  effort=$(fm_spawn_recovery_exact "$meta" effort 2>/dev/null || true)
  [ -n "$model" ] && [ -n "$effort" ] || {
    echo "error: OMP recovery found incomplete recorded launch identity for task $id; preserving task state" >&2
    return 1
  }
  [ -f "$data/$id/brief.md" ] && [ ! -L "$data/$id/brief.md" ] || {
    echo "error: OMP recovery requires the preserved regular brief for task $id; preserving task state" >&2
    return 1
  }
  FM_SPAWN_RECOVERY_OMP_BIN=$(fm_spawn_recovery_exact "$meta" omp_bin) || return 1
  FM_SPAWN_RECOVERY_OMP_BUN=$(fm_spawn_recovery_exact "$meta" omp_bun) || return 1
  prewalk_count=$(fm_spawn_recovery_count "$meta" prewalk_into)
  generation_count=$(fm_spawn_recovery_count "$meta" endpoint_generation)
  [ "$generation_count" -le 1 ] || return 1
  case "$prewalk_count" in 0) FM_SPAWN_RECOVERY_PREWALK_INTO= ;; 1) FM_SPAWN_RECOVERY_PREWALK_INTO=$(fm_spawn_recovery_exact "$meta" prewalk_into) || return 1 ;; *) return 1 ;; esac
  allow_count=$(fm_spawn_recovery_count "$meta" allow_project_omp_extensions)
  case "$allow_count" in 0) FM_SPAWN_RECOVERY_ALLOW_EXTENSIONS=0 ;; 1) [ "$(fm_spawn_recovery_exact "$meta" allow_project_omp_extensions)" = 1 ] || return 1; FM_SPAWN_RECOVERY_ALLOW_EXTENSIONS=1 ;; *) return 1 ;; esac
  FM_SPAWN_RECOVERY_TRACEPARENT=
  trace_count=$(fm_spawn_recovery_count "$meta" traceparent)
  case "$trace_count" in
    0) ;;
    1) FM_SPAWN_RECOVERY_TRACEPARENT=$(fm_spawn_recovery_exact "$meta" traceparent) || return 1; fm_trace_context_valid "$FM_SPAWN_RECOVERY_TRACEPARENT" || return 1 ;;
    *) return 1 ;;
  esac

  FM_SPAWN_RECOVERY_PENDING=0
  if [ -e "$FM_SPAWN_RECOVERY_INTENT" ] || [ -L "$FM_SPAWN_RECOVERY_INTENT" ] \
     || [ -e "$FM_SPAWN_RECOVERY_CANDIDATE" ] || [ -L "$FM_SPAWN_RECOVERY_CANDIDATE" ] \
     || [ -e "$FM_SPAWN_RECOVERY_BASE" ] || [ -L "$FM_SPAWN_RECOVERY_BASE" ]; then
    FM_SPAWN_RECOVERY_PENDING=1
  else
    endpoint_state=$(fm_backend_agent_state "$backend" "$target" "$meta" 2>/dev/null || printf 'unreadable')
    if [ "$endpoint_state" != missing ]; then
      if [ "$backend" = herdr ] && [ "$endpoint_state" = unreadable ]; then
        echo "error: OMP recovery requires the recorded Herdr server and endpoint inventory to remain readable; server-gone recovery is not supported" >&2
      else
        echo "error: OMP recovery requires an authoritatively missing endpoint for task $id (observed $endpoint_state); preserving task state" >&2
      fi
      return 1
    fi
  fi

  FM_SPAWN_RECOVERY_META=$meta
  FM_SPAWN_RECOVERY_BACKEND=$backend
  FM_SPAWN_RECOVERY_OLD_TARGET=$target
  FM_SPAWN_RECOVERY_KIND=$kind
  FM_SPAWN_RECOVERY_TASKTMP=$tasktmp
  FM_SPAWN_RECOVERY_MODEL=$model
  FM_SPAWN_RECOVERY_EFFORT=$effort
  FM_SPAWN_RECOVERY_MODE=
  FM_SPAWN_RECOVERY_YOLO=
  if [ "$kind" = ship ]; then
    FM_SPAWN_RECOVERY_MODE=$(fm_spawn_recovery_exact "$meta" mode)
    FM_SPAWN_RECOVERY_YOLO=$(fm_spawn_recovery_exact "$meta" yolo)
  fi
  FM_SPAWN_RECOVERY_HERDR_SESSION=
  FM_SPAWN_RECOVERY_HERDR_WORKSPACE=
  FM_SPAWN_RECOVERY_TMUX_SESSION=
  if [ "$backend" = tmux ]; then
    if [ "${target#@}" != "$target" ]; then
      FM_SPAWN_RECOVERY_TMUX_SESSION=$(fm_spawn_recovery_exact "$meta" tmux_session) || return 1
    else
      FM_SPAWN_RECOVERY_TMUX_SESSION=${target%%:*}
    fi
  fi
  if [ "$backend" = herdr ]; then
    FM_SPAWN_RECOVERY_HERDR_SESSION=$(fm_spawn_recovery_exact "$meta" herdr_session) || return 1
    FM_SPAWN_RECOVERY_HERDR_WORKSPACE=$(fm_spawn_recovery_exact "$meta" herdr_workspace_id) || return 1
  fi
}

fm_spawn_recovery_prepare_session() { # <state> <task-id>
  local state=$1 id=$2 session_dir pointer legacy_dir
  state=$(cd "$state" && pwd -P) || return 1
  session_dir="$state/$id.omp-sessions"
  pointer="$state/$id.omp-session"
  legacy_dir="$FM_SPAWN_RECOVERY_TASKTMP/omp-sessions"
  if [ -e "$legacy_dir" ] || [ -L "$legacy_dir" ]; then
    echo "error: legacy OMP session binding under $legacy_dir is not accepted by recovery and is marked for removal" >&2
    return 1
  fi
  [ -d "$session_dir" ] && [ ! -L "$session_dir" ] || return 1
  [ -f "$pointer" ] && [ ! -L "$pointer" ] || return 1
  session_dir=$(cd "$session_dir" && pwd -P) || return 1
  [ "$(dirname "$session_dir")" = "$state" ] || return 1
  fm_spawn_recovery_pointer_valid "$pointer" "$session_dir" || return 1
  FM_SPAWN_RECOVERY_RESUME_FILE=$FM_SPAWN_RECOVERY_POINTER_SESSION
  mkdir -p "$FM_SPAWN_RECOVERY_TASKTMP/gotmp" || return 1
  FM_SPAWN_RECOVERY_SESSION_DIR=$session_dir
  FM_SPAWN_RECOVERY_SESSION_POINTER=$pointer
}

fm_spawn_recovery_prepare_artifacts() { # <brief>
  local brief=$1 path
  for path in "$FM_SPAWN_RECOVERY_NOTE" "$FM_SPAWN_RECOVERY_EXTENSION" "$FM_SPAWN_RECOVERY_READY" "$FM_SPAWN_RECOVERY_STARTED"; do
    [ ! -L "$path" ] || return 1
  done
  rm -f -- "$FM_SPAWN_RECOVERY_READY" "$FM_SPAWN_RECOVERY_STARTED"
  cat -- "$brief" > "$FM_SPAWN_RECOVERY_NOTE" || return 1
  printf '\n\nRecovery continuation: Firstmate replaced a proven-missing OMP endpoint in the preserved isolated copy. Re-read the brief, inspect the current branch and uncommitted work, and continue without resetting or discarding work.\n' >> "$FM_SPAWN_RECOVERY_NOTE"
}

fm_spawn_recovery_begin_attempt() { # <state> <task-id> <backend>
  local state=$1 id=$2 backend=$3 intent_tmp base_sha
  [ ! -e "$FM_SPAWN_RECOVERY_INTENT" ] && [ ! -L "$FM_SPAWN_RECOVERY_INTENT" ] || return 1
  base_sha=$(fm_spawn_recovery_sha256 "$FM_SPAWN_RECOVERY_META") || return 1
  intent_tmp=$(mktemp "$state/.${id}.omp-replacement-intent.XXXXXX") || return 1
  {
    printf 'base_sha256=%s\n' "$base_sha"
    printf 'backend=%s\n' "$backend"
  } > "$intent_tmp" || { rm -f -- "$intent_tmp"; return 1; }
  mv -f -- "$intent_tmp" "$FM_SPAWN_RECOVERY_INTENT" || { rm -f -- "$intent_tmp"; return 1; }
}

fm_spawn_recovery_stage_candidate() { # <state> <task-id> <backend> <target> [session workspace tab pane]
  local state=$1 id=$2 backend=$3 target=$4 session=${5:-} workspace=${6:-} tab=${7:-} pane=${8:-}
  local base_tmp candidate_tmp base_sha generation
  generation="$id-$(date +%s)-$$-${RANDOM:-0}"
  base_sha=$(fm_spawn_recovery_sha256 "$FM_SPAWN_RECOVERY_META") || return 1
  base_tmp=$(mktemp "$state/.${id}.omp-replacement-base.XXXXXX") || return 1
  printf '%s\n' "$base_sha" > "$base_tmp" || { rm -f -- "$base_tmp"; return 1; }
  mv -f -- "$base_tmp" "$FM_SPAWN_RECOVERY_BASE" || { rm -f -- "$base_tmp"; return 1; }
  candidate_tmp=$(mktemp "$state/.${id}.omp-replacement-meta.XXXXXX") || return 1
  if ! awk -v target="$target" -v id="$id" -v generation="$generation" -v backend="$backend" -v session="$session" -v workspace="$workspace" -v tab="$tab" -v pane="$pane" '
    /^window=/ { print "window=" target; next }
    /^endpoint_task_id=/ { print "endpoint_task_id=" id; next }
    /^endpoint_generation=/ { if (!generation_seen++) print "endpoint_generation=" generation; next }
    /^backend=/ { if (backend != "tmux") print "backend=" backend; next }
    /^tmux_session=/ { if (backend == "tmux") { print "tmux_session=" session; tmux_session_seen=1 }; next }
    /^herdr_session=/ { if (backend == "herdr") print "herdr_session=" session; next }
    /^herdr_workspace_id=/ { if (backend == "herdr") print "herdr_workspace_id=" workspace; next }
    /^herdr_tab_id=/ { if (backend == "herdr") print "herdr_tab_id=" tab; next }
    /^herdr_pane_id=/ { if (backend == "herdr") print "herdr_pane_id=" pane; next }
    { print }
    END {
      if (!generation_seen) print "endpoint_generation=" generation
      if (backend == "tmux" && !tmux_session_seen) print "tmux_session=" session
    }
  ' "$FM_SPAWN_RECOVERY_META" > "$candidate_tmp"; then
    rm -f -- "$candidate_tmp"
    return 1
  fi
  fm_backend_validate_task_endpoint "$candidate_tmp" "$id" || { rm -f -- "$candidate_tmp"; return 1; }
  [ "$FM_BACKEND_VALIDATED_BACKEND" = "$backend" ] && [ "$FM_BACKEND_VALIDATED_TARGET" = "$target" ] || { rm -f -- "$candidate_tmp"; return 1; }
  mv -f -- "$candidate_tmp" "$FM_SPAWN_RECOVERY_CANDIDATE" || { rm -f -- "$candidate_tmp"; return 1; }
  rm -f -- "$FM_SPAWN_RECOVERY_INTENT" || return 1
  FM_SPAWN_RECOVERY_NEW_TARGET=$target
}

fm_spawn_recovery_acknowledged() {
  [ -f "$FM_SPAWN_RECOVERY_STARTED" ] && [ ! -L "$FM_SPAWN_RECOVERY_STARTED" ] || return 1
  fm_spawn_recovery_pointer_valid "$FM_SPAWN_RECOVERY_SESSION_POINTER" "$FM_SPAWN_RECOVERY_SESSION_DIR" "$FM_SPAWN_RECOVERY_RESUME_FILE"
}

fm_spawn_recovery_publish() { # <state> <task-id>
  local state=$1 id=$2 expected current publish_tmp
  [ -f "$FM_SPAWN_RECOVERY_CANDIDATE" ] && [ ! -L "$FM_SPAWN_RECOVERY_CANDIDATE" ] \
    && [ -f "$FM_SPAWN_RECOVERY_BASE" ] && [ ! -L "$FM_SPAWN_RECOVERY_BASE" ] || return 1
  IFS= read -r expected < "$FM_SPAWN_RECOVERY_BASE" || return 1
  current=$(fm_spawn_recovery_sha256 "$FM_SPAWN_RECOVERY_META") || return 1
  [ "$current" = "$expected" ] || {
    echo "error: OMP recovery metadata changed after replacement staging; preserving both records" >&2
    return 1
  }
  fm_spawn_recovery_acknowledged || {
    echo "error: OMP recovery lost its exact session or turn_start acknowledgement before publication" >&2
    return 1
  }
  fm_backend_validate_task_endpoint "$FM_SPAWN_RECOVERY_CANDIDATE" "$id" || return 1
  publish_tmp=$(mktemp "$state/.${id}.omp-publish.XXXXXX") || return 1
  cat -- "$FM_SPAWN_RECOVERY_CANDIDATE" > "$publish_tmp" || { rm -f -- "$publish_tmp"; return 1; }
  mv -f -- "$publish_tmp" "$FM_SPAWN_RECOVERY_META" || { rm -f -- "$publish_tmp"; return 1; }
}

fm_spawn_recovery_remove_sidecars() {
  rm -f -- "$FM_SPAWN_RECOVERY_INTENT" "$FM_SPAWN_RECOVERY_CANDIDATE" "$FM_SPAWN_RECOVERY_BASE" \
    "$FM_SPAWN_RECOVERY_NOTE" "$FM_SPAWN_RECOVERY_EXTENSION" \
    "$FM_SPAWN_RECOVERY_READY" "$FM_SPAWN_RECOVERY_STARTED"
}

fm_spawn_recovery_candidate_state() { # <backend> <target> <candidate-meta>
  local backend=$1 target=$2 meta=$3 omp_bin omp_bun tmux_session
  case "$backend" in
    tmux)
      omp_bin=$(fm_spawn_recovery_exact "$meta" omp_bin) || return 1
      omp_bun=$(fm_spawn_recovery_exact "$meta" omp_bun) || return 1
      tmux_session=
      if [ "${target#@}" != "$target" ]; then
        tmux_session=$(fm_spawn_recovery_exact "$meta" tmux_session) || return 1
      fi
      fm_backend_source tmux || return 1
      fm_backend_tmux_agent_state "$target" "$omp_bun" "$omp_bin" "" "$tmux_session"
      ;;
    herdr)
      fm_backend_agent_state herdr "$target" "$meta"
      ;;
    *) printf 'unverified' ;;
  esac
}

fm_spawn_recovery_reconcile_pending() { # <state> <task-id>
  local state=$1 id=$2 current expected candidate_state candidate_target candidate_backend
  FM_SPAWN_RECOVERY_RECONCILED=retry
  if { [ -e "$FM_SPAWN_RECOVERY_INTENT" ] || [ -L "$FM_SPAWN_RECOVERY_INTENT" ]; } \
     && [ ! -e "$FM_SPAWN_RECOVERY_CANDIDATE" ] && [ ! -L "$FM_SPAWN_RECOVERY_CANDIDATE" ]; then
    [ -f "$FM_SPAWN_RECOVERY_INTENT" ] && [ ! -L "$FM_SPAWN_RECOVERY_INTENT" ] || return 1
    echo "error: interrupted OMP recovery has a pre-create intent without a response-derived replacement endpoint; preserving task state" >&2
    return 1
  fi
  if [ ! -e "$FM_SPAWN_RECOVERY_CANDIDATE" ] && [ -f "$FM_SPAWN_RECOVERY_BASE" ] && [ ! -L "$FM_SPAWN_RECOVERY_BASE" ]; then
    IFS= read -r expected < "$FM_SPAWN_RECOVERY_BASE" || return 1
    current=$(fm_spawn_recovery_sha256 "$FM_SPAWN_RECOVERY_META") || return 1
    [ "$current" = "$expected" ] || return 1
    fm_spawn_recovery_remove_sidecars
    return 0
  fi
  [ -f "$FM_SPAWN_RECOVERY_CANDIDATE" ] && [ ! -L "$FM_SPAWN_RECOVERY_CANDIDATE" ] \
    && [ -f "$FM_SPAWN_RECOVERY_BASE" ] && [ ! -L "$FM_SPAWN_RECOVERY_BASE" ] || return 1
  fm_backend_validate_task_endpoint "$FM_SPAWN_RECOVERY_CANDIDATE" "$id" || return 1
  candidate_backend=$FM_BACKEND_VALIDATED_BACKEND
  candidate_target=$FM_BACKEND_VALIDATED_TARGET
  if cmp -s "$FM_SPAWN_RECOVERY_META" "$FM_SPAWN_RECOVERY_CANDIDATE"; then
    candidate_state=$(fm_spawn_recovery_candidate_state "$candidate_backend" "$candidate_target" "$FM_SPAWN_RECOVERY_CANDIDATE" 2>/dev/null || printf 'unreadable')
    [ "$candidate_state" = alive ] && fm_spawn_recovery_acknowledged || return 1
    fm_spawn_recovery_remove_sidecars
    FM_SPAWN_RECOVERY_RECONCILED=complete
    return 0
  fi
  IFS= read -r expected < "$FM_SPAWN_RECOVERY_BASE" || return 1
  current=$(fm_spawn_recovery_sha256 "$FM_SPAWN_RECOVERY_META") || return 1
  [ "$current" = "$expected" ] || {
    echo "error: interrupted OMP recovery no longer matches its staged metadata base" >&2
    return 1
  }
  candidate_state=$(fm_spawn_recovery_candidate_state "$candidate_backend" "$candidate_target" "$FM_SPAWN_RECOVERY_CANDIDATE" 2>/dev/null || printf 'unreadable')
  case "$candidate_state" in
    alive)
      fm_spawn_recovery_acknowledged || {
        echo "error: interrupted OMP recovery is live without its exact session and turn_start acknowledgement" >&2
        return 1
      }
      fm_spawn_recovery_publish "$state" "$id" || return 1
      fm_spawn_recovery_remove_sidecars
      FM_SPAWN_RECOVERY_RECONCILED=complete
      ;;
    missing)
      fm_spawn_recovery_remove_sidecars
      ;;
    *)
      echo "error: interrupted OMP recovery replacement is neither live nor missing (observed $candidate_state)" >&2
      return 1
      ;;
  esac
}

fm_spawn_recovery_cleanup_replacement() { # <backend> <target>
  local backend=$1 target=$2 state
  if [ -f "$FM_SPAWN_RECOVERY_CANDIDATE" ] && [ ! -L "$FM_SPAWN_RECOVERY_CANDIDATE" ] \
     && cmp -s "$FM_SPAWN_RECOVERY_META" "$FM_SPAWN_RECOVERY_CANDIDATE"; then
    fm_spawn_recovery_remove_sidecars
    return 0
  fi
  if [ -n "$target" ]; then
    if [ "$backend" = herdr ]; then
      fm_backend_source herdr || return 1
      fm_backend_herdr_recovery_kill "$target" "$FM_SPAWN_RECOVERY_CANDIDATE" 2>/dev/null || return 1
    else
      fm_backend_kill "$backend" "$target" 2>/dev/null || return 1
    fi
    state=$(fm_spawn_recovery_candidate_state "$backend" "$target" "$FM_SPAWN_RECOVERY_CANDIDATE" 2>/dev/null || printf 'unreadable')
    [ "$state" = missing ] || {
      echo "warning: OMP recovery stopped its replacement but observed endpoint state $state instead of missing" >&2
      return 1
    }
  fi
  fm_spawn_recovery_remove_sidecars
}

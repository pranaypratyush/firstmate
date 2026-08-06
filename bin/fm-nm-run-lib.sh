#!/usr/bin/env bash
# Shared no-mistakes axi run attribution primitives.
#
# ONE owner for the branch+code-identity matching rule and fully attributed
# run object that decide whether a no-mistakes run belongs to a given
# worktree, used by fm-crew-state.sh (read-only current-state reporting),
# fm-teardown.sh (pre-teardown run abort), and fm-nm-live.sh (exact companion
# thread attribution). Getting this wrong in either
# direction is unsafe: a false negative hides a genuinely parked run, and a
# false positive lets teardown act on a run it does not own.
#
# Bounded call to `no-mistakes "$@"` in dir $1, timeout $2 seconds. The bounded
# form preserves stdout, stderr, and exit status; the checked form discards
# stderr, while fm_nm_run keeps the fail-open query contract for read-only callers.
fm_nm_run_bounded() {  # <dir> <timeout_secs> <args...>
  local dir=$1 timeout_secs=$2 have_timeout=none
  shift 2
  if command -v timeout >/dev/null 2>&1; then have_timeout=timeout
  elif command -v gtimeout >/dev/null 2>&1; then have_timeout=gtimeout
  elif command -v perl >/dev/null 2>&1; then have_timeout=perl
  fi
  case "$have_timeout" in
    timeout)  ( cd "$dir" && timeout "$timeout_secs" no-mistakes "$@" ) ;;
    gtimeout) ( cd "$dir" && gtimeout "$timeout_secs" no-mistakes "$@" ) ;;
    perl)     ( cd "$dir" && perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$timeout_secs" no-mistakes "$@" ) ;;
    *)        return 1 ;;
  esac
}

fm_nm_run_checked() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_bounded "$@" 2>/dev/null
}

fm_nm_run() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_checked "$@" || true
}

fm_nm_trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

fm_nm_strip_quotes() {
  local s
  s=$(fm_nm_trim "${1:-}")
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
  esac
  fm_nm_trim "$s"
}

# Scalar value of a TOON key in captured `axi status` output $1.
fm_nm_field() {  # <toon-output> <key>
  printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*\(.*\)/\1/p" | head -1
}

# 0 if run head $2 matches worktree $1's code identity, per the same rule
# everywhere this attribution is needed:
#   - missing/empty head: cannot bind; reject
#   - equal commits (short or full SHA): match
#   - worktree HEAD is an ancestor of run head: match (pipeline fix commits on
#     the same history advanced the run tip past local HEAD)
#   - run head is a strict ancestor of worktree HEAD, or diverged: no match
#     (local work advanced outside the run, or the branch tip was rewritten)
fm_nm_head_matches_worktree() {  # <worktree> <run_head>
  local wt=$1 run_head=$2 local_full run_full
  [ -n "$run_head" ] || return 1
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  run_full=$(git -C "$wt" rev-parse --verify "${run_head}^{commit}" 2>/dev/null) || return 1
  [ "$run_full" = "$local_full" ] && return 0
  git -C "$wt" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null
}

# fm_nm_attributed_status <worktree> <expected-branch> <timeout> [<run-id>]
# queries one exact worktree and succeeds only for the exact branch plus the
# shared code-identity rule above.
# On success it sets FM_NM_ATTRIBUTED_* globals, including the complete TOON
# object in FM_NM_ATTRIBUTED_OUT.
# Return 1 means the query answered but did not attribute; return 2 means the
# executable call or run object was malformed/unavailable.
fm_nm_attributed_status() {
  local wt=$1 expected_branch=$2 timeout_secs=$3 pinned_run=${4:-}
  local out rc actual_branch run_id run_branch run_head run_status outcome
  FM_NM_ATTRIBUTED_OUT=""
  FM_NM_ATTRIBUTED_ID=""
  FM_NM_ATTRIBUTED_BRANCH=""
  FM_NM_ATTRIBUTED_HEAD=""
  FM_NM_ATTRIBUTED_STATUS=""
  FM_NM_ATTRIBUTED_OUTCOME=""
  FM_NM_ATTRIBUTED_REASON=""
  [ -d "$wt" ] || { FM_NM_ATTRIBUTED_REASON=missing-worktree; return 2; }
  actual_branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null) || {
    FM_NM_ATTRIBUTED_REASON=detached-head
    return 1
  }
  [ -n "$expected_branch" ] && [ "$actual_branch" = "$expected_branch" ] || {
    FM_NM_ATTRIBUTED_REASON=worktree-branch-changed
    return 1
  }
  if [ -n "$pinned_run" ]; then
    out=$(fm_nm_run_bounded "$wt" "$timeout_secs" axi status --run "$pinned_run" 2>&1)
    rc=$?
  else
    out=$(fm_nm_run_bounded "$wt" "$timeout_secs" axi status 2>&1)
    rc=$?
  fi
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    FM_NM_ATTRIBUTED_REASON=query-failed
    return 2
  fi
  if printf '%s\n' "$out" | grep -Eq '^runs:[[:space:]]+0 runs yet in this repository[[:space:]]*$'; then
    FM_NM_ATTRIBUTED_REASON=no-run
    return 1
  fi
  run_id=$(fm_nm_strip_quotes "$(fm_nm_field "$out" id)")
  run_branch=$(fm_nm_strip_quotes "$(fm_nm_field "$out" branch)")
  run_head=$(fm_nm_strip_quotes "$(fm_nm_field "$out" head)")
  run_status=$(fm_nm_strip_quotes "$(fm_nm_field "$out" status)")
  outcome=$(fm_nm_strip_quotes "$(fm_nm_field "$out" outcome)")
  case "$run_id" in
    ''|*[!A-Za-z0-9._-]*) FM_NM_ATTRIBUTED_REASON=malformed-run-id; return 2 ;;
  esac
  if [ -n "$pinned_run" ] && [ "$run_id" != "$pinned_run" ]; then
    FM_NM_ATTRIBUTED_REASON=pinned-run-mismatch
    return 2
  fi
  [ "$run_branch" = "$expected_branch" ] || {
    FM_NM_ATTRIBUTED_REASON=branch-mismatch
    return 1
  }
  fm_nm_head_matches_worktree "$wt" "$run_head" || {
    FM_NM_ATTRIBUTED_REASON=head-mismatch
    return 1
  }
  [ -n "$run_status" ] || {
    FM_NM_ATTRIBUTED_REASON=missing-status
    return 2
  }
  FM_NM_ATTRIBUTED_OUT=$out
  FM_NM_ATTRIBUTED_ID=$run_id
  FM_NM_ATTRIBUTED_BRANCH=$run_branch
  FM_NM_ATTRIBUTED_HEAD=$run_head
  FM_NM_ATTRIBUTED_STATUS=$run_status
  FM_NM_ATTRIBUTED_OUTCOME=$outcome
  FM_NM_ATTRIBUTED_REASON=attributed
  return 0
}

# Print the nonempty session_id values from the pinned no-mistakes companion
# interface's exact active_steps table.
# The table shape is pinned to no-mistakes commit
# 0d39eadf3f36ed8087794947425d122ca9323f8f.
# Return 0 includes the valid absent/empty case; return 2 means a malformed,
# duplicated, truncated, or differently shaped table.
fm_nm_active_session_ids() {  # <toon-output>
  printf '%s\n' "$1" | awk '
    function csv(line, out,    i, ch, nextch, quoted, n, field) {
      n = 1
      field = ""
      quoted = 0
      for (i = 1; i <= length(line); i++) {
        ch = substr(line, i, 1)
        nextch = substr(line, i + 1, 1)
        if (ch == "\"") {
          if (quoted && nextch == "\"") {
            field = field "\""
            i++
          } else {
            quoted = !quoted
          }
        } else if (ch == "," && !quoted) {
          out[n++] = field
          field = ""
        } else {
          field = field ch
        }
      }
      if (quoted) return -1
      out[n] = field
      return n
    }
    /^[[:space:]]*active_steps\[[0-9][0-9]*\]\{step,status,active_for,last_activity,agent_pid,session_id,round\}:[[:space:]]*$/ {
      if (seen_header++) exit 22
      header = $0
      sub(/^[[:space:]]*active_steps\[/, "", header)
      sub(/\].*$/, "", header)
      want = header + 0
      reading = 1
      next
    }
    reading && got < want {
      delete fields
      count = csv($0, fields)
      if (count != 7) exit 23
      got++
      if (fields[6] != "") print fields[6]
      if (got == want) reading = 0
      next
    }
    END {
      if (seen_header && got != want) exit 24
    }
  '
}

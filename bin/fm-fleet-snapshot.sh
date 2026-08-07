#!/usr/bin/env bash
# fm-fleet-snapshot.sh - read-only structured fleet snapshot.
#
# Output contract: `--json` prints one object with schema
# `fm-fleet-snapshot.v1`.
# The command is read-only: it does not acquire the session lock, drain wakes,
# arm watchers, mutate backlog state, or write reports.
#
# Top-level fields:
#   schema: stable schema id.
#   generated: UTC observation time for this fresh command execution.
#   fm_home: resolved operational home.
#   roots: resolved root/config/data/state/projects directories.
#   backlog: {path,present,records[]} where records are ordered as written in
#     data/backlog.md and cover In flight, Queued, and Done.
#     Canonical tasks-axi rows are structured; free-form non-empty lines in
#     those sections are preserved as unstructured records.
#     Structured rows preserve captain-hold metadata such as hold_kind and
#     hold_reason when tasks-axi emits it. They also carry normalized current_role,
#     requires_child_metadata, blocked_by_ids, unresolved_blocker_ids, and
#     captain_actionable fields. Repeated blocker tokens remain ordered; a blocker
#     resolves only when its structured record is Done, and missing ids stay open.
#   tasks[]: one row per state/<id>.meta, sorted by id.
#     current_state is parsed from bin/fm-crew-state.sh <id> and preserves
#     state, source, detail, and raw line separately.
#     paths.status_log.last_event is historical wake-event data only, never
#     current state.
#     hints.open_decisions is the keyed open-decision set returned by
#     fm-classify-lib.sh's authoritative status_open_decisions fold and reconciled
#     against current_state; hints.pending_decision and hints.blocked_event are
#     booleans derived from that set.
#     endpoint.exists is the cheap backend endpoint-presence read.
#     endpoint.agent_alive is populated for secondmates only, where it is useful
#     return-channel supervision data; other tasks use "not_checked".
#   scout_reports[]: present data/<id>/report.md pointers plus bounded leading
#     context for current or completed structured work. Context reads are capped
#     per report and across the snapshot; other report pointers remain present.
#   main_inventory: {valid,reason,orphan_in_flight[],unstructured_current_count} -
#     main-home current-inventory checks shared with secondmate_home_summary_json
#     (orphan structured in-flight ids with no state/<id>.meta, and unstructured
#     current backlog rows). Does not invent live tasks; meta remains truth for
#     workers. Bearings maps failures into omitted[] disclosure (and a Charted
#     Next gate line) rather than silent empty Underway.
#   secondmate_current: {records[],total,shown,truncated} - bounded current summaries
#     for registered secondmates, selected from validated structured state inside
#     each home with explicit provenance, freshness, endpoint evidence, and unknown
#     failure reasons. Parent status and bounded terminal evidence are historical,
#     untrusted supplements only and never override readable structured-home facts.
#     Each structured-home record carries active_children, decisions_open, holds,
#     queued, landed, endpoints, counts, and omitted. Actionable captain holds
#     appear in decisions_open; blocked captain holds remain queued with metadata.
#   secondmate_landed: {records[],truncated[],unreadable[],partial[]} - the
#     compatibility landed-work roll-up derived from secondmate_current. Readable
#     structured homes with an unknown current classification are partial, not
#     unreadable, and retain independently trustworthy structured surfaces.
#   secondmate_guidance: return-channel action note for renderers and bearings.
#
# Compatibility: JSON is the primary machine-readable surface.
# Human views must render this output instead of parsing state files again.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
BACKLOG="$DATA/backlog.md"
SNAPSHOT_NOW=${FM_SNAPSHOT_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
if [ -n "${FM_SNAPSHOT_NOW_EPOCH:-}" ]; then
  SNAPSHOT_EPOCH=$FM_SNAPSHOT_NOW_EPOCH
else
  SNAPSHOT_EPOCH=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$SNAPSHOT_NOW" +%s 2>/dev/null \
    || date -u -d "$SNAPSHOT_NOW" +%s 2>/dev/null \
    || date +%s)
fi
case "$SNAPSHOT_EPOCH" in ''|*[!0-9]*) SNAPSHOT_EPOCH=$(date +%s) ;; esac

# Cross-home bounds are explicit so one broken or unexpectedly large home cannot
# hang or explode the parent snapshot.
FM_SNAPSHOT_SECONDMATES=${FM_SNAPSHOT_SECONDMATES:-20}
FM_SNAPSHOT_SECONDMATE_TIMEOUT=${FM_SNAPSHOT_SECONDMATE_TIMEOUT:-8}
FM_SNAPSHOT_SECONDMATE_MAX_BYTES=${FM_SNAPSHOT_SECONDMATE_MAX_BYTES:-262144}
FM_SNAPSHOT_SECONDMATE_CHILDREN=${FM_SNAPSHOT_SECONDMATE_CHILDREN:-20}
FM_SNAPSHOT_SECONDMATE_QUEUED=${FM_SNAPSHOT_SECONDMATE_QUEUED:-20}
FM_SNAPSHOT_SECONDMATE_DECISIONS=${FM_SNAPSHOT_SECONDMATE_DECISIONS:-20}
FM_SNAPSHOT_TERMINAL_LINES=${FM_SNAPSHOT_TERMINAL_LINES:-8}
FM_SNAPSHOT_TERMINAL_BYTES=${FM_SNAPSHOT_TERMINAL_BYTES:-4096}
FM_SNAPSHOT_TERMINAL_TIMEOUT=${FM_SNAPSHOT_TERMINAL_TIMEOUT:-2}
FM_SNAPSHOT_PARENT_ACTIVITY_LINES=${FM_SNAPSHOT_PARENT_ACTIVITY_LINES:-256}
FM_SNAPSHOT_PARENT_ACTIVITY_BYTES=${FM_SNAPSHOT_PARENT_ACTIVITY_BYTES:-65536}
FM_SNAPSHOT_PARENT_ACTIVITIES=${FM_SNAPSHOT_PARENT_ACTIVITIES:-20}
FM_SNAPSHOT_PARENT_ACTIVITY_TIMEOUT=${FM_SNAPSHOT_PARENT_ACTIVITY_TIMEOUT:-2}
FM_SNAPSHOT_REGISTRY_LINES=${FM_SNAPSHOT_REGISTRY_LINES:-256}
FM_SNAPSHOT_REGISTRY_BYTES=${FM_SNAPSHOT_REGISTRY_BYTES:-65536}
FM_SNAPSHOT_REGISTRY_RECORDS=${FM_SNAPSHOT_REGISTRY_RECORDS:-40}
FM_SNAPSHOT_REGISTRY_TIMEOUT=${FM_SNAPSHOT_REGISTRY_TIMEOUT:-2}
FM_SNAPSHOT_REPORT_SUMMARIES=${FM_SNAPSHOT_REPORT_SUMMARIES:-40}
FM_SNAPSHOT_REPORT_SUMMARY_BYTES=${FM_SNAPSHOT_REPORT_SUMMARY_BYTES:-4096}
FM_SNAPSHOT_REPORT_SUMMARY_CHARS=${FM_SNAPSHOT_REPORT_SUMMARY_CHARS:-800}
validate_positive_bound() {  # <name> <value>
  case "$2" in
    ''|*[!0-9]*|0)
      printf 'fm-fleet-snapshot: %s must be a positive integer\n' "$1" >&2
      exit 2
      ;;
  esac
}
case "$FM_SNAPSHOT_SECONDMATES" in
  ''|*[!0-9]*)
    echo "fm-fleet-snapshot: FM_SNAPSHOT_SECONDMATES must be a non-negative integer" >&2
    exit 2
    ;;
esac
validate_positive_bound FM_SNAPSHOT_SECONDMATE_TIMEOUT "$FM_SNAPSHOT_SECONDMATE_TIMEOUT"
validate_positive_bound FM_SNAPSHOT_SECONDMATE_MAX_BYTES "$FM_SNAPSHOT_SECONDMATE_MAX_BYTES"
validate_positive_bound FM_SNAPSHOT_SECONDMATE_CHILDREN "$FM_SNAPSHOT_SECONDMATE_CHILDREN"
validate_positive_bound FM_SNAPSHOT_SECONDMATE_QUEUED "$FM_SNAPSHOT_SECONDMATE_QUEUED"
validate_positive_bound FM_SNAPSHOT_SECONDMATE_DECISIONS "$FM_SNAPSHOT_SECONDMATE_DECISIONS"
validate_positive_bound FM_SNAPSHOT_TERMINAL_LINES "$FM_SNAPSHOT_TERMINAL_LINES"
validate_positive_bound FM_SNAPSHOT_TERMINAL_BYTES "$FM_SNAPSHOT_TERMINAL_BYTES"
validate_positive_bound FM_SNAPSHOT_TERMINAL_TIMEOUT "$FM_SNAPSHOT_TERMINAL_TIMEOUT"
validate_positive_bound FM_SNAPSHOT_PARENT_ACTIVITY_LINES "$FM_SNAPSHOT_PARENT_ACTIVITY_LINES"
validate_positive_bound FM_SNAPSHOT_PARENT_ACTIVITY_BYTES "$FM_SNAPSHOT_PARENT_ACTIVITY_BYTES"
validate_positive_bound FM_SNAPSHOT_PARENT_ACTIVITIES "$FM_SNAPSHOT_PARENT_ACTIVITIES"
validate_positive_bound FM_SNAPSHOT_PARENT_ACTIVITY_TIMEOUT "$FM_SNAPSHOT_PARENT_ACTIVITY_TIMEOUT"
validate_positive_bound FM_SNAPSHOT_REGISTRY_LINES "$FM_SNAPSHOT_REGISTRY_LINES"
validate_positive_bound FM_SNAPSHOT_REGISTRY_BYTES "$FM_SNAPSHOT_REGISTRY_BYTES"
validate_positive_bound FM_SNAPSHOT_REGISTRY_RECORDS "$FM_SNAPSHOT_REGISTRY_RECORDS"
validate_positive_bound FM_SNAPSHOT_REGISTRY_TIMEOUT "$FM_SNAPSHOT_REGISTRY_TIMEOUT"
validate_positive_bound FM_SNAPSHOT_REPORT_SUMMARIES "$FM_SNAPSHOT_REPORT_SUMMARIES"
validate_positive_bound FM_SNAPSHOT_REPORT_SUMMARY_BYTES "$FM_SNAPSHOT_REPORT_SUMMARY_BYTES"
validate_positive_bound FM_SNAPSHOT_REPORT_SUMMARY_CHARS "$FM_SNAPSHOT_REPORT_SUMMARY_CHARS"

# shellcheck source=bin/fm-backend.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-ff-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-ff-lib.sh"  # validate_secondmate_home: shared seeded-home boundary checks
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"  # fm_run_timed: the shared hard bound

usage() {
  cat <<'EOF'
usage: fm-fleet-snapshot.sh --json
       fm-fleet-snapshot.sh --secondmate-home-summary

Print a read-only structured snapshot of the firstmate fleet.
JSON is the stable machine-readable output contract.

--secondmate-home-summary emits the bounded structured summary used after a
validated registered-home handoff. It is local-only, skips nested secondmate
aggregation, and marks inventory contradictions or unavailable child state invalid.
Current peers emit fm-secondmate-home-summary.v2; bounded legacy v1 summaries
remain accepted with safe projection defaults during mixed-version operation.
Its invalidity object names the normalized failure kind and affected ids.
Actionable tasks-axi captain holds appear as decisions_open and stay visible in
queued with hold_reason, hold_kind, and plural blocker fields for downstream
projections. A captain hold is actionable only when every blocker is Done.
Use a backlog body line such as `Captain action: review-changes+merge-decision`
with the values review-changes, merge-decision, and missing-choice. Empty,
duplicate, missing, or invalid tokens remain an explicit action-type evidence gap.
Backlog body excerpts are capped at 240 characters with per-record truncation
disclosure. Secondmate Charted Next context is capped at 800 characters, while
its next action and advancement condition are capped at 320 characters.
Cross-home reads use FM_SNAPSHOT_SECONDMATES (default 20); zero lifts this count.
FM_SNAPSHOT_SECONDMATE_TIMEOUT (default 8 seconds),
FM_SNAPSHOT_SECONDMATE_MAX_BYTES (default 262144),
FM_SNAPSHOT_SECONDMATE_CHILDREN (default 20),
FM_SNAPSHOT_SECONDMATE_QUEUED (default 20),
FM_SNAPSHOT_SECONDMATE_DECISIONS (default 20), and
FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME (default 10).
Terminal contradiction evidence uses FM_SNAPSHOT_TERMINAL_LINES (default 8),
FM_SNAPSHOT_TERMINAL_BYTES (default 4096), and
FM_SNAPSHOT_TERMINAL_TIMEOUT (default 2 seconds) and never becomes canonical current state.
Parent activity evidence uses FM_SNAPSHOT_PARENT_ACTIVITY_LINES (default 256),
FM_SNAPSHOT_PARENT_ACTIVITY_BYTES (default 65536),
FM_SNAPSHOT_PARENT_ACTIVITIES (default 20), and
FM_SNAPSHOT_PARENT_ACTIVITY_TIMEOUT (default 2 seconds), with truncation disclosed.
The registered secondmate table uses FM_SNAPSHOT_REGISTRY_LINES (default 256),
FM_SNAPSHOT_REGISTRY_BYTES (default 65536),
FM_SNAPSHOT_REGISTRY_RECORDS (default 40), and
FM_SNAPSHOT_REGISTRY_TIMEOUT (default 2 seconds), with truncation disclosed.
Bounded report context uses FM_SNAPSHOT_REPORT_SUMMARIES (default 40) across
the snapshot, FM_SNAPSHOT_REPORT_SUMMARY_BYTES (default 4096) per selected
report, and FM_SNAPSHOT_REPORT_SUMMARY_CHARS (default 800) after whitespace
normalization. Report pointers remain visible outside the context-count bound.
EOF
}

OUTPUT_MODE=json
case "${1:---json}" in
  --json) ;;
  --secondmate-home-summary) OUTPUT_MODE=secondmate-home-summary ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "fm-fleet-snapshot: jq not found" >&2; exit 1; }

bool_json() {
  if [ "$1" = 1 ]; then printf 'true'; else printf 'false'; fi
}

path_present_json() {  # <path>
  local present=0
  [ -e "$1" ] && present=1
  jq -n --arg path "$1" --argjson present "$(bool_json "$present")" \
    '{path:$path,present:$present}'
}

meta_value() {  # <meta-file> <key>
  fm_meta_get "$1" "$2"
}

last_nonempty_line() {  # <file>
  [ -f "$1" ] || return 1
  grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -1
}

crew_state_json() {  # <id>
  local id=$1 raw rest state source detail sep
  raw=$(
    FM_ROOT_OVERRIDE="$FM_ROOT" \
      FM_HOME="$FM_HOME" \
      FM_STATE_OVERRIDE="$STATE" \
      FM_DATA_OVERRIDE="$DATA" \
      FM_PROJECTS_OVERRIDE="$PROJECTS" \
      FM_CONFIG_OVERRIDE="$CONFIG" \
      "$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null || true
  )
  raw=$(printf '%s\n' "$raw" | head -1)
  sep=' · '
  state=unknown
  source=none
  detail=
  case "$raw" in
    state:\ *"$sep"source:\ *)
      rest=${raw#state: }
      state=${rest%%"$sep"source: *}
      rest=${rest#*"$sep"source: }
      case "$rest" in
        *"$sep"*) source=${rest%%"$sep"*}; detail=${rest#*"$sep"} ;;
        *) source=$rest ;;
      esac
      ;;
  esac
  jq -n --arg raw "$raw" --arg state "$state" --arg source "$source" --arg detail "$detail" \
    '{state:$state,source:$source,detail:$detail,raw:$raw}'
}

status_event_json() {  # <status-log>
  local log=$1 present=0 raw='' verb='' note=''
  if [ -f "$log" ]; then
    present=1
    raw=$(last_nonempty_line "$log" || true)
    verb=$(status_line_verb "$raw")
    note=$(status_line_note "$raw")
  fi
  jq -n \
    --arg path "$log" \
    --arg raw "$raw" \
    --arg verb "$verb" \
    --arg note "$note" \
    --argjson present "$(bool_json "$present")" \
    '{path:$path,present:$present,kind:"event_history",last_event:{state:$verb,note:$note,raw:$raw}}'
}

first_pr_url_in_file() {  # <file>
  [ -f "$1" ] || return 1
  grep -Eo 'https?://[^[:space:])"]+/pull/[0-9]+' "$1" 2>/dev/null | head -1
}

backlog_json() {  # [<backlog-path>] - defaults to this home's $BACKLOG
  local backlog=${1:-$BACKLOG}
  if [ ! -f "$backlog" ]; then
    jq -n --arg path "$backlog" '{path:$path,present:false,records:[]}'
    return 0
  fi

  # shellcheck disable=SC2094
  jq -Rn --arg path "$backlog" '
    def trim: gsub("^[[:space:]]+|[[:space:]]+$"; "");
    def section_state:
      if . == "In flight" then "in_flight"
      elif . == "Queued" then "queued"
      elif . == "Done" then "done"
      else null end;
    def cap($rest; $re):
      (((($rest | capture($re)?) // {}) | .v) // null) as $v
      | if $v == null then null else ($v | trim) end;
    def metadata($rest; $key):
      cap($rest; ".*(?:\\(|,[[:space:]]*)" + $key + ":[[:space:]]*(?<v>[^,)]*)");
    def metadata_word($rest; $key):
      cap($rest; ".*(?:\\(|,[[:space:]]*)" + $key + "[[:space:]]+(?<v>[^,)]*)");
    def url_pattern: "https?://[^[:space:])\"<>]+";
    def wrapped_url_pattern: "<?" + url_pattern + ">?";
    def links($rest): [$rest | scan(url_pattern)];
    def strip_trailing_metadata:
      reduce range(0; 20) as $_ (.;
        sub("[[:space:]]*\\([[:space:]]*(?:(?:repo|kind|priority|hold|hold-kind|captain-action):[[:space:]]*[^)]*|(?:since|merged|reported|done)[[:space:]]+[^)]*)[[:space:]]*\\)[[:space:]]*$"; ""));
    def strip_title_artifacts:
      sub("[[:space:]]+-[[:space:]]+data/[^[:space:])]+/report\\.md$"; "")
      | sub("[[:space:]]+data/[^[:space:])]+/report\\.md$"; "")
      | sub("[[:space:]]+-[[:space:]]+local main$"; "")
      | sub("[[:space:]]+local main$"; "")
      | sub("[[:space:]]+-[[:space:]]*$"; "");
    def clean_title:
      strip_trailing_metadata
      | strip_title_artifacts
      | gsub("[[:space:]]+"; " ")
      | trim;
    def title_of($rest):
      $rest
      | gsub(wrapped_url_pattern; "")
      | sub("[[:space:]]*blocked-by:[[:space:]]+[^[:space:])]+[[:space:]]+-[[:space:]]+.*$"; "")
      | gsub("[[:space:]]*blocked-by:[[:space:]]+[^[:space:]]+"; "")
      | clean_title;
    def blocked_by_ids($rest):
      [ $rest | scan("blocked-by:[[:space:]]+(?<id>[^[:space:])]+)") | .[0] ]
      | reduce .[] as $id ([]; if index($id) == null then . + [$id] else . end);
    def blocked_reason($rest):
      cap($rest; ".*blocked-by:[[:space:]]*[^[:space:])]+[[:space:]]+-[[:space:]]*(?<v>.*)$") as $reason
      | if $reason == null then null
        else ($reason | clean_title | if . == "" then null else . end)
        end;
    def local_note($rest):
      cap(($rest | strip_trailing_metadata); ".*(?:^|[[:space:]]+-[[:space:]]+|[[:space:]])(?<v>local main)$");
    def completion($rest):
      (metadata_word($rest; "merged")) as $merged
      | (metadata_word($rest; "reported")) as $reported
      | (metadata_word($rest; "done")) as $done
      | if $merged != null then {verb:"merged",date:$merged}
        elif $reported != null then {verb:"reported",date:$reported}
        elif $done != null then {verb:"done",date:$done}
        else {verb:null,date:null} end;
    def row_match($line):
      (($line | capture("^[-*][[:space:]]+\\[(?<check>[ xX])\\][[:space:]]+(?<id>[^[:space:]]+)[[:space:]]+-[[:space:]]+(?<rest>.*)$")?) //
       (($line | capture("^[-*][[:space:]]+\\*\\*(?<id>[^*]+)\\*\\*[[:space:]]+-[[:space:]]+(?<rest>.*)$")?)
        | if . == null then null else . + {check:" "} end));
    def structured_row($line):
      ($line | test("^[-*][[:space:]]+\\[[ xX]\\][[:space:]]+[^[:space:]]+[[:space:]]+-[[:space:]]+"))
      or ($line | test("^[-*][[:space:]]+\\*\\*[^*]+\\*\\*[[:space:]]+-[[:space:]]+"));
    def parse_row($line; $section; $order):
      row_match($line) as $m
      | if $m == null then
          {order:$order,state:$section,structured:false,id:null,raw:$line,body_lines:[],body_excerpt:null,body_excerpt_truncated:false}
        else
          ($m.rest) as $rest
          | {order:$order,
             state:$section,
             structured:true,
             id:($m.id | trim),
             checked:($m.check | test("[xX]")),
             title:title_of($rest),
             repo:metadata($rest; "repo"),
             kind:metadata($rest; "kind"),
             priority:metadata($rest; "priority"),
             hold_reason:metadata($rest; "hold"),
             hold_kind:metadata($rest; "hold-kind"),
             blocked_by:cap($rest; ".*blocked-by:[[:space:]]*(?<v>[^[:space:])]+).*"),
             blocked_by_ids:blocked_by_ids($rest),
             blocked_reason:blocked_reason($rest),
             since:metadata_word($rest; "since"),
             merged:metadata_word($rest; "merged"),
             reported:metadata_word($rest; "reported"),
             done:metadata_word($rest; "done"),
             completion:completion($rest),
             links:links($rest),
             pr_url:((links($rest) | map(select(test("/pull/[0-9]+"))) | .[0]) // null),
             report_path:cap($rest; ".*(?<v>data/[^[:space:])]+/report\\.md).*"),
             local_note:local_note($rest),
             raw:$line,
             body_lines:[],
             body_excerpt:null,
             body_excerpt_truncated:false}
        end;
    reduce inputs as $line
      ({path:$path,present:true,records:[],section:null,order:0};
       if ($line | test("^##[[:space:]]+")) then
         .section = (($line | sub("^##[[:space:]]+";"") | trim) | section_state)
       elif .section == null or ($line | trim) == "" then
         .
       elif structured_row($line) then
         .order += 1
         | .records += [parse_row($line; .section; .order)]
       elif ((.records | length) > 0 and (.records[-1].structured == true) and ($line | test("^[[:space:]]+"))) then
         ($line | trim) as $body
         | if $body == "" then .
           else .records[-1].body_lines += [$body] end
       else
         .order += 1
         | .records += [{order:.order,state:.section,structured:false,id:null,raw:$line,body_lines:[],body_excerpt:null,body_excerpt_truncated:false}]
       end)
    | .records |= map(
        if (.body_lines | length) > 0 then
          ([.body_lines[] | select(test("^Captain action:[[:space:]]*") | not)] | join(" ")) as $body
          | .body_excerpt = ($body[:240])
          | .body_excerpt_truncated = (($body | length) > 240)
        else . end)
    | .records as $records
    | (reduce ($records[] | select(.structured)) as $record ({};
         .[$record.id] = ((.[$record.id] // true) and ($record.state == "done")))) as $resolved_ids
    | .records |= map(
        if .structured then
          . as $record
          | .unresolved_blocker_ids = [
              $record.blocked_by_ids[] as $blocker
              | select($resolved_ids[$blocker] != true)
              | $blocker
            ]
          | .current_role =
              (if .state == "in_flight" and .hold_reason != null and .hold_kind != null then "held"
               elif .state == "in_flight" and .kind == "program" then "program"
               elif .state == "in_flight" then "worker"
               elif .state == "queued" then "queued"
               else "done" end)
          | .requires_child_metadata = (.current_role == "worker")
          | .captain_actionable =
              (.state == "queued" and .kind == "captain" and .hold_kind == "captain"
               and .hold_reason != null and (.unresolved_blocker_ids | length) == 0)
          | ([.body_lines[]?
              | capture("^Captain action:[[:space:]]*(?<value>.*)$")?
              | .value]) as $captain_action_lines
          | ($captain_action_lines[0] // null) as $captain_action
          | .captain_action = $captain_action
          | (($captain_action // "") | split("+")) as $declared_actions
          | ($declared_actions
             | all(. == "review-changes" or . == "merge-decision" or . == "missing-choice")) as $tokens_valid
          | (($declared_actions | unique | length) == ($declared_actions | length)) as $tokens_unique
          | (($captain_action_lines | length) == 1 and $captain_action != ""
             and $tokens_valid and $tokens_unique) as $action_valid
          | .captain_action_types =
              (if .kind != "captain" or ($action_valid | not) then []
               else ($declared_actions | unique | sort) end)
          | .captain_action_type_missing = (.kind == "captain" and ($captain_action == null or $captain_action == ""))
          | .captain_action_type_invalid =
              (.kind == "captain" and ($captain_action_lines | length) > 0 and ($action_valid | not))
        else . end)
    | del(.section,.order)
  ' < "$backlog"
}

task_json_lines() {
  local meta id kind harness mode yolo project worktree home projects backend target status_log report_path
  local remote_host remote_root remote_state remote_rc remote_home_present
  local pr pr_source event_json current_json endpoint_exists agent_alive meta_json status_json report_json worktree_json home_json
  local last_event_raw current_state current_source pending_decision blocked_event report_present=0 pr_from_status
  local open_decisions_tsv open_decisions_json

  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    kind=$(meta_value "$meta" kind)
    [ -n "$kind" ] || kind=ship
    harness=$(meta_value "$meta" harness)
    mode=$(meta_value "$meta" mode)
    yolo=$(meta_value "$meta" yolo)
    project=$(meta_value "$meta" project)
    worktree=$(meta_value "$meta" worktree)
    home=$(meta_value "$meta" home)
    projects=$(meta_value "$meta" projects)
    remote_host=$(meta_value "$meta" remote_host)
    remote_root=$(meta_value "$meta" remote_root)
    remote_home_present=null
    if [ -n "$remote_host" ]; then
      backend=$(meta_value "$meta" remote_backend)
      [ -n "$backend" ] || backend=unknown
      target=$(meta_value "$meta" remote_target)
    else
      backend=$(fm_backend_of_meta "$meta")
      target=$(fm_backend_target_of_meta "$meta")
    fi
    status_log="$STATE/$id.status"
    report_path="$DATA/$id/report.md"
    pr=$(meta_value "$meta" pr)
    pr_source=meta
    if [ -z "$pr" ]; then
      pr_from_status=$(first_pr_url_in_file "$status_log" || true)
      pr=$pr_from_status
      pr_source=status_event
    fi
    if [ -z "$pr" ]; then
      pr_source=absent
    fi

    current_json=$(crew_state_json "$id")
    event_json=$(status_event_json "$status_log")
    last_event_raw=$(printf '%s' "$event_json" | jq -r '.last_event.raw // ""')
    current_state=$(printf '%s' "$current_json" | jq -r '.state // ""')
    current_source=$(printf '%s' "$current_json" | jq -r '.source // ""')

    # Durable keyed open-decision set: fold the WHOLE status stream
    # (fm-classify-lib.sh's status_open_decisions) so a later unrelated event can
    # never mask a still-open captain decision. The set is derived purely from the
    # keyed fold - never from report bodies or decision-like prose - and then
    # reconciled against the crew LIFECYCLE, which only clears a stale decision the
    # crew has provably moved past. Two lifecycle signals clear it, neither of which
    # reads any report content:
    #   - a live activity read (run-step or busy pane) that is working/done, so a
    #     crew that resumed past a gate is not still reported as parked; and
    #   - a TERMINAL done/failed state on a single-owner task (scout or ship), whose
    #     deliverable is its report or PR, so a COMPLETED scout surfaces only as a
    #     report POINTER, never as a reopened pending decision.
    # Secondmates are excluded from lifecycle clearing: they are persistent and
    # multiplex many concerns onto one stream, so activity on one concern must
    # never clear another concern's keyed decision. A parked/blocked state, or a
    # non-authoritative status-log/none read on a still-live task, keeps the fold's
    # open decision surfacing.
    open_decisions_tsv=$(status_open_decisions "$status_log")
    if [ "$kind" != secondmate ] && \
       { { { [ "$current_source" = run-step ] || [ "$current_source" = pane ]; } \
           && [ "$current_state" != parked ] && [ "$current_state" != blocked ]; } \
         || { [ "$current_state" = "done" ] || [ "$current_state" = "failed" ]; }; }; then
      open_decisions_tsv=""
    fi
    open_decisions_json=$(printf '%s' "$open_decisions_tsv" | jq -R -s '
      [ splits("\n") | select(length > 0)
        | (capture("^(?<key>[^\t]*)\t(?<verb>[^\t]*)\t(?<summary>.*)$")?)
        | select(. != null) ]')
    pending_decision=$(printf '%s' "$open_decisions_json" | jq 'if any(.[]; .verb == "needs-decision") then 1 else 0 end')
    blocked_event=$(printf '%s' "$open_decisions_json" | jq 'if any(.[]; .verb == "blocked") then 1 else 0 end')

    endpoint_exists=null
    agent_alive=not_checked
    if [ -n "$remote_host" ]; then
      if remote_state=$(fm_run_timed "$FM_SNAPSHOT_SECONDMATE_TIMEOUT" \
        "$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh state "$id" < /dev/null 2>/dev/null); then
        remote_rc=0
      else
        remote_rc=$?
      fi
      if [ "$remote_rc" -eq 0 ]; then
        remote_home_present=true
        remote_state=$(printf '%s\n' "$remote_state" | tail -1)
        case "$remote_state" in
          alive) endpoint_exists=true; agent_alive=alive ;;
          dead) endpoint_exists=true; agent_alive=dead ;;
          missing) endpoint_exists=false; agent_alive=dead ;;
          *) endpoint_exists=null; agent_alive=unknown ;;
        esac
      else
        endpoint_exists=null
        agent_alive=unknown
      fi
    else
      if [ -n "$target" ]; then
        if fm_backend_target_exists "$backend" "$target" "fm-$id" >/dev/null 2>&1; then
          endpoint_exists=true
        else
          endpoint_exists=false
        fi
      fi
      if [ "$kind" = secondmate ] && [ -n "$target" ]; then
        agent_alive=$(fm_backend_agent_alive "$backend" "$target" 2>/dev/null || printf unknown)
      fi
    fi

    [ -f "$report_path" ] && report_present=1 || report_present=0
    meta_json=$(path_present_json "$meta")
    status_json=$event_json
    report_json=$(path_present_json "$report_path")
    if [ -n "$worktree" ]; then worktree_json=$(path_present_json "$worktree"); else worktree_json=$(jq -n '{path:null,present:false}'); fi
    if [ -n "$home" ] && [ -n "$remote_host" ]; then
      home_json=$(jq -n --arg path "$home" --argjson present "$remote_home_present" '{path:$path,present:$present}')
    elif [ -n "$home" ]; then
      home_json=$(path_present_json "$home")
    else
      home_json=$(jq -n '{path:null,present:false}')
    fi

    jq -n \
      --arg id "$id" \
      --arg kind "$kind" \
      --arg harness "$harness" \
      --arg mode "$mode" \
      --arg yolo "$yolo" \
      --arg project "$project" \
      --arg worktree "$worktree" \
      --arg home "$home" \
      --arg projects "$projects" \
      --arg backend "$backend" \
      --arg target "$target" \
      --arg remote_host "$remote_host" \
      --arg remote_root "$remote_root" \
      --arg pr "$pr" \
      --arg pr_source "$pr_source" \
      --arg agent_alive "$agent_alive" \
      --arg observed_at "$SNAPSHOT_NOW" \
      --arg last_event_raw "$last_event_raw" \
      --argjson current_state "$current_json" \
      --argjson meta_path "$meta_json" \
      --argjson status_log "$status_json" \
      --argjson report "$report_json" \
      --argjson worktree_path "$worktree_json" \
      --argjson home_path "$home_json" \
      --argjson endpoint_exists "$endpoint_exists" \
      --argjson open_decisions "$open_decisions_json" \
      --argjson pending_decision "$(bool_json "$pending_decision")" \
      --argjson blocked_event "$(bool_json "$blocked_event")" \
      --argjson report_present "$(bool_json "$report_present")" \
      '{
        id:$id,
        kind:$kind,
        harness:($harness // ""),
        mode:($mode // ""),
        yolo:($yolo // ""),
        project:($project // ""),
        backend:$backend,
        remote:(if $remote_host == "" then null else {host:$remote_host,root:$remote_root} end),
        paths:{
          meta:$meta_path,
          status_log:$status_log,
          worktree:$worktree_path,
          home:$home_path,
          report:$report
        },
        secondmate_projects:($projects | if . == "" then [] else split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) | map(select(. != "")) end),
        current_state:($current_state + {observed_at:$observed_at,freshness:"fresh"}),
        endpoint:{target:($target | if . == "" then null else . end),exists:$endpoint_exists,agent_alive:$agent_alive,
          status:(if $endpoint_exists == false then "absent"
                  elif $agent_alive == "alive" or $agent_alive == "dead" then $agent_alive
                  else "unknown" end),
          observed_at:$observed_at,freshness:"fresh"},
        pr:{url:($pr | if . == "" then null else . end),source:$pr_source},
        hints:{
          pending_decision:$pending_decision,
          blocked_event:$blocked_event,
          open_decisions:$open_decisions,
          scout_report_present:$report_present,
          last_event_text:$last_event_raw
        },
        actions:(
          if $kind == "secondmate" then
            {send:"bin/fm-send.sh fm-\($id) \u0027<request>\u0027",
             watch:"read status/doc return channel; do not routinely fm-peek a secondmate for answers",
             return_channel_note:"Secondmate answers come back through status/doc paths after a marked fm-send request."}
          else
            {watch:"bin/fm-peek.sh fm-\($id)",
             steer:"bin/fm-send.sh fm-\($id) \u0027<instruction>\u0027",
             return_channel_note:null}
          end)
      }'
  done | jq -s 'sort_by(.id)'
}

# Main-home current-inventory validity: same orphan / unstructured-current checks
# used by secondmate_home_summary_json, without inventing live task rows.
# Meta inventory remains the sole source of live workers; this object only
# discloses backlog↔task inconsistency for renderers (Bearings omitted/gates).
main_inventory_json() {  # <backlog-json> <tasks-json>
  jq -n \
    --argjson backlog "$1" \
    --argjson tasks "$2" '
    ([ $backlog.records[]?
       | select((.state == "in_flight" or .state == "queued") and (.structured | not)) ]) as $unstructured_current
    | ([ $backlog.records[]?
         | select(.state == "in_flight" and .structured and .requires_child_metadata) ]) as $owned_in_flight
    | ([ $owned_in_flight[]
         | select(.id as $id | [$tasks[].id] | index($id) | not)
         | .id ]) as $orphan_in_flight
    | (($unstructured_current | length) == 0
       and ($orphan_in_flight | length) == 0) as $valid
    | (if ($unstructured_current | length) > 0 then "unstructured current backlog row"
       elif ($orphan_in_flight | length) > 0 then "in-flight backlog item has no child metadata"
       else null end) as $reason
    | {
        valid:$valid,
        reason:$reason,
        orphan_in_flight:$orphan_in_flight,
        unstructured_current_count:($unstructured_current | length)
      }'
}

# Project one home's canonical structured inventory into the bounded shape a
# validated parent read needs.
# This mode never reads parent events or terminal text and never aggregates
# nested secondmates.
secondmate_home_summary_json() {  # <backlog-json> <tasks-json> <scout-reports-json>
  jq -n \
    --arg generated "$SNAPSHOT_NOW" \
    --arg home "$FM_HOME" \
    --argjson child_n "$FM_SNAPSHOT_SECONDMATE_CHILDREN" \
    --argjson queued_n "$FM_SNAPSHOT_SECONDMATE_QUEUED" \
    --argjson decisions_n "$FM_SNAPSHOT_SECONDMATE_DECISIONS" \
    --argjson landed_n "$FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME" \
    --argjson backlog "$1" \
    --argjson tasks "$2" \
    --argjson reports "$3" '
    def trunc($n):
      tostring | gsub("\\s+"; " ")
      | if length > $n then .[:$n] + "…" else . end;
    def bounded($n):
      tostring | gsub("\\s+"; " ")
      | if length > $n then .[:($n - 1)] + "…" else . end;
    def report_context($id):
      ([ $reports[]? | select(.id == $id) | .summary_excerpt // empty ][0]) // null;
    def report_byte_truncated($id):
      ([ $reports[]? | select(.id == $id) | .summary_byte_truncated ][0]) // false;
    def report_character_truncated($id):
      ([ $reports[]? | select(.id == $id) | .summary_character_truncated ][0]) // false;
    def report_count_omitted($id):
      ([ $reports[]? | select(.id == $id) | .summary_omitted_by_count ][0]) // false;
    def joined_context($body; $report):
      ([ $body, $report ] | map(select(. != null and . != "")) | join(" "));
    def context_value($body; $report):
      (joined_context($body; $report)) as $context
      | if $context == "" then null else ($context | trunc(800)) end;
    def context_projection_truncated($body; $report):
      (joined_context($body; $report) | gsub("\\s+"; " ") | length) > 800;
    def source_caveat($backlog; $byte; $character; $count; $projection; $hold_reason):
      ([if $backlog then "backlog body limit reached" else empty end,
        if $byte then "report byte limit reached" else empty end,
        if $character then "report character limit reached" else empty end,
        if $count then "report-count limit reached" else empty end,
        if $projection then "final projection limit reached" else empty end,
        if $hold_reason then "hold-reason limit reached" else empty end]
       | if length == 0 then null else join("; ") end);
    def invalidity_next($invalidity):
      if $invalidity.kind == "missing_backlog" or $invalidity.kind == "unstructured_current" then
        "Repair the structured backlog for this home"
      elif $invalidity.kind == "orphan_in_flight" then
        "Restore child metadata for " + (($invalidity.ids // []) | join(", "))
      elif $invalidity.kind == "unowned_current" then
        "Reconcile unowned child state for " + (($invalidity.ids // []) | join(", "))
      elif $invalidity.kind == "terminal_in_flight" then
        "Move terminal in-flight items to Done or relaunch " + (($invalidity.ids // []) | join(", "))
      elif $invalidity.kind == "child_current_unavailable" then
        "Restore current child state for " + (($invalidity.ids // []) | join(", "))
      else "Restore trustworthy structured state for this home" end;
    def invalidity_advance($invalidity):
      if $invalidity.kind == "missing_backlog" or $invalidity.kind == "unstructured_current" then
        "When a valid structured backlog is available"
      elif $invalidity.kind == "orphan_in_flight" then
        "When child metadata is available for " + (($invalidity.ids // []) | join(", "))
      elif $invalidity.kind == "unowned_current" then
        "When " + (($invalidity.ids // []) | join(", ")) + " are owned by the backlog or retired"
      elif $invalidity.kind == "terminal_in_flight" then
        "When backlog and terminal child state agree for " + (($invalidity.ids // []) | join(", "))
      elif $invalidity.kind == "child_current_unavailable" then
        "When current child state is available for " + (($invalidity.ids // []) | join(", "))
      else "When trustworthy structured state is available" end;
    ([ $backlog.records[]?
       | select((.state == "in_flight" or .state == "queued") and (.structured | not)) ]) as $unstructured_current
    | ([ $backlog.records[]? | select(.state == "in_flight" and .structured) ]) as $owned_in_flight
    | ([ $backlog.records[]?
         | select(.structured and
             (.state == "queued" or
              (.state == "in_flight" and .current_role == "held"
               and (.id as $id
                    | any($tasks[]; .id == $id and .current_state.state == "working") | not)))) ]) as $queued_all
    | ([ $queued_all[]
         | select(.captain_actionable == true)
         | {id,key:.id,verb:"captain-hold",summary:(.title | trunc(160)),
            reason:(.hold_reason | trunc(160)),action_types:.captain_action_types,
            action_type_missing:.captain_action_type_missing,
            action_type_invalid:.captain_action_type_invalid,
            context:context_value(.body_excerpt; report_context(.id)),
            context_backlog_truncated:(.body_excerpt_truncated // false),
            context_byte_truncated:report_byte_truncated(.id),
            context_character_truncated:report_character_truncated(.id),
            context_report_count_omitted:report_count_omitted(.id),
            context_projection_truncated:context_projection_truncated(.body_excerpt; report_context(.id)),
            source:"backlog"} ]) as $captain_holds_all
    | ([ $backlog.records[]? | select(.state == "done" and .structured and .kind != "captain")
         | {id:(.id | trunc(120)),title:(.title | trunc(120)),
            pr_url:((.pr_url // null) | if . == null then null else trunc(500) end),
            report_path:((.report_path // null) | if . == null then null else trunc(500) end),
            local_note:((.local_note // null) | if . == null then null else trunc(120) end),
            context:context_value(.body_excerpt; report_context(.id)),
            context_backlog_truncated:(.body_excerpt_truncated // false),
            context_byte_truncated:report_byte_truncated(.id),
            context_character_truncated:report_character_truncated(.id),
            context_report_count_omitted:report_count_omitted(.id),
            context_projection_truncated:context_projection_truncated(.body_excerpt; report_context(.id)),completion} ]
       | sort_by([(.completion.date // ""), .id]) | reverse) as $landed_all
    | ([ $tasks[] | select(.current_state.state == "unknown") ]) as $unknown_children
    | ([ $owned_in_flight[]
         | select(.requires_child_metadata)
         | select(.id as $id | [$tasks[].id] | index($id) | not) ]) as $orphan_in_flight
    | ([ $tasks[]
         | select(.id as $id | [$owned_in_flight[].id] | index($id) | not)
         | {id,state:.current_state.state} ]) as $unowned_children
    | ([ $owned_in_flight[] as $work
         | $tasks[]
         | select(.id == $work.id and (.current_state.state == "done" or .current_state.state == "failed"))
         | {id,state:.current_state.state} ]) as $terminal_in_flight
    | ([if $backlog.present != true then
          {kind:"missing_backlog",ids:[],reason:"missing structured backlog"}
        else empty end,
        if ($unstructured_current | length) > 0 then
          {kind:"unstructured_current",ids:[],reason:"unstructured current backlog row"}
        else empty end,
        if ($orphan_in_flight | length) > 0 then
          {kind:"orphan_in_flight",ids:($orphan_in_flight | map(.id)),
           reason:("in-flight backlog item has no child metadata: " + ($orphan_in_flight | map(.id) | join(", ")))}
        else empty end,
        if ($unowned_children | length) > 0 then
          {kind:"unowned_current",ids:($unowned_children | map(.id)),
           reason:("live child state has no in-flight backlog item: " +
                   ($unowned_children | map(.id + "=" + .state) | join(", ")))}
        else empty end,
        if ($terminal_in_flight | length) > 0 then
          {kind:"terminal_in_flight",ids:($terminal_in_flight | map(.id)),
           reason:("in-flight backlog item has terminal child state: " +
                   ($terminal_in_flight | map(.id + "=" + .state) | join(", ")))}
        else empty end]) as $strict_invalidities
    | ([ $owned_in_flight[] as $work
         | select($work.current_role != "program")
         | $tasks[]
         | select(.id == $work.id and .current_state.state == "working")
         | {id,kind,state:.current_state.state,source:.current_state.source,
            objective:(($work.title // .id) | trunc(160)),
            doing:((.current_state.detail // "") | trunc(160)),
            next_action:(("Continue objective: " + ($work.title // .id)) | trunc(320)),
            next_action_truncated:((("Continue objective: " + ($work.title // .id)) | length) > 320),
            milestone:((.hints.last_event_text // "") | trunc(200)),
            context:context_value($work.body_excerpt; report_context(.id)),
            context_backlog_truncated:($work.body_excerpt_truncated // false),
            context_byte_truncated:report_byte_truncated(.id),
            context_character_truncated:report_character_truncated(.id),
            context_report_count_omitted:report_count_omitted(.id),
            context_projection_truncated:context_projection_truncated($work.body_excerpt; report_context(.id))} ]) as $active_all
    | ($captain_holds_all
       + ([ $tasks[] as $t | ($t.hints.open_decisions // [])[]
            | {id:$t.id,key,verb,summary:(.summary | trunc(160)),reason:null,source:"status"} ])) as $decisions_all
    | ([ $queued_all[]
         | select((.unresolved_blocker_ids | length) > 0 or (.hold_reason != null and .hold_kind != null))
         | {id:(.id | trunc(120)),title:(.title | trunc(90)),
            blocked_by:((.unresolved_blocker_ids | join(",")) | if . == "" then null else trunc(120) end),
            blocked_by_ids:(.blocked_by_ids | map(trunc(120))),
            unresolved_blocker_ids:(.unresolved_blocker_ids | map(trunc(120))),
            reason:((.hold_reason // .blocked_reason // "blocked") | trunc(120)),
            context:context_value(.body_excerpt; report_context(.id)),
            context_backlog_truncated:(.body_excerpt_truncated // false),
            context_byte_truncated:report_byte_truncated(.id),
            context_character_truncated:report_character_truncated(.id),
            context_report_count_omitted:report_count_omitted(.id),
            context_projection_truncated:context_projection_truncated(.body_excerpt; report_context(.id)),
            hold_reason_truncated:(((.hold_reason // "") | length) > 120),
            blocked_reason_truncated:(((.blocked_reason // "") | length) > 120),source:"backlog"} ]
       + [ $owned_in_flight[] as $work
           | $tasks[]
           | select(.id == $work.id and (.current_state.state == "parked" or .current_state.state == "paused" or .current_state.state == "blocked"))
           | select(($work.hold_reason != null and $work.hold_kind != null) | not)
           | {id,title:((.backlog.title // .id) | trunc(90)),blocked_by:null,
              blocked_by_ids:[],unresolved_blocker_ids:[],
              reason:((.current_state.detail // .current_state.state) | trunc(120)),
              context:null,context_backlog_truncated:false,context_byte_truncated:false,
              context_character_truncated:false,context_report_count_omitted:false,
              context_projection_truncated:false,hold_reason_truncated:false,
              blocked_reason_truncated:false,source:"child-state"} ]) as $holds_all
    | ($backlog.present == true
       and ($unstructured_current | length) == 0
       and ($unknown_children | length) == 0
       and ($orphan_in_flight | length) == 0
       and ($unowned_children | length) == 0
       and ($terminal_in_flight | length) == 0) as $valid
    | (if ($strict_invalidities | length) > 0 then $strict_invalidities[0].reason
       elif ($unknown_children | length) > 0 then
         "child current state unavailable: " + ($unknown_children | map(.id) | join(", "))
       else null end) as $reason
    | (if ($strict_invalidities | length) > 0 then $strict_invalidities[0] | del(.reason)
       elif ($unknown_children | length) > 0 then {kind:"child_current_unavailable",ids:($unknown_children | map(.id))}
       else {kind:null,ids:[]} end) as $invalidity
    | (if $valid | not then "unknown"
       elif any($decisions_all[]; .verb == "captain-hold") then "captain_decision"
       elif ($active_all | length) > 0 then "active_child_work"
       elif ($holds_all | length) > 0 then "externally_held"
       else "no_active_work" end) as $state
    | (if $state == "externally_held" then
         ([ $holds_all[] | [.title, .context, .reason]
           | map(select(. != null and . != "")) | join(": ") ] | join("; ")) as $held_context
         | ([ $holds_all[] | .id +
            (if ((.unresolved_blocker_ids // []) | length) > 0
             then " waits for " + (.unresolved_blocker_ids | join(", "))
             else " remains held: " + (.reason // "held") end) ] | join("; ")) as $held_next
         | ([ $holds_all[]
            | if ((.unresolved_blocker_ids // []) | length) > 0
              then "After " + (.unresolved_blocker_ids | join(", ")) + " are done"
              else "When hold clears for " + .id + ": " + (.reason // "held") end ]
            | join("; ")) as $held_advance
         | (any($holds_all[]; .context_backlog_truncated == true)) as $backlog_cut
         | (any($holds_all[]; .context_byte_truncated == true)) as $byte_cut
         | (any($holds_all[]; .context_character_truncated == true)) as $character_cut
         | (any($holds_all[]; .context_report_count_omitted == true)) as $count_cut
         | (any($holds_all[]; .context_projection_truncated == true)) as $projection_cut
         | (any($holds_all[]; (.hold_reason_truncated // false) or (.blocked_reason_truncated // false))) as $hold_cut
         | {context:($held_context | bounded(800)),context_truncated:(($held_context | length) > 800),
            context_backlog_truncated:$backlog_cut,context_byte_truncated:$byte_cut,
            context_character_truncated:$character_cut,context_report_count_omitted:$count_cut,
            context_projection_truncated:$projection_cut,hold_reason_truncated:$hold_cut,
            next_action:($held_next | bounded(320)),next_action_truncated:(($held_next | length) > 320),
            advance_when:($held_advance | bounded(320)),advance_when_truncated:(($held_advance | length) > 320),
            caveat:(["Structured child work is externally held",
              source_caveat($backlog_cut;$byte_cut;$character_cut;$count_cut;$projection_cut;$hold_cut) // empty]
              | join("; "))}
       elif $state == "unknown" then
         ([ $unknown_children[] as $child
            | $child.id + ": " +
              (([ $owned_in_flight[] | select(.id == $child.id) | .title ][0])
               // $child.hints.last_event_text // "current state unavailable") ]
          | join("; ")) as $unknown_context
         | (if $unknown_context == "" then ($reason // "Current home state unavailable")
            else $unknown_context end) as $unknown_context_value
         | (any($owned_in_flight[]; (.body_excerpt_truncated // false) == true)) as $backlog_cut
         | (any($owned_in_flight[]; report_byte_truncated(.id) == true)) as $byte_cut
         | (any($owned_in_flight[]; report_character_truncated(.id) == true)) as $character_cut
         | (any($owned_in_flight[]; report_count_omitted(.id) == true)) as $count_cut
         | (any($owned_in_flight[]; context_projection_truncated(.body_excerpt; report_context(.id)) == true)) as $projection_cut
         | (invalidity_next($invalidity)) as $unknown_next
         | (invalidity_advance($invalidity)) as $unknown_advance
         | {context:($unknown_context_value | bounded(800)),context_truncated:(($unknown_context_value | length) > 800),
            context_backlog_truncated:$backlog_cut,context_byte_truncated:$byte_cut,
            context_character_truncated:$character_cut,context_report_count_omitted:$count_cut,
            context_projection_truncated:$projection_cut,hold_reason_truncated:false,
            next_action:($unknown_next | bounded(320)),next_action_truncated:(($unknown_next | length) > 320),
            advance_when:($unknown_advance | bounded(320)),advance_when_truncated:(($unknown_advance | length) > 320),
            caveat:([$reason // "Current home state unavailable",
              source_caveat($backlog_cut;$byte_cut;$character_cut;$count_cut;$projection_cut;false) // empty]
              | join("; ") | bounded(320))}
       else null end) as $charted_next
    | {
        schema:"fm-secondmate-home-summary.v2",
        generated:$generated,
        home:$home,
        valid:$valid,
        reason:$reason,
        invalidity:$invalidity,
        state:$state,
        charted_next:$charted_next,
        active_children:$active_all[:$child_n],
        decisions_open:$decisions_all[:$decisions_n],
        holds:$holds_all[:$queued_n],
        queued:([$queued_all[] | {id:(.id | trunc(120)),title:(.title | trunc(120)),
          blocked_by:((.blocked_by // null) | if . == null then null else trunc(120) end),
          blocked_by_ids:((.blocked_by_ids // []) | map(trunc(120))),
          unresolved_blocker_ids:((.unresolved_blocker_ids // []) | map(trunc(120))),
          blocked_reason:((.blocked_reason // null) | if . == null then null else trunc(160) end),
          blocked_reason_truncated:(((.blocked_reason // "") | length) > 160),
          hold_reason:((.hold_reason // null) | if . == null then null else trunc(160) end),
          hold_reason_truncated:(((.hold_reason // "") | length) > 160),
          hold_kind:((.hold_kind // null) | if . == null then null else trunc(40) end),
          captain_actionable:(.captain_actionable // false),
          repo:((.repo // null) | if . == null then null else trunc(120) end),
          kind:((.kind // null) | if . == null then null else trunc(40) end),
          context:context_value(.body_excerpt; report_context(.id)),
          context_backlog_truncated:(.body_excerpt_truncated // false),
          context_byte_truncated:report_byte_truncated(.id),
          context_character_truncated:report_character_truncated(.id),
          context_report_count_omitted:report_count_omitted(.id),
          context_projection_truncated:context_projection_truncated(.body_excerpt; report_context(.id))}][:$queued_n]),
        landed:(if $landed_n == 0 then $landed_all else $landed_all[:$landed_n] end),
        endpoints:([$tasks[] | . as $task | {id,state:.current_state.state,source:.current_state.source,
          objective:(([ $owned_in_flight[] | select(.id == $task.id) | .title ][0] // .id) | trunc(160)),
          milestone:((.hints.last_event_text // "") | trunc(200)),
          endpoint:(.endpoint + {target:((.endpoint.target // null) | if . == null then null else trunc(240) end)})}][:$child_n]),
        counts:{
          active_children:($active_all | length),
          decisions_open:($decisions_all | length),
          holds:($holds_all | length),
          queued:($queued_all | length),
          landed:($landed_all | length),
          endpoints:($tasks | length)
        },
        omitted:[
          (if ($active_all | length) > $child_n then {surface:"active_children",count:(($active_all | length) - $child_n)} else empty end),
          (if ($decisions_all | length) > $decisions_n then {surface:"decisions_open",count:(($decisions_all | length) - $decisions_n)} else empty end),
          (if ($holds_all | length) > $queued_n then {surface:"holds",count:(($holds_all | length) - $queued_n)} else empty end),
          (if ($queued_all | length) > $queued_n then {surface:"queued",count:(($queued_all | length) - $queued_n)} else empty end),
          (if ($tasks | length) > $child_n then {surface:"endpoints",count:(($tasks | length) - $child_n)} else empty end),
          (if $landed_n > 0 and ($landed_all | length) > $landed_n then {surface:"landed",count:(($landed_all | length) - $landed_n)} else empty end)
        ]
      }'
}

capture_bounded_secondmate_summary() {  # <seconds> <max-bytes> <command...>
  local seconds=$1 max_bytes=$2
  shift 2
  # shellcheck disable=SC2016  # Expansion is deliberately deferred to the bounded child shell.
  fm_run_timed "$seconds" bash -c '
    limit=$1
    shift
    set -o pipefail
    "$@" | LC_ALL=C head -c "$limit"
    statuses=("${PIPESTATUS[@]}")
    command_rc=${statuses[0]}
    head_rc=${statuses[1]}
    [ "$head_rc" -eq 0 ] || exit "$head_rc"
    [ "$command_rc" -eq 141 ] && command_rc=0
    exit "$command_rc"
  ' fm-secondmate-summary-capture "$((max_bytes + 1))" "$@"
}

# Current registered-secondmate aggregation.
# The validated home summary is canonical.
# Parent status and bounded terminal capture remain untrusted supplemental evidence
# with explicit provenance, and can only produce a contradiction or unknown fallback.
FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME=${FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME:-10}
case "$FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME" in ''|*[!0-9]*) FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME=10 ;; esac

# GNU stat treats -f as a filesystem-report command, so a BSD-first fallback can
# pollute arithmetic input before failing. Select the platform syntax once.
if [ "$(uname 2>/dev/null || true)" = Darwin ]; then
  SNAPSHOT_STAT_STYLE=bsd
  file_mtime_epoch() { stat -f '%m' "$1" 2>/dev/null || true; }
  file_mode_octal() { stat -f '%Lp' "$1" 2>/dev/null || true; }
else
  SNAPSHOT_STAT_STYLE=gnu
  file_mtime_epoch() { stat -c '%Y' "$1" 2>/dev/null || true; }
  file_mode_octal() { stat -c '%a' "$1" 2>/dev/null || true; }
fi

registry_secondmates_json() {
  local reg="$DATA/secondmates.md" out rc reason mode script parse_filter output_filter
  if [ ! -f "$reg" ]; then
    jq -n --arg path "$reg" --arg observed "$SNAPSHOT_NOW" \
      '{present:false,available:true,complete:true,reason:null,provenance:"registered-table",path:$path,freshness:{status:"fresh",observed_at:$observed},records:[],input_truncated:false,records_truncated:false,reasons:[],lines_in_window:0,records_in_window:0}'
    return 0
  fi
  mode=$(file_mode_octal "$reg")
  if [ -z "$mode" ] || [ $((8#$mode & 0444)) -eq 0 ]; then
    jq -n --arg path "$reg" --arg observed "$SNAPSHOT_NOW" \
      --arg reason "registered secondmate table is unreadable" \
      '{present:true,available:false,complete:false,reason:$reason,provenance:"registered-table",path:$path,freshness:{status:"unavailable",observed_at:$observed},records:[],input_truncated:false,records_truncated:false,reasons:[$reason],lines_in_window:0,records_in_window:0}'
    return 0
  fi
  script=$(cat <<'BASH'
    f=$1
    max_lines=$2
    max_bytes=$3
    max_records=$4
    path=$5
    observed=$6
    parse_filter=$7
    output_filter=$8
    content=$(LC_ALL=C head -c "$((max_bytes + 1))" "$f" || exit 3; printf "\036") || exit 3
    content=${content%$'\036'}
    bytes=$(printf "%s" "$content" | LC_ALL=C wc -c | tr -d " ")
    byte_truncated=false
    if [ "$bytes" -gt "$max_bytes" ]; then
      byte_truncated=true
      content=$(printf "%s" "$content" | LC_ALL=C head -c "$max_bytes")
      complete=${content%$'\n'*}
      if [ "$complete" != "$content" ]; then
        content=$complete
      else
        content=
      fi
    fi
    if [ -n "$content" ]; then
      lines=$(printf "%s\n" "$content" | awk "END {print NR}")
    else
      lines=0
    fi
    line_truncated=false
    if [ "$lines" -gt "$max_lines" ]; then line_truncated=true; fi
    window=$(printf "%s\n" "$content" | LC_ALL=C head -n "$max_lines") || exit 3
    if [ -n "$window" ]; then
      lines_in_window=$(printf "%s\n" "$window" | awk "END {print NR}")
    else
      lines_in_window=0
    fi
    records=$(printf "%s\n" "$window" | jq -Rn "$parse_filter") || exit 3
    records_in_window=$(printf "%s" "$records" | jq "length") || exit 3
    records_truncated=false
    if [ "$records_in_window" -gt "$max_records" ]; then records_truncated=true; fi
    printf "%s" "$records" | jq \
      --arg path "$path" --arg observed "$observed" \
      --argjson byte_truncated "$byte_truncated" \
      --argjson line_truncated "$line_truncated" \
      --argjson records_truncated "$records_truncated" \
      --argjson lines_in_window "$lines_in_window" \
      --argjson records_in_window "$records_in_window" \
      --argjson max_records "$max_records" "$output_filter"
BASH
  )
  parse_filter=$(cat <<'JQ'
      [ inputs
        | select(startswith("- "))
        | (capture("^- (?<id>[^[:space:]]+)")?) as $id
        | select($id != null)
        | ([capture("^.*\\(host:[[:space:]]*(?<host>[^;)]*);[[:space:]]*root:[[:space:]]*(?<root>[^;)]*);[[:space:]]*home:[[:space:]]*(?<home>[^;)]*);[[:space:]]*scope:[[:space:]]*.*;[[:space:]]*projects:[[:space:]]*[^;)]*;[[:space:]]*added[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}\\)[[:space:]]*$")?][0] // null) as $remote
        | ([capture("^.*\\(home:[[:space:]]*(?<home>[^;)]*);[[:space:]]*scope:[[:space:]]*.*;[[:space:]]*projects:[[:space:]]*[^;)]*;[[:space:]]*added[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}\\)[[:space:]]*$")?][0] // null) as $local
        | ($local // $remote) as $route
        | (($local == null) and ($remote != null)) as $is_remote
        | {id:$id.id,home:($route.home // null),host:(if $is_remote then $remote.host else null end),root:(if $is_remote then $remote.root else null end),
           remote:$is_remote,registered:true,
           registry_error:(if $route == null or ($route.home | length) == 0 then "registry entry has no home" else null end)} ]
      | group_by(.id)
      | map(if length > 1 then .[0] + {registry_error:"duplicate secondmate id in registry"} else .[0] end)
JQ
  )
  output_filter=$(cat <<'JQ'
      {present:true,available:true,reason:null,provenance:"registered-table",path:$path,
       freshness:{status:"fresh",observed_at:$observed},
       records:(if length > $max_records then .[:$max_records] else . end),
       input_truncated:($byte_truncated or $line_truncated),records_truncated:$records_truncated,
       complete:(($byte_truncated or $line_truncated or $records_truncated) | not),
       reasons:[
         (if $byte_truncated then "byte_limit" else empty end),
         (if $line_truncated then "line_limit" else empty end),
         (if $records_truncated then "record_limit" else empty end)
       ],lines_in_window:$lines_in_window,records_in_window:$records_in_window}
JQ
  )
  out=$(fm_run_timed "$FM_SNAPSHOT_REGISTRY_TIMEOUT" bash -c "$script" \
    fm-secondmate-registry "$reg" "$FM_SNAPSHOT_REGISTRY_LINES" \
    "$FM_SNAPSHOT_REGISTRY_BYTES" "$FM_SNAPSHOT_REGISTRY_RECORDS" "$reg" "$SNAPSHOT_NOW" \
    "$parse_filter" "$output_filter" 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | jq -e '
    .available == true and (.records | type) == "array"
  ' >/dev/null 2>&1; then
    printf '%s' "$out"
    return 0
  fi
  [ "$rc" -eq 124 ] && reason="registered secondmate table read timed out" \
    || reason="registered secondmate table is unreadable"
  jq -n --arg path "$reg" --arg observed "$SNAPSHOT_NOW" --arg reason "$reason" \
    '{present:true,available:false,complete:false,reason:$reason,provenance:"registered-table",path:$path,freshness:{status:"unavailable",observed_at:$observed},records:[],input_truncated:false,records_truncated:false,reasons:[$reason],lines_in_window:0,records_in_window:0}'
}

bounded_parent_activities_json() {  # <status-file>
  local f=$1 out rc reason script
  if [ ! -f "$f" ]; then
    jq -n '{records:[],available:true,input_truncated:false,retained_truncated:false,reasons:[],lines_in_window:0,records_in_window:0}'
    return 0
  fi
  script=$(cat <<'BASH'
    classify=$1
    f=$2
    max_lines=$3
    max_bytes=$4
    max_records=$5
    stat_style=$6
    . "$classify"
    if [ "$stat_style" = bsd ]; then
      size=$(stat -f "%z" "$f" 2>/dev/null) || exit 3
    else
      size=$(stat -c "%s" "$f" 2>/dev/null) || exit 3
    fi
    content=$(LC_ALL=C tail -c "$max_bytes" "$f") || exit 3
    byte_truncated=false
    if [ "$size" -gt "$max_bytes" ]; then
      byte_truncated=true
      complete=${content#*$'\n'}
      if [ "$complete" != "$content" ]; then
        content=$complete
      else
        content=
      fi
    fi
    if [ -n "$content" ]; then
      lines_in_chunk=$(printf "%s\n" "$content" | awk "END {print NR}")
    else
      lines_in_chunk=0
    fi
    line_truncated=false
    if [ "$lines_in_chunk" -gt "$max_lines" ]; then line_truncated=true; fi
    window=$(printf "%s\n" "$content" | LC_ALL=C tail -n "$max_lines") || exit 3
    if [ -n "$window" ]; then
      lines_in_window=$(printf "%s\n" "$window" | awk "END {print NR}")
    else
      lines_in_window=0
    fi
    records=$(printf "%s\n" "$window" | status_open_activities - \
      | jq -R -s '[splits("\n") | select(length > 0)
          | (capture("^(?<key>[^\t]*)\t(?<verb>[^\t]*)\t(?<summary>.*)$")?)
          | select(. != null)]') || exit 3
    records_in_window=$(printf "%s" "$records" | jq "length") || exit 3
    retained_truncated=false
    if [ "$records_in_window" -gt "$max_records" ]; then retained_truncated=true; fi
    printf "%s" "$records" | jq \
      --argjson byte_truncated "$byte_truncated" \
      --argjson line_truncated "$line_truncated" \
      --argjson retained_truncated "$retained_truncated" \
      --argjson lines_in_window "$lines_in_window" \
      --argjson records_in_window "$records_in_window" \
      --argjson max_records "$max_records" '
        {records:(if length > $max_records then .[-$max_records:] else . end),
         available:true,
         input_truncated:($byte_truncated or $line_truncated),
         retained_truncated:$retained_truncated,
         reasons:[
           (if $byte_truncated then "byte_limit" else empty end),
           (if $line_truncated then "line_limit" else empty end),
           (if $retained_truncated then "activity_limit" else empty end)
         ],
         lines_in_window:$lines_in_window,
         records_in_window:$records_in_window}'
BASH
  )
  out=$(fm_run_timed "$FM_SNAPSHOT_PARENT_ACTIVITY_TIMEOUT" bash -c "$script" \
    fm-parent-activities "$SCRIPT_DIR/fm-classify-lib.sh" "$f" \
    "$FM_SNAPSHOT_PARENT_ACTIVITY_LINES" "$FM_SNAPSHOT_PARENT_ACTIVITY_BYTES" \
    "$FM_SNAPSHOT_PARENT_ACTIVITIES" "$SNAPSHOT_STAT_STYLE" 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | jq -e '
    (.records | type) == "array" and (.available | type) == "boolean"
  ' >/dev/null 2>&1; then
    printf '%s' "$out"
    return 0
  fi
  [ "$rc" -eq 124 ] && reason="timeout" || reason="read_failed"
  jq -n --arg reason "$reason" \
    '{records:[],available:false,input_truncated:false,retained_truncated:false,reasons:[$reason],lines_in_window:0,records_in_window:0}'
}

terminal_evidence_json() {  # <parent-task-json> <event-note> <evidence-contradicts>
  local task=$1 note=$2 evidence_contradicts=$3 backend target exists expected out rc clean bytes lines seen=false contradiction=false reason='' remote_host
  backend=$(printf '%s' "$task" | jq -r '.backend // ""')
  target=$(printf '%s' "$task" | jq -r '.endpoint.target // ""')
  exists=$(printf '%s' "$task" | jq -r '.endpoint.exists // "unknown"')
  remote_host=$(printf '%s' "$task" | jq -r '.remote.host // ""')
  if [ -n "$remote_host" ]; then
    jq -n --arg observed "$SNAPSHOT_NOW" --arg reason "remote terminal evidence is not collected by the primary" \
      '{provenance:"remote-direct-report-terminal",trust:"untrusted-supplement",captured:false,observed_at:$observed,freshness:"not-collected",reason:$reason,lines:0,bytes:0,event_note_seen:false,contradiction:false}'
    return 0
  fi
  expected=$(printf '%s' "$task" | jq -r '"fm-" + (.id // "")')
  if [ -z "$target" ] || [ "$exists" = false ]; then
    [ "$exists" = false ] && reason="recorded endpoint is absent" || reason="no recorded endpoint"
    jq -n --arg observed "$SNAPSHOT_NOW" --arg reason "$reason" \
      '{provenance:"parent-direct-report-terminal",trust:"untrusted-supplement",captured:false,observed_at:$observed,freshness:"unknown",reason:$reason,lines:0,bytes:0,event_note_seen:false,contradiction:false}'
    return 0
  fi
  # shellcheck disable=SC2016 # Positional parameters expand inside the child bash, not here.
  out=$(fm_run_timed "$FM_SNAPSHOT_TERMINAL_TIMEOUT" bash -c \
    '. "$1"; fm_backend_capture "$2" "$3" "$4" "$5" | LC_ALL=C head -c "$6"; rc=${PIPESTATUS[0]}; [ "$rc" -eq 141 ] && rc=0; exit "$rc"' \
    fm-terminal-capture "$SCRIPT_DIR/fm-backend.sh" "$backend" "$target" "$FM_SNAPSHOT_TERMINAL_LINES" "$expected" "$FM_SNAPSHOT_TERMINAL_BYTES" 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    [ "$rc" -eq 124 ] && reason="terminal capture timed out" || reason="terminal capture unavailable"
    jq -n --arg observed "$SNAPSHOT_NOW" --arg reason "$reason" \
      '{provenance:"parent-direct-report-terminal",trust:"untrusted-supplement",captured:false,observed_at:$observed,freshness:"unknown",reason:$reason,lines:0,bytes:0,event_note_seen:false,contradiction:false}'
    return 0
  fi
  clean=$(printf '%s' "$out" | tail -n "$FM_SNAPSHOT_TERMINAL_LINES" | LC_ALL=C head -c "$FM_SNAPSHOT_TERMINAL_BYTES")
  if command -v perl >/dev/null 2>&1; then
    clean=$(printf '%s' "$clean" | perl -pe 's/\e\[[0-?]*[ -\/]*[@-~]//g; s/[^\x09\x0A\x0D\x20-\x7E]//g')
  else
    clean=$(printf '%s' "$clean" | LC_ALL=C tr -cd '\11\12\15\40-\176')
  fi
  bytes=$(printf '%s' "$clean" | LC_ALL=C wc -c | tr -d ' ')
  if [ -n "$clean" ]; then
    lines=$(printf '%s\n' "$clean" | wc -l | tr -d ' ')
  else
    lines=0
  fi
  if [ -n "$note" ]; then
    case "$clean" in *"$note"*) seen=true ;; esac
  fi
  if [ "$seen" = true ] && [ "$evidence_contradicts" = true ]; then contradiction=true; fi
  jq -n \
    --arg observed "$SNAPSHOT_NOW" \
    --argjson lines "$lines" \
    --argjson bytes "$bytes" \
    --argjson seen "$seen" \
    --argjson contradiction "$contradiction" \
    '{provenance:"parent-direct-report-terminal",trust:"untrusted-supplement",captured:true,observed_at:$observed,freshness:"fresh",reason:null,lines:$lines,bytes:$bytes,event_note_seen:$seen,contradiction:$contradiction}'
}

parent_evidence_reconciliation_json() {  # <summary-json> <activities-json> <decisions-json>
  jq -n --argjson summary "$1" --argjson activities "$2" --argjson decisions "$3" '
    def keyed: . != null and . != "" and . != "default";
    def result($e; $matches; $complete; $surface):
      $e + {
        verdict:(if ($e.key | keyed | not) then "inconclusive"
                 elif ($matches | length) > 0 then "corroborates"
                 elif $complete then "contradicts"
                 else "inconclusive" end),
        compared_to:$surface,
        matched:(if ($e.key | keyed) then ($matches[0] // null) else null end)
      };
    ([ $activities[] as $e
       | if $e.verb == "working" then
           ([ $summary.active_children[]
              | select(if ($e.key | keyed) then .id == $e.key else true end)
              | {surface:"active_children",id,key:null,verb:"working"}]) as $matches
           | result($e; $matches;
               $summary.counts.active_children == ($summary.active_children | length);
               "active_children")
         elif $e.verb == "paused" then
           ([ $summary.holds[]
              | select(if ($e.key | keyed) then .id == $e.key or .blocked_by == $e.key else true end)
              | {surface:"holds",id,key:(.blocked_by // null),verb:"paused"}]) as $matches
           | result($e; $matches;
               $summary.counts.holds == ($summary.holds | length);
               "holds")
         else
           $e + {verdict:"inconclusive",compared_to:null,matched:null}
         end ]) as $activity_results
    | ([ $decisions[] as $e
         | if $e.verb == "needs-decision" then
             ([ $summary.decisions_open[]
                | select(.verb == "needs-decision")
                | select(if ($e.key | keyed) then .key == $e.key else true end)
                | {surface:"decisions_open",id,key,verb}]) as $matches
             | result($e; $matches;
                 $summary.counts.decisions_open == ($summary.decisions_open | length);
                 "decisions_open")
           elif $e.verb == "blocked" then
             ([ $summary.decisions_open[]
                | select(.verb == "blocked")
                | select(if ($e.key | keyed) then .key == $e.key or .id == $e.key else true end)
                | {surface:"decisions_open",id,key,verb}]
              + [ $summary.holds[]
                  | select(if ($e.key | keyed) then .id == $e.key or .blocked_by == $e.key else true end)
                  | {surface:"holds",id,key:(.blocked_by // null),verb:"blocked"}]) as $matches
             | result($e; $matches;
                 ($summary.counts.decisions_open == ($summary.decisions_open | length)
                  and $summary.counts.holds == ($summary.holds | length));
                 "decisions_open_or_holds")
           else
             $e + {verdict:"inconclusive",compared_to:null,matched:null}
           end ]) as $decision_results
    | {provenance:"parent-status-keyed-fold",trust:"untrusted-supplement",
       activities:$activity_results,decisions:$decision_results,
       contradiction:any(($activity_results + $decision_results)[]; .verdict == "contradicts"),
       inconclusive:any(($activity_results + $decision_results)[]; .verdict == "inconclusive")}'
}

secondmate_current_json() {  # <parent-tasks-json>
  local tasks=$1 registry union rows total_registered total shown truncated
  local row id home host remote registered registry_error task status_file event_raw event_note event_epoch event_age
  local activity_scan activities decisions reconciliation provenance freshness reason summary summary_rc summary_bytes summary_valid summary_reason summary_invalidity fallback_invalidity state current_reason terminal terminal_contradiction contradiction
  local records='[]' seen_homes=''
  registry=$(registry_secondmates_json) || return 1
  union=$(jq -n --argjson registry "$registry" --argjson tasks "$tasks" '
    ($registry.records // []) as $registered
    | (($registered | map(.id)) // []) as $registered_ids
    | ([ $registered[] as $r
         | $r + {parent_task:([$tasks[] | select(.id == $r.id)][0] // null)} ]
       + [ $tasks[] | select(.kind == "secondmate") as $t
           | select(($registered_ids | index($t.id)) == null)
           | {id:$t.id,home:($t.paths.home.path // null),
              registered:(if $registry.complete == true then false else null end),
              registry_error:(if $registry.complete == true
                              then "secondmate metadata is not registered"
                              else "secondmate registration is unknown because the registry read is incomplete or unavailable" end),
              parent_task:$t} ])
    | sort_by(.id)
    | {registry:$registry,records:.}') || return 1
  total_registered=$(printf '%s' "$union" | jq '[.records[] | select(.registered)] | length')
  total=$(printf '%s' "$union" | jq '.records | length')
  rows=$(printf '%s' "$union" | jq -c --argjson cap "$FM_SNAPSHOT_SECONDMATES" '(if $cap == 0 then .records else .records[:$cap] end)[]')
  shown=$(printf '%s\n' "$rows" | grep -c . || true)
  truncated=$((total - shown))

  while IFS= read -r row; do
    [ -n "$row" ] || continue
    id=$(printf '%s' "$row" | jq -r '.id')
    home=$(printf '%s' "$row" | jq -r '.home // ""')
    host=$(printf '%s' "$row" | jq -r '.host // ""')
    remote=$(printf '%s' "$row" | jq -r '.remote // false')
    registered=$(printf '%s' "$row" | jq -r '.registered')
    registry_error=$(printf '%s' "$row" | jq -r '.registry_error // ""')
    task=$(printf '%s' "$row" | jq -c '.parent_task // {}')
    status_file=$(printf '%s' "$task" | jq -r '.paths.status_log.path // ""')
    event_raw=$(printf '%s' "$task" | jq -r '.paths.status_log.last_event.raw // ""')
    event_note=$(printf '%s' "$task" | jq -r '.paths.status_log.last_event.note // ""')
    activity_scan=$(bounded_parent_activities_json "$status_file")
    activities=$(printf '%s' "$activity_scan" | jq -c '.records')
    decisions=$(printf '%s' "$task" | jq -c '.hints.open_decisions // []')
    event_epoch=$(file_mtime_epoch "$status_file")
    event_age=null
    if [ -n "$event_epoch" ]; then
      event_age=$((SNAPSHOT_EPOCH - event_epoch))
      [ "$event_age" -lt 0 ] && event_age=0
    fi

    reason=$registry_error
    summary='{}'
    summary_valid=false
    fallback_invalidity='{"kind":"structured_home_unavailable","ids":[]}'
    if [ -z "$reason" ] && [ -z "$home" ]; then reason="no recorded secondmate home"; fi
    if [ -z "$reason" ]; then
      case "$home" in
        /*) : ;;
        *) reason="invalid home: registered path is not absolute" ;;
      esac
    fi
    if [ -z "$reason" ]; then
      if [ "$remote" = true ]; then
        [ -n "$host" ] || reason="invalid remote route: missing SSH host"
        case " $seen_homes " in
          *" $host:$home "*) reason="invalid home: duplicate resolved remote route" ;;
          *) seen_homes="$seen_homes $host:$home" ;;
        esac
      elif ! validate_secondmate_home "$id" "$home" 2>/dev/null; then
        reason="invalid home: $VALIDATION_ERROR"
      else
        home=$VALIDATED_HOME
        case " $seen_homes " in
          *" local:$home "*) reason="invalid home: duplicate resolved home route" ;;
          *) seen_homes="$seen_homes local:$home" ;;
        esac
      fi
    fi
    if [ -z "$reason" ]; then
      if [ "$remote" = true ]; then
        summary=$(capture_bounded_secondmate_summary "$FM_SNAPSHOT_SECONDMATE_TIMEOUT" \
          "$FM_SNAPSHOT_SECONDMATE_MAX_BYTES" \
          "$SCRIPT_DIR/fm-on.sh" "$id" fm-fleet-snapshot.sh --secondmate-home-summary < /dev/null 2>/dev/null)
        summary_rc=$?
      else
        summary=$(capture_bounded_secondmate_summary "$FM_SNAPSHOT_SECONDMATE_TIMEOUT" \
          "$FM_SNAPSHOT_SECONDMATE_MAX_BYTES" env \
          FM_ROOT_OVERRIDE="$FM_ROOT" \
          FM_HOME="$home" \
          FM_STATE_OVERRIDE="$home/state" \
          FM_DATA_OVERRIDE="$home/data" \
          FM_CONFIG_OVERRIDE="$home/config" \
          FM_PROJECTS_OVERRIDE="$home/projects" \
          FM_SNAPSHOT_NOW="$SNAPSHOT_NOW" \
          FM_SNAPSHOT_NOW_EPOCH="$SNAPSHOT_EPOCH" \
          FM_SNAPSHOT_SECONDMATE_CHILDREN="$FM_SNAPSHOT_SECONDMATE_CHILDREN" \
          FM_SNAPSHOT_SECONDMATE_QUEUED="$FM_SNAPSHOT_SECONDMATE_QUEUED" \
          FM_SNAPSHOT_SECONDMATE_DECISIONS="$FM_SNAPSHOT_SECONDMATE_DECISIONS" \
          FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME="$FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME" \
          "$SCRIPT_DIR/fm-fleet-snapshot.sh" --secondmate-home-summary 2>/dev/null)
        summary_rc=$?
      fi
      summary_bytes=$(printf '%s' "$summary" | LC_ALL=C wc -c | tr -d ' ')
      if [ "$summary_rc" -eq 124 ]; then
        reason="structured home snapshot timed out"
      elif [ "$summary_bytes" -gt "$FM_SNAPSHOT_SECONDMATE_MAX_BYTES" ]; then
        reason="structured home snapshot exceeded byte limit"
      elif [ "$summary_rc" -ne 0 ]; then
        reason="structured home snapshot failed"
      else
        if ! printf '%s' "$summary" | jq -e --arg home "$home" --arg generated "$SNAPSHOT_NOW" --argjson remote "$remote" '
          def string_or_null: . == null or type == "string";
          def nonempty_string: type == "string" and length > 0;
          def bounded_nonempty($n): nonempty_string and length <= $n;
          def string_array:
            type == "array" and all(.[]; nonempty_string) and (unique | length) == length;
          def legacy_context:
            (.context | string_or_null);
          def modern_context:
            (.context | string_or_null)
            and (.context_backlog_truncated | type) == "boolean"
            and (.context_byte_truncated | type) == "boolean"
            and (.context_character_truncated | type) == "boolean"
            and (.context_report_count_omitted | type) == "boolean"
            and (.context_projection_truncated | type) == "boolean";
          def action_types:
            type == "array" and all(.[];
              type == "string" and (. == "review-changes" or . == "merge-decision" or . == "missing-choice"))
            and (unique | length) == length;
          def count_at_least($items):
            type == "number" and floor == . and . >= ($items | length);
          def omitted_count($omitted; $surface):
            ([$omitted[] | select(.surface == $surface) | .count] | add // 0);
          def count_exact($items; $omitted; $surface):
            type == "number" and floor == .
            and . == (($items | length) + omitted_count($omitted; $surface));
          def valid_omitted:
            type == "array"
            and all(.[]; type == "object"
              and (.surface == "active_children" or .surface == "decisions_open" or .surface == "holds"
                or .surface == "queued" or .surface == "landed" or .surface == "endpoints")
              and (.count as $count | ($count | type) == "number"
                and ($count | floor) == $count and $count > 0))
            and (group_by(.surface) | all(.[]; length == 1));
          def valid_active_legacy:
            type == "object" and (.id | nonempty_string) and .state == "working"
            and (.source | nonempty_string) and (.objective | nonempty_string)
            and (.doing | type) == "string"
            and (.milestone | type) == "string" and legacy_context;
          def valid_active_modern:
            valid_active_legacy
            and (.next_action_truncated | type) == "boolean"
            and (.next_action | bounded_nonempty(320))
            and modern_context;
          def valid_decision_legacy:
            type == "object" and (.id | nonempty_string) and (.key | nonempty_string)
            and (.summary | nonempty_string)
            and (.reason | string_or_null) and (.source | type) == "string"
            and (if .source == "backlog" then
              .verb == "captain-hold" and (.reason | nonempty_string) and legacy_context
            else .source == "status" and (.verb == "needs-decision" or .verb == "blocked") end);
          def valid_decision_modern:
            valid_decision_legacy
            and (if .source == "backlog" then
              (.action_types | action_types)
              and (.action_type_missing | type) == "boolean"
              and (.action_type_invalid | type) == "boolean"
              and (if .action_type_missing then (.action_types | length) == 0 and (.action_type_invalid | not)
                   elif .action_type_invalid then (.action_types | length) == 0
                   else (.action_types | length) > 0 end)
              and modern_context
            else true end);
          def valid_hold_legacy:
            type == "object" and (.id | nonempty_string) and (.title | nonempty_string)
            and (.reason | nonempty_string) and (.source == "backlog" or .source == "child-state")
            and (.blocked_by_ids | string_array) and (.unresolved_blocker_ids | string_array)
            and legacy_context;
          def valid_hold_modern:
            valid_hold_legacy
            and (.hold_reason_truncated | type) == "boolean"
            and (.blocked_reason_truncated | type) == "boolean" and modern_context;
          def valid_queued_legacy:
            type == "object" and (.id | nonempty_string) and (.title | nonempty_string)
            and (.blocked_by_ids | string_array) and (.unresolved_blocker_ids | string_array)
            and (.blocked_reason | string_or_null) and (.hold_reason | string_or_null)
            and (.hold_kind | string_or_null) and (.captain_actionable | type) == "boolean" and legacy_context;
          def valid_queued_modern:
            valid_queued_legacy
            and (.blocked_reason_truncated | type) == "boolean"
            and (.hold_reason_truncated | type) == "boolean" and modern_context;
          def valid_landed_legacy:
            type == "object" and (.id | nonempty_string) and (.title | nonempty_string)
            and (.pr_url | string_or_null) and (.report_path | string_or_null)
            and (.local_note | string_or_null) and (.completion | type) == "object"
            and (.completion.verb == null or .completion.verb == "merged"
              or .completion.verb == "reported" or .completion.verb == "done")
            and (.completion.date == null or (.completion.date | nonempty_string)) and legacy_context;
          def valid_landed_modern:
            valid_landed_legacy and modern_context;
          def valid_endpoint:
            type == "object" and (.id | nonempty_string)
            and (.state == "working" or .state == "unknown" or .state == "parked" or .state == "paused"
              or .state == "blocked" or .state == "done" or .state == "failed")
            and (.source | nonempty_string) and (.objective | nonempty_string)
            and (.milestone | type) == "string" and (.endpoint | type) == "object"
            and (.endpoint.exists | type) == "boolean"
            and (.endpoint.agent_alive | nonempty_string) and (.endpoint.target | string_or_null);
          def valid_charted:
            type == "object"
            and (.context_truncated | type) == "boolean"
            and (.next_action_truncated | type) == "boolean"
            and (.advance_when_truncated | type) == "boolean"
            and (.context | bounded_nonempty(800))
            and (.next_action | bounded_nonempty(320))
            and (.advance_when | bounded_nonempty(320))
            and (.context_backlog_truncated | type) == "boolean"
            and (.context_byte_truncated | type) == "boolean"
            and (.context_character_truncated | type) == "boolean"
            and (.context_report_count_omitted | type) == "boolean"
            and (.context_projection_truncated | type) == "boolean"
            and (.hold_reason_truncated | type) == "boolean"
            and (.caveat | nonempty_string);
          def state_consistent:
            if .valid == false then .state == "unknown"
            elif .state == "unknown" then false
            elif .state == "no_active_work" then
              .counts.active_children == 0 and .counts.decisions_open == 0 and .counts.holds == 0
              and all(.endpoints[]; .state != "working")
            elif .state == "active_child_work" then
              .counts.active_children > 0 and (.active_children | length) > 0
            elif .state == "externally_held" then
              .counts.holds > 0 and (.holds | length) > 0
            elif .state == "captain_decision" then
              .counts.decisions_open > 0
              and any(.decisions_open[]; .source == "backlog" and .verb == "captain-hold")
            else false end;
          (.schema == "fm-secondmate-home-summary.v1" or .schema == "fm-secondmate-home-summary.v2")
          and .home == $home
          and (($remote == true) or .generated == $generated)
          and (.valid | type) == "boolean"
          and (.state == "unknown" or .state == "captain_decision" or .state == "active_child_work"
            or .state == "externally_held" or .state == "no_active_work")
          and (if .schema == "fm-secondmate-home-summary.v2" then
                 if .state == "unknown" or .state == "externally_held" then (.charted_next | valid_charted)
                 else .charted_next == null end
               else .charted_next == null or (.charted_next | valid_charted) end)
          and (if .state == "unknown" then (.reason | nonempty_string) else (.reason == null) end)
          and (if .valid then .invalidity == {kind:null,ids:[]}
               else .state == "unknown"
                 and (.invalidity.kind == "missing_backlog" or .invalidity.kind == "unstructured_current"
                   or .invalidity.kind == "orphan_in_flight" or .invalidity.kind == "unowned_current"
                   or .invalidity.kind == "terminal_in_flight" or .invalidity.kind == "child_current_unavailable")
                 and (.invalidity.ids | string_array)
                 and (if .invalidity.kind == "missing_backlog" or .invalidity.kind == "unstructured_current"
                      then (.invalidity.ids | length) == 0 else (.invalidity.ids | length) > 0 end) end)
          and (.active_children | type) == "array"
          and (.decisions_open | type) == "array"
          and (.holds | type) == "array"
          and (.queued | type) == "array"
          and (.landed | type) == "array"
          and (.endpoints | type) == "array" and all(.endpoints[]; valid_endpoint)
          and (.counts | type) == "object"
          and (.omitted | valid_omitted)
          and (if .schema == "fm-secondmate-home-summary.v2" then
            all(.active_children[]; valid_active_modern)
            and all(.decisions_open[]; valid_decision_modern)
            and all(.holds[]; valid_hold_modern)
            and all(.queued[]; valid_queued_modern)
            and all(.landed[]; valid_landed_modern)
            and (.active_children as $items | .omitted as $omitted
              | .counts.active_children | count_exact($items; $omitted; "active_children"))
            and (.decisions_open as $items | .omitted as $omitted
              | .counts.decisions_open | count_exact($items; $omitted; "decisions_open"))
            and (.holds as $items | .omitted as $omitted
              | .counts.holds | count_exact($items; $omitted; "holds"))
            and (.queued as $items | .omitted as $omitted
              | .counts.queued | count_exact($items; $omitted; "queued"))
            and (.landed as $items | .omitted as $omitted
              | .counts.landed | count_exact($items; $omitted; "landed"))
            and (.endpoints as $items | .omitted as $omitted
              | .counts.endpoints | count_exact($items; $omitted; "endpoints"))
          else
            all(.active_children[]; valid_active_legacy)
            and all(.decisions_open[]; valid_decision_legacy)
            and all(.holds[]; valid_hold_legacy)
            and all(.queued[]; valid_queued_legacy)
            and all(.landed[]; valid_landed_legacy)
            and (.active_children as $items | .omitted as $omitted
              | .counts.active_children | count_exact($items; $omitted; "active_children"))
            and (.decisions_open as $items | .omitted as $omitted
              | .counts.decisions_open | count_exact($items; $omitted; "decisions_open"))
            and (.holds as $items | .counts.holds | count_at_least($items))
            and (.queued as $items | .omitted as $omitted
              | .counts.queued | count_exact($items; $omitted; "queued"))
            and (.landed as $items | .omitted as $omitted
              | .counts.landed | count_exact($items; $omitted; "landed"))
            and (.endpoints as $items | .omitted as $omitted
              | .counts.endpoints | count_exact($items; $omitted; "endpoints"))
          end)
          and state_consistent
        ' >/dev/null 2>&1; then
          reason="structured home snapshot was malformed or stale"
          fallback_invalidity='{"kind":"malformed_structured_home","ids":[]}'
        else
          if printf '%s' "$summary" | jq -e '.schema == "fm-secondmate-home-summary.v1"' >/dev/null; then
            summary=$(printf '%s' "$summary" | jq '
              def context_defaults:
                .context_backlog_truncated = (if (.context_backlog_truncated | type) == "boolean" then .context_backlog_truncated else false end)
                | .context_byte_truncated = (if (.context_byte_truncated | type) == "boolean" then .context_byte_truncated else false end)
                | .context_character_truncated = (if (.context_character_truncated | type) == "boolean" then .context_character_truncated else false end)
                | .context_report_count_omitted = (if (.context_report_count_omitted | type) == "boolean" then .context_report_count_omitted else false end)
                | .context_projection_truncated = ((if (.context_projection_truncated | type) == "boolean" then .context_projection_truncated else false end)
                  or ((.context // "") | length) > 800);
              .active_children |= map(context_defaults
                | .next_action = (if (.next_action | type) == "string" and (.next_action | length) > 0
                  then .next_action else ("Continue objective: " + .objective) end)
                | .next_action_truncated = ((if (.next_action_truncated | type) == "boolean" then .next_action_truncated else false end)
                  or (.next_action | length) > 320))
              | .decisions_open |= map(if .source == "backlog" then
                  context_defaults
                  | .action_types = (if (.action_types | type) == "array"
                    and all(.action_types[]; . == "review-changes" or . == "merge-decision" or . == "missing-choice")
                    then (.action_types | unique) else [] end)
                  | .action_type_invalid = (if (.action_type_invalid | type) == "boolean" then .action_type_invalid else false end)
                  | .action_type_missing = (if .action_type_invalid then false
                    elif (.action_types | length) == 0 then true
                    elif (.action_type_missing | type) == "boolean" then .action_type_missing
                    else false end)
                else . end)
              | .holds |= map(context_defaults
                | .hold_reason_truncated = (if (.hold_reason_truncated | type) == "boolean" then .hold_reason_truncated else false end)
                | .blocked_reason_truncated = (if (.blocked_reason_truncated | type) == "boolean" then .blocked_reason_truncated else false end))
              | .queued |= map(context_defaults
                | .hold_reason_truncated = (if (.hold_reason_truncated | type) == "boolean" then .hold_reason_truncated else false end)
                | .blocked_reason_truncated = (if (.blocked_reason_truncated | type) == "boolean" then .blocked_reason_truncated else false end))
              | .landed |= map(context_defaults
                | .context_byte_truncated = (.context_byte_truncated
                  or (if (.context_truncated | type) == "boolean" then .context_truncated else false end)))
              |
              (.counts.holds - (.holds | length)) as $holds_omitted
              | if $holds_omitted > 0 and ([.omitted[] | select(.surface == "holds")] | length) == 0
                then .omitted += [{surface:"holds",count:$holds_omitted}]
                else . end')
          fi
          summary_valid=$(printf '%s' "$summary" | jq -r '.valid')
          if [ "$summary_valid" != true ]; then
            summary_reason=$(printf '%s' "$summary" | jq -r '.reason // "unknown reason"')
            summary_invalidity=$(printf '%s' "$summary" | jq -r '.invalidity.kind // "unknown"')
            if [ "$summary_invalidity" = unknown ]; then
              reason="structured home state invalid: $summary_reason"
              fallback_invalidity=$(printf '%s' "$summary" | jq -c '.invalidity')
            fi
          fi
        fi
      fi
    fi

    if [ -z "$reason" ]; then
      state=$(printf '%s' "$summary" | jq -r '.state')
      current_reason=
      if [ "$summary_valid" != true ]; then
        current_reason="structured home state invalid: $(printf '%s' "$summary" | jq -r '.reason // "unknown reason"')"
      fi
      reconciliation=$(parent_evidence_reconciliation_json "$summary" "$activities" "$decisions")
      contradiction=$(printf '%s' "$reconciliation" | jq -r '.contradiction')
      terminal_contradiction=$(printf '%s' "$reconciliation" | jq -r --arg note "$event_note" '
        any(.activities[]; .verdict == "contradicts" and .summary == $note)')
      if [ "$terminal_contradiction" = true ]; then
        terminal=$(terminal_evidence_json "$task" "$event_note" true)
      else
        terminal=$(jq -n --arg observed "$SNAPSHOT_NOW" \
          '{provenance:"parent-direct-report-terminal",trust:"untrusted-supplement",captured:false,observed_at:$observed,freshness:"not-collected",reason:"no useful contradiction check",lines:0,bytes:0,event_note_seen:false,contradiction:false}')
      fi
      if printf '%s' "$terminal" | jq -e '.contradiction == true' >/dev/null; then contradiction=true; fi
      record=$(jq -n \
        --arg id "$id" --arg home "$home" --arg host "$host" --argjson remote "$remote" --arg state "$state" --arg current_reason "$current_reason" --arg observed "$SNAPSHOT_NOW" \
        --argjson registered "$registered" --argjson summary "$summary" --argjson summary_valid "$summary_valid" --argjson decisions "$decisions" \
        --argjson activities "$activities" --argjson activity_scan "$activity_scan" \
        --argjson reconciliation "$reconciliation" --argjson terminal "$terminal" --argjson contradiction "$contradiction" \
        --arg event_raw "$event_raw" --arg event_note "$event_note" --argjson event_age "$event_age" '
        {id:$id,home:$home,host:($host | if . == "" then null else . end),remote:$remote,registered:$registered,
         current:{state:$state,reason:($current_reason | if . == "" then null else . end)},invalidity:$summary.invalidity,
         provenance:{selected:"structured-home",structured_home:$home,summary_schema:$summary.schema,summary_valid:$summary_valid,
           trust:(if $summary_valid then "complete" else "partial-structured" end),parent_event_role:"historical-only"},
         freshness:{status:"fresh",observed_at:$observed,age_seconds:0},
         charted_next:$summary.charted_next,
         active_children:$summary.active_children,
         decisions_open:$summary.decisions_open,holds:$summary.holds,queued:$summary.queued,
         landed:$summary.landed,endpoints:$summary.endpoints,counts:$summary.counts,omitted:$summary.omitted,
         parent_event:{raw:$event_raw,note:$event_note,age_seconds:$event_age,open_activities:$activities,open_decisions:$decisions,activity_scan:$activity_scan,reconciliation:$reconciliation},
         terminal_evidence:$terminal,contradiction:$contradiction}')
    else
      if [ -n "$event_raw" ]; then
        provenance='parent-event-fallback'
        freshness=historical-event
      else
        provenance=unknown
        freshness=unknown
      fi
      if [ -n "$event_raw" ]; then
        terminal=$(terminal_evidence_json "$task" "$event_note" false)
      else
        terminal=$(jq -n --arg observed "$SNAPSHOT_NOW" \
          '{provenance:"parent-direct-report-terminal",trust:"untrusted-supplement",captured:false,observed_at:$observed,freshness:"not-collected",reason:"no parent event to compare",lines:0,bytes:0,event_note_seen:false,contradiction:false}')
      fi
      record=$(jq -n \
        --arg id "$id" --arg home "$home" --arg host "$host" --argjson remote "$remote" --arg reason "$reason" --arg observed "$SNAPSHOT_NOW" \
        --arg provenance "$provenance" --arg freshness "$freshness" --arg event_raw "$event_raw" --arg event_note "$event_note" \
        --argjson registered "$registered" --argjson event_age "$event_age" --argjson activities "$activities" --argjson activity_scan "$activity_scan" \
        --argjson fallback_invalidity "$fallback_invalidity" \
        --argjson decisions "$decisions" --argjson terminal "$terminal" '
        def bounded($n):
          tostring | gsub("\\s+"; " ")
          | if length > $n then .[:($n - 1)] + "…" else . end;
        def fallback_next($invalidity; $id):
          if $invalidity.kind == "malformed_structured_home" then
            "Repair malformed structured home snapshot for " + $id
          elif $invalidity.kind == "missing_backlog" or $invalidity.kind == "unstructured_current" then
            "Repair the structured backlog for " + $id
          elif $invalidity.kind == "orphan_in_flight" then
            "Restore child metadata for " + (($invalidity.ids // []) | join(", "))
          elif $invalidity.kind == "unowned_current" then
            "Reconcile unowned child state for " + (($invalidity.ids // []) | join(", "))
          elif $invalidity.kind == "terminal_in_flight" then
            "Move terminal in-flight items to Done or relaunch " + (($invalidity.ids // []) | join(", "))
          elif $invalidity.kind == "child_current_unavailable" then
            "Restore current child state for " + (($invalidity.ids // []) | join(", "))
          else "Restore readable structured state for " + $id end;
        def fallback_advance($invalidity; $id):
          if $invalidity.kind == "malformed_structured_home" then
            "When " + $id + " emits a schema-valid bounded snapshot"
          elif $invalidity.kind == "missing_backlog" or $invalidity.kind == "unstructured_current" then
            "When a valid structured backlog is available for " + $id
          elif $invalidity.kind == "orphan_in_flight" then
            "When child metadata is available for " + (($invalidity.ids // []) | join(", "))
          elif $invalidity.kind == "unowned_current" then
            "When " + (($invalidity.ids // []) | join(", ")) + " are owned by the backlog or retired"
          elif $invalidity.kind == "terminal_in_flight" then
            "When backlog and terminal child state agree for " + (($invalidity.ids // []) | join(", "))
          elif $invalidity.kind == "child_current_unavailable" then
            "When current child state is available for " + (($invalidity.ids // []) | join(", "))
          else "When the registered home is readable for " + $id end;
        {id:$id,home:($home | if . == "" then null else . end),host:($host | if . == "" then null else . end),remote:$remote,registered:$registered,
         current:{state:"unknown",reason:$reason},invalidity:$fallback_invalidity,
         provenance:{selected:$provenance,structured_home:($home | if . == "" then null else . end),parent_event_role:"fallback-only-not-current"},
         freshness:{status:$freshness,observed_at:$observed,age_seconds:$event_age},
         charted_next:($reason as $context
           | fallback_next($fallback_invalidity; $id) as $next
           | fallback_advance($fallback_invalidity; $id) as $advance
           | {context:($context | bounded(800)),
              context_truncated:(($context | length) > 800),
              context_backlog_truncated:false,
              context_byte_truncated:false,
              context_character_truncated:false,
              context_report_count_omitted:false,
              context_projection_truncated:(($context | length) > 800),
              hold_reason_truncated:false,
              next_action:($next | bounded(320)),
              next_action_truncated:(($next | length) > 320),
              advance_when:($advance | bounded(320)),
              advance_when_truncated:(($advance | length) > 320),
              caveat:(("Structured home state unavailable (" + ($fallback_invalidity.kind // "unknown") + "): " + $reason) | bounded(320))}),
         active_children:[],decisions_open:[],holds:[],queued:[],landed:[],endpoints:[],counts:{active_children:0,decisions_open:0,holds:0,queued:0,landed:0,endpoints:0},omitted:[],
         parent_event:{raw:$event_raw,note:$event_note,age_seconds:$event_age,open_activities:$activities,open_decisions:$decisions,activity_scan:$activity_scan},
         terminal_evidence:$terminal,contradiction:false}')
    fi
    records=$(jq -n --argjson records "$records" --argjson record "$record" '$records + [$record]')
  done <<EOF
$rows
EOF
  jq -n \
    --argjson registry "$(printf '%s' "$union" | jq '.registry')" \
    --argjson records "$records" \
    --argjson total_registered "$total_registered" \
    --argjson total "$total" \
    --argjson shown "$shown" \
    --argjson truncated "$truncated" \
    '{registry:$registry,records:$records,total_registered:$total_registered,total:$total,shown:$shown,truncated:$truncated}'
}

secondmate_landed_from_current_json() {  # <secondmate-current-json>
  jq -n --argjson current "$1" '
    {records:[ $current.records[]
      | select(.provenance.selected == "structured-home") as $mate
      | $mate.landed[]
      | . + {home:$mate.home,home_id:$mate.id}],
     truncated:[ $current.records[]
       | select(.provenance.selected == "structured-home" and (.counts.landed > (.landed | length)))
       | .home],
     unreadable:[ $current.records[]
       | select(.current.state == "unknown" and .provenance.selected != "structured-home")
       | .home // ("<" + .id + ": unavailable>")],
     partial:[ $current.records[]
       | select(.current.state == "unknown" and .provenance.selected == "structured-home")
       | .home // ("<" + .id + ": partial>")]}
    | .records |= sort_by([(.completion.date // ""), .id]) | .records |= reverse'
}

scout_report_lines() {  # <backlog-json> <tasks-json>
  local report id relevant_ids summarized=0 content bytes characters truncated excerpt normalized
  local byte_truncated character_truncated omitted_by_count relevant
  if [ ! -d "$DATA" ]; then
    jq -n '[]'
    return 0
  fi
  relevant_ids=$(jq -n -r --argjson backlog "$1" --argjson tasks "$2" '
    ([ $backlog.records[]?
       | select(.structured and
           (.state == "in_flight" or .state == "queued" or .state == "done"))
       | .id ] + [ $tasks[].id ]) | unique[]')
  LC_ALL=C find "$DATA" -mindepth 2 -maxdepth 2 -type f -name report.md -print \
    | sort \
    | while IFS= read -r report; do
      id=$(basename "$(dirname "$report")")
      excerpt=
      truncated=false
      byte_truncated=false
      character_truncated=false
      omitted_by_count=false
      relevant=false
      if printf '%s\n' "$relevant_ids" | grep -Fqx -- "$id"; then
        relevant=true
      fi
      if [ "$summarized" -lt "$FM_SNAPSHOT_REPORT_SUMMARIES" ] && [ "$relevant" = true ]; then
        content=$(LC_ALL=C head -c "$((FM_SNAPSHOT_REPORT_SUMMARY_BYTES + 1))" "$report" 2>/dev/null; printf '\036')
        content=${content%$'\036'}
        bytes=$(printf '%s' "$content" | LC_ALL=C wc -c | tr -d ' ')
        if [ "$bytes" -gt "$FM_SNAPSHOT_REPORT_SUMMARY_BYTES" ]; then
          byte_truncated=true
          content=$(printf '%s' "$content" | LC_ALL=C head -c "$FM_SNAPSHOT_REPORT_SUMMARY_BYTES")
        fi
        normalized=$(printf '%s' "$content" | jq -R -s -r \
          'gsub("[[:space:]]+"; " ") | gsub("^ | $"; "")')
        characters=$(printf '%s' "$normalized" | jq -R -s 'length')
        if [ "$characters" -gt "$FM_SNAPSHOT_REPORT_SUMMARY_CHARS" ]; then
          character_truncated=true
        fi
        if [ "$byte_truncated" = true ] || [ "$character_truncated" = true ]; then
          truncated=true
        fi
        excerpt=$(printf '%s' "$normalized" | jq -R -s -r \
          --argjson chars "$FM_SNAPSHOT_REPORT_SUMMARY_CHARS" '.[:$chars]')
        summarized=$((summarized + 1))
      elif [ "$relevant" = true ]; then
        omitted_by_count=true
        truncated=true
      fi
      jq -n --arg id "$id" --arg path "$report" --arg excerpt "$excerpt" \
        --argjson byte_truncated "$byte_truncated" \
        --argjson character_truncated "$character_truncated" \
        --argjson omitted_by_count "$omitted_by_count" \
        --argjson truncated "$truncated" \
        '{id:$id,path:$path,summary_excerpt:($excerpt | if . == "" then null else . end),
          summary_byte_truncated:$byte_truncated,
          summary_character_truncated:$character_truncated,
          summary_omitted_by_count:$omitted_by_count,
          summary_truncated:$truncated}'
    done \
    | jq -s 'sort_by(.id)'
}

BACKLOG_JSON=$(backlog_json) || { echo "fm-fleet-snapshot: backlog read failed" >&2; exit 1; }
TASKS_JSON=$(task_json_lines) || { echo "fm-fleet-snapshot: task snapshot failed" >&2; exit 1; }
SCOUT_REPORTS_JSON=$(scout_report_lines "$BACKLOG_JSON" "$TASKS_JSON") \
  || { echo "fm-fleet-snapshot: scout report summary failed" >&2; exit 1; }

if [ "$OUTPUT_MODE" = secondmate-home-summary ]; then
  secondmate_home_summary_json "$BACKLOG_JSON" "$TASKS_JSON" "$SCOUT_REPORTS_JSON" \
    || { echo "fm-fleet-snapshot: secondmate home summary failed" >&2; exit 1; }
  exit 0
fi

MAIN_INVENTORY_JSON=$(main_inventory_json "$BACKLOG_JSON" "$TASKS_JSON") \
  || { echo "fm-fleet-snapshot: main inventory summary failed" >&2; exit 1; }
SECONDMATE_CURRENT_JSON=$(secondmate_current_json "$TASKS_JSON") \
  || { echo "fm-fleet-snapshot: registered secondmate aggregation failed" >&2; exit 1; }
SECONDMATE_LANDED_JSON=$(secondmate_landed_from_current_json "$SECONDMATE_CURRENT_JSON") \
  || { echo "fm-fleet-snapshot: secondmate landed projection failed" >&2; exit 1; }

jq -n \
  --arg generated "$SNAPSHOT_NOW" \
  --arg fm_home "$FM_HOME" \
  --arg fm_root "$FM_ROOT" \
  --arg state "$STATE" \
  --arg data "$DATA" \
  --arg config "$CONFIG" \
  --arg projects "$PROJECTS" \
  --argjson backlog "$BACKLOG_JSON" \
  --argjson tasks "$TASKS_JSON" \
  --argjson main_inventory "$MAIN_INVENTORY_JSON" \
  --argjson scout_reports "$SCOUT_REPORTS_JSON" \
  --argjson secondmate_current "$SECONDMATE_CURRENT_JSON" \
  --argjson secondmate_landed "$SECONDMATE_LANDED_JSON" \
  'def backlog_by_id($id): ($backlog.records[]? | select(.structured == true and .id == $id) | .) // null;
   def task_by_id($id): ($tasks[]? | select(.id == $id) | .) // null;
   def report_kind($id): (task_by_id($id).kind // backlog_by_id($id).kind // "scout");
   {
     schema:"fm-fleet-snapshot.v1",
     generated:$generated,
     fm_home:$fm_home,
     roots:{fm_root:$fm_root,state:$state,data:$data,config:$config,projects:$projects},
     backlog:$backlog,
     tasks:($tasks | map(. + {backlog:backlog_by_id(.id)})),
     main_inventory:$main_inventory,
     scout_reports:($scout_reports | map(. + {kind:report_kind(.id)})),
     secondmate_current:$secondmate_current,
     secondmate_landed:$secondmate_landed,
     secondmate_guidance:{
       note:"For kind=secondmate, bearings selects validated structured state from that registered home; parent events and bounded terminal evidence are fallback-only supplements and never current-state authority."
     }
   }'

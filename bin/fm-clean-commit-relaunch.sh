#!/usr/bin/env bash
# Relaunch one missing ordinary ship worker from its clean committed HEAD.
#
# Usage: fm-clean-commit-relaunch.sh <source-task-id> <destination-task-id>
# Validation receipts: append final-head evidence through fm-receipt.sh to
# data/fm-clean-commit-worker-relaunch/evidence.jsonl.
#
# This is deliberately an operator command, not a recovery callback.  It holds
# the source task's existing spawn lock while it proves that the recorded source
# endpoint is authoritatively missing, its linked worktree is a clean readable
# copy of its recorded project, and its exact branch tip is locally reachable.
# It never resumes, closes, rewrites, or otherwise changes that source.
#
# The destination brief must already be a complete ship brief.  A successful
# invocation records data/<destination>/relaunch-handoff.json and an inbox
# reference before it delegates endpoint creation to fm-spawn.sh with its
# narrowly internal exact-commit base.  The handoff is durable evidence of the
# source-to-destination relationship;
# it deliberately records repository and commit identities instead of source
# paths, sessions, worktree bytes, or copied prose.
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT=${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd -P)}
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}

resolve_dir() {  # <label> <path>
  local label=$1 path=$2
  [ -d "$path" ] && [ ! -L "$path" ] || {
    echo "error: $label must be a readable ordinary directory: $path" >&2
    return 1
  }
  (CDPATH='' cd -- "$path" && pwd -P)
}

FM_HOME=$(resolve_dir FM_HOME "$FM_HOME") || exit 1
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
STATE=$(resolve_dir state "$STATE") || exit 1
DATA=$(resolve_dir data "$DATA") || exit 1
[ "$STATE" = "$FM_HOME/state" ] && [ "$DATA" = "$FM_HOME/data" ] || {
  echo "error: clean-commit relaunch refuses cross-home state or data overrides" >&2
  exit 1
}

# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

valid_id() {
  case "$1" in
    ''|.|..|*[!A-Za-z0-9._-]*|[._-]*) return 1 ;;
    *) return 0 ;;
  esac
}
[ "$#" -eq 2 ] || { usage >&2; exit 2; }
SOURCE=$1
DESTINATION=$2
if ! valid_id "$SOURCE" || ! valid_id "$DESTINATION"; then
  echo "error: source and destination task ids must be valid task ids" >&2
  exit 2
fi
[ "$SOURCE" != "$DESTINATION" ] || {
  echo "error: source and destination task ids must differ" >&2
  exit 1
}

SOURCE_META=$STATE/$SOURCE.meta
DEST_META=$STATE/$DESTINATION.meta
SOURCE_LOCK=$STATE/.spawn-$SOURCE.lock
DEST_LOCK=$STATE/.spawn-$DESTINATION.lock
DEST_BRIEF=$DATA/$DESTINATION/brief.md
DEST_HANDOFF=$DATA/$DESTINATION/relaunch-handoff.json
HANDOFF_TMP=
LOCK_HELD=0
DEST_LOCK_HELD=0

cleanup() {
  [ -z "$HANDOFF_TMP" ] || rm -f -- "$HANDOFF_TMP"
  [ "$DEST_LOCK_HELD" -eq 0 ] || fm_lock_release "$DEST_LOCK" || true
  [ "$LOCK_HELD" -eq 0 ] || fm_lock_release "$SOURCE_LOCK" || true
}
trap cleanup EXIT HUP INT TERM

if ! fm_lock_try_acquire "$SOURCE_LOCK"; then
  echo "error: source task $SOURCE is busy with another spawn or relaunch" >&2
  exit 1
fi
LOCK_HELD=1
if ! fm_lock_try_acquire "$DEST_LOCK"; then
  echo "error: destination task $DESTINATION is busy with another spawn or relaunch" >&2
  exit 1
fi
DEST_LOCK_HELD=1

meta_exact() {  # <key>
  local key=$1 count value
  count=$(grep -c "^$key=" "$SOURCE_META" 2>/dev/null || true)
  [ "$count" -eq 1 ] || return 1
  value=$(sed -n "s/^$key=//p" "$SOURCE_META")
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}
meta_optional_exact() {  # <key>
  local key=$1 count value
  count=$(grep -c "^$key=" "$SOURCE_META" 2>/dev/null || true)
  case "$count" in
    0) return 0 ;;
    1) value=$(sed -n "s/^$key=//p" "$SOURCE_META"); [ -n "$value" ] || return 1; printf '%s' "$value" ;;
    *) return 1 ;;
  esac
}

[ -f "$SOURCE_META" ] && [ ! -L "$SOURCE_META" ] || {
  echo "error: source task $SOURCE has no readable regular metadata" >&2
  exit 1
}
[ ! -e "$DEST_META" ] && [ ! -L "$DEST_META" ] && [ ! -e "$STATE/$DESTINATION.status" ] && [ ! -L "$STATE/$DESTINATION.status" ] && [ ! -e "$STATE/$DESTINATION.inbox" ] && [ ! -L "$STATE/$DESTINATION.inbox" ] && [ ! -e "$DEST_HANDOFF" ] && [ ! -L "$DEST_HANDOFF" ] || {
  echo "error: destination task $DESTINATION already has durable task state" >&2
  exit 1
}
[ -f "$DEST_BRIEF" ] && [ ! -L "$DEST_BRIEF" ] || {
  echo "error: destination task $DESTINATION needs a pre-existing complete ship brief" >&2
  exit 1
}
grep -Fq '{TASK}' "$DEST_BRIEF" && {
  echo "error: destination task $DESTINATION brief still contains a task placeholder" >&2
  exit 1
}
"$SCRIPT_DIR/fm-receipt-check.sh" --parse-criteria "$DEST_BRIEF" >/dev/null 2>&1 || {
  echo "error: destination task $DESTINATION needs a complete ship brief with concrete acceptance criteria" >&2
  exit 1
}

KIND=$(meta_exact kind) || { echo "error: source task $SOURCE has malformed kind metadata" >&2; exit 1; }
[ "$KIND" = ship ] || {
  echo "error: clean-commit relaunch accepts only ordinary ship tasks, not $KIND" >&2
  exit 1
}
[ "$(grep -c '^home=' "$SOURCE_META" 2>/dev/null || true)" -eq 0 ] || {
  echo "error: source task $SOURCE carries secondmate-home metadata and cannot be relaunched here" >&2
  exit 1
}
ENDPOINT_TASK=$(meta_exact endpoint_task_id) || {
  echo "error: source task $SOURCE lacks an exact endpoint identity" >&2
  exit 1
}
[ "$ENDPOINT_TASK" = "$SOURCE" ] || {
  echo "error: source task metadata endpoint identity belongs to $ENDPOINT_TASK, not $SOURCE" >&2
  exit 1
}
SOURCE_WORKTREE=$(meta_exact worktree) || { echo "error: source task $SOURCE has malformed worktree metadata" >&2; exit 1; }
PROJECT=$(meta_exact project) || { echo "error: source task $SOURCE has malformed project metadata" >&2; exit 1; }
HARNESS=$(meta_exact harness) || { echo "error: source task $SOURCE has malformed harness metadata" >&2; exit 1; }
MODE=$(meta_exact mode) || { echo "error: source task $SOURCE has malformed delivery metadata" >&2; exit 1; }
YOLO=$(meta_exact yolo) || { echo "error: source task $SOURCE has malformed merge-posture metadata" >&2; exit 1; }
case "$MODE:$YOLO" in
  no-mistakes:on|no-mistakes:off|direct-PR:on|direct-PR:off|local-only:on|local-only:off) ;;
  *) echo "error: source task $SOURCE has invalid delivery or merge posture" >&2; exit 1 ;;
esac
grep -Fxq "Delivery contract: mode=$MODE" "$DEST_BRIEF" || {
  echo "error: destination brief delivery contract does not match source mode=$MODE" >&2
  exit 1
}
MODEL=$(meta_optional_exact model) || { echo "error: source task $SOURCE has malformed model metadata" >&2; exit 1; }
case "$MODEL" in
  ''|default) ;;
  *[!A-Za-z0-9._:/@+-]*) echo "error: source task $SOURCE has invalid model metadata" >&2; exit 1 ;;
esac
EFFORT=$(meta_optional_exact effort) || { echo "error: source task $SOURCE has malformed effort metadata" >&2; exit 1; }
case "$EFFORT" in
  ''|default|low|medium|high|xhigh|max) ;;
  *) echo "error: source task $SOURCE has invalid effort metadata" >&2; exit 1 ;;
esac
PREWALK=$(meta_optional_exact prewalk_into) || { echo "error: source task $SOURCE has malformed prewalk metadata" >&2; exit 1; }
case "$PREWALK" in
  '') ;;
  *[!A-Za-z0-9._:/@+-]*) echo "error: source task $SOURCE has invalid prewalk metadata" >&2; exit 1 ;;
esac
[ -z "$PREWALK" ] || [ "$HARNESS" = omp ] || {
  echo "error: source task $SOURCE has prewalk metadata for non-OMP harness $HARNESS" >&2
  exit 1
}
EXTENSION_COUNT=$(grep -c '^allow_project_omp_extensions=' "$SOURCE_META" 2>/dev/null || true)
case "$EXTENSION_COUNT" in
  0) ALLOW_PROJECT_OMP_EXTENSIONS=0 ;;
  1) grep -Fxq 'allow_project_omp_extensions=1' "$SOURCE_META" || { echo "error: source task $SOURCE has invalid OMP extension metadata" >&2; exit 1; }; ALLOW_PROJECT_OMP_EXTENSIONS=1 ;;
  *) echo "error: source task $SOURCE has malformed OMP extension metadata" >&2; exit 1 ;;
esac

fm_backend_validate_task_endpoint "$SOURCE_META" "$SOURCE" >/dev/null || exit 1
BACKEND=$FM_BACKEND_VALIDATED_BACKEND
TARGET=$FM_BACKEND_VALIDATED_TARGET
case "$(fm_backend_agent_state "$BACKEND" "$TARGET" "$SOURCE_META")" in
  missing) ;;
  *) echo "error: source task $SOURCE endpoint is not authoritatively missing; preserved every source record" >&2; exit 1 ;;
esac

SOURCE_WORKTREE=$(resolve_dir "source worktree" "$SOURCE_WORKTREE") || exit 1
PROJECT=$(resolve_dir "recorded project" "$PROJECT") || exit 1
SOURCE_TOP=$(git -C "$SOURCE_WORKTREE" rev-parse --show-toplevel 2>/dev/null || true)
SOURCE_TOP=$(resolve_dir "source repository root" "$SOURCE_TOP") || exit 1
[ "$SOURCE_TOP" = "$SOURCE_WORKTREE" ] || {
  echo "error: source task $SOURCE worktree is not its recorded repository root" >&2
  exit 1
}
PROJECT_TOP=$(git -C "$PROJECT" rev-parse --show-toplevel 2>/dev/null || true)
PROJECT_TOP=$(resolve_dir "recorded project repository root" "$PROJECT_TOP") || exit 1
[ "$PROJECT_TOP" = "$PROJECT" ] || {
  echo "error: source task $SOURCE project is not a repository root" >&2
  exit 1
}
SOURCE_COMMON=$(git -C "$SOURCE_WORKTREE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
PROJECT_COMMON=$(git -C "$PROJECT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
SOURCE_COMMON=$(resolve_dir "source physical repository" "$SOURCE_COMMON") || exit 1
PROJECT_COMMON=$(resolve_dir "project physical repository" "$PROJECT_COMMON") || exit 1
[ "$SOURCE_COMMON" = "$PROJECT_COMMON" ] || {
  echo "error: source task $SOURCE worktree does not belong to its recorded project repository" >&2
  exit 1
}

SOURCE_STATUS=$(git -C "$SOURCE_WORKTREE" status --porcelain --untracked-files=all --ignore-submodules=none 2>/dev/null) || {
  echo "error: source task $SOURCE worktree status is unreadable" >&2
  exit 1
}
[ -z "$SOURCE_STATUS" ] || {
  echo "error: source task $SOURCE worktree is not completely clean; use manual salvage for uncommitted work" >&2
  exit 1
}
for operation in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD REBASE_HEAD BISECT_START BISECT_LOG sequencer rebase-apply rebase-merge; do
  operation_path=$(git -C "$SOURCE_WORKTREE" rev-parse --git-path "$operation" 2>/dev/null || true)
  [ -z "$operation_path" ] || { [ ! -e "$operation_path" ] && [ ! -L "$operation_path" ]; } || {
    echo "error: source task $SOURCE has a Git operation in progress ($operation)" >&2
    exit 1
  }
done
SOURCE_COMMIT=$(git -C "$SOURCE_WORKTREE" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null || true)
[ -n "$SOURCE_COMMIT" ] || { echo "error: source task $SOURCE has no exact readable HEAD commit" >&2; exit 1; }
SOURCE_BRANCH=$(git -C "$SOURCE_WORKTREE" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
[ -n "$SOURCE_BRANCH" ] || { echo "error: source task $SOURCE is detached and has no durable source branch" >&2; exit 1; }
SOURCE_BRANCH_HEAD=$(git -C "$SOURCE_WORKTREE" rev-parse --verify --quiet "refs/heads/$SOURCE_BRANCH^{commit}" 2>/dev/null || true)
[ "$SOURCE_BRANCH_HEAD" = "$SOURCE_COMMIT" ] || {
  echo "error: source task $SOURCE branch no longer binds its exact HEAD commit" >&2
  exit 1
}
git -C "$PROJECT" cat-file -e "$SOURCE_COMMIT^{commit}" 2>/dev/null || {
  echo "error: source task $SOURCE commit is not reachable from its recorded repository" >&2
  exit 1
}
DESTINATION_SEED_BRANCH="fm/relaunch-$DESTINATION"
[ "$SOURCE_BRANCH" != "$DESTINATION_SEED_BRANCH" ] && [ "$SOURCE_BRANCH" != "fm/$DESTINATION" ] || {
  echo "error: source and destination branch identities would collide" >&2
  exit 1
}
if git -C "$PROJECT" show-ref --verify --quiet "refs/heads/$DESTINATION_SEED_BRANCH" \
  || git -C "$PROJECT" show-ref --verify --quiet "refs/heads/fm/$DESTINATION"; then
  echo "error: destination task $DESTINATION already has a branch" >&2
  exit 1
fi

sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  fi
}
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

NM_TIMEOUT=${FM_CLEAN_COMMIT_RELAUNCH_NM_TIMEOUT:-10}
case "$NM_TIMEOUT" in ''|*[!0-9]*) NM_TIMEOUT=10 ;; esac
CUSTODY=none
RUN_ID=
RUN_STATUS=
RUN_HEAD=
RUN_BRANCH=
RUN_NEXT_ACTION=none
NM_OUTPUT=$(fm_nm_run_bounded "$SOURCE_WORKTREE" "$NM_TIMEOUT" axi status 2>&1) || NM_STATUS=$?
NM_STATUS=${NM_STATUS:-0}
if [ "$NM_STATUS" -eq 0 ] && [ -n "$NM_OUTPUT" ]; then
  RUN_ID=$(fm_nm_strip_quotes "$(fm_nm_field "$NM_OUTPUT" id)")
  RUN_BRANCH=$(fm_nm_strip_quotes "$(fm_nm_field "$NM_OUTPUT" branch)")
  RUN_HEAD=$(fm_nm_strip_quotes "$(fm_nm_field "$NM_OUTPUT" head)")
  RUN_STATUS=$(fm_nm_strip_quotes "$(fm_nm_field "$NM_OUTPUT" status)")
  RUN_OUTCOME=$(fm_nm_strip_quotes "$(fm_nm_field "$NM_OUTPUT" outcome)")
  if [ -n "$RUN_ID" ] && [ "$RUN_BRANCH" = "$SOURCE_BRANCH" ] \
    && fm_nm_head_matches_worktree "$SOURCE_WORKTREE" "$RUN_HEAD" && [ -z "$RUN_OUTCOME" ]; then
    case "$RUN_STATUS" in
      running|fixing|ci) CUSTODY=active; RUN_NEXT_ACTION=firstmate-custody-decision-required ;;
      awaiting_approval|fix_review) CUSTODY=parked; RUN_NEXT_ACTION=firstmate-custody-decision-required ;;
      *)
        if printf '%s\n' "$NM_OUTPUT" | grep -Eq '^[[:space:]]*(awaiting_agent|gate):'; then
          CUSTODY=parked
          RUN_NEXT_ACTION=firstmate-custody-decision-required
        else
          CUSTODY=unreadable
          RUN_NEXT_ACTION=manual-validation-custody-inspection-required
        fi
        ;;
    esac
  else
    CUSTODY=unreadable
    RUN_NEXT_ACTION=manual-validation-custody-inspection-required
  fi
elif [ "$NM_STATUS" -ne 0 ] && [ "$(fm_nm_trim "$NM_OUTPUT")" = 'no active run' ]; then
  :
else
  CUSTODY=unreadable
  RUN_NEXT_ACTION=manual-validation-custody-inspection-required
fi

[ "$CUSTODY" != unreadable ] || {
  echo "error: source task $SOURCE No-Mistakes custody is unreadable; preserved every source record" >&2
  exit 1
}
[ "$CUSTODY" != active ] && [ "$CUSTODY" != parked ] || {
  echo "error: source task $SOURCE has active or parked No-Mistakes custody; resolve it before clean-commit relaunch" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || {
  echo "error: jq is required to publish the destination relaunch handoff" >&2
  exit 1
}
SOURCE_BRIEF=$DATA/$SOURCE/brief.md
[ -f "$SOURCE_BRIEF" ] && [ ! -L "$SOURCE_BRIEF" ] && [ -r "$SOURCE_BRIEF" ] || {
  echo "error: source task $SOURCE needs a readable regular brief to bind its preserved-work handoff" >&2
  exit 1
}
SOURCE_BRIEF_IDENTITY=$(sha256_file "$SOURCE_BRIEF") || {
  echo "error: source task $SOURCE brief identity could not be read" >&2
  exit 1
}
PR_COUNT=$(grep -c '^pr=' "$SOURCE_META" 2>/dev/null || true)
case "$PR_COUNT" in
  0) PR= ;;
  1) PR=$(sed -n 's/^pr=//p' "$SOURCE_META") ;;
  *) echo "error: source PR metadata is ambiguous; source was preserved" >&2; exit 1 ;;
esac

if ! grep -Fq '<!-- fm-clean-commit-relaunch-handoff -->' "$DEST_BRIEF"; then
  cat >> "$DEST_BRIEF" <<EOF

## Preserved-work handoff

<!-- fm-clean-commit-relaunch-handoff -->

Before acting, read $DEST_HANDOFF and follow its No-Mistakes custody next action.
EOF
fi

REPOSITORY_IDENTITY=$(sha256_text "$SOURCE_COMMON")
DESTINATION_BRIEF_IDENTITY=$(sha256_file "$DEST_BRIEF")
HANDOFF_TMP=$(mktemp "$DATA/$DESTINATION/.relaunch-handoff.XXXXXX") || exit 1
jq -n \
  --arg schema fm-clean-commit-relaunch.v1 \
  --arg source "$SOURCE" \
  --arg destination "$DESTINATION" \
  --arg repository_identity "$REPOSITORY_IDENTITY" \
  --arg source_commit "$SOURCE_COMMIT" \
  --arg source_branch "$SOURCE_BRANCH" \
  --arg mode "$MODE" \
  --arg yolo "$YOLO" \
  --arg source_brief_identity "$SOURCE_BRIEF_IDENTITY" \
  --arg destination_brief_identity "$DESTINATION_BRIEF_IDENTITY" \
  --arg pr "$PR" \
  --arg custody "$CUSTODY" \
  --arg run_id "$RUN_ID" \
  --arg run_status "$RUN_STATUS" \
  --arg run_branch "$RUN_BRANCH" \
  --arg run_head "$RUN_HEAD" \
  --arg next_action "$RUN_NEXT_ACTION" \
  '{schema:$schema,source:$source,destination:$destination,repository_identity:$repository_identity,source_commit:$source_commit,source_branch:$source_branch,delivery:{mode:$mode,yolo:$yolo},source_brief_identity:$source_brief_identity,destination_brief_identity:$destination_brief_identity,no_mistakes_custody:{state:$custody,run_id:$run_id,status:$run_status,branch:$run_branch,head:$run_head,next_action:$next_action}} + (if $pr == "" then {} else {pr:$pr} end)' \
  > "$HANDOFF_TMP"
mv -f -- "$HANDOFF_TMP" "$DEST_HANDOFF"
HANDOFF_TMP=
fm_task_inbox_write "$STATE" "$DESTINATION" "Read the preserved-work handoff at $DEST_HANDOFF before acting. Its No-Mistakes custody next action is authoritative." >/dev/null || {
  echo "error: could not publish the destination relaunch-handoff inbox record" >&2
  exit 1
}

SPAWN_ARGS=("$DESTINATION" "$PROJECT" --mode "$MODE" --yolo "$YOLO" --harness "$HARNESS" --backend "$BACKEND" --accepted-clean-commit "$SOURCE_COMMIT" --accepted-clean-commit-source-common "$SOURCE_COMMON")
[ -z "$MODEL" ] || [ "$MODEL" = default ] || SPAWN_ARGS+=(--model "$MODEL")
[ -z "$EFFORT" ] || [ "$EFFORT" = default ] || SPAWN_ARGS+=(--effort "$EFFORT")
[ -z "$PREWALK" ] || SPAWN_ARGS+=(--prewalk-into "$PREWALK")
[ "$ALLOW_PROJECT_OMP_EXTENSIONS" -eq 0 ] || SPAWN_ARGS+=(--allow-project-omp-extensions)
FM_CLEAN_COMMIT_RELAUNCH=1 \
  FM_CLEAN_COMMIT_DESTINATION_LOCK_OWNER="${BASHPID:-$$}" \
  "$SCRIPT_DIR/fm-spawn.sh" "${SPAWN_ARGS[@]}"
echo "relaunched $SOURCE as $DESTINATION at $SOURCE_COMMIT"

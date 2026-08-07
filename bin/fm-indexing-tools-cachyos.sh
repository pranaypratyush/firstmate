#!/usr/bin/env bash
# fm-indexing-tools-cachyos.sh - recover a local-only code-indexing stack on CachyOS/Arch.
#
# This file is the single owner of setup mechanics and flags.
# The operator decisions, resource expectations, update policy, and rollback
# sequence live in docs/indexing-tools-cachyos.md.
#
# Usage:
#   fm-indexing-tools-cachyos.sh --action plan|apply|health --project PATH \
#     --ollama-owner arch|upstream --ollama-accel cpu|cuda|rocm|vulkan \
#     --pull-model yes|no --start-ollama yes|no --persist-ollama yes|no \
#     --install-tools yes|no --init none|grepai,codegraph,serena \
#     --ignore-policy defaults|existing --state-policy local-ignored|existing \
#     --serena-language ID [--serena-language ID ...] \
#     --allow-language-downloads yes|no --telemetry off \
#     --benchmark yes|no --health-query QUERY \
#     --mcp-client none|lazy-mcp --mcp-scope print|user \
#     --persistent-grepai-watch no --destructive-rollback no [options]
#
# Apply options:
#   --rollback-manifest PATH       Append a private, operator-chosen recovery record.
#   --install-root PATH            Versioned user-local payloads.
#   --bin-dir PATH                 User-local command symlinks; must already be on PATH.
#   --lazy-mcp-dir PATH            Required for lazy-mcp user registration.
#   --lazy-mcp-generator PATH      Defaults to DIR/structure_generator.
#   --benchmark-query Q=PATH       Repeat exactly five or more times for benchmark=yes.
#   --max-index-seconds N          Hard scratch/canonical indexing bound (default 900).
#   --command-timeout-seconds N    Hard status/search/stop/query bound (default 30).
#   --max-micro-batch-seconds N    Hard 100-chunk cold/warm bound (default 300).
#   --max-embed-request-seconds N  Hard per-request embed bound (default 30).
#   --max-search-ms N               Warm semantic-search median bound (default 2000).
#   --max-incremental-seconds N     Scratch incremental-convergence bound (default 10).
#   --mcp-timeout-seconds N        Hard direct stdio health bound (default 15).
#   --max-ram-percent N            Maximum observed scratch-index RAM delta (default 25).
#   --max-swap-growth-mib N        Maximum benchmark swap growth (default 0).
#   --max-temperature-celsius N    Maximum observed sensor temperature (default 90).
#   --max-load-per-cpu-percent N   Maximum one-minute load per CPU (default 100).
#   --max-watcher-idle-cpu-percent N  Maximum scratch watcher idle CPU (default 5).
#   --min-free-ram-mib N           Pre-mutation MemAvailable floor (default 1024).
#   --min-free-disk-mib N          Pre-mutation project/install free-space floor (default 2048).
# Environment:
#   XDG_RUNTIME_DIR                 Preferred owner-owned mode-0700 directory for the run lock.
#                                   When unset, HOME/.fm-indexing-tools-cachyos-locks is used at mode 0700.
#
# Pinned provenance:
#   grepai v0.35.0 and CodeGraph v1.5.0 use official GitHub release assets
#   and the exact SHA-256 values published in their release metadata.
#   Serena 1.6.1 is installed as an exact PyPI package through uv.
#   Arch-owned Ollama/uv versions are explicitly discovered with pacman -Si;
#   this script never performs pacman -Sy or a partial system upgrade.
#
# Test-only overrides:
#   FM_INDEX_OS_RELEASE replaces /etc/os-release.
#   FM_INDEX_MEMINFO replaces /proc/meminfo.
#   FM_INDEX_LOADAVG replaces /proc/loadavg.
#   FM_INDEX_UNAME_M replaces uname -m.
set -euo pipefail

readonly SCRIPT_NAME=fm-indexing-tools-cachyos.sh
readonly GREPAI_VERSION=0.35.0
readonly CODEGRAPH_VERSION=1.5.0
readonly SERENA_VERSION=1.6.1
readonly OLLAMA_UPSTREAM_VERSION=0.32.6
readonly MODEL_BASE=nomic-embed-text
readonly MODEL_EXPECTED_DIGEST=0a109f422b47e3a30ba2b10eca18548e944e8a23073ee3f3e947efcf3c45e59f
readonly MODEL_EXPECTED_DIMENSIONS=768
readonly MODEL_EXPECTED_BYTES=274302450
readonly MODEL_EXPECTED_QUANTIZATION=F16
readonly OLLAMA_ENDPOINT=http://127.0.0.1:11434
readonly GREPAI_MAX_ASSET_BYTES=20000000
readonly CODEGRAPH_MAX_ASSET_BYTES=100000000

die() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

note() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$*"
}

usage() {
  sed -n '2,/^set -euo pipefail$/s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"
}

need_value() {
  [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 requires a value"
}

valid_yes_no() {
  case "$2" in
    yes|no) ;;
    *) die "$1 must be yes or no (got '$2')" ;;
  esac
}

valid_uint() {
  case "$2" in
    ''|*[!0-9]*) die "$1 must be a positive integer (got '$2')" ;;
    0) die "$1 must be greater than zero" ;;
  esac
}

valid_nonnegative_uint() {
  case "$2" in
    ''|*[!0-9]*) die "$1 must be a non-negative integer (got '$2')" ;;
  esac
}

canonical_path() {
  local path=$1
  if command -v realpath >/dev/null 2>&1; then
    realpath -e -- "$path"
  else
    (cd "$path" && pwd -P)
  fi
}

path_has_dir() {
  local needle=$1 dir
  local old_ifs=$IFS
  IFS=:
  for dir in $PATH; do
    [ "$dir" = "$needle" ] && { IFS=$old_ifs; return 0; }
  done
  IFS=$old_ifs
  return 1
}

command_path() {
  command -v "$1" 2>/dev/null || true
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

nearest_existing_parent() {
  local path=$1 parent
  while [ ! -e "$path" ]; do
    parent=$(dirname "$path")
    [ "$parent" != "$path" ] || break
    path=$parent
  done
  printf '%s\n' "$path"
}

version_token() {
  printf '%s\n' "$1" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1
}

contains_component() {
  case ",${INIT_COMPONENTS}," in
    *",$1,"*) return 0 ;;
    *) return 1 ;;
  esac
}

append_manifest() {
  [ -n "${ROLLBACK_MANIFEST:-}" ] || return 0
  printf '%s\n' "$*" >> "$ROLLBACK_MANIFEST"
}

run_privileged() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    command -v sudo >/dev/null 2>&1 || die "sudo is required for the selected Arch package/service mutation"
    sudo "$@"
  fi
}

ACTION=
PROJECT_INPUT=
OLLAMA_OWNER=
OLLAMA_ACCEL=
PULL_MODEL=
START_OLLAMA=
PERSIST_OLLAMA=
INSTALL_TOOLS=
INIT_COMPONENTS=
IGNORE_POLICY=
STATE_POLICY=
ALLOW_LANGUAGE_DOWNLOADS=
TELEMETRY=
BENCHMARK=
HEALTH_QUERY=
MCP_CLIENT=
MCP_SCOPE=
PERSISTENT_GREPAI_WATCH=
DESTRUCTIVE_ROLLBACK=
ROLLBACK_MANIFEST=
LAZY_MCP_DIR=
LAZY_MCP_GENERATOR=
MODEL=nomic-embed-text:latest
MAX_INDEX_SECONDS=900
COMMAND_TIMEOUT_SECONDS=30
MAX_MICRO_BATCH_SECONDS=300
MAX_EMBED_REQUEST_SECONDS=30
MAX_SEARCH_MS=2000
MAX_INCREMENTAL_SECONDS=10
MCP_TIMEOUT_SECONDS=15
MAX_RAM_PERCENT=25
MAX_SWAP_GROWTH_MIB=0
MAX_TEMPERATURE_CELSIUS=90
MAX_LOAD_PER_CPU_PERCENT=100
MAX_WATCHER_IDLE_CPU_PERCENT=5
MIN_FREE_RAM_MIB=1024
MIN_FREE_DISK_MIB=2048
INSTALL_ROOT=${XDG_DATA_HOME:-$HOME/.local/share}/firstmate-indexing-tools
BIN_DIR=${XDG_BIN_HOME:-$HOME/.local/bin}
SERENA_LANGUAGES=()
BENCHMARK_QUERIES=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --action) need_value "$@"; ACTION=$2; shift 2 ;;
    --project) need_value "$@"; PROJECT_INPUT=$2; shift 2 ;;
    --ollama-owner) need_value "$@"; OLLAMA_OWNER=$2; shift 2 ;;
    --ollama-accel) need_value "$@"; OLLAMA_ACCEL=$2; shift 2 ;;
    --model) need_value "$@"; MODEL=$2; shift 2 ;;
    --pull-model) need_value "$@"; PULL_MODEL=$2; shift 2 ;;
    --start-ollama) need_value "$@"; START_OLLAMA=$2; shift 2 ;;
    --persist-ollama) need_value "$@"; PERSIST_OLLAMA=$2; shift 2 ;;
    --install-tools) need_value "$@"; INSTALL_TOOLS=$2; shift 2 ;;
    --init) need_value "$@"; INIT_COMPONENTS=$2; shift 2 ;;
    --ignore-policy) need_value "$@"; IGNORE_POLICY=$2; shift 2 ;;
    --state-policy) need_value "$@"; STATE_POLICY=$2; shift 2 ;;
    --serena-language) need_value "$@"; SERENA_LANGUAGES+=("$2"); shift 2 ;;
    --allow-language-downloads) need_value "$@"; ALLOW_LANGUAGE_DOWNLOADS=$2; shift 2 ;;
    --telemetry) need_value "$@"; TELEMETRY=$2; shift 2 ;;
    --benchmark) need_value "$@"; BENCHMARK=$2; shift 2 ;;
    --benchmark-query) need_value "$@"; BENCHMARK_QUERIES+=("$2"); shift 2 ;;
    --health-query) need_value "$@"; HEALTH_QUERY=$2; shift 2 ;;
    --mcp-client) need_value "$@"; MCP_CLIENT=$2; shift 2 ;;
    --mcp-scope) need_value "$@"; MCP_SCOPE=$2; shift 2 ;;
    --lazy-mcp-dir) need_value "$@"; LAZY_MCP_DIR=$2; shift 2 ;;
    --lazy-mcp-generator) need_value "$@"; LAZY_MCP_GENERATOR=$2; shift 2 ;;
    --persistent-grepai-watch) need_value "$@"; PERSISTENT_GREPAI_WATCH=$2; shift 2 ;;
    --destructive-rollback) need_value "$@"; DESTRUCTIVE_ROLLBACK=$2; shift 2 ;;
    --rollback-manifest) need_value "$@"; ROLLBACK_MANIFEST=$2; shift 2 ;;
    --install-root) need_value "$@"; INSTALL_ROOT=$2; shift 2 ;;
    --bin-dir) need_value "$@"; BIN_DIR=$2; shift 2 ;;
    --max-index-seconds) need_value "$@"; MAX_INDEX_SECONDS=$2; shift 2 ;;
    --command-timeout-seconds) need_value "$@"; COMMAND_TIMEOUT_SECONDS=$2; shift 2 ;;
    --max-micro-batch-seconds) need_value "$@"; MAX_MICRO_BATCH_SECONDS=$2; shift 2 ;;
    --max-embed-request-seconds) need_value "$@"; MAX_EMBED_REQUEST_SECONDS=$2; shift 2 ;;
    --max-search-ms) need_value "$@"; MAX_SEARCH_MS=$2; shift 2 ;;
    --max-incremental-seconds) need_value "$@"; MAX_INCREMENTAL_SECONDS=$2; shift 2 ;;
    --mcp-timeout-seconds) need_value "$@"; MCP_TIMEOUT_SECONDS=$2; shift 2 ;;
    --max-ram-percent) need_value "$@"; MAX_RAM_PERCENT=$2; shift 2 ;;
    --max-swap-growth-mib) need_value "$@"; MAX_SWAP_GROWTH_MIB=$2; shift 2 ;;
    --max-temperature-celsius) need_value "$@"; MAX_TEMPERATURE_CELSIUS=$2; shift 2 ;;
    --max-load-per-cpu-percent) need_value "$@"; MAX_LOAD_PER_CPU_PERCENT=$2; shift 2 ;;
    --max-watcher-idle-cpu-percent) need_value "$@"; MAX_WATCHER_IDLE_CPU_PERCENT=$2; shift 2 ;;
    --min-free-ram-mib) need_value "$@"; MIN_FREE_RAM_MIB=$2; shift 2 ;;
    --min-free-disk-mib) need_value "$@"; MIN_FREE_DISK_MIB=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument '$1' (run --help)" ;;
  esac
done

[ -n "$ACTION" ] || die "--action is required"
[ -n "$PROJECT_INPUT" ] || die "--project is required"
[ -n "$OLLAMA_OWNER" ] || die "--ollama-owner is required"
[ -n "$OLLAMA_ACCEL" ] || die "--ollama-accel is required"
[ -n "$PULL_MODEL" ] || die "--pull-model is required"
[ -n "$START_OLLAMA" ] || die "--start-ollama is required"
[ -n "$PERSIST_OLLAMA" ] || die "--persist-ollama is required"
[ -n "$INSTALL_TOOLS" ] || die "--install-tools is required"
[ -n "$INIT_COMPONENTS" ] || die "--init is required"
[ -n "$IGNORE_POLICY" ] || die "--ignore-policy is required"
[ -n "$STATE_POLICY" ] || die "--state-policy is required"
[ -n "$ALLOW_LANGUAGE_DOWNLOADS" ] || die "--allow-language-downloads is required"
[ -n "$TELEMETRY" ] || die "--telemetry is required"
[ -n "$BENCHMARK" ] || die "--benchmark is required"
[ -n "$HEALTH_QUERY" ] || die "--health-query is required"
[ -n "$MCP_CLIENT" ] || die "--mcp-client is required"
[ -n "$MCP_SCOPE" ] || die "--mcp-scope is required"
[ -n "$PERSISTENT_GREPAI_WATCH" ] || die "--persistent-grepai-watch is required"
[ -n "$DESTRUCTIVE_ROLLBACK" ] || die "--destructive-rollback is required"
[ "${#SERENA_LANGUAGES[@]}" -gt 0 ] || die "at least one --serena-language is required"

case "$ACTION" in plan|apply|health) ;; *) die "--action must be plan, apply, or health" ;; esac
case "$OLLAMA_OWNER" in arch|upstream) ;; *) die "--ollama-owner must be arch or upstream" ;; esac
case "$OLLAMA_ACCEL" in cpu|cuda|rocm|vulkan) ;; *) die "unsupported --ollama-accel '$OLLAMA_ACCEL'" ;; esac
case "$MODEL" in
  nomic-embed-text|nomic-embed-text:latest) MODEL=nomic-embed-text:latest ;;
  *) die "--model must be the pinned nomic-embed-text:latest manifest" ;;
esac
valid_yes_no --pull-model "$PULL_MODEL"
valid_yes_no --start-ollama "$START_OLLAMA"
valid_yes_no --persist-ollama "$PERSIST_OLLAMA"
valid_yes_no --install-tools "$INSTALL_TOOLS"
valid_yes_no --allow-language-downloads "$ALLOW_LANGUAGE_DOWNLOADS"
valid_yes_no --benchmark "$BENCHMARK"
[ "$TELEMETRY" = off ] || die "--telemetry must be off; this recovery kit does not send telemetry"
case "$MCP_CLIENT" in none|lazy-mcp) ;; *) die "--mcp-client must be none or lazy-mcp" ;; esac
case "$MCP_SCOPE" in print|user) ;; *) die "--mcp-scope must be print or user" ;; esac
[ "$PERSISTENT_GREPAI_WATCH" = no ] || die "persistent grepai watching is intentionally unsupported; pass --persistent-grepai-watch no"
[ "$DESTRUCTIVE_ROLLBACK" = no ] || die "destructive rollback is intentionally unsupported; pass --destructive-rollback no"
case "$IGNORE_POLICY" in defaults|existing) ;; *) die "--ignore-policy must be defaults or existing" ;; esac
case "$STATE_POLICY" in local-ignored|existing) ;; *) die "--state-policy must be local-ignored or existing" ;; esac
valid_uint --max-index-seconds "$MAX_INDEX_SECONDS"
valid_uint --command-timeout-seconds "$COMMAND_TIMEOUT_SECONDS"
valid_uint --max-micro-batch-seconds "$MAX_MICRO_BATCH_SECONDS"
valid_uint --max-embed-request-seconds "$MAX_EMBED_REQUEST_SECONDS"
valid_uint --max-search-ms "$MAX_SEARCH_MS"
valid_uint --max-incremental-seconds "$MAX_INCREMENTAL_SECONDS"
valid_uint --mcp-timeout-seconds "$MCP_TIMEOUT_SECONDS"
valid_uint --max-ram-percent "$MAX_RAM_PERCENT"
valid_nonnegative_uint --max-swap-growth-mib "$MAX_SWAP_GROWTH_MIB"
valid_uint --max-temperature-celsius "$MAX_TEMPERATURE_CELSIUS"
valid_uint --max-load-per-cpu-percent "$MAX_LOAD_PER_CPU_PERCENT"
valid_nonnegative_uint --max-watcher-idle-cpu-percent "$MAX_WATCHER_IDLE_CPU_PERCENT"
valid_uint --min-free-ram-mib "$MIN_FREE_RAM_MIB"
valid_uint --min-free-disk-mib "$MIN_FREE_DISK_MIB"
[ "$MAX_RAM_PERCENT" -le 100 ] || die "--max-ram-percent must be at most 100"

case "$INIT_COMPONENTS" in
  none) ;;
  *)
    old_ifs=$IFS
    IFS=,
    read -r -a requested_components <<< "$INIT_COMPONENTS"
    IFS=$old_ifs
    [ "${#requested_components[@]}" -gt 0 ] || die "--init accepts only comma-separated grepai,codegraph,serena or none"
    for component in "${requested_components[@]}"; do
      case "$component" in grepai|codegraph|serena) ;; *) die "--init accepts only comma-separated grepai,codegraph,serena or none" ;; esac
    done
    ;;
esac

for language in "${SERENA_LANGUAGES[@]}"; do
  case "$language" in
    rust|typescript|python|go|java|csharp|cpp|php|ruby) ;;
    *) die "unsupported Serena language '$language'; inspect upstream support before extending this pin" ;;
  esac
done

if [ "$BENCHMARK" = yes ]; then
  [ "${#BENCHMARK_QUERIES[@]}" -ge 5 ] || die "--benchmark yes requires at least five --benchmark-query QUERY=EXPECTED_PATH entries"
  for benchmark_case in "${BENCHMARK_QUERIES[@]}"; do
    case "$benchmark_case" in *=?*) ;; *) die "benchmark query '$benchmark_case' must be QUERY=EXPECTED_PATH" ;; esac
  done
fi

if [ "$MCP_CLIENT" = none ] && [ "$MCP_SCOPE" != print ]; then
  die "--mcp-client none requires --mcp-scope print"
fi
if [ "$MCP_CLIENT" = lazy-mcp ] && [ "$MCP_SCOPE" = user ] && [ -z "$LAZY_MCP_DIR" ]; then
  die "lazy-mcp user registration requires --lazy-mcp-dir"
fi
if [ "$MCP_SCOPE" = user ] && [ "$ACTION" != apply ]; then
  die "--mcp-scope user requires --action apply; use --mcp-scope print for a read-only plan"
fi
if [ "$ACTION" = apply ] && [ -z "$ROLLBACK_MANIFEST" ]; then
  die "--action apply requires --rollback-manifest"
fi
if [ "$ACTION" = health ] && { [ "$INSTALL_TOOLS" != no ] || [ "$PULL_MODEL" != no ] || [ "$START_OLLAMA" != no ] || [ "$PERSIST_OLLAMA" != no ]; }; then
  die "--action health is read-only and requires install/pull/start/persist choices all set to no"
fi
if [ "$PERSIST_OLLAMA" = yes ] && [ "$START_OLLAMA" != yes ]; then
  die "--persist-ollama yes requires --start-ollama yes"
fi
if [ "$OLLAMA_OWNER" = upstream ] && [ "$INSTALL_TOOLS" = yes ]; then
  die "fresh upstream-owned Ollama installation is not automated because its bundle owns system paths; install pinned v${OLLAMA_UPSTREAM_VERSION} separately, then rerun with --install-tools no"
fi
if [ "$OLLAMA_OWNER" = upstream ] && [ "$OLLAMA_ACCEL" != cpu ]; then
  die "this kit validates upstream-owned Ollama only in CPU mode; use the Arch owner for an explicitly supported split accelerator package"
fi

for prerequisite in awk curl df find findmnt flock git grep iconv jq ln mktemp pacman ps realpath sed setsid sha256sum sort ss stat systemctl tar timeout; do
  command -v "$prerequisite" >/dev/null 2>&1 || die "missing prerequisite '$prerequisite'; install it before rerunning"
done

OS_RELEASE=${FM_INDEX_OS_RELEASE:-/etc/os-release}
[ -r "$OS_RELEASE" ] || die "cannot read OS release metadata at $OS_RELEASE"
os_id=$(sed -n 's/^ID=//p' "$OS_RELEASE" | tr -d '"' | head -n 1)
os_like=$(sed -n 's/^ID_LIKE=//p' "$OS_RELEASE" | tr -d '"' | head -n 1)
case " $os_id $os_like " in
  *' cachyos '*|*' arch '*) ;;
  *) die "unsupported OS '$os_id' (ID_LIKE='$os_like'); this script supports CachyOS/Arch only" ;;
esac

machine_arch=${FM_INDEX_UNAME_M:-$(uname -m)}
case "$machine_arch" in
  x86_64|amd64) asset_arch=amd64; codegraph_arch=x64 ;;
  aarch64|arm64) asset_arch=arm64; codegraph_arch=arm64 ;;
  *) die "unsupported architecture '$machine_arch'; expected x86_64 or arm64" ;;
esac

PROJECT=$(canonical_path "$PROJECT_INPUT") || die "project path does not exist: $PROJECT_INPUT"
[ -d "$PROJECT" ] || die "project path is not a directory: $PROJECT"
case "$PROJECT" in *$'\n'*|*$'\t'*) die "project paths containing tabs or newlines are unsupported" ;; esac
git_root=$(git -C "$PROJECT" rev-parse --show-toplevel 2>/dev/null) || die "project is not a Git worktree: $PROJECT"
git_root=$(canonical_path "$git_root")
[ "$git_root" = "$PROJECT" ] || die "--project must name the Git worktree root exactly (resolved root: $git_root)"
git -C "$PROJECT" rev-parse --verify HEAD >/dev/null 2>&1 || die "project has no committed HEAD for a scratch benchmark"

INSTALL_ROOT=$(realpath -m -- "$INSTALL_ROOT")
BIN_DIR=$(realpath -m -- "$BIN_DIR")
if [ "$ACTION" != plan ]; then
  path_has_dir "$BIN_DIR" || die "--bin-dir '$BIN_DIR' is not on PATH; add it before mutation so ownership checks are deterministic"
fi

if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
  LOCK_ROOT=$XDG_RUNTIME_DIR
  LOCK_FILE_NAME=fm-indexing-tools-cachyos.lock
else
  case "$HOME" in /*) ;; *) die "HOME must be absolute when XDG_RUNTIME_DIR is unset: $HOME" ;; esac
  [ -d "$HOME" ] && [ ! -L "$HOME" ] || die "HOME must be a real directory when XDG_RUNTIME_DIR is unset: $HOME"
  home_owner=$(stat -c %u -- "$HOME") || die "could not inspect HOME ownership: $HOME"
  [ "$home_owner" -eq "$EUID" ] || die "HOME owner $home_owner does not match effective user $EUID: $HOME"
  LOCK_ROOT=$HOME/.fm-indexing-tools-cachyos-locks
  LOCK_FILE_NAME=recovery.lock
  if [ ! -e "$LOCK_ROOT" ]; then
    (umask 077; mkdir -- "$LOCK_ROOT") 2>/dev/null || [ -d "$LOCK_ROOT" ] \
      || die "could not create owner-private fallback lock directory: $LOCK_ROOT"
  fi
fi
case "$LOCK_ROOT" in
  /*) ;;
  *) die "XDG_RUNTIME_DIR must be an absolute path: $LOCK_ROOT" ;;
esac
case "$LOCK_ROOT" in *$'\n'*|*$'\t'*) die "XDG_RUNTIME_DIR paths containing tabs or newlines are unsupported" ;; esac
[ -d "$LOCK_ROOT" ] && [ ! -L "$LOCK_ROOT" ] || die "XDG_RUNTIME_DIR must be a real directory, not a symlink: $LOCK_ROOT"
lock_root_owner=$(stat -c %u -- "$LOCK_ROOT") || die "could not inspect XDG_RUNTIME_DIR ownership: $LOCK_ROOT"
lock_root_mode=$(stat -c %a -- "$LOCK_ROOT") || die "could not inspect XDG_RUNTIME_DIR mode: $LOCK_ROOT"
[ "$lock_root_owner" -eq "$EUID" ] || die "XDG_RUNTIME_DIR owner $lock_root_owner does not match effective user $EUID: $LOCK_ROOT"
[ "$lock_root_mode" = 700 ] || die "XDG_RUNTIME_DIR must have mode 0700, observed $lock_root_mode: $LOCK_ROOT"

LOCK_FILE="$LOCK_ROOT/$LOCK_FILE_NAME"
[ ! -L "$LOCK_FILE" ] || die "recovery lock path is an unsafe symlink: $LOCK_FILE"
if [ ! -e "$LOCK_FILE" ]; then
  (umask 077; set -o noclobber; : > "$LOCK_FILE") 2>/dev/null || [ -e "$LOCK_FILE" ] \
    || die "could not create the private recovery lock: $LOCK_FILE"
fi
[ ! -L "$LOCK_FILE" ] && [ -f "$LOCK_FILE" ] || die "recovery lock path is not a safe regular file: $LOCK_FILE"
lock_file_owner=$(stat -c %u -- "$LOCK_FILE") || die "could not inspect recovery lock ownership: $LOCK_FILE"
lock_file_mode=$(stat -c %a -- "$LOCK_FILE") || die "could not inspect recovery lock mode: $LOCK_FILE"
[ "$lock_file_owner" -eq "$EUID" ] || die "recovery lock owner $lock_file_owner does not match effective user $EUID: $LOCK_FILE"
[ "$lock_file_mode" = 600 ] || die "recovery lock must have mode 0600, observed $lock_file_mode: $LOCK_FILE"
exec 9<>"$LOCK_FILE"
flock -n 9 || die "another indexing recovery run holds $LOCK_FILE"

MEMINFO=${FM_INDEX_MEMINFO:-/proc/meminfo}
LOADAVG=${FM_INDEX_LOADAVG:-/proc/loadavg}
mem_total_kib=$(awk '/^MemTotal:/ {print $2; exit}' "$MEMINFO")
mem_available_kib=$(awk '/^MemAvailable:/ {print $2; exit}' "$MEMINFO")
swap_total_kib=$(awk '/^SwapTotal:/ {print $2; exit}' "$MEMINFO")
swap_free_kib=$(awk '/^SwapFree:/ {print $2; exit}' "$MEMINFO")
[ -n "$mem_total_kib" ] && [ -n "$mem_available_kib" ] && [ -n "$swap_total_kib" ] && [ -n "$swap_free_kib" ] \
  || die "could not read RAM/swap observations from $MEMINFO"
project_free_kib=$(df -Pk "$PROJECT" | awk 'NR==2 {print $4}')
install_parent=$(nearest_existing_parent "$(dirname "$INSTALL_ROOT")")
install_free_kib=$(df -Pk "$install_parent" | awk 'NR==2 {print $4}')
min_free_ram_kib=$((MIN_FREE_RAM_MIB * 1024))
min_free_disk_kib=$((MIN_FREE_DISK_MIB * 1024))
[ "$mem_available_kib" -ge "$min_free_ram_kib" ] || die "insufficient available RAM: $((mem_available_kib / 1024)) MiB observed, ${MIN_FREE_RAM_MIB} MiB required"
[ "$project_free_kib" -ge "$min_free_disk_kib" ] || die "insufficient project filesystem space: $((project_free_kib / 1024)) MiB observed, ${MIN_FREE_DISK_MIB} MiB required"
[ "$install_free_kib" -ge "$min_free_disk_kib" ] || die "insufficient install filesystem space: $((install_free_kib / 1024)) MiB observed, ${MIN_FREE_DISK_MIB} MiB required"

candidate_file=$(mktemp "${TMPDIR:-/tmp}/fm-index-candidates.XXXXXX")
cleanup_files=()
cleanup_files+=("$candidate_file")
LAZY_TRANSACTION_ACTIVE=0
LAZY_BACKUPS=()
LAZY_TARGETS=()
LAZY_CREATED_DIRS=()
PLANNED_STATE_NAMES=()
PLANNED_STATE_PATHS=()
declare -A INITIALIZER_COMPLETE=()
watch_command_pid=
watch_command_starttime=
watch_command_pgid=

process_starttime() {
  local pid=$1 line fields
  local -a stat_fields=()
  [ -r "/proc/$pid/stat" ] || return 1
  IFS= read -r line < "/proc/$pid/stat" || return 1
  fields=${line##*) }
  # After removing PID and comm, starttime (field 22) is field 20.
  read -r -a stat_fields <<< "$fields"
  [ "${#stat_fields[@]}" -ge 20 ] || return 1
  printf '%s\n' "${stat_fields[19]}"
}

record_watch_command() {
  watch_command_pid=$1
  watch_command_starttime=$(process_starttime "$watch_command_pid") \
    || die "could not generation-bind scratch watch command PID $watch_command_pid"
  watch_command_pgid=$(ps -o pgid= -p "$watch_command_pid" 2>/dev/null | tr -d ' ')
  [ "$watch_command_pgid" = "$watch_command_pid" ] \
    || die "scratch watch command did not enter its required private process group"
}

clear_watch_command() {
  watch_command_pid=
  watch_command_starttime=
  watch_command_pgid=
}

terminate_watch_command() {
  local current_starttime='' current_pgid='' member
  local -a group_members=()
  [ -n "$watch_command_pid" ] || return 0
  current_starttime=$(process_starttime "$watch_command_pid" 2>/dev/null || true)
  current_pgid=$(ps -o pgid= -p "$watch_command_pid" 2>/dev/null | tr -d ' ')
  if [ -n "$current_starttime" ] && [ "$current_starttime" = "$watch_command_starttime" ] \
    && [ "$current_pgid" = "$watch_command_pgid" ] && [ "$watch_command_pgid" = "$watch_command_pid" ]; then
    mapfile -t group_members < <(ps -eo pid=,pgid= | awk -v pgid="$watch_command_pgid" '$2 == pgid {print $1}')
    for member in "${group_members[@]}"; do
      kill -TERM "$member" 2>/dev/null || true
    done
    wait "$watch_command_pid" 2>/dev/null || true
  fi
  clear_watch_command
}

cleanup() {
  local exit_status=$? path index restore_tmp name state_path
  trap - EXIT INT TERM
  if [ "$LAZY_TRANSACTION_ACTIVE" -eq 1 ]; then
    for ((index = 0; index < ${#LAZY_BACKUPS[@]}; index++)); do
      path=${LAZY_TARGETS[$index]}
      restore_tmp="$path.fm-indexing-restore-$$"
      cp -p -- "${LAZY_BACKUPS[$index]}" "$restore_tmp" 2>/dev/null && mv -f -- "$restore_tmp" "$path" 2>/dev/null || true
    done
    for path in "${LAZY_CREATED_DIRS[@]}"; do
      rm -rf -- "$path" 2>/dev/null || true
    done
  fi
  terminate_watch_command
  if [ "${SCRATCH_WATCH_STARTED:-0}" -eq 1 ] && [ -d "${SCRATCH_DIR:-}" ] && [ -x "${GREPAI_BIN:-}" ]; then
    (cd "$SCRATCH_DIR" && timeout --kill-after=5s "$COMMAND_TIMEOUT_SECONDS" "$GREPAI_BIN" watch --stop >/dev/null 2>&1) || true
  fi
  if [ "${PROJECT_WATCH_STARTED:-0}" -eq 1 ] && [ -x "${GREPAI_BIN:-}" ]; then
    (cd "$PROJECT" && timeout --kill-after=5s "$COMMAND_TIMEOUT_SECONDS" "$GREPAI_BIN" watch --stop >/dev/null 2>&1) || true
  fi
  if [ "$exit_status" -ne 0 ]; then
    for ((index = 0; index < ${#PLANNED_STATE_NAMES[@]}; index++)); do
      name=${PLANNED_STATE_NAMES[$index]}
      state_path=${PLANNED_STATE_PATHS[$index]}
      if [ -e "$state_path" ] && [ -z "${INITIALIZER_COMPLETE[$name]:-}" ]; then
        append_manifest "partial_project_state=$state_path initializer=$name operator_review_required=yes"
      fi
    done
  fi
  if [ "${MODEL_LOADED_BY_RUN:-0}" -eq 1 ] && command -v ollama >/dev/null 2>&1; then
    ollama stop "$MODEL" >/dev/null 2>&1 || true
  fi
  if [ "${OLLAMA_SERVICE_STARTED:-0}" -eq 1 ] && [ "$PERSIST_OLLAMA" = no ]; then
    run_privileged systemctl stop ollama >/dev/null 2>&1 || true
  fi
  for path in "${cleanup_files[@]}"; do
    [ -e "$path" ] && rm -rf -- "$path"
  done
  return "$exit_status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

is_supported_extension() {
  case "$1" in
    go|js|ts|jsx|tsx|py|rb|java|c|cpp|cc|h|hpp|cs|php|rs|swift|kt|scala|vue|svelte|html|css|scss|less|sql|sh|bash|zsh|yaml|yml|json|xml|md|txt|toml|ini|cfg|conf|env|lua|r|dart|ex|exs|erl|clj|hs|ml|fs|elm|nim|zig|proto|tf|hcl|pas|dpr) return 0 ;;
    *) return 1 ;;
  esac
}

is_default_ignored_path() {
  case "/$1/" in
    */.git/*|*/.grepai/*|*/node_modules/*|*/vendor/*|*/bin/*|*/dist/*|*/__pycache__/*|*/.venv/*|*/venv/*|*/.idea/*|*/.vscode/*|*/target/*|*/.zig-cache/*|*/zig-out/*|*/qdrant_storage/*) return 0 ;;
    *) return 1 ;;
  esac
}

validate_local_exclude_path() {
  local exclude_parent exclude_owner parent_owner
  GIT_EXCLUDE_FILE=
  [ "$STATE_POLICY" = local-ignored ] || return 0
  [ "$INIT_COMPONENTS" != none ] || return 0
  GIT_EXCLUDE_FILE=$(git -C "$PROJECT" rev-parse --git-path info/exclude) \
    || die "Git could not resolve the canonical local exclude for $PROJECT"
  case "$GIT_EXCLUDE_FILE" in /*) ;; *) GIT_EXCLUDE_FILE=$PROJECT/$GIT_EXCLUDE_FILE ;; esac
  exclude_parent=$(dirname "$GIT_EXCLUDE_FILE")
  [ -d "$exclude_parent" ] && [ ! -L "$exclude_parent" ] \
    || die "Git info directory must be a real directory: $exclude_parent"
  parent_owner=$(stat -c %u -- "$exclude_parent" 2>/dev/null || true)
  [ "$parent_owner" = "$EUID" ] || die "Git info directory must be owner-owned: $exclude_parent"
  if [ -e "$GIT_EXCLUDE_FILE" ] || [ -L "$GIT_EXCLUDE_FILE" ]; then
    [ ! -L "$GIT_EXCLUDE_FILE" ] \
      || die "Git info/exclude must be an owner-owned regular file: $GIT_EXCLUDE_FILE"
    exclude_owner=$(stat -c %u -- "$GIT_EXCLUDE_FILE" 2>/dev/null || true)
    [ -f "$GIT_EXCLUDE_FILE" ] && [ "$exclude_owner" = "$EUID" ] \
      || die "Git info/exclude must be an owner-owned regular file: $GIT_EXCLUDE_FILE"
  fi
}

candidate_count=0
candidate_bytes=0
oversize_count=0
while IFS= read -r -d '' rel; do
  case "$rel" in *$'\n'*|*$'\t'*) die "project file paths containing tabs or newlines are unsupported: $rel" ;; esac
  is_default_ignored_path "$rel" && continue
  git -C "$PROJECT" check-ignore --quiet --no-index -- "$rel" 2>/dev/null && continue
  if [ "$IGNORE_POLICY" = existing ]; then
    git -C "$PROJECT" -c "core.excludesFile=$PROJECT/.grepaiignore" check-ignore --quiet --no-index -- "$rel" 2>/dev/null && continue
  fi
  lower=$(printf '%s' "$rel" | tr '[:upper:]' '[:lower:]')
  case "$lower" in *.min.js|*.min.css|*.bundle.js|*.bundle.css) continue ;; esac
  ext=${lower##*.}
  [ "$ext" != "$lower" ] || continue
  is_supported_extension "$ext" || continue
  [ ! -L "$PROJECT/$rel" ] \
    || die "tracked source is not a regular in-worktree file and will not be read: $rel (symbolic link)"
  if [ ! -f "$PROJECT/$rel" ]; then
    file_type=$(stat -c %F -- "$PROJECT/$rel" 2>/dev/null || true)
    die "tracked source is not a regular in-worktree file and will not be read: $rel ($file_type)"
  fi
  size=$(stat -c %s "$PROJECT/$rel" 2>/dev/null || printf 0)
  if [ "$size" -gt 1048576 ]; then
    oversize_count=$((oversize_count + 1))
    continue
  fi
  LC_ALL=C grep -Iq '' "$PROJECT/$rel" || continue
  iconv -f UTF-8 -t UTF-8 "$PROJECT/$rel" >/dev/null 2>&1 || continue
  printf '%s\t%s\n' "$ext" "$rel" >> "$candidate_file"
  candidate_count=$((candidate_count + 1))
  candidate_bytes=$((candidate_bytes + size))
done < <(git -C "$PROJECT" ls-files -co --exclude-standard -z)

detected_languages=()
for detection in 'rust:rs' 'typescript:ts,tsx,js,jsx' 'python:py' 'go:go' 'java:java' 'csharp:cs' 'cpp:c,cc,cpp,h,hpp' 'php:php' 'ruby:rb'; do
  language=${detection%%:*}
  extensions=${detection#*:}
  matched=0
  old_ifs=$IFS
  IFS=,
  for ext in $extensions; do
    if awk -F '\t' -v ext="$ext" '$1 == ext {found=1; exit} END {exit !found}' "$candidate_file"; then
      matched=1
      break
    fi
  done
  IFS=$old_ifs
  [ "$matched" -eq 1 ] && detected_languages+=("$language")
done

for detected in "${detected_languages[@]}"; do
  selected=0
  for language in "${SERENA_LANGUAGES[@]}"; do
    [ "$language" = "$detected" ] && selected=1
  done
  [ "$selected" -eq 1 ] || die "detected Serena language '$detected' is not selected; add --serena-language $detected or adjust the explicit project scope"
done

if [ "$IGNORE_POLICY" = existing ] && [ ! -f "$PROJECT/.grepaiignore" ]; then
  die "--ignore-policy existing requires $PROJECT/.grepaiignore"
fi

for state_dir in .grepai .codegraph .serena; do
  if [ -L "$PROJECT/$state_dir" ]; then
    die "ambiguous existing project state: $PROJECT/$state_dir is a symlink"
  fi
done

grepai_config_scalar() {
  local key=$1 file=$2
  awk -v key="$key" '
    BEGIN { pattern = "^[[:space:]]*" key "[[:space:]]*:" }
    $0 ~ pattern {
      count++
      value = $0
      sub(pattern, "", value)
      sub(/[[:space:]]+#.*$/, "", value)
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      if ((substr(value, 1, 1) == "\"" && substr(value, length(value), 1) == "\"") ||
          (substr(value, 1, 1) == "\047" && substr(value, length(value), 1) == "\047")) {
        value = substr(value, 2, length(value) - 2)
      }
    }
    END {
      if (count != 1 || value == "") exit 1
      print value
    }
  ' "$file"
}

validate_grepai_config() {
  local root=$1 context=$2 config grepai_provider grepai_model grepai_backend grepai_endpoint grepai_endpoint_port
  config=$root/.grepai/config.yaml
  [ -f "$config" ] && [ ! -L "$config" ] || die "$context grepai state has no regular config.yaml: $root/.grepai"
  grepai_provider=$(grepai_config_scalar provider "$config") \
    || die "$context grepai config must contain exactly one active non-empty provider scalar"
  grepai_model=$(grepai_config_scalar model "$config") \
    || die "$context grepai config must contain exactly one active non-empty model scalar"
  grepai_backend=$(grepai_config_scalar backend "$config") \
    || die "$context grepai config must contain exactly one active non-empty backend scalar"
  grepai_endpoint=$(grepai_config_scalar endpoint "$config") \
    || die "$context grepai config must contain exactly one active non-empty endpoint scalar"
  [ "$grepai_provider" = ollama ] || die "$context grepai provider is '$grepai_provider', expected local Ollama"
  [ "$grepai_model" = "$MODEL" ] || die "$context grepai model is '$grepai_model', expected '$MODEL'"
  [ "$grepai_backend" = gob ] || die "$context grepai backend is '$grepai_backend', expected local GOB"
  case "$grepai_endpoint" in
    http://127.0.0.1:*) grepai_endpoint_port=${grepai_endpoint#http://127.0.0.1:} ;;
    http://localhost:*) grepai_endpoint_port=${grepai_endpoint#http://localhost:} ;;
    *) die "$context grepai endpoint is not an explicit loopback Ollama URL: $grepai_endpoint" ;;
  esac
  case "$grepai_endpoint_port" in
    ''|*[!0-9]*) die "$context grepai endpoint is not an explicit loopback Ollama URL: $grepai_endpoint" ;;
  esac
  [ "$grepai_endpoint_port" -ge 1 ] && [ "$grepai_endpoint_port" -le 65535 ] \
    || die "$context grepai endpoint has an invalid loopback port: $grepai_endpoint"
}

write_and_validate_fresh_grepai_endpoint() {
  local root=$1 config active_endpoint_count
  config=$root/.grepai/config.yaml
  [ -f "$config" ] && [ ! -L "$config" ] || die "fresh grepai init did not create a regular config.yaml: $config"
  active_endpoint_count=$(awk '/^[[:space:]]*endpoint[[:space:]]*:/ {count++} END {print count+0}' "$config")
  case "$active_endpoint_count" in
    0) printf 'endpoint: %s\n' "$OLLAMA_ENDPOINT" >> "$config" ;;
    1) ;;
    *) die "fresh grepai config contains ambiguous duplicate endpoint fields: $config" ;;
  esac
  validate_grepai_config "$root" fresh
}

if [ -d "$PROJECT/.grepai" ]; then
  validate_grepai_config "$PROJECT" existing
fi
if [ -d "$PROJECT/.codegraph" ] && [ ! -f "$PROJECT/.codegraph/codegraph.db" ]; then
  die "existing CodeGraph state has no codegraph.db; choose repair or rebuild outside this non-destructive run"
fi

filesystem_type=$(findmnt -no FSTYPE -T "$PROJECT" 2>/dev/null || true)
case "$filesystem_type" in
  nfs*|cifs|smb*|fuse.sshfs) die "project filesystem '$filesystem_type' is unsupported for CodeGraph SQLite WAL state" ;;
  '') die "could not determine the project filesystem type" ;;
esac

if [ "$STATE_POLICY" = existing ]; then
  for component in grepai codegraph serena; do
    if contains_component "$component" && [ ! -d "$PROJECT/.$component" ]; then
      die "--state-policy existing requires $PROJECT/.$component for requested component '$component'"
    fi
  done
fi

if [ -d "$PROJECT/.serena" ]; then
  [ -f "$PROJECT/.serena/project.yml" ] || die "existing Serena state has no project.yml: $PROJECT/.serena"
  for language in "${SERENA_LANGUAGES[@]}"; do
    grep -F "$language" "$PROJECT/.serena/project.yml" >/dev/null || die "existing Serena project.yml does not include selected language '$language'"
  done
fi

dirty_count=$(git -C "$PROJECT" status --porcelain=v1 | wc -l | tr -d ' ')
if [ "$ACTION" = apply ] && [ "$dirty_count" -gt 0 ] && { [ "$BENCHMARK" = yes ] || [ "$INIT_COMPONENTS" != none ]; }; then
  die "project has $dirty_count dirty entries; commit/stash by operator choice or use a clean worktree so the HEAD benchmark matches canonical indexing"
fi
validate_local_exclude_path
load_observation=$(cat "$LOADAVG" 2>/dev/null || printf unavailable)
cpu_threads=$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)
case "$cpu_threads" in ''|*[!0-9]*|0) die "could not determine online CPU threads" ;; esac
note "platform os=$os_id arch=$machine_arch project=$PROJECT"
note "resources cpu_threads=$cpu_threads ram_total_mib=$((mem_total_kib / 1024)) ram_available_mib=$((mem_available_kib / 1024)) swap_total_mib=$((swap_total_kib / 1024)) swap_free_mib=$((swap_free_kib / 1024)) project_free_mib=$((project_free_kib / 1024)) install_free_mib=$((install_free_kib / 1024)) load='$load_observation'"
note "grepai_candidates files=$candidate_count bytes=$candidate_bytes over_1mib=$oversize_count ignore_policy=$IGNORE_POLICY"
note "project_state dirty_entries=$dirty_count grepai=$([ -d "$PROJECT/.grepai" ] && printf present || printf absent) codegraph=$([ -d "$PROJECT/.codegraph" ] && printf present || printf absent) serena=$([ -d "$PROJECT/.serena" ] && printf present || printf absent)"
note "decisions ollama_owner=$OLLAMA_OWNER accel=$OLLAMA_ACCEL model=$MODEL pull=$PULL_MODEL start=$START_OLLAMA persist=$PERSIST_OLLAMA install=$INSTALL_TOOLS init=$INIT_COMPONENTS benchmark=$BENCHMARK mcp=$MCP_CLIENT/$MCP_SCOPE watcher=no destructive_rollback=no telemetry=off"

arch_ollama_package=
case "$OLLAMA_ACCEL" in
  cpu) arch_ollama_package=ollama ;;
  cuda)
    arch_ollama_package=ollama-cuda
    command -v nvidia-smi >/dev/null 2>&1 || die "CUDA selected but nvidia-smi is unavailable"
    ;;
  rocm)
    arch_ollama_package=ollama-rocm
    command -v rocminfo >/dev/null 2>&1 || die "ROCm selected but rocminfo is unavailable"
    ;;
  vulkan)
    arch_ollama_package=ollama-vulkan
    command -v vulkaninfo >/dev/null 2>&1 || die "Vulkan selected but vulkaninfo is unavailable"
    ;;
esac

ollama_path=$(command_path ollama)
if [ -n "$ollama_path" ]; then
  if pacman -Qo "$ollama_path" >/dev/null 2>&1; then observed_ollama_owner=arch; else observed_ollama_owner=upstream; fi
  [ "$observed_ollama_owner" = "$OLLAMA_OWNER" ] || die "Ollama owner conflict: '$ollama_path' is $observed_ollama_owner-owned but --ollama-owner is $OLLAMA_OWNER"
  observed_ollama_version=$(version_token "$("$ollama_path" --version 2>/dev/null || true)")
  [ -n "$observed_ollama_version" ] || die "could not determine Ollama version from $ollama_path"
  if [ "$OLLAMA_OWNER" = upstream ] && [ "$observed_ollama_version" != "$OLLAMA_UPSTREAM_VERSION" ]; then
    die "upstream Ollama version '$observed_ollama_version' conflicts with the validated pin '$OLLAMA_UPSTREAM_VERSION'"
  fi
  note "ollama_binary path=$ollama_path version=$observed_ollama_version owner=$observed_ollama_owner"
  if [ "$OLLAMA_OWNER" = arch ] && [ "$OLLAMA_ACCEL" != cpu ]; then
    pacman -Q "$arch_ollama_package" >/dev/null 2>&1 || die "selected accelerator package '$arch_ollama_package' is not installed"
  fi
elif [ "$INSTALL_TOOLS" = no ]; then
  die "Ollama is missing and --install-tools no forbids installation"
fi

service_active_before=no
service_enabled_before=no
systemctl is-active --quiet ollama && service_active_before=yes || true
systemctl is-enabled --quiet ollama && service_enabled_before=yes || true
fragment=$(systemctl show -p FragmentPath --value ollama 2>/dev/null || true)
if [ -n "$fragment" ]; then
  if pacman -Qo "$fragment" >/dev/null 2>&1; then observed_service_owner=arch; else observed_service_owner=upstream; fi
  [ "$observed_service_owner" = "$OLLAMA_OWNER" ] || die "Ollama service owner conflict: '$fragment' is $observed_service_owner-owned but the binary owner choice is $OLLAMA_OWNER"
  note "ollama_service fragment=$fragment owner=$observed_service_owner active_before=$service_active_before enabled_before=$service_enabled_before"
elif [ "$START_OLLAMA" = yes ] && [ -n "$ollama_path" ]; then
  die "systemctl cannot resolve the existing Ollama service unit required by --start-ollama yes"
fi

if [ "$INSTALL_TOOLS" = yes ] && [ "$OLLAMA_OWNER" = arch ] && [ -z "$ollama_path" ]; then
  planned_ollama_version=$(pacman -Si "$arch_ollama_package" 2>/dev/null | sed -n 's/^Version[[:space:]]*:[[:space:]]*//p' | head -n 1)
  [ -n "$planned_ollama_version" ] || die "Arch repository package '$arch_ollama_package' is unavailable for $machine_arch; perform a deliberate full system upgrade or choose a supported state"
  note "Arch repository discovered $arch_ollama_package=$planned_ollama_version"
fi
uv_path_preflight=$(command_path uv)
if [ "$INSTALL_TOOLS" = yes ]; then
  if [ -n "$uv_path_preflight" ]; then
    pacman -Qo "$uv_path_preflight" >/dev/null 2>&1 || die "uv owner conflict: '$uv_path_preflight' is not Arch-package-owned"
  else
    planned_uv_version=$(pacman -Si uv 2>/dev/null | sed -n 's/^Version[[:space:]]*:[[:space:]]*//p' | head -n 1)
    [ -n "$planned_uv_version" ] || die "Arch repository metadata for uv is unavailable; perform a deliberate full system upgrade separately"
    note "Arch repository discovered uv=$planned_uv_version"
  fi
fi

case "${OLLAMA_HOST:-}" in
  ''|127.0.0.1|127.0.0.1:*|localhost|localhost:*|http://127.0.0.1:*|http://localhost:*) ;;
  *) die "OLLAMA_HOST must be loopback-only for this recovery kit (got '$OLLAMA_HOST')" ;;
esac

listener_snapshot=$(ss -ltnH 2>/dev/null) || die "ss could not inventory TCP listeners; refusing to continue"
nonlocal_listener=$(printf '%s\n' "$listener_snapshot" | awk '$4 ~ /:11434$/ && $4 !~ /^(127\.0\.0\.1|\[::1\]|localhost):/ {print $4; exit}')
[ -z "$nonlocal_listener" ] || die "port 11434 is exposed beyond loopback at $nonlocal_listener"

GREPAI_DEST="$INSTALL_ROOT/grepai/v$GREPAI_VERSION/grepai"
CODEGRAPH_DEST="$INSTALL_ROOT/codegraph/v$CODEGRAPH_VERSION/bin/codegraph"
SERENA_TOOL_DIR="$INSTALL_ROOT/uv-tools"
SERENA_HOME_DIR="$INSTALL_ROOT/serena-home"
GREPAI_BIN=$(command_path grepai)
CODEGRAPH_BIN=$(command_path codegraph)
SERENA_BIN=$(command_path serena)

if [ "$INSTALL_TOOLS" = no ]; then
  [ -x "$GREPAI_BIN" ] || die "grepai is missing and --install-tools no forbids installation"
  [ -x "$CODEGRAPH_BIN" ] || die "CodeGraph is missing and --install-tools no forbids installation"
  [ -x "$SERENA_BIN" ] || die "Serena is missing and --install-tools no forbids installation"
fi

check_tool_conflict() {
  local name=$1 observed=$2 expected_link=$3 expected_dest=$4 version=$5 version_arg=$6 destination_owner
  if [ "$INSTALL_TOOLS" = yes ]; then
    if [ -e "$expected_dest" ] || [ -L "$expected_dest" ]; then
      destination_owner=$(stat -c %u -- "$expected_dest" 2>/dev/null || true)
      [ ! -L "$expected_dest" ] && [ -f "$expected_dest" ] && [ -x "$expected_dest" ] \
        && [ "$destination_owner" = "$EUID" ] \
        || die "$name managed destination is not a proven owner-managed regular executable: $expected_dest"
    fi
    [ ! -L "$expected_link" ] || [ -e "$expected_link" ] || die "$name ownership conflict: $expected_link is a broken symlink"
    if [ -e "$expected_link" ]; then
      link_target=$(canonical_path "$expected_link")
      [ "$link_target" = "$expected_dest" ] || die "$name ownership conflict: $expected_link resolves to $link_target, expected $expected_dest"
    elif [ -n "$observed" ]; then
      die "$name PATH conflict: '$observed' wins before the managed $expected_link; choose a clean --bin-dir or pass --install-tools no"
    fi
  fi
  [ -n "$observed" ] || return 0
  observed=$(canonical_path "$observed")
  if [ "$INSTALL_TOOLS" = yes ]; then
    [ "$observed" = "$expected_dest" ] || die "$name PATH shadowing: '$observed' wins instead of managed '$expected_dest'"
  fi
  observed_version=$(version_token "$("$observed" "$version_arg" 2>/dev/null || true)")
  [ "$observed_version" = "$version" ] || die "$name version conflict: observed '${observed_version:-unknown}', required '$version'"
}

check_tool_conflict grepai "$GREPAI_BIN" "$BIN_DIR/grepai" "$GREPAI_DEST" "$GREPAI_VERSION" version
check_tool_conflict codegraph "$CODEGRAPH_BIN" "$BIN_DIR/codegraph" "$CODEGRAPH_DEST" "$CODEGRAPH_VERSION" --version
if [ -n "$SERENA_BIN" ]; then
  observed_serena_version=$(version_token "$("$SERENA_BIN" --version 2>/dev/null || true)")
  [ "$observed_serena_version" = "$SERENA_VERSION" ] || die "Serena version conflict: observed '${observed_serena_version:-unknown}', required '$SERENA_VERSION'"
  if [ "$INSTALL_TOOLS" = yes ] && [ -e "$BIN_DIR/serena" ]; then
    expected_serena="$SERENA_TOOL_DIR/serena-agent/bin/serena"
    [ "$(canonical_path "$BIN_DIR/serena")" = "$expected_serena" ] || die "Serena ownership conflict at $BIN_DIR/serena"
    [ "$(canonical_path "$SERENA_BIN")" = "$expected_serena" ] || die "Serena PATH shadowing: '$SERENA_BIN' wins instead of '$expected_serena'"
  fi
elif [ "$INSTALL_TOOLS" = yes ] && { [ -e "$BIN_DIR/serena" ] || [ -L "$BIN_DIR/serena" ]; }; then
  die "Serena ownership conflict: $BIN_DIR/serena exists but is not executable"
fi

codegraph_status_is_healthy() {
  jq -e '
    .initialized == true
    and ((.journalMode // "") | ascii_downcase) == "wal"
    and .worktreeMismatch == null
    and .index.state == "complete"
    and .index.pendingRefs == 0
    and .index.reindexRecommended == false
    and ([.pendingChanges[]] | add // 0) == 0
  ' >/dev/null
}

bounded_command() {
  local label=$1 seconds=$2 status
  shift 2
  timeout --kill-after=5s "$seconds" "$@" && return 0
  status=$?
  case "$status" in
    124|137) die "$label exceeded its ${seconds}s hard timeout" ;;
    *) return "$status" ;;
  esac
}

SERENA_HEALTH_CHECKED=0
SERENA_HEALTH_EVIDENCE=
run_serena_health() {
  local context=$1 sandbox
  [ "$SERENA_HEALTH_CHECKED" -eq 0 ] || return 0
  sandbox=$(mktemp -d "${TMPDIR:-/tmp}/fm-serena-health.XXXXXX")
  cleanup_files+=("$sandbox")
  mkdir -p "$sandbox/home" "$sandbox/cache" "$sandbox/state" "$sandbox/serena"
  HOME="$sandbox/home" XDG_CACHE_HOME="$sandbox/cache" XDG_STATE_HOME="$sandbox/state" \
    SERENA_HOME="$sandbox/serena" SERENA_USAGE_REPORTING=false \
    bounded_command "$context Serena health-check" "$MAX_INDEX_SECONDS" "$SERENA_BIN" project health-check "$PROJECT" >/dev/null \
    || die "$context serena index is unhealthy; choose repair or rebuild outside this non-destructive run"
  SERENA_HEALTH_CHECKED=1
  SERENA_HEALTH_EVIDENCE="serena_health_artifacts=sandboxed removed_at_exit=yes"
  if [ -n "${ROLLBACK_MANIFEST:-}" ] && [ -e "$ROLLBACK_MANIFEST" ]; then
    append_manifest "$SERENA_HEALTH_EVIDENCE"
  fi
  return 0
}

if [ "$ACTION" != plan ] && [ "$ALLOW_LANGUAGE_DOWNLOADS" = no ] \
  && { contains_component serena || [ -d "$PROJECT/.serena" ]; }; then
  die "cannot prove Serena dependency resolution is network-free for the selected languages; use --action plan, or pass --allow-language-downloads yes after approving Serena-managed downloads"
fi

if [ "$ACTION" != plan ]; then
  if [ -d "$PROJECT/.grepai" ]; then
    (cd "$PROJECT" && bounded_command "existing grepai status" "$COMMAND_TIMEOUT_SECONDS" "$GREPAI_BIN" status --no-ui) >/dev/null \
      || die "existing grepai index is unhealthy; choose repair or rebuild outside this non-destructive run"
  fi
  if [ -d "$PROJECT/.codegraph" ]; then
    CODEGRAPH_TELEMETRY=0 DO_NOT_TRACK=1 bounded_command "existing CodeGraph status" "$COMMAND_TIMEOUT_SECONDS" "$CODEGRAPH_BIN" status --json "$PROJECT" \
      | codegraph_status_is_healthy \
      || die "existing codegraph index is unhealthy, stale, non-WAL, or mismatched"
  fi
  if [ -d "$PROJECT/.serena" ]; then
    run_serena_health existing
  fi
fi

GREPAI_MCP_BIN=${GREPAI_BIN:-$BIN_DIR/grepai}
CODEGRAPH_MCP_BIN=${CODEGRAPH_BIN:-$BIN_DIR/codegraph}
SERENA_MCP_BIN=${SERENA_BIN:-$BIN_DIR/serena}

json_command() {
  jq -nc --arg command "$1" --argjson args "$2" --argjson env "$3" '{transportType:"stdio",command:$command,args:$args,env:$env}'
}

build_mcp_entries() {
  grepai_entry=$(json_command "$GREPAI_MCP_BIN" "$(jq -nc --arg project "$PROJECT" '["mcp-serve",$project]')" '{}')
  codegraph_entry=$(json_command "$CODEGRAPH_MCP_BIN" "$(jq -nc --arg project "$PROJECT" '["serve","--mcp","--path",$project]')" '{"CODEGRAPH_NO_DAEMON":"1","CODEGRAPH_TELEMETRY":"0","DO_NOT_TRACK":"1"}')
  serena_entry=$(json_command "$SERENA_MCP_BIN" "$(jq -nc --arg project "$PROJECT" '["start-mcp-server","--project",$project,"--context=codex","--enable-web-dashboard","false","--open-web-dashboard","false"]')" "$(jq -nc --arg home "$SERENA_HOME_DIR" '{SERENA_HOME:$home,SERENA_USAGE_REPORTING:"false"}')")
  mcp_entries=$(jq -nc --argjson grepai "$grepai_entry" --argjson codegraph "$codegraph_entry" --argjson serena "$serena_entry" '{grepai:$grepai,codegraph:$codegraph,serena:$serena}')
}
build_mcp_entries

validate_lazy_mcp_state() {
  local file name desired existing runtime_entry generator_entry proxy_type proxy_addr
  LAZY_RUNTIME_CONFIG="$LAZY_MCP_DIR/config.json"
  LAZY_GENERATOR_CONFIG="$LAZY_MCP_DIR/gen_config.json"
  LAZY_HIERARCHY="$LAZY_MCP_DIR/hierarchy"
  LAZY_GENERATOR=${LAZY_MCP_GENERATOR:-$LAZY_MCP_DIR/structure_generator}
  LAZY_CHANGES_NEEDED=0
  [ -f "$LAZY_RUNTIME_CONFIG" ] && [ -f "$LAZY_GENERATOR_CONFIG" ] && [ -d "$LAZY_HIERARCHY" ] \
    && [ -f "$LAZY_HIERARCHY/root.json" ] && [ -x "$LAZY_GENERATOR" ] \
    || die "lazy-mcp directory must contain config.json, gen_config.json, hierarchy/root.json, and an executable structure_generator"
  for file in "$LAZY_RUNTIME_CONFIG" "$LAZY_GENERATOR_CONFIG" "$LAZY_HIERARCHY/root.json"; do
    [ ! -L "$file" ] || die "lazy-mcp refuses symlink-managed config or hierarchy files: $file"
  done
  proxy_type=$(jq -r '.mcpProxy.type // empty' "$LAZY_RUNTIME_CONFIG")
  proxy_addr=$(jq -r '.mcpProxy.addr // empty' "$LAZY_RUNTIME_CONFIG")
  if [ "$proxy_type" != stdio ]; then
    case "$proxy_addr" in 127.0.0.1:*|localhost:*) ;; *) die "lazy-mcp HTTP proxy addr '$proxy_addr' is not loopback-only" ;; esac
  fi
  for file in "$LAZY_RUNTIME_CONFIG" "$LAZY_GENERATOR_CONFIG"; do
    jq -e '.mcpServers | type == "object"' "$file" >/dev/null || die "lazy-mcp config has no object mcpServers: $file"
    for name in grepai codegraph serena; do
      desired=$(printf '%s' "$mcp_entries" | jq -c --arg name "$name" '.[$name]')
      existing=$(jq -c --arg name "$name" '.mcpServers[$name] // empty' "$file")
      if [ -n "$existing" ] && [ "$(printf '%s' "$existing" | jq -S .)" != "$(printf '%s' "$desired" | jq -S .)" ]; then
        die "lazy-mcp entry '$name' conflicts in $file; existing state was not changed"
      fi
      [ -n "$existing" ] || LAZY_CHANGES_NEEDED=1
    done
  done
  for name in grepai codegraph serena; do
    runtime_entry=$(jq -c --arg name "$name" '.mcpServers[$name] // empty' "$LAZY_RUNTIME_CONFIG")
    generator_entry=$(jq -c --arg name "$name" '.mcpServers[$name] // empty' "$LAZY_GENERATOR_CONFIG")
    if [ -d "$LAZY_HIERARCHY/$name" ]; then
      [ -n "$runtime_entry" ] && [ -n "$generator_entry" ] || die "lazy-mcp hierarchy category '$name' exists without matching entries in both configs"
      [ -f "$LAZY_HIERARCHY/$name/$name.json" ] || die "lazy-mcp hierarchy category '$name' has no overview file"
      jq -e --arg name "$name" '.overview | type == "string" and contains($name)' "$LAZY_HIERARCHY/$name/$name.json" >/dev/null \
        || die "lazy-mcp hierarchy category '$name' has an invalid overview"
    else
      LAZY_CHANGES_NEEDED=1
    fi
  done
}

if [ "$MCP_CLIENT" = lazy-mcp ] && [ "$MCP_SCOPE" = user ]; then
  validate_lazy_mcp_state
fi

# An already-running local Ollama stack is compatibility-checked before the
# rollback manifest, package installs, local excludes, or index state can change.
if [ "$ACTION" != plan ] && [ -n "$ollama_path" ] \
  && curl --silent --show-error --fail --noproxy '*' --max-time 3 "$OLLAMA_ENDPOINT/api/version" >/dev/null 2>&1; then
  preflight_binary_version=$(version_token "$("$ollama_path" --version 2>/dev/null || true)")
  preflight_api_version=$(curl --silent --show-error --fail --noproxy '*' --max-time 3 "$OLLAMA_ENDPOINT/api/version" | jq -r '.version // empty')
  [ -n "$preflight_binary_version" ] && [ "$preflight_binary_version" = "$preflight_api_version" ] \
    || die "Ollama binary/API version mismatch: binary='${preflight_binary_version:-unknown}' API='${preflight_api_version:-unknown}'"
  preflight_model_record=$(curl --silent --show-error --fail --noproxy '*' --max-time 5 "$OLLAMA_ENDPOINT/api/tags" \
    | jq -c --arg model "$MODEL" '.models[]? | select(.name == $model or .model == $model)' | head -n 1)
  if [ -n "$preflight_model_record" ]; then
    preflight_digest=$(printf '%s' "$preflight_model_record" | jq -r '.digest // empty')
    preflight_size=$(printf '%s' "$preflight_model_record" | jq -r '.size // 0')
    [ "$preflight_digest" = "$MODEL_EXPECTED_DIGEST" ] \
      || die "model digest '$preflight_digest' does not match pinned digest '$MODEL_EXPECTED_DIGEST' for '$MODEL'"
    [ "$preflight_size" -eq "$MODEL_EXPECTED_BYTES" ] \
      || die "model size '$preflight_size' does not match pinned size '$MODEL_EXPECTED_BYTES' for '$MODEL'"
    preflight_show_body=$(jq -nc --arg model "$MODEL" '{model:$model,verbose:false}')
    preflight_metadata=$(curl --silent --show-error --fail --noproxy '*' --max-time 5 \
      -H 'Content-Type: application/json' -d "$preflight_show_body" "$OLLAMA_ENDPOINT/api/show") \
      || die "Ollama /api/show metadata preflight failed for '$MODEL'"
    preflight_quantization=$(printf '%s' "$preflight_metadata" | jq -r '.details.quantization_level // empty')
    preflight_dimensions=$(printf '%s' "$preflight_metadata" | jq -r '.model_info["nomic-bert.embedding_length"] // .details.embedding_length // 0')
    [ "$preflight_quantization" = "$MODEL_EXPECTED_QUANTIZATION" ] \
      || die "model quantization '$preflight_quantization' does not match pinned '$MODEL_EXPECTED_QUANTIZATION'"
    [ "$preflight_dimensions" -eq "$MODEL_EXPECTED_DIMENSIONS" ] \
      || die "model metadata dimensions '$preflight_dimensions' do not match pinned '$MODEL_EXPECTED_DIMENSIONS'"
    preflight_model_running=no
    if "$ollama_path" ps 2>/dev/null | awk -v model="$MODEL" '$1 == model {found=1} END {exit !found}'; then preflight_model_running=yes; fi
    preflight_probe_body=$(jq -nc --arg model "$MODEL" '{model:$model,input:["fn local_index_health_probe() -> usize { 768 }"],truncate:false,keep_alive:"5m"}')
    preflight_probe_response=$(bounded_command "Ollama embedding preflight" "$MAX_EMBED_REQUEST_SECONDS" curl --silent --show-error --fail --noproxy '*' \
      --max-time "$MAX_EMBED_REQUEST_SECONDS" -H 'Content-Type: application/json' -d "$preflight_probe_body" "$OLLAMA_ENDPOINT/api/embed") \
      || die "Ollama /api/embed compatibility preflight failed"
    preflight_vector_length=$(printf '%s' "$preflight_probe_response" | jq -r '.embeddings[0] | length')
    [ "$preflight_vector_length" -eq "$MODEL_EXPECTED_DIMENSIONS" ] \
      || die "Ollama returned vector length $preflight_vector_length, expected $MODEL_EXPECTED_DIMENSIONS"
    [ "$preflight_model_running" = yes ] || MODEL_LOADED_BY_RUN=1
  elif [ "$PULL_MODEL" = no ]; then
    die "model '$MODEL' is absent and --pull-model no forbids the approximately 274 MB download"
  fi
elif [ "$ACTION" != plan ] && [ -n "$ollama_path" ] && [ "$START_OLLAMA" = no ]; then
  die "Ollama loopback API is unavailable and --start-ollama no forbids starting it"
fi

if [ "$ACTION" = plan ]; then
  note "plan complete; no package, service, model, index, MCP, or rollback-manifest state was changed"
  exit 0
fi

if [ -n "$ROLLBACK_MANIFEST" ]; then
  manifest_parent=$(dirname "$ROLLBACK_MANIFEST")
  [ -d "$manifest_parent" ] || die "rollback manifest parent does not exist: $manifest_parent"
  [ ! -L "$ROLLBACK_MANIFEST" ] || die "rollback manifest must not be a symlink: $ROLLBACK_MANIFEST"
  umask 077
  if [ ! -e "$ROLLBACK_MANIFEST" ]; then
    : > "$ROLLBACK_MANIFEST"
    chmod 600 "$ROLLBACK_MANIFEST"
  fi
  [ -f "$ROLLBACK_MANIFEST" ] && [ -w "$ROLLBACK_MANIFEST" ] || die "rollback manifest is not a writable regular file: $ROLLBACK_MANIFEST"
  append_manifest "run=$(date -u +%Y-%m-%dT%H:%M:%SZ) action=$ACTION project=$PROJECT"
  append_manifest "pins=grepai:v$GREPAI_VERSION,codegraph:v$CODEGRAPH_VERSION,serena:$SERENA_VERSION model=$MODEL"
  [ -z "$SERENA_HEALTH_EVIDENCE" ] || append_manifest "$SERENA_HEALTH_EVIDENCE"
fi

plan_project_initializer() {
  local name=$1 state_path=$2
  PLANNED_STATE_NAMES+=("$name")
  PLANNED_STATE_PATHS+=("$state_path")
  append_manifest "planned_project_state=$state_path initializer=$name"
}

complete_project_initializer() {
  INITIALIZER_COMPLETE["$1"]=1
}

ensure_local_ignores() {
  [ "$STATE_POLICY" = local-ignored ] || return 0
  [ "$INIT_COMPONENTS" != none ] || return 0
  local exclude_file exclude_parent exclude_owner handle_dir handle original_identity current_identity entry
  validate_local_exclude_path
  exclude_file=$GIT_EXCLUDE_FILE
  exclude_parent=$(dirname "$exclude_file")
  [ -d "$exclude_parent" ] && [ ! -L "$exclude_parent" ] \
    || die "Git info directory must be a real directory: $exclude_parent"
  if [ ! -e "$exclude_file" ] && [ ! -L "$exclude_file" ]; then
    (umask 077; set -o noclobber; : > "$exclude_file") 2>/dev/null || [ -e "$exclude_file" ] \
      || die "could not create Git info/exclude safely: $exclude_file"
  fi
  [ ! -L "$exclude_file" ] || die "Git info/exclude must be an owner-owned regular file: $exclude_file"
  exclude_owner=$(stat -c %u -- "$exclude_file" 2>/dev/null || true)
  [ -f "$exclude_file" ] && [ "$exclude_owner" = "$EUID" ] \
    || die "Git info/exclude must be an owner-owned regular file: $exclude_file"
  handle_dir=$(mktemp -d "$exclude_parent/.fm-indexing-exclude.XXXXXX")
  cleanup_files+=("$handle_dir")
  handle=$handle_dir/exclude
  ln -P -- "$exclude_file" "$handle" \
    || die "could not acquire a no-follow hard-link handle for Git info/exclude: $exclude_file"
  [ ! -L "$handle" ] && [ -f "$handle" ] \
    || die "Git info/exclude changed topology while it was being opened: $exclude_file"
  original_identity=$(stat -c '%d:%i' -- "$handle")
  [ ! -L "$exclude_file" ] || die "Git info/exclude changed while its safe handle was acquired: $exclude_file"
  current_identity=$(stat -c '%d:%i' -- "$exclude_file" 2>/dev/null || true)
  [ "$current_identity" = "$original_identity" ] \
    || die "Git info/exclude changed while its safe handle was acquired: $exclude_file"
  for entry in .grepai/ .codegraph/ .serena/; do
    if ! grep -Fxq "$entry" "$handle"; then
      printf '%s\n' "$entry" >> "$handle"
      append_manifest "created_git_exclude_entry=$exclude_file:$entry"
      note "added local Git exclude $entry"
    fi
  done
  [ ! -L "$exclude_file" ] || die "Git info/exclude changed during its no-follow update: $exclude_file"
  current_identity=$(stat -c '%d:%i' -- "$exclude_file" 2>/dev/null || true)
  [ "$current_identity" = "$original_identity" ] \
    || die "Git info/exclude changed during its no-follow update: $exclude_file"
}

download_verified() {
  local url=$1 expected=$2 max_bytes=$3 output=$4
  note "download url=$url sha256=$expected max_bytes=$max_bytes"
  curl --fail --show-error --location --max-time 600 --max-filesize "$max_bytes" --output "$output" "$url"
  actual=$(sha256_file "$output")
  [ "$actual" = "$expected" ] || die "checksum mismatch for $url (expected $expected, got $actual)"
}

install_grepai() {
  if [ -e "$GREPAI_DEST" ] || [ -L "$GREPAI_DEST" ]; then
    [ ! -L "$GREPAI_DEST" ] && [ -f "$GREPAI_DEST" ] && [ -x "$GREPAI_DEST" ] \
      && [ "$(stat -c %u -- "$GREPAI_DEST")" = "$EUID" ] \
      || die "grepai managed destination is not a proven owner-managed regular executable: $GREPAI_DEST"
    installed=$(version_token "$("$GREPAI_DEST" version 2>/dev/null || true)")
    [ "$installed" = "$GREPAI_VERSION" ] || die "managed grepai destination exists with version '${installed:-unknown}': $GREPAI_DEST"
  else
    case "$asset_arch" in
      amd64) digest=a830e0bf7a7d9db0c98207774ffea1652080679fb51b644759ae4ce25fc239b2 ;;
      arm64) digest=ba080e19f36cb7d5ef825f761fa56ad3d8aaeae8445efb2517d4c08472acaa4a ;;
    esac
    asset="grepai_${GREPAI_VERSION}_linux_${asset_arch}.tar.gz"
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-grepai.XXXXXX")
    cleanup_files+=("$tmp")
    download_verified "https://github.com/yoanbernabeu/grepai/releases/download/v$GREPAI_VERSION/$asset" "$digest" "$GREPAI_MAX_ASSET_BYTES" "$tmp/$asset"
    tar -xzf "$tmp/$asset" -C "$tmp"
    [ -x "$tmp/grepai" ] || die "verified grepai archive did not contain an executable grepai"
    destination_parent=$(dirname "$GREPAI_DEST")
    mkdir -p "$destination_parent"
    staged_binary=$(mktemp "$destination_parent/.grepai.XXXXXX")
    cleanup_files+=("$staged_binary")
    install -m 0755 "$tmp/grepai" "$staged_binary"
    mv "$staged_binary" "$GREPAI_DEST"
    append_manifest "created_tool=$GREPAI_DEST sha256=$(sha256_file "$GREPAI_DEST")"
  fi
  if [ ! -e "$BIN_DIR/grepai" ]; then
    mkdir -p "$BIN_DIR"
    ln -s "$GREPAI_DEST" "$BIN_DIR/grepai"
    append_manifest "created_symlink=$BIN_DIR/grepai->$GREPAI_DEST"
  fi
  GREPAI_BIN=$BIN_DIR/grepai
}

install_codegraph() {
  if [ -x "$CODEGRAPH_DEST" ]; then
    installed=$(version_token "$("$CODEGRAPH_DEST" --version 2>/dev/null || true)")
    [ "$installed" = "$CODEGRAPH_VERSION" ] || die "managed CodeGraph destination exists with version '${installed:-unknown}': $CODEGRAPH_DEST"
  else
    case "$codegraph_arch" in
      x64) digest=2ba65e87a1210b706bb1e67d5e48b5fc4a1935e43dbb3fb5f31c5597840d2e58 ;;
      arm64) digest=9f17750aedf45d51f68caae39ed21d6e2a7290b2326e5c53f95a165918ebd1d8 ;;
    esac
    asset="codegraph-linux-${codegraph_arch}.tar.gz"
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-codegraph.XXXXXX")
    cleanup_files+=("$tmp")
    download_verified "https://github.com/colbymchenry/codegraph/releases/download/v$CODEGRAPH_VERSION/$asset" "$digest" "$CODEGRAPH_MAX_ASSET_BYTES" "$tmp/$asset"
    stage="$tmp/stage"
    mkdir -p "$stage"
    tar -xzf "$tmp/$asset" -C "$stage" --strip-components=1
    [ -x "$stage/bin/codegraph" ] || die "verified CodeGraph archive did not contain bin/codegraph"
    destination_root=$(dirname "$(dirname "$CODEGRAPH_DEST")")
    mkdir -p "$(dirname "$destination_root")"
    [ ! -e "$destination_root" ] || die "CodeGraph destination appeared concurrently: $destination_root"
    mv "$stage" "$destination_root"
    append_manifest "created_tool_tree=$destination_root asset_sha256=$digest"
  fi
  if [ ! -e "$BIN_DIR/codegraph" ]; then
    mkdir -p "$BIN_DIR"
    ln -s "$CODEGRAPH_DEST" "$BIN_DIR/codegraph"
    append_manifest "created_symlink=$BIN_DIR/codegraph->$CODEGRAPH_DEST"
  fi
  CODEGRAPH_BIN=$BIN_DIR/codegraph
}

install_serena() {
  uv_path=$(command_path uv)
  if [ -z "$uv_path" ]; then
    [ "$OLLAMA_OWNER" = arch ] || die "uv is missing; install one explicit owner before upstream-Ollama reuse"
    repo_uv_version=$(pacman -Si uv 2>/dev/null | sed -n 's/^Version[[:space:]]*:[[:space:]]*//p' | head -n 1)
    [ -n "$repo_uv_version" ] || die "Arch repository metadata for uv is unavailable; run a deliberate full system upgrade separately"
    note "Arch repository discovered uv=$repo_uv_version"
    run_privileged pacman -S --needed uv
    append_manifest "installed_arch_package=uv:$repo_uv_version"
    uv_path=$(command_path uv)
  else
    pacman -Qo "$uv_path" >/dev/null 2>&1 || die "uv owner conflict: '$uv_path' is not owned by the selected Arch package track"
  fi
  mkdir -p "$SERENA_TOOL_DIR" "$SERENA_HOME_DIR" "$BIN_DIR"
  if [ ! -x "$BIN_DIR/serena" ]; then
    UV_TOOL_DIR="$SERENA_TOOL_DIR" UV_TOOL_BIN_DIR="$BIN_DIR" "$uv_path" tool install --python 3.13 "serena-agent==$SERENA_VERSION"
    append_manifest "created_uv_tool=serena-agent:$SERENA_VERSION tool_dir=$SERENA_TOOL_DIR bin=$BIN_DIR/serena"
  fi
  SERENA_BIN=$BIN_DIR/serena
  installed=$(version_token "$("$SERENA_BIN" --version 2>/dev/null || true)")
  [ "$installed" = "$SERENA_VERSION" ] || die "Serena post-install version '${installed:-unknown}' does not match $SERENA_VERSION"
}

install_arch_ollama() {
  repo_version=$(pacman -Si "$arch_ollama_package" 2>/dev/null | sed -n 's/^Version[[:space:]]*:[[:space:]]*//p' | head -n 1)
  [ -n "$repo_version" ] || die "Arch repository package '$arch_ollama_package' is unavailable for $machine_arch; perform a deliberate full system upgrade or choose a supported state"
  note "Arch repository discovered $arch_ollama_package=$repo_version"
  run_privileged pacman -S --needed "$arch_ollama_package"
  append_manifest "installed_arch_package=$arch_ollama_package:$repo_version"
}

if [ "$ACTION" = apply ]; then
  if [ "$INSTALL_TOOLS" = yes ]; then
    [ "$OLLAMA_OWNER" = arch ] && [ -z "$ollama_path" ] && install_arch_ollama
    install_grepai
    install_codegraph
    install_serena
  fi
  ensure_local_ignores
fi

ollama_path=$(command_path ollama)
GREPAI_BIN=${GREPAI_BIN:-$(command_path grepai)}
CODEGRAPH_BIN=${CODEGRAPH_BIN:-$(command_path codegraph)}
SERENA_BIN=${SERENA_BIN:-$(command_path serena)}
[ -x "$ollama_path" ] || die "Ollama is unavailable after setup"
[ -x "$GREPAI_BIN" ] || die "grepai is unavailable after setup"
[ -x "$CODEGRAPH_BIN" ] || die "CodeGraph is unavailable after setup"
[ -x "$SERENA_BIN" ] || die "Serena is unavailable after setup"

[ "$(version_token "$("$GREPAI_BIN" version 2>/dev/null || true)")" = "$GREPAI_VERSION" ] || die "grepai postcondition failed"
[ "$(version_token "$("$CODEGRAPH_BIN" --version 2>/dev/null || true)")" = "$CODEGRAPH_VERSION" ] || die "CodeGraph postcondition failed"
[ "$(version_token "$("$SERENA_BIN" --version 2>/dev/null || true)")" = "$SERENA_VERSION" ] || die "Serena postcondition failed"

api_healthy=no
persistence_changed=0
if curl --silent --show-error --fail --noproxy '*' --max-time 3 "$OLLAMA_ENDPOINT/api/version" >/dev/null 2>&1; then
  api_healthy=yes
fi
if [ "$api_healthy" = no ]; then
  [ "$START_OLLAMA" = yes ] || die "Ollama loopback API is unavailable and --start-ollama no forbids starting it"
  command -v systemctl >/dev/null 2>&1 || die "systemctl is unavailable; start the selected Ollama owner manually"
  if [ "$PERSIST_OLLAMA" = yes ]; then
    run_privileged systemctl enable --now ollama
    append_manifest "changed_service=ollama prior_active=$service_active_before prior_enabled=$service_enabled_before requested_persistent=yes"
    persistence_changed=1
  else
    run_privileged systemctl start ollama
    OLLAMA_SERVICE_STARTED=1
    append_manifest "temporarily_started_service=ollama prior_active=$service_active_before prior_enabled=$service_enabled_before stop_at_exit=yes"
  fi
  for _ in $(seq 1 20); do
    if curl --silent --show-error --fail --noproxy '*' --max-time 2 "$OLLAMA_ENDPOINT/api/version" >/dev/null 2>&1; then api_healthy=yes; break; fi
    sleep 1
  done
  [ "$api_healthy" = yes ] || die "Ollama service started but the loopback API did not become healthy within 20 seconds"
fi
runtime_ollama_version=$(version_token "$("$ollama_path" --version 2>/dev/null || true)")
api_ollama_version=$(curl --silent --show-error --fail --noproxy '*' --max-time 3 "$OLLAMA_ENDPOINT/api/version" | jq -r '.version // empty')
[ -n "$runtime_ollama_version" ] && [ "$runtime_ollama_version" = "$api_ollama_version" ] || die "Ollama binary/API version mismatch: binary='${runtime_ollama_version:-unknown}' API='${api_ollama_version:-unknown}'"
if [ "$ACTION" = apply ] && [ "$PERSIST_OLLAMA" = yes ] && [ "$service_enabled_before" = no ] && [ "$persistence_changed" -eq 0 ]; then
  run_privileged systemctl enable ollama
  append_manifest "changed_service=ollama prior_active=$service_active_before prior_enabled=$service_enabled_before requested_persistent=yes"
fi

model_present() {
  curl --silent --show-error --fail --noproxy '*' --max-time 5 "$OLLAMA_ENDPOINT/api/tags" \
    | jq -e --arg model "$MODEL" '.models[]? | select(.name == $model or .model == $model)' >/dev/null
}

if ! model_present; then
  [ "$PULL_MODEL" = yes ] || die "model '$MODEL' is absent and --pull-model no forbids the approximately 274 MB download"
  [ "$ACTION" = apply ] || die "model '$MODEL' is absent; health mode cannot pull it"
  note "pulling local Ollama model $MODEL (expected current payload approximately $MODEL_EXPECTED_BYTES bytes)"
  "$ollama_path" pull "$MODEL"
  append_manifest "pulled_model=$MODEL removal_requires_explicit_approval=yes"
fi

model_record=$(curl --silent --show-error --fail --noproxy '*' --max-time 5 "$OLLAMA_ENDPOINT/api/tags" | jq -c --arg model "$MODEL" '.models[]? | select(.name == $model or .model == $model)' | head -n 1)
[ -n "$model_record" ] || die "model '$MODEL' disappeared after pull/inspection"
model_digest=$(printf '%s' "$model_record" | jq -r '.digest // empty')
model_size=$(printf '%s' "$model_record" | jq -r '.size // 0')
[ -n "$model_digest" ] || die "Ollama did not report a digest for '$MODEL'"
case "$model_size" in ''|*[!0-9]*) die "Ollama reported an invalid model size for '$MODEL'" ;; esac
[ "$model_digest" = "$MODEL_EXPECTED_DIGEST" ] || die "model digest '$model_digest' does not match pinned digest '$MODEL_EXPECTED_DIGEST' for '$MODEL'"
[ "$model_size" -eq "$MODEL_EXPECTED_BYTES" ] || die "model size '$model_size' does not match pinned size '$MODEL_EXPECTED_BYTES' for '$MODEL'"
model_show_body=$(jq -nc --arg model "$MODEL" '{model:$model,verbose:false}')
model_metadata=$(curl --silent --show-error --fail --noproxy '*' --max-time 5 \
  -H 'Content-Type: application/json' -d "$model_show_body" "$OLLAMA_ENDPOINT/api/show") \
  || die "Ollama /api/show metadata probe failed for '$MODEL'"
model_quantization=$(printf '%s' "$model_metadata" | jq -r '.details.quantization_level // empty')
model_metadata_dimensions=$(printf '%s' "$model_metadata" | jq -r '.model_info["nomic-bert.embedding_length"] // .details.embedding_length // 0')
[ "$model_quantization" = "$MODEL_EXPECTED_QUANTIZATION" ] || die "model quantization '$model_quantization' does not match pinned '$MODEL_EXPECTED_QUANTIZATION'"
[ "$model_metadata_dimensions" -eq "$MODEL_EXPECTED_DIMENSIONS" ] || die "model metadata dimensions '$model_metadata_dimensions' do not match pinned '$MODEL_EXPECTED_DIMENSIONS'"
append_manifest "observed_model=$MODEL digest=$model_digest size=$model_size"

model_running_before=no
if "$ollama_path" ps 2>/dev/null | awk -v model="$MODEL" '$1 == model {found=1} END {exit !found}'; then
  model_running_before=yes
fi
probe_body=$(jq -nc --arg model "$MODEL" '{model:$model,input:["fn local_index_health_probe() -> usize { 768 }"],truncate:false,keep_alive:"5m"}')
probe_response=$(bounded_command "Ollama embedding health" "$MAX_EMBED_REQUEST_SECONDS" curl --silent --show-error --fail --noproxy '*' \
  --max-time "$MAX_EMBED_REQUEST_SECONDS" -H 'Content-Type: application/json' -d "$probe_body" "$OLLAMA_ENDPOINT/api/embed") \
  || die "Ollama /api/embed health probe failed"
vector_length=$(printf '%s' "$probe_response" | jq -r '.embeddings[0] | length')
[ "$vector_length" -eq "$MODEL_EXPECTED_DIMENSIONS" ] || die "Ollama returned vector length $vector_length, expected $MODEL_EXPECTED_DIMENSIONS"
[ "$model_running_before" = yes ] || MODEL_LOADED_BY_RUN=1
processor_line=$("$ollama_path" ps 2>/dev/null | awk -v model="$MODEL" '$1 == model {print; exit}' || true)
[ -n "$processor_line" ] || die "ollama ps did not show '$MODEL_BASE' after the embedding probe"
if [ "$OLLAMA_ACCEL" = cpu ]; then
  printf '%s\n' "$processor_line" | grep -F '100% CPU' >/dev/null || die "CPU mode selected but ollama ps did not report 100% CPU: $processor_line"
else
  printf '%s\n' "$processor_line" | grep -E '[0-9]+% GPU|GPU' >/dev/null || die "$OLLAMA_ACCEL selected but ollama ps did not report GPU placement: $processor_line"
fi
note "ollama_health digest=$model_digest size=$model_size quantization=$model_quantization dimensions=$vector_length total_duration=$(printf '%s' "$probe_response" | jq -r '.total_duration // "unknown"') prompt_eval_count=$(printf '%s' "$probe_response" | jq -r '.prompt_eval_count // "unknown"') placement='$processor_line'"

now_millis() {
  date +%s%3N
}

process_is_live() {
  local state
  state=$(ps -o stat= -p "$1" 2>/dev/null | awk '{print $1}')
  case "$state" in ''|Z*) return 1 ;; *) return 0 ;; esac
}

observe_temperature_millicelsius() {
  local root=${FM_INDEX_THERMAL_ROOT:-/sys} file value maximum=
  while IFS= read -r file; do
    value=$(cat "$file" 2>/dev/null || true)
    case "$value" in ''|*[!0-9]*) continue ;; esac
    [ "$value" -gt 0 ] && [ "$value" -lt 200000 ] || continue
    [ -n "$maximum" ] && [ "$value" -le "$maximum" ] || maximum=$value
  done < <(find "$root/class/thermal" "$root/class/hwmon" -type f \( -name temp -o -name 'temp*_input' \) 2>/dev/null | sort)
  printf '%s\n' "${maximum:-unavailable}"
}

sample_benchmark_resources() {
  local available swap_free load_milli temperature rss pid
  available=$(awk '/^MemAvailable:/ {print $2; exit}' "$MEMINFO")
  swap_free=$(awk '/^SwapFree:/ {print $2; exit}' "$MEMINFO")
  load_milli=$(awk 'NR == 1 {printf "%.0f", $1 * 1000}' "$LOADAVG")
  temperature=$(observe_temperature_millicelsius)
  [ "$available" -ge "$BENCH_MIN_MEM_KIB" ] || BENCH_MIN_MEM_KIB=$available
  [ "$swap_free" -ge "$BENCH_MIN_SWAP_FREE_KIB" ] || BENCH_MIN_SWAP_FREE_KIB=$swap_free
  [ "$load_milli" -le "$BENCH_MAX_LOAD_MILLI" ] || BENCH_MAX_LOAD_MILLI=$load_milli
  if [ "$temperature" != unavailable ]; then
    [ "$BENCH_MAX_TEMP_MILLIC" != unavailable ] && [ "$temperature" -le "$BENCH_MAX_TEMP_MILLIC" ] || BENCH_MAX_TEMP_MILLIC=$temperature
  fi
  pid=${FM_INDEX_OLLAMA_PID:-}
  if [ -z "$pid" ] && command -v systemctl >/dev/null 2>&1; then
    pid=$(systemctl show -p MainPID --value ollama 2>/dev/null || true)
  fi
  case "$pid" in ''|0|*[!0-9]*) return 0 ;; esac
  rss=$(awk '/^VmRSS:/ {print $2; exit}' "/proc/$pid/status" 2>/dev/null || true)
  case "$rss" in ''|*[!0-9]*) return 0 ;; esac
  [ "$rss" -le "$BENCH_MAX_OLLAMA_RSS_KIB" ] || BENCH_MAX_OLLAMA_RSS_KIB=$rss
}

prepare_micro_batch() {
  local scratch=$1 micro_dir=$2
  local paths=$micro_dir/paths rel index=0
  awk -F '\t' '
    function emit() { print $2; selected[$2] = 1; total++ }
    $1 == "rs" && rust < 60 { emit(); rust++; next }
    ($1 == "ts" || $1 == "tsx" || $1 == "js" || $1 == "jsx") && frontend < 20 { emit(); frontend++; next }
    $1 == "py" && python < 10 { emit(); python++; next }
    ($1 == "json" || $1 == "yaml" || $1 == "yml" || $1 == "toml" || $1 == "md") && config < 10 { emit(); config++; next }
    { fallback[++fallback_count] = $2 }
    END {
      for (i = 1; i <= fallback_count && total < 100; i++) {
        if (!selected[fallback[i]]) { print fallback[i]; selected[fallback[i]] = 1; total++ }
      }
    }
  ' "$candidate_file" > "$paths"
  [ "$(wc -l < "$paths" | tr -d ' ')" -eq 100 ] || die "the cold/warm benchmark requires at least 100 eligible real files after ignores"
  while IFS= read -r rel; do
    index=$((index + 1))
    awk '
      { for (i = 1; i <= NF && count < 512; i++) { if (count++) printf " "; printf "%s", $i } }
      END { print "" }
    ' "$scratch/$rel" > "$micro_dir/chunk-$index.txt"
    [ -s "$micro_dir/chunk-$index.txt" ] || die "benchmark candidate produced an empty real chunk: $rel"
  done < "$paths"
}

run_micro_batch() {
  local micro_dir=$1 start deadline pass chunk request_start request_end response dimensions prompt_tokens=0
  local remaining_millis request_budget_seconds
  local pass_start pass_end cold_ms=0 warm1_ms=0 warm2_ms=0 warm3_ms=0 request_count median_ms p95_ms
  start=$(now_millis)
  deadline=$((start + MAX_MICRO_BATCH_SECONDS * 1000))
  : > "$micro_dir/durations"
  for pass in cold warm1 warm2 warm3; do
    pass_start=$(now_millis)
    for chunk in "$micro_dir"/chunk-*.txt; do
      [ "$(now_millis)" -lt "$deadline" ] || die "100-chunk cold/warm benchmark exceeded the ${MAX_MICRO_BATCH_SECONDS}s hard bound"
      probe_body=$(jq -Rs --arg model "$MODEL" '{model:$model,input:[.],truncate:false,keep_alive:"5m"}' < "$chunk")
      request_start=$(now_millis)
      remaining_millis=$((deadline - request_start))
      request_budget_seconds=$(((remaining_millis + 999) / 1000))
      [ "$request_budget_seconds" -le "$MAX_EMBED_REQUEST_SECONDS" ] || request_budget_seconds=$MAX_EMBED_REQUEST_SECONDS
      [ "$request_budget_seconds" -gt 0 ] || die "100-chunk cold/warm benchmark exceeded the ${MAX_MICRO_BATCH_SECONDS}s hard bound"
      response=$(bounded_command "micro-batch embed request" "$request_budget_seconds" curl --silent --show-error --fail --noproxy '*' \
        --max-time "$request_budget_seconds" -H 'Content-Type: application/json' -d "$probe_body" "$OLLAMA_ENDPOINT/api/embed") \
        || die "Ollama micro-batch embed failed in pass '$pass'"
      request_end=$(now_millis)
      printf '%s\n' "$((request_end - request_start))" >> "$micro_dir/durations"
      dimensions=$(printf '%s' "$response" | jq -r '.embeddings[0] | length')
      [ "$dimensions" -eq "$MODEL_EXPECTED_DIMENSIONS" ] || die "micro-batch returned vector length $dimensions, expected $MODEL_EXPECTED_DIMENSIONS"
      prompt_tokens=$((prompt_tokens + $(printf '%s' "$response" | jq -r '.prompt_eval_count // 0')))
      sample_benchmark_resources
    done
    pass_end=$(now_millis)
    case "$pass" in
      cold) cold_ms=$((pass_end - pass_start)) ;;
      warm1) warm1_ms=$((pass_end - pass_start)) ;;
      warm2) warm2_ms=$((pass_end - pass_start)) ;;
      warm3) warm3_ms=$((pass_end - pass_start)) ;;
    esac
  done
  sort -n "$micro_dir/durations" > "$micro_dir/durations.sorted"
  request_count=$(wc -l < "$micro_dir/durations.sorted" | tr -d ' ')
  median_ms=$(sed -n "$(((request_count + 1) / 2))p" "$micro_dir/durations.sorted")
  p95_ms=$(sed -n "$(((request_count * 95 + 99) / 100))p" "$micro_dir/durations.sorted")
  note "micro_batch chunks=100 passes=4 cold_ms=$cold_ms warm_ms=$warm1_ms,$warm2_ms,$warm3_ms request_median_ms=$median_ms request_p95_ms=$p95_ms prompt_tokens=$prompt_tokens wall_ms=$(($(now_millis) - start))"
}

run_scratch_benchmark() {
  local scratch micro_dir start end allowed_delta_kib query expected output hits=0 query_start query_end
  local search_count search_median_ms incremental_path marker incremental_start incremental_seconds watcher_status watcher_pid watcher_idle_cpu
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/fm-index-scratch.XXXXXX")
  micro_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-index-micro.XXXXXX")
  SCRATCH_DIR=$scratch
  cleanup_files+=("$scratch" "$micro_dir")
  git -C "$PROJECT" archive HEAD | tar -x -C "$scratch"
  if [ "$IGNORE_POLICY" = existing ] && [ ! -e "$scratch/.grepaiignore" ]; then
    cp "$PROJECT/.grepaiignore" "$scratch/.grepaiignore"
  fi
  prepare_micro_batch "$scratch" "$micro_dir"
  BENCH_MIN_MEM_KIB=$mem_available_kib
  BENCH_MIN_SWAP_FREE_KIB=$swap_free_kib
  BENCH_MAX_LOAD_MILLI=0
  BENCH_MAX_TEMP_MILLIC=unavailable
  BENCH_MAX_OLLAMA_RSS_KIB=0
  sample_benchmark_resources

  (cd "$scratch" && bounded_command "scratch grepai init" "$COMMAND_TIMEOUT_SECONDS" "$GREPAI_BIN" init --provider ollama --model "$MODEL" --backend gob --yes >/dev/null) \
    || die "scratch grepai init failed"
  write_and_validate_fresh_grepai_endpoint "$scratch"
  start=$(date +%s)
  mkfifo "$scratch/watch.start"
  # The launch gate keeps the exact child alive until its PID generation is
  # recorded, closing the fast-exit/PID-reuse race seen in the test suite.
  # shellcheck disable=SC2016 # Positional parameters expand in the child shell.
  setsid bash -c 'IFS= read -r _ < "$3"; cd "$1" && exec "$2" watch --background' _ "$scratch" "$GREPAI_BIN" "$scratch/watch.start" \
    >"$scratch/watch.out" 2>"$scratch/watch.err" &
  SCRATCH_WATCH_STARTED=1
  record_watch_command "$!"
  printf 'start\n' > "$scratch/watch.start"
  rm "$scratch/watch.start"
  while process_is_live "$watch_command_pid"; do
    now=$(date +%s)
    if [ $((now - start)) -ge "$MAX_INDEX_SECONDS" ]; then
      terminate_watch_command
      (cd "$scratch" && timeout --kill-after=5s "$COMMAND_TIMEOUT_SECONDS" "$GREPAI_BIN" watch --stop >/dev/null 2>&1) || true
      SCRATCH_WATCH_STARTED=0
      die "scratch grepai index exceeded the ${MAX_INDEX_SECONDS}s hard bound"
    fi
    sample_benchmark_resources
    sleep 1
  done
  completed_watch_pid=$watch_command_pid
  if wait "$completed_watch_pid"; then
    clear_watch_command
  else
    clear_watch_command
    cat "$scratch/watch.err" >&2
    die "scratch grepai indexing failed"
  fi
  end=$(date +%s)
  watcher_status=$(cd "$scratch" && bounded_command "scratch grepai watcher status" "$COMMAND_TIMEOUT_SECONDS" "$GREPAI_BIN" watch --status) \
    || die "scratch grepai watcher did not report running after initialization"
  watcher_pid=$(printf '%s\n' "$watcher_status" | sed -n 's/.*PID \([0-9][0-9]*\).*/\1/p' | head -n 1)
  if [ -z "$watcher_pid" ] || ! kill -0 "$watcher_pid" 2>/dev/null; then
    die "scratch grepai watcher status did not identify a live PID"
  fi
  allowed_delta_kib=$((mem_total_kib * MAX_RAM_PERCENT / 100))
  observed_delta_kib=$((mem_available_kib - BENCH_MIN_MEM_KIB))
  [ "$observed_delta_kib" -le "$allowed_delta_kib" ] || die "scratch benchmark used $((observed_delta_kib / 1024)) MiB observed RAM delta, above ${MAX_RAM_PERCENT}% of installed RAM"
  (cd "$scratch" && bounded_command "scratch grepai status" "$COMMAND_TIMEOUT_SECONDS" "$GREPAI_BIN" status --no-ui) \
    >"$scratch/status.out" 2>"$scratch/status.err" || die "scratch grepai status failed"
  : > "$micro_dir/search-durations"
  for benchmark_case in "${BENCHMARK_QUERIES[@]}"; do
    query=${benchmark_case%%=*}
    expected=${benchmark_case#*=}
    query_start=$(now_millis)
    output=$(cd "$scratch" && bounded_command "scratch grepai search" "$COMMAND_TIMEOUT_SECONDS" "$GREPAI_BIN" search "$query" --json --limit 10) \
      || die "scratch grepai query failed: $query"
    query_end=$(now_millis)
    printf '%s\n' "$((query_end - query_start))" >> "$micro_dir/search-durations"
    if printf '%s' "$output" | jq -e --arg expected "$expected" 'tostring | contains($expected)' >/dev/null; then hits=$((hits + 1)); fi
    sample_benchmark_resources
  done
  sort -n "$micro_dir/search-durations" > "$micro_dir/search-durations.sorted"
  search_count=$(wc -l < "$micro_dir/search-durations.sorted" | tr -d ' ')
  search_median_ms=$(sed -n "$(((search_count + 1) / 2))p" "$micro_dir/search-durations.sorted")
  [ "$hits" -ge 4 ] || die "scratch usefulness gate failed: $hits/${#BENCHMARK_QUERIES[@]} expected areas appeared in the top 10 (need at least 4)"
  [ "$search_median_ms" -le "$MAX_SEARCH_MS" ] || die "warm search median ${search_median_ms}ms exceeds the ${MAX_SEARCH_MS}ms bound"

  incremental_path=$(head -n 1 "$micro_dir/paths")
  marker="fm_incremental_probe_$$"
  printf '\n// %s\n' "$marker" >> "$scratch/$incremental_path"
  incremental_start=$(date +%s)
  while :; do
    output=$(cd "$scratch" && bounded_command "scratch incremental grepai search" "$COMMAND_TIMEOUT_SECONDS" "$GREPAI_BIN" search "$marker" --json --limit 10 2>/dev/null) \
      || die "scratch incremental grepai search failed"
    if printf '%s' "$output" | jq -e --arg expected "$incremental_path" 'tostring | contains($expected)' >/dev/null 2>&1; then break; fi
    incremental_seconds=$(($(date +%s) - incremental_start))
    [ "$incremental_seconds" -lt "$MAX_INCREMENTAL_SECONDS" ] || die "scratch incremental convergence exceeded the ${MAX_INCREMENTAL_SECONDS}s bound"
    sample_benchmark_resources
    sleep 1
  done
  incremental_seconds=$(($(date +%s) - incremental_start))
  cp "$PROJECT/$incremental_path" "$scratch/$incremental_path"

  sleep 2
  watcher_idle_cpu=$(ps -o %cpu= -p "$watcher_pid" | awk '{printf "%.0f", $1}')
  case "$watcher_idle_cpu" in ''|*[!0-9]*) die "could not observe scratch watcher idle CPU for PID $watcher_pid" ;; esac
  [ "$watcher_idle_cpu" -le "$MAX_WATCHER_IDLE_CPU_PERCENT" ] || die "scratch watcher idle CPU ${watcher_idle_cpu}% exceeds the ${MAX_WATCHER_IDLE_CPU_PERCENT}% bound"
  sample_benchmark_resources
  swap_growth_kib=$((swap_free_kib - BENCH_MIN_SWAP_FREE_KIB))
  [ "$swap_growth_kib" -le $((MAX_SWAP_GROWTH_MIB * 1024)) ] || die "benchmark swap growth $((swap_growth_kib / 1024)) MiB exceeds the ${MAX_SWAP_GROWTH_MIB} MiB bound"
  [ "$BENCH_MAX_LOAD_MILLI" -le $((cpu_threads * MAX_LOAD_PER_CPU_PERCENT * 10)) ] || die "benchmark one-minute load exceeds ${MAX_LOAD_PER_CPU_PERCENT}% per online CPU"
  if [ "$BENCH_MAX_TEMP_MILLIC" != unavailable ]; then
    [ "$BENCH_MAX_TEMP_MILLIC" -le $((MAX_TEMPERATURE_CELSIUS * 1000)) ] || die "benchmark temperature $((BENCH_MAX_TEMP_MILLIC / 1000)) C exceeds the ${MAX_TEMPERATURE_CELSIUS} C bound"
  fi
  (cd "$scratch" && bounded_command "scratch grepai watcher stop" "$COMMAND_TIMEOUT_SECONDS" "$GREPAI_BIN" watch --stop >/dev/null) \
    || die "scratch grepai watcher could not be stopped"
  SCRATCH_WATCH_STARTED=0
  run_micro_batch "$micro_dir"
  note "grepai_benchmark seconds=$((end - start)) quality_hits=$hits/${#BENCHMARK_QUERIES[@]} search_median_ms=$search_median_ms incremental_seconds=$incremental_seconds watcher_idle_cpu_percent=$watcher_idle_cpu observed_ram_delta_mib=$((observed_delta_kib / 1024)) ollama_peak_rss_mib=$((BENCH_MAX_OLLAMA_RSS_KIB / 1024)) swap_growth_mib=$((swap_growth_kib / 1024)) temperature_peak_celsius=$([ "$BENCH_MAX_TEMP_MILLIC" = unavailable ] && printf unavailable || printf '%s' "$((BENCH_MAX_TEMP_MILLIC / 1000))") load_peak=$(awk -v milli="$BENCH_MAX_LOAD_MILLI" 'BEGIN {printf "%.2f", milli / 1000}') scratch_removed_at_exit=yes"
}

if [ "$BENCHMARK" = yes ]; then
  run_scratch_benchmark
elif [ "$ACTION" = apply ] && contains_component grepai && [ ! -d "$PROJECT/.grepai" ]; then
  die "new canonical grepai initialization requires --benchmark yes"
fi

if [ "$ACTION" = apply ]; then
  if contains_component grepai; then
    if [ -d "$PROJECT/.grepai" ]; then
      note "grepai init no-op: existing compatible config preserved"
    else
      plan_project_initializer grepai "$PROJECT/.grepai"
      (cd "$PROJECT" && bounded_command "canonical grepai init" "$COMMAND_TIMEOUT_SECONDS" "$GREPAI_BIN" init --provider ollama --model "$MODEL" --backend gob --yes) \
        || die "canonical grepai init failed"
      write_and_validate_fresh_grepai_endpoint "$PROJECT"
      PROJECT_WATCH_STARTED=1
      (cd "$PROJECT" && timeout --kill-after=5s "$MAX_INDEX_SECONDS" "$GREPAI_BIN" watch --background)
      (cd "$PROJECT" && bounded_command "canonical grepai status" "$COMMAND_TIMEOUT_SECONDS" "$GREPAI_BIN" status --no-ui)
      (cd "$PROJECT" && bounded_command "canonical grepai search" "$COMMAND_TIMEOUT_SECONDS" "$GREPAI_BIN" search "$HEALTH_QUERY" --json --limit 1) \
        | jq -e 'type == "array" or type == "object"' >/dev/null
      (cd "$PROJECT" && bounded_command "canonical grepai watcher stop" "$COMMAND_TIMEOUT_SECONDS" "$GREPAI_BIN" watch --stop)
      PROJECT_WATCH_STARTED=0
      complete_project_initializer grepai
      append_manifest "created_project_state=$PROJECT/.grepai removal_requires_explicit_approval=yes"
    fi
  fi
  if contains_component codegraph; then
    if [ -d "$PROJECT/.codegraph" ]; then
      note "CodeGraph init no-op: existing healthy state preserved"
    else
      plan_project_initializer codegraph "$PROJECT/.codegraph"
      CODEGRAPH_TELEMETRY=0 DO_NOT_TRACK=1 bounded_command "CodeGraph init" "$COMMAND_TIMEOUT_SECONDS" "$CODEGRAPH_BIN" init "$PROJECT" \
        || die "CodeGraph init failed"
      complete_project_initializer codegraph
      append_manifest "created_project_state=$PROJECT/.codegraph removal_requires_explicit_approval=yes"
    fi
  fi
  if contains_component serena; then
    if [ -d "$PROJECT/.serena" ]; then
      note "Serena create no-op: existing healthy project state preserved"
    else
      plan_project_initializer serena "$PROJECT/.serena"
      serena_args=()
      for language in "${SERENA_LANGUAGES[@]}"; do serena_args+=(--language "$language"); done
      if [ "$ALLOW_LANGUAGE_DOWNLOADS" = no ]; then
        for language in "${SERENA_LANGUAGES[@]}"; do
          case "$language" in
            rust) command -v rust-analyzer >/dev/null 2>&1 || die "Rust Serena setup needs rust-analyzer or --allow-language-downloads yes" ;;
            go) command -v gopls >/dev/null 2>&1 || die "Go Serena setup needs gopls or --allow-language-downloads yes" ;;
            java) command -v java >/dev/null 2>&1 || die "Java Serena setup needs java" ;;
          esac
        done
      fi
      SERENA_HOME="$SERENA_HOME_DIR" SERENA_USAGE_REPORTING=false timeout --kill-after=5s "$MAX_INDEX_SECONDS" "$SERENA_BIN" project create "${serena_args[@]}" --index "$PROJECT"
      complete_project_initializer serena
      append_manifest "created_project_state=$PROJECT/.serena languages=$(IFS=,; printf '%s' "${SERENA_LANGUAGES[*]}") removal_requires_explicit_approval=yes"
    fi
  fi
fi

if [ -d "$PROJECT/.grepai" ]; then
  (cd "$PROJECT" && bounded_command "grepai health status" "$COMMAND_TIMEOUT_SECONDS" "$GREPAI_BIN" status --no-ui) >/dev/null || die "grepai index health failed"
  grepai_query=$(cd "$PROJECT" && bounded_command "grepai health search" "$COMMAND_TIMEOUT_SECONDS" "$GREPAI_BIN" search "$HEALTH_QUERY" --json --limit 1) \
    || die "grepai query health failed"
  printf '%s' "$grepai_query" | jq -e 'if type == "array" then length > 0 elif type == "object" then ((.results // []) | length > 0) else false end' >/dev/null || die "grepai health query returned no result: $HEALTH_QUERY"
  note "grepai_health index=healthy watcher=${PROJECT_WATCH_STARTED:-0} query='$HEALTH_QUERY'"
fi
if [ -d "$PROJECT/.codegraph" ]; then
  cg_status=$(CODEGRAPH_TELEMETRY=0 DO_NOT_TRACK=1 bounded_command "CodeGraph health status" "$COMMAND_TIMEOUT_SECONDS" "$CODEGRAPH_BIN" status --json "$PROJECT") \
    || die "CodeGraph status failed"
  printf '%s' "$cg_status" | codegraph_status_is_healthy || die "CodeGraph status is unhealthy, stale, non-WAL, or mismatched"
  cg_query=$(CODEGRAPH_TELEMETRY=0 DO_NOT_TRACK=1 bounded_command "CodeGraph health query" "$COMMAND_TIMEOUT_SECONDS" "$CODEGRAPH_BIN" query --path "$PROJECT" --limit 1 --json "$HEALTH_QUERY") \
    || die "CodeGraph query health failed"
  printf '%s' "$cg_query" | jq -e 'if type == "array" then length > 0 elif type == "object" then ((.results // .nodes // []) | length > 0) else false end' >/dev/null || die "CodeGraph health query returned no result: $HEALTH_QUERY"
  note "codegraph_health index=healthy query='$HEALTH_QUERY' telemetry=off"
fi
if [ -d "$PROJECT/.serena" ]; then
  run_serena_health canonical || die "Serena project health-check failed"
  note "serena_health languages=$(IFS=,; printf '%s' "${SERENA_LANGUAGES[*]}") symbols=healthy telemetry=off"
fi

note "MCP snippet (stdio only; no secrets):"
printf '%s\n' "$mcp_entries" | jq .

mcp_probe() {
  local name=$1 cwd=$2 command=$3 args_json=$4 env_json=$5 temp pid deadline success=0 response_line
  temp=$(mktemp -d "${TMPDIR:-/tmp}/fm-mcp-${name}.XXXXXX")
  cleanup_files+=("$temp")
  mkfifo "$temp/in"
  jq -r 'to_entries[] | "export \(.key)=\(.value | @sh)"' <<<"$env_json" > "$temp/env.sh"
  jq -r '.[] | @sh' <<<"$args_json" > "$temp/args"
  (
    cd "$cwd"
    # shellcheck disable=SC1090,SC1091 # Generated from validated MCP env JSON.
    . "$temp/env.sh"
    command_args=()
    while IFS= read -r quoted; do eval "command_args+=( $quoted )"; done < "$temp/args"
    exec setsid "$command" "${command_args[@]}" < "$temp/in" > "$temp/out" 2> "$temp/err"
  ) &
  pid=$!
  exec 8>"$temp/in"
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"fm-indexing-health","version":"1"}}}' >&8
  printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' >&8
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' >&8
  deadline=$((SECONDS + MCP_TIMEOUT_SECONDS))
  while [ "$SECONDS" -lt "$deadline" ]; do
    response_line=$(grep -E '"id"[[:space:]]*:[[:space:]]*2' "$temp/out" 2>/dev/null | tail -n 1 || true)
    if [ -n "$response_line" ] && printf '%s' "$response_line" | jq -e '.result.tools | type == "array" and length > 0' >/dev/null 2>&1; then success=1; break; fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  exec 8>&-
  kill -TERM -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$success" -eq 1 ] || { sed -n '1,40p' "$temp/err" >&2; die "$name MCP initialize/tools-list health failed within ${MCP_TIMEOUT_SECONDS}s"; }
  note "${name}_mcp_health transport=stdio tools_list=healthy timeout_seconds=$MCP_TIMEOUT_SECONDS process_stopped=yes"
}

if [ -d "$PROJECT/.grepai" ]; then
  mcp_probe grepai "$PROJECT" "$GREPAI_BIN" "$(printf '%s' "$grepai_entry" | jq -c '.args')" '{}'
fi
if [ -d "$PROJECT/.codegraph" ]; then
  mcp_probe codegraph "$PROJECT" "$CODEGRAPH_BIN" "$(printf '%s' "$codegraph_entry" | jq -c '.args')" "$(printf '%s' "$codegraph_entry" | jq -c '.env')"
fi
if [ -d "$PROJECT/.serena" ]; then
  mcp_probe serena "$PROJECT" "$SERENA_BIN" "$(printf '%s' "$serena_entry" | jq -c '.args')" "$(printf '%s' "$serena_entry" | jq -c '.env')"
fi

register_lazy_mcp() {
  local runtime_config generator_config hierarchy generator temp backup_suffix file name
  validate_lazy_mcp_state
  runtime_config=$LAZY_RUNTIME_CONFIG
  generator_config=$LAZY_GENERATOR_CONFIG
  hierarchy=$LAZY_HIERARCHY
  generator=$LAZY_GENERATOR
  if [ "$LAZY_CHANGES_NEEDED" -eq 0 ]; then
    for name in grepai codegraph serena; do
      jq -e --arg name "$name" '.overview | contains($name)' "$hierarchy/root.json" >/dev/null || die "lazy-mcp root hierarchy omits healthy existing category '$name'"
    done
    note "lazy_mcp registration=no-op existing entries and hierarchy are healthy"
    return 0
  fi
  temp=$(mktemp -d "${TMPDIR:-/tmp}/fm-lazy-mcp.XXXXXX")
  cleanup_files+=("$temp")
  jq -n --argjson servers "$mcp_entries" '{mcpServers:$servers}' > "$temp/three.json"
  timeout --kill-after=5s "$((MCP_TIMEOUT_SECONDS * 4))" "$generator" -config "$temp/three.json" -output "$temp/hierarchy" >/dev/null || die "lazy-mcp hierarchy generation failed; source configs remain unchanged"
  for name in grepai codegraph serena; do
    [ -d "$temp/hierarchy/$name" ] || die "lazy-mcp generator produced no $name hierarchy"
    if [ -d "$hierarchy/$name" ]; then
      diff -qr "$hierarchy/$name" "$temp/hierarchy/$name" >/dev/null || die "lazy-mcp hierarchy '$name' already exists with different content"
    fi
  done
  backup_suffix=$(date -u +%Y%m%dT%H%M%SZ).$$
  for file in "$runtime_config" "$generator_config" "$hierarchy/root.json"; do
    backup="$file.fm-indexing-backup-$backup_suffix"
    cp -p "$file" "$backup"
    LAZY_TARGETS+=("$file")
    LAZY_BACKUPS+=("$backup")
    append_manifest "lazy_mcp_backup=$backup restore_to=$file"
  done
  LAZY_TRANSACTION_ACTIVE=1
  for name in grepai codegraph serena; do
    if [ ! -d "$hierarchy/$name" ]; then
      cp -a "$temp/hierarchy/$name" "$hierarchy/$name"
      LAZY_CREATED_DIRS+=("$hierarchy/$name")
      append_manifest "created_lazy_hierarchy=$hierarchy/$name"
    fi
  done
  for file in "$runtime_config" "$generator_config"; do
    jq --argjson additions "$mcp_entries" '.mcpServers += $additions' "$file" > "$temp/$(basename "$file")"
    chmod --reference="$file" "$temp/$(basename "$file")"
    mv "$temp/$(basename "$file")" "$file"
    append_manifest "updated_lazy_config=$file additive_servers=grepai,codegraph,serena"
  done
  server_count=0
  tool_count=0
  summary=
  for category in "$hierarchy"/*; do
    [ -d "$category" ] || continue
    name=$(basename "$category")
    overview=$(jq -r '.overview // empty' "$category/$name.json" 2>/dev/null || true)
    [ -n "$overview" ] || continue
    first_clause=${overview%%;*}
    count=$(printf '%s' "$first_clause" | sed -n 's/.*: \([0-9][0-9]*\) tools\{0,1\}.*/\1/p')
    case "$count" in ''|*[!0-9]*) count=0 ;; esac
    server_count=$((server_count + 1))
    tool_count=$((tool_count + count))
    if [ -n "$summary" ]; then summary="$summary, "; fi
    summary="$summary$name -> $first_clause"
  done
  jq --arg overview "Root: $server_count servers, $tool_count tools; $summary" '.overview = $overview' "$hierarchy/root.json" > "$temp/root.json"
  chmod --reference="$hierarchy/root.json" "$temp/root.json"
  mv "$temp/root.json" "$hierarchy/root.json"
  append_manifest "updated_lazy_hierarchy_root=$hierarchy/root.json"
  LAZY_TRANSACTION_ACTIVE=0
  note "lazy_mcp registration=healthy configs=2 hierarchy=$hierarchy reversible_backups_suffix=$backup_suffix"
}

if [ "$MCP_CLIENT" = lazy-mcp ] && [ "$MCP_SCOPE" = user ]; then
  [ "$ACTION" = apply ] || die "lazy-mcp user registration requires --action apply; use --mcp-scope print for a read-only plan"
  [ -d "$PROJECT/.grepai" ] && [ -d "$PROJECT/.codegraph" ] && [ -d "$PROJECT/.serena" ] || die "lazy-mcp registration requires healthy project state for all three indexers"
  register_lazy_mcp
fi

note "complete action=$ACTION project=$PROJECT versions=grepai:$GREPAI_VERSION,codegraph:$CODEGRAPH_VERSION,serena:$SERENA_VERSION model_digest=$model_digest"

#!/usr/bin/env bash
# Deterministic offline contract tests for the CachyOS local indexing recovery kit.
# No case uses the network, package installation, systemd mutation, model download,
# a real indexer, or a real MCP server.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-indexing-tools-cachyos.sh"
TMP_ROOT=$(fm_test_tmproot fm-indexing-tools-cachyos)

new_fixture() {
  local name=$1 dir="$TMP_ROOT/$1" fakebin
  mkdir -p "$dir/home" "$dir/runtime" "$dir/install-parent" "$dir/bin" "$dir/project/src" "$dir/project/scripts" "$dir/project/web"
  chmod 700 "$dir/runtime"
  printf 'ID=cachyos\nID_LIKE=arch\n' > "$dir/os-release"
  printf 'MemTotal:       16777216 kB\nMemAvailable:   12582912 kB\nSwapTotal:       2097152 kB\nSwapFree:        2097152 kB\n' > "$dir/meminfo"
  printf '0.10 0.20 0.30 1/100 123\n' > "$dir/loadavg"
  printf '1048576\n' > "$dir/inotify-max-user-watches"
  printf '128\n' > "$dir/inotify-max-user-instances"
  mkdir -p "$dir/thermal/class/thermal/thermal_zone0"
  printf '45000\n' > "$dir/thermal/class/thermal/thermal_zone0/temp"
  vector=$(jq -nc '[range(0;768) | 0]')
  jq -nc --argjson vector "$vector" '{embeddings:[$vector],total_duration:100,prompt_eval_count:512}' > "$dir/embed-response.json"
  printf 'fn main() {}\n' > "$dir/project/src/main.rs"
  printf 'def helper(): pass\n' > "$dir/project/scripts/helper.py"
  printf 'export const value = 1;\n' > "$dir/project/web/app.ts"
  git -C "$dir/project" init -q
  git -C "$dir/project" add .
  git -C "$dir/project" -c user.name=Test -c user.email=test@example.invalid commit -qm initial
  fakebin=$(fm_fakebin "$dir")

  cat > "$fakebin/findmnt" <<'SH'
#!/usr/bin/env bash
printf 'ext4\n'
SH
  cat > "$fakebin/pacman" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -Qo) exit 0 ;;
  -Si) printf 'Name : %s\nVersion : 1.2.3-1\n' "${2:-package}" ;;
  *) printf 'unexpected pacman mutation\n' >&2; exit 91 ;;
esac
SH
  cat > "$fakebin/systemctl" <<'SH'
#!/usr/bin/env bash
[ -n "${FM_FAKE_LOG:-}" ] && printf 'systemctl args=%s\n' "$*" >> "$FM_FAKE_LOG"
state_prefix=${FM_FAKE_SYSTEMCTL_STATE_PREFIX:?}
if [ ! -e "$state_prefix.initialized" ]; then
  : > "$state_prefix.initialized"
  [ "${FM_FAKE_SERVICE_ACTIVE_BEFORE:-no}" != yes ] || : > "$state_prefix.active"
  [ "${FM_FAKE_SERVICE_ENABLED_BEFORE:-no}" != yes ] || : > "$state_prefix.enabled"
  if [ "${FM_FAKE_SERVICE_ACTIVE_BEFORE:-no}" = yes ] && [ -n "${FM_FAKE_OLLAMA_STATE:-}" ]; then
    : > "$FM_FAKE_OLLAMA_STATE"
  fi
fi
case "${1:-}" in
  is-active) [ -e "$state_prefix.active" ] ;;
  is-enabled) [ -e "$state_prefix.enabled" ] ;;
  show) printf '/usr/lib/systemd/system/ollama.service\n' ;;
  enable)
    : > "$state_prefix.enabled"
    [ "${FM_FAKE_SYSTEMCTL_ENABLE_FAIL_AFTER_CHANGE:-no}" != yes ] || exit 54
    ;;
  disable)
    rm -f "$state_prefix.enabled"
    ;;
  start)
    : > "$state_prefix.active"
    [ -n "${FM_FAKE_OLLAMA_STATE:-}" ] && : > "$FM_FAKE_OLLAMA_STATE"
    [ "${FM_FAKE_SYSTEMCTL_START_FAIL_AFTER_CHANGE:-no}" != yes ] || exit 56
    ;;
  stop)
    if [ "${FM_FAKE_SYSTEMCTL_STOP_FAIL:-no}" = yes ]; then
      printf 'fake Ollama stop failure\n' >&2
      exit 55
    fi
    rm -f "$state_prefix.active"
    [ -z "${FM_FAKE_OLLAMA_STATE:-}" ] || rm -f "$FM_FAKE_OLLAMA_STATE"
    ;;
  *) printf 'unexpected systemctl mutation: %s\n' "$*" >&2; exit 92 ;;
esac
SH
  cat > "$fakebin/sudo" <<'SH'
#!/usr/bin/env bash
exec "$@"
SH
  cat > "$fakebin/ss" <<'SH'
#!/usr/bin/env bash
[ -n "${FM_FAKE_SS_LISTENER:-}" ] && printf 'LISTEN 0 4096 %s 0.0.0.0:*\n' "$FM_FAKE_SS_LISTENER"
exit 0
SH
  cat > "$fakebin/ollama" <<'SH'
#!/usr/bin/env bash
[ -n "${FM_FAKE_LOG:-}" ] && printf 'ollama args=%s\n' "$*" >> "$FM_FAKE_LOG"
case "${1:-}" in
  --version) printf 'ollama version 0.32.6\n' ;;
  ps)
    printf 'NAME ID SIZE PROCESSOR\n'
    [ -z "${FM_FAKE_MODEL_RUNTIME_STATE:-}" ] || [ ! -e "$FM_FAKE_MODEL_RUNTIME_STATE" ] \
      || printf 'nomic-embed-text:latest abc 274 MB 100%% CPU\n'
    ;;
  stop)
    [ -z "${FM_FAKE_MODEL_RUNTIME_STATE:-}" ] || rm -f "$FM_FAKE_MODEL_RUNTIME_STATE"
    ;;
  *) printf 'unexpected ollama call: %s\n' "$*" >&2; exit 94 ;;
esac
SH
  cat > "$fakebin/grepai" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_FAKE_LOG:-}" ]; then
  printf 'grepai pid=%s pgid=%s cwd=%s args=%s\n' "$$" "$(ps -o pgid= -p $$ | tr -d ' ')" "$PWD" "$*" >> "$FM_FAKE_LOG"
fi
case "${1:-}" in
  version) printf 'grepai version 0.35.0\n' ;;
  init)
    mkdir -p .grepai
    printf 'provider: ollama\nmodel: nomic-embed-text:latest\nbackend: gob\n' > .grepai/config.yaml
    ;;
  status)
    [ "${FM_FAKE_HANG_COMMAND:-}" != grepai-status ] || sleep 3
    [ "${FM_FAKE_GREPAI_HEALTH:-healthy}" = healthy ] || exit 41
    printf 'healthy grepai index\n'
    ;;
  search)
    [ "${FM_FAKE_HANG_COMMAND:-}" != grepai-search ] || sleep 3
    case "${2:-}" in
      fm_incremental_probe_*)
        matched=$(grep -Rsl --exclude-dir=.grepai -- "${2:-}" . | head -n 1)
        matched=${matched#./}
        jq -nc --arg path "$matched" '[{path:$path}]'
        ;;
      *) printf '[{"path":"src/main.rs"}]\n' ;;
    esac
    ;;
  watch)
    case "${2:-}" in
      --background)
        grep -Fxq 'endpoint: http://127.0.0.1:11434' .grepai/config.yaml || {
          printf 'watch refused config without explicit loopback endpoint\n' >&2
          exit 40
        }
        if [ "${FM_FAKE_WATCH_HANG:-no}" = yes ]; then
          if [ "${FM_FAKE_WATCH_TERM_RESISTANT:-no}" = yes ]; then
            bash -c 'trap "" TERM; end=$((SECONDS + 8)); while [ "$SECONDS" -lt "$end" ]; do sleep 1; done' &
          else
            sleep 30 &
          fi
          child=$!
          [ -n "${FM_FAKE_CHILD_PID_FILE:-}" ] && printf '%s\n%s\n' "$child" "$(date +%s)" > "$FM_FAKE_CHILD_PID_FILE"
          wait "$child"
        else
          if [ "${FM_FAKE_WATCH_CPU_BURST:-no}" = yes ]; then
            setsid bash -c 'end=$((SECONDS + 1)); while [ "$SECONDS" -lt "$end" ]; do :; done; sleep 60' </dev/null >/dev/null 2>&1 &
          else
            setsid sleep 60 </dev/null >/dev/null 2>&1 &
          fi
          watcher_pid=$!
          disown "$watcher_pid" 2>/dev/null || true
          printf '%s\n' "$watcher_pid" > .grepai/fake-watcher.pid
          exec /bin/true
        fi
        ;;
      --status)
        [ "${FM_FAKE_WATCH_STATUS_FAIL:-no}" != yes ] || exit 46
        pid=$(cat .grepai/fake-watcher.pid 2>/dev/null || true)
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || exit 1
        printf 'Watcher: running (PID %s)\n' "$pid"
        ;;
      --stop)
        [ "${FM_FAKE_HANG_COMMAND:-}" != grepai-stop ] || sleep 3
        pid=$(cat .grepai/fake-watcher.pid 2>/dev/null || true)
        [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
        rm -f .grepai/fake-watcher.pid
        ;;
      *) printf 'unexpected grepai watch call: %s\n' "$*" >&2; exit 95 ;;
    esac
    ;;
  mcp-serve)
    [ -z "${FM_FAKE_MCP_PID_FILE:-}" ] || printf '%s\n' "$$" > "$FM_FAKE_MCP_PID_FILE"
    if [ "${FM_FAKE_MCP_TERM_RESISTANT:-no}" = yes ]; then
      trap '' TERM
    fi
    while IFS= read -r line; do
      case "$line" in
        *'"id":1'*) printf '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"grepai","version":"test"}}}\n' ;;
        *'"id":2'*) printf '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"grepai_search"}]}}\n' ;;
      esac
    done
    if [ "${FM_FAKE_MCP_TERM_RESISTANT:-no}" = yes ]; then
      end=$((SECONDS + 8))
      while [ "$SECONDS" -lt "$end" ]; do sleep 1; done
    fi
    ;;
  *) printf 'unexpected grepai mutation: %s\n' "$*" >&2; exit 95 ;;
esac
SH
  cat > "$fakebin/codegraph" <<'SH'
#!/usr/bin/env bash
[ -n "${FM_FAKE_LOG:-}" ] && printf 'codegraph cwd=%s args=%s\n' "$PWD" "$*" >> "$FM_FAKE_LOG"
case "${1:-}" in
  --version) printf '1.5.0\n' ;;
  status)
    [ "${FM_FAKE_HANG_COMMAND:-}" != codegraph-status ] || sleep 3
    if [ "${FM_FAKE_CODEGRAPH_HEALTH:-healthy}" = healthy ]; then
      printf '{"initialized":true,"journalMode":"wal","worktreeMismatch":null,"pendingChanges":{"added":0,"modified":0,"removed":0},"index":{"state":"complete","pendingRefs":0,"reindexRecommended":false}}\n'
    else
      printf '{"initialized":false,"journalMode":"delete","worktreeMismatch":"wrong","pendingChanges":{"added":1},"index":{"state":"stale","pendingRefs":1,"reindexRecommended":true}}\n'
    fi
    ;;
  query)
    [ "${FM_FAKE_HANG_COMMAND:-}" != codegraph-query ] || sleep 3
    printf '[{"node":{"filePath":"src/main.rs"}}]\n'
    ;;
  init)
    [ "${FM_FAKE_HANG_COMMAND:-}" != codegraph-init ] || sleep 3
    target=${2:-}
    mkdir -p "$target/.codegraph"
    printf 'sqlite fixture\n' > "$target/.codegraph/codegraph.db"
    [ "${FM_FAKE_PARTIAL_INITIALIZER:-}" != codegraph ] || exit 43
    ;;
  serve)
    while IFS= read -r line; do
      case "$line" in
        *'"id":1'*) printf '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"codegraph","version":"test"}}}\n' ;;
        *'"id":2'*) printf '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"codegraph_explore"}]}}\n' ;;
      esac
    done
    ;;
  *) printf 'unexpected CodeGraph mutation: %s\n' "$*" >&2; exit 96 ;;
esac
SH
  cat > "$fakebin/serena" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_FAKE_LOG:-}" ]; then
  printf 'serena cwd=%s args=%s\n' "$PWD" "$*" >> "$FM_FAKE_LOG"
fi
assert_offline_managed_runtime() {
  [ "${FM_FAKE_SERENA_OFFLINE_RERUN:-no}" = yes ] || return 0
  expected_root=${FM_FAKE_SERENA_MANAGED_ROOT:?}
  [ "$HOME" = "$expected_root/runtime-home" ] \
    && [ "$SERENA_HOME" = "$expected_root/home" ] \
    && [ "$XDG_CACHE_HOME" = "$expected_root/runtime-home/.cache" ] \
    && [ "$XDG_STATE_HOME" = "$expected_root/runtime-home/.local/state" ] \
    && [ "${UV_OFFLINE:-}" = 1 ] \
    && [ "${npm_config_offline:-}" = true ] \
    && [ "${PIP_NO_INDEX:-}" = 1 ] \
    && [ "${HTTPS_PROXY:-}" = http://127.0.0.1:9 ] \
    && [ -f "$HOME/.solidlsp/cache.ready" ] || {
      [ -z "${FM_FAKE_NETWORK_ATTEMPT:-}" ] || : > "$FM_FAKE_NETWORK_ATTEMPT"
      exit 44
    }
}
case "${1:-}" in
  --version) printf 'Serena 1.6.1\n' ;;
  project)
    case "${2:-}" in
      health-check)
        target=${3:-}
        log_dir="$target/.serena/logs/health-checks"
        log_file="$log_dir/health_check_fake_$$.log"
        mkdir -p "$log_dir"
        printf health > "$log_file"
        printf 'Log saved to: %s\n' "$log_file"
        assert_offline_managed_runtime
        [ "${FM_FAKE_SERENA_HEALTH:-healthy}" = healthy ] || exit 42
        printf 'Health check passed - All tools working correctly\n'
        ;;
      create)
        target=${!#}
        mkdir -p "$target/.serena"
        printf 'languages:\n- rust\n- typescript\n- python\n' > "$target/.serena/project.yml"
        ;;
      *) printf 'unexpected Serena project mutation: %s\n' "$*" >&2; exit 97 ;;
    esac
    ;;
  start-mcp-server)
    assert_offline_managed_runtime
    while IFS= read -r line; do
      case "$line" in
        *'"id":1'*) printf '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"serena","version":"test"}}}\n' ;;
        *'"id":2'*) printf '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"find_symbol"}]}}\n' ;;
      esac
    done
    ;;
  *) printf 'unexpected Serena mutation: %s\n' "$*" >&2; exit 98 ;;
esac
SH
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'/api/version'*)
    [ "${FM_FAKE_API_UNHEALTHY:-no}" != yes ] || exit 7
    if [ "${FM_FAKE_API_REQUIRES_START:-no}" = yes ] \
      && { [ -z "${FM_FAKE_OLLAMA_STATE:-}" ] || [ ! -f "$FM_FAKE_OLLAMA_STATE" ]; }; then
      exit 7
    fi
    printf '{"version":"0.32.6"}\n'
    ;;
  *'/api/tags'*)
    jq -nc \
      --arg digest "${FM_FAKE_MODEL_DIGEST:-0a109f422b47e3a30ba2b10eca18548e944e8a23073ee3f3e947efcf3c45e59f}" \
      --argjson size "${FM_FAKE_MODEL_SIZE:-274302450}" \
      '{models:[{name:"nomic-embed-text:latest",model:"nomic-embed-text:latest",digest:$digest,size:$size}]}'
    ;;
  *'/api/show'*)
    jq -nc \
      --arg quantization "${FM_FAKE_MODEL_QUANTIZATION:-F16}" \
      --argjson dimensions "${FM_FAKE_MODEL_DIMENSIONS:-768}" \
      '{details:{format:"gguf",family:"nomic-bert",parameter_size:"137M",quantization_level:$quantization},model_info:{"nomic-bert.embedding_length":$dimensions}}'
    ;;
  *'/api/embed'*)
    if [ "${FM_FAKE_HANG_MICRO:-no}" = yes ] && [[ "$*" != *local_index_health_probe* ]]; then sleep 3; fi
    if [[ "$*" != *local_index_health_probe* ]] && [ "${FM_FAKE_REQUIRE_COLD_MICRO:-no}" = yes ] \
      && { [ -z "${FM_FAKE_COLD_PROOF:-}" ] || [ ! -e "$FM_FAKE_COLD_PROOF" ]; }; then
      [ -z "${FM_FAKE_MODEL_RUNTIME_STATE:-}" ] || [ ! -e "$FM_FAKE_MODEL_RUNTIME_STATE" ] || exit 67
      [ -z "${FM_FAKE_COLD_PROOF:-}" ] || : > "$FM_FAKE_COLD_PROOF"
    fi
    [ -z "${FM_FAKE_MODEL_RUNTIME_STATE:-}" ] || : > "$FM_FAKE_MODEL_RUNTIME_STATE"
    cat "$FM_FAKE_EMBED_RESPONSE"
    ;;
  *) printf 'unexpected curl network request: %s\n' "$*" >&2; exit 99 ;;
esac
SH
  chmod +x "$fakebin"/*
  printf '%s\n' "$dir"
}

run_kit() {
  local dir=$1
  shift
  FM_INDEX_OS_RELEASE="$dir/os-release" \
    FM_INDEX_MEMINFO="$dir/meminfo" \
    FM_INDEX_LOADAVG="$dir/loadavg" \
    FM_INDEX_UNAME_M=x86_64 \
    FM_INDEX_THERMAL_ROOT="$dir/thermal" \
    FM_INDEX_INOTIFY_MAX_USER_WATCHES="$dir/inotify-max-user-watches" \
    FM_INDEX_INOTIFY_MAX_USER_INSTANCES="$dir/inotify-max-user-instances" \
    FM_INDEX_PHYSICAL_CORES=8 \
    FM_REAL_GIT="${FM_REAL_GIT:-}" \
    FM_FAKE_EMBED_RESPONSE="$dir/embed-response.json" \
    FM_FAKE_LOG="${FM_FAKE_LOG:-}" \
    FM_FAKE_WATCH_HANG="${FM_FAKE_WATCH_HANG:-no}" \
    FM_FAKE_WATCH_TERM_RESISTANT="${FM_FAKE_WATCH_TERM_RESISTANT:-no}" \
    FM_FAKE_WATCH_STATUS_FAIL="${FM_FAKE_WATCH_STATUS_FAIL:-no}" \
    FM_FAKE_WATCH_CPU_BURST="${FM_FAKE_WATCH_CPU_BURST:-no}" \
    FM_FAKE_MCP_TERM_RESISTANT="${FM_FAKE_MCP_TERM_RESISTANT:-no}" \
    FM_FAKE_MCP_PID_FILE="${FM_FAKE_MCP_PID_FILE:-}" \
    FM_FAKE_CHILD_PID_FILE="${FM_FAKE_CHILD_PID_FILE:-}" \
    FM_FAKE_GENERATOR_LOG="${FM_FAKE_GENERATOR_LOG:-}" \
    FM_FAKE_MODEL_DIGEST="${FM_FAKE_MODEL_DIGEST:-}" \
    FM_FAKE_MODEL_SIZE="${FM_FAKE_MODEL_SIZE:-}" \
    FM_FAKE_MODEL_QUANTIZATION="${FM_FAKE_MODEL_QUANTIZATION:-}" \
    FM_FAKE_MODEL_DIMENSIONS="${FM_FAKE_MODEL_DIMENSIONS:-}" \
    FM_FAKE_MODEL_RUNTIME_STATE="$dir/model.running" \
    FM_FAKE_REQUIRE_COLD_MICRO="${FM_FAKE_REQUIRE_COLD_MICRO:-no}" \
    FM_FAKE_COLD_PROOF="${FM_FAKE_COLD_PROOF:-}" \
    FM_FAKE_GREPAI_HEALTH="${FM_FAKE_GREPAI_HEALTH:-}" \
    FM_FAKE_CODEGRAPH_HEALTH="${FM_FAKE_CODEGRAPH_HEALTH:-}" \
    FM_FAKE_SERENA_HEALTH="${FM_FAKE_SERENA_HEALTH:-}" \
    FM_FAKE_HANG_COMMAND="${FM_FAKE_HANG_COMMAND:-}" \
    FM_FAKE_HANG_MICRO="${FM_FAKE_HANG_MICRO:-no}" \
    FM_FAKE_PARTIAL_INITIALIZER="${FM_FAKE_PARTIAL_INITIALIZER:-}" \
    FM_FAKE_SS_LISTENER="${FM_FAKE_SS_LISTENER:-}" \
    FM_FAKE_API_REQUIRES_START="${FM_FAKE_API_REQUIRES_START:-no}" \
    FM_FAKE_API_UNHEALTHY="${FM_FAKE_API_UNHEALTHY:-no}" \
    FM_FAKE_OLLAMA_STATE="${FM_FAKE_OLLAMA_STATE:-}" \
    FM_FAKE_SYSTEMCTL_STATE_PREFIX="$dir/systemctl-state" \
    FM_FAKE_SERVICE_ACTIVE_BEFORE="${FM_FAKE_SERVICE_ACTIVE_BEFORE:-no}" \
    FM_FAKE_SERVICE_ENABLED_BEFORE="${FM_FAKE_SERVICE_ENABLED_BEFORE:-no}" \
    FM_FAKE_SYSTEMCTL_ENABLE_FAIL_AFTER_CHANGE="${FM_FAKE_SYSTEMCTL_ENABLE_FAIL_AFTER_CHANGE:-no}" \
    FM_FAKE_SYSTEMCTL_START_FAIL_AFTER_CHANGE="${FM_FAKE_SYSTEMCTL_START_FAIL_AFTER_CHANGE:-no}" \
    FM_FAKE_SYSTEMCTL_STOP_FAIL="${FM_FAKE_SYSTEMCTL_STOP_FAIL:-no}" \
    FM_FAKE_SERENA_OFFLINE_RERUN="${FM_FAKE_SERENA_OFFLINE_RERUN:-no}" \
    FM_FAKE_SERENA_MANAGED_ROOT="${FM_FAKE_SERENA_MANAGED_ROOT:-}" \
    FM_FAKE_NETWORK_ATTEMPT="${FM_FAKE_NETWORK_ATTEMPT:-}" \
    HOME="$dir/home" \
    XDG_RUNTIME_DIR="$dir/runtime" \
    PATH="$dir/fakebin:$PATH" \
    "$SCRIPT" \
      --project "${FM_TEST_PROJECT:-$dir/project}" \
      --ollama-owner arch \
      --ollama-accel cpu \
      --ignore-policy defaults \
      --state-policy local-ignored \
      --serena-language rust \
      --serena-language typescript \
      --serena-language python \
      --allow-language-downloads no \
      --telemetry off \
      --benchmark no \
      --health-query main \
      --mcp-client none \
      --mcp-scope print \
      --persistent-grepai-watch no \
      --destructive-rollback no \
      --install-root "$dir/install-parent/tools" \
      --bin-dir "$dir/fakebin" \
      "$@"
}

test_help_and_plan_are_read_only() {
  local dir out before after before_exclude after_exclude
  dir=$(new_fixture plan)
  "$SCRIPT" --help | grep -F -- '--persistent-grepai-watch no' >/dev/null || fail "help omitted the watcher decision"
  before=$(git -C "$dir/project" status --porcelain=v1)
  before_exclude=$(sha256sum "$dir/project/.git/info/exclude")
  out=$(run_kit "$dir" --action plan --pull-model yes --start-ollama yes --persist-ollama no --install-tools no --init grepai,codegraph,serena)
  after=$(git -C "$dir/project" status --porcelain=v1)
  after_exclude=$(sha256sum "$dir/project/.git/info/exclude")
  assert_contains "$out" "platform os=cachyos arch=x86_64" "plan platform inventory"
  assert_contains "$out" "grepai_candidates files=3" "plan scanner census"
  assert_contains "$out" "extensions=" "plan extension distribution"
  assert_contains "$out" "inotify_max_user_watches=1048576" "plan inotify capacity"
  assert_contains "$out" "cpu_physical_cores=8" "plan physical CPU evidence"
  assert_contains "$out" "accelerator=cpu" "plan accelerator evidence"
  assert_contains "$out" "filesystem=ext4" "plan filesystem topology evidence"
  assert_contains "$out" "plan complete; no package, service, model, index, MCP, or rollback-manifest state was changed" "plan no-mutation result"
  [ "$before" = "$after" ] || fail "plan changed project state"
  [ "$before_exclude" = "$after_exclude" ] || fail "plan changed the local exclude file"
  [ ! -e "$dir/install-parent/tools" ] || fail "plan created the install root"
  pass "indexing recovery: help is explicit and plan inventories without mutation"
}

test_inventory_is_hard_bounded_and_inotify_capacity_fails_closed() {
  local dir out rc real_git before_exclude
  dir=$(new_fixture inventory-timeout)
  real_git=$(command -v git)
  # shellcheck disable=SC2016 # The generated fake expands these variables at runtime.
  printf '#!/usr/bin/env bash\ncase " $* " in *" ls-files "*) sleep 3 ;; esac\nexec "$FM_REAL_GIT" "$@"\n' \
    > "$dir/fakebin/git"
  chmod +x "$dir/fakebin/git"
  FM_REAL_GIT="$real_git" \
    out=$(run_kit "$dir" --action plan --pull-model no --start-ollama no --persist-ollama no --install-tools no \
      --init none --inventory-timeout-seconds 1 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "hung source inventory passed"
  assert_contains "$out" "source inventory exceeded its 1s hard timeout" "inventory hard-timeout refusal"

  dir=$(new_fixture inotify-exhaustion)
  printf '2\n' > "$dir/inotify-max-user-watches"
  before_exclude=$(sha256sum "$dir/project/.git/info/exclude")
  out=$(run_kit "$dir" --action apply --pull-model no --start-ollama no --persist-ollama no --install-tools no \
    --init serena --allow-language-downloads yes --rollback-manifest "$dir/rollback.log" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "exhausted inotify capacity passed"
  assert_contains "$out" "inotify max_user_watches" "inotify capacity refusal"
  [ "$before_exclude" = "$(sha256sum "$dir/project/.git/info/exclude")" ] || fail "inotify refusal happened after exclude mutation"
  [ ! -e "$dir/rollback.log" ] || fail "inotify refusal happened after manifest mutation"
  unset FM_REAL_GIT
  pass "indexing recovery: complete inventory is bounded and inotify capacity fails closed"
}

test_fail_closed_preflight_matrix() {
  local dir out rc
  dir=$(new_fixture refusals)
  printf 'ID=ubuntu\nID_LIKE=debian\n' > "$dir/os-release"
  out=$(run_kit "$dir" --action plan --pull-model no --start-ollama no --persist-ollama no --install-tools no --init none 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "unsupported OS passed"
  assert_contains "$out" "unsupported OS 'ubuntu'" "unsupported OS refusal"

  printf 'ID=cachyos\nID_LIKE=arch\n' > "$dir/os-release"
  out=$(FM_INDEX_OS_RELEASE="$dir/os-release" FM_INDEX_MEMINFO="$dir/meminfo" FM_INDEX_LOADAVG="$dir/loadavg" FM_INDEX_UNAME_M=x86_64 HOME="$dir/home" XDG_RUNTIME_DIR="$dir/runtime" PATH="$dir/fakebin:$PATH" "$SCRIPT" \
    --action plan --project "$dir/project" --ollama-owner arch --ollama-accel cpu --pull-model no --start-ollama no --persist-ollama no --install-tools no --init none \
    --ignore-policy defaults --state-policy local-ignored --serena-language rust --allow-language-downloads no --telemetry off --benchmark no --health-query main \
    --mcp-client none --mcp-scope print --persistent-grepai-watch no --destructive-rollback no --install-root "$dir/install-parent/tools" --bin-dir "$dir/fakebin" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "unselected detected languages passed"
  assert_contains "$out" "detected Serena language 'typescript' is not selected" "polyglot refusal"

  out=$(run_kit "$dir" --action plan --pull-model no --start-ollama no --persist-ollama no --install-tools no --init none --min-free-ram-mib 20000 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "insufficient RAM passed"
  assert_contains "$out" "insufficient available RAM" "resource refusal"

  out=$(run_kit "$dir" --action plan --pull-model no --start-ollama no --persist-ollama no --install-tools no --init none --persistent-grepai-watch yes 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "persistent grepai watch passed"
  assert_contains "$out" "persistent grepai watching is intentionally unsupported" "watcher refusal"

  out=$(run_kit "$dir" --action plan --pull-model no --start-ollama no --persist-ollama no --install-tools no --init none \
    --benchmark yes --benchmark-query 'one=a' --benchmark-query 'two=b' --benchmark-query 'three=c' \
    --benchmark-query 'four=d' --benchmark-query 'five=e' --benchmark-query 'six=f' 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "six-query benchmark passed the exact-five contract"
  assert_contains "$out" "requires exactly five" "exact-five benchmark refusal"
  pass "indexing recovery: OS, polyglot, resource, and daemon hazards fail closed"
}

test_unset_runtime_uses_private_home_lock_without_following_public_symlink() {
  local dir public_tmp target out rc
  dir=$(new_fixture unsafe-public-lock)
  public_tmp="$dir/public-tmp"
  target="$dir/lock-target"
  mkdir -p "$public_tmp"
  chmod 1777 "$public_tmp"
  printf 'do-not-truncate\n' > "$target"
  ln -s "$target" "$public_tmp/fm-indexing-tools-cachyos.lock"

  out=$(env -u XDG_RUNTIME_DIR \
    FM_INDEX_OS_RELEASE="$dir/os-release" \
    FM_INDEX_MEMINFO="$dir/meminfo" \
    FM_INDEX_LOADAVG="$dir/loadavg" \
    FM_INDEX_UNAME_M=x86_64 \
    TMPDIR="$public_tmp" \
    HOME="$dir/home" \
    PATH="$dir/fakebin:$PATH" \
    "$SCRIPT" \
      --action plan \
      --project "$dir/project" \
      --ollama-owner arch \
      --ollama-accel cpu \
      --pull-model no \
      --start-ollama no \
      --persist-ollama no \
      --install-tools no \
      --init none \
      --ignore-policy defaults \
      --state-policy local-ignored \
      --serena-language rust \
      --serena-language typescript \
      --serena-language python \
      --allow-language-downloads no \
      --telemetry off \
      --benchmark no \
      --health-query main \
      --mcp-client none \
      --mcp-scope print \
      --persistent-grepai-watch no \
      --destructive-rollback no \
      --install-root "$dir/install-parent/tools" \
      --bin-dir "$dir/fakebin" 2>&1); rc=$?
  [ "$(cat "$target")" = 'do-not-truncate' ] || fail "public-temp lock symlink target was modified"
  [ "$rc" -eq 0 ] || fail "unset XDG_RUNTIME_DIR did not use a safe owner-private fallback: $out"
  assert_contains "$out" "plan complete" "private lock fallback completion"
  [ -f "$dir/home/.fm-indexing-tools-cachyos-locks/recovery.lock" ] || fail "private fallback lock was not created under HOME"
  [ "$(stat -c %a "$dir/home/.fm-indexing-tools-cachyos-locks")" = 700 ] || fail "private fallback lock directory is not mode 0700"
  pass "indexing recovery: unset runtime uses a private lock without following a public-temp symlink"
}

test_temporary_ollama_stop_failure_is_terminal_without_masking_primary_failure() {
  local dir out rc
  dir=$(new_fixture ollama-cleanup-failure)
  : > "$dir/fake.log"
  FM_FAKE_LOG="$dir/fake.log" FM_FAKE_API_REQUIRES_START=yes FM_FAKE_OLLAMA_STATE="$dir/ollama.started" \
    FM_FAKE_SYSTEMCTL_STOP_FAIL=yes \
    out=$(run_kit "$dir" --action apply --pull-model no --start-ollama yes --persist-ollama no --install-tools no \
      --init none --rollback-manifest "$dir/rollback.log" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "temporary Ollama stop failure was reported as success"
  assert_contains "$out" "could not stop task-started Ollama service" "temporary Ollama cleanup failure"
  grep -Fq 'systemctl args=start ollama' "$dir/fake.log" || fail "cleanup fixture did not start Ollama"
  grep -Fq 'systemctl args=stop ollama' "$dir/fake.log" || fail "cleanup fixture did not attempt Ollama stop"

  dir=$(new_fixture ollama-primary-and-cleanup-failure)
  : > "$dir/fake.log"
  FM_FAKE_LOG="$dir/fake.log" FM_FAKE_API_REQUIRES_START=yes FM_FAKE_OLLAMA_STATE="$dir/ollama.started" \
    FM_FAKE_SYSTEMCTL_STOP_FAIL=yes FM_FAKE_MODEL_DIGEST=wrong \
    out=$(run_kit "$dir" --action apply --pull-model no --start-ollama yes --persist-ollama no --install-tools no \
      --init none --rollback-manifest "$dir/rollback.log" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "combined primary and Ollama cleanup failure was reported as success"
  assert_contains "$out" "model digest 'wrong'" "preserved primary model failure"
  assert_contains "$out" "could not stop task-started Ollama service" "surfaced secondary cleanup failure"
  unset FM_FAKE_LOG FM_FAKE_API_REQUIRES_START FM_FAKE_OLLAMA_STATE FM_FAKE_SYSTEMCTL_STOP_FAIL FM_FAKE_MODEL_DIGEST
  pass "indexing recovery: task-started Ollama cleanup failure is terminal without masking the primary failure"
}

test_preexisting_active_ollama_is_never_adopted_or_stopped() {
  local dir out rc before_exclude after_exclude
  dir=$(new_fixture preexisting-active-ollama)
  : > "$dir/fake.log"
  before_exclude=$(sha256sum "$dir/project/.git/info/exclude")
  FM_FAKE_LOG="$dir/fake.log" FM_FAKE_SERVICE_ACTIVE_BEFORE=yes FM_FAKE_API_UNHEALTHY=yes \
    FM_FAKE_OLLAMA_STATE="$dir/ollama.started" \
    out=$(run_kit "$dir" --action apply --pull-model no --start-ollama yes --persist-ollama no --install-tools no \
      --init none --rollback-manifest "$dir/rollback.log" 2>&1); rc=$?
  after_exclude=$(sha256sum "$dir/project/.git/info/exclude")
  [ "$rc" -ne 0 ] || fail "unhealthy pre-existing active Ollama was adopted"
  assert_contains "$out" "pre-existing active Ollama service" "pre-existing service ownership refusal"
  ! grep -Eq 'systemctl args=(start|stop|enable|disable)' "$dir/fake.log" \
    || fail "pre-existing active Ollama was mutated or stopped"
  [ "$before_exclude" = "$after_exclude" ] || fail "pre-existing Ollama refusal happened after exclude mutation"
  [ ! -e "$dir/rollback.log" ] || fail "pre-existing Ollama refusal happened after rollback-manifest mutation"
  unset FM_FAKE_LOG FM_FAKE_SERVICE_ACTIVE_BEFORE FM_FAKE_API_UNHEALTHY FM_FAKE_OLLAMA_STATE
  pass "indexing recovery: pre-existing active Ollama is never adopted or stopped"
}

test_canonical_grepai_watcher_is_reconciled_without_adoption() {
  local dir out rc watcher_pid
  dir=$(new_fixture canonical-watcher)
  mkdir -p "$dir/project/.grepai"
  printf 'provider: ollama\nmodel: nomic-embed-text:latest\nbackend: gob\nendpoint: http://127.0.0.1:11434\n' \
    > "$dir/project/.grepai/config.yaml"
  setsid sleep 30 &
  watcher_pid=$!
  printf '%s\n' "$watcher_pid" > "$dir/project/.grepai/fake-watcher.pid"
  : > "$dir/fake.log"
  FM_FAKE_LOG="$dir/fake.log" \
    out=$(run_kit "$dir" --action health --pull-model no --start-ollama no --persist-ollama no --install-tools no \
      --init none 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "pre-existing canonical grepai watcher passed no-persistence policy"
  assert_contains "$out" "pre-existing canonical grepai watcher" "canonical watcher ownership refusal"
  grep -Fq 'args=watch --status' "$dir/fake.log" || fail "canonical watcher state was not inventoried"
  ! grep -Fq 'args=watch --stop' "$dir/fake.log" || fail "pre-existing canonical watcher was stopped"
  kill -0 "$watcher_pid" 2>/dev/null || fail "pre-existing canonical watcher was terminated"
  kill "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true
  unset FM_FAKE_LOG
  pass "indexing recovery: canonical grepai watcher is reconciled without adoption"
}

test_partial_ollama_service_transitions_are_reconciled() {
  local dir out rc
  dir=$(new_fixture partial-ollama-enable)
  : > "$dir/fake.log"
  FM_FAKE_LOG="$dir/fake.log" FM_FAKE_API_REQUIRES_START=yes FM_FAKE_OLLAMA_STATE="$dir/ollama.started" \
    FM_FAKE_SYSTEMCTL_ENABLE_FAIL_AFTER_CHANGE=yes \
    out=$(run_kit "$dir" --action apply --pull-model no --start-ollama yes --persist-ollama yes --install-tools no \
      --init none --rollback-manifest "$dir/rollback.log" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "partial Ollama enable failure passed"
  grep -Fq 'systemctl args=disable ollama' "$dir/fake.log" || fail "partial Ollama enable was not reconciled"
  ! grep -Fq 'systemctl args=stop ollama' "$dir/fake.log" || fail "enable-only failure stopped an Ollama service it did not start"

  dir=$(new_fixture partial-ollama-start)
  : > "$dir/fake.log"
  FM_FAKE_LOG="$dir/fake.log" FM_FAKE_API_REQUIRES_START=yes FM_FAKE_OLLAMA_STATE="$dir/ollama.started" \
    FM_FAKE_SYSTEMCTL_ENABLE_FAIL_AFTER_CHANGE=no FM_FAKE_SYSTEMCTL_START_FAIL_AFTER_CHANGE=yes \
    out=$(run_kit "$dir" --action apply --pull-model no --start-ollama yes --persist-ollama yes --install-tools no \
      --init none --rollback-manifest "$dir/rollback.log" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "partial Ollama start failure passed"
  grep -Fq 'systemctl args=stop ollama' "$dir/fake.log" || fail "partial Ollama start was not reconciled"
  grep -Fq 'systemctl args=disable ollama' "$dir/fake.log" || fail "persistent enable was not reconciled after start failure"
  assert_contains "$(cat "$dir/rollback.log")" "planned_service_transition=ollama active:no->yes" "planned Ollama start transition"
  unset FM_FAKE_LOG FM_FAKE_API_REQUIRES_START FM_FAKE_OLLAMA_STATE \
    FM_FAKE_SYSTEMCTL_ENABLE_FAIL_AFTER_CHANGE FM_FAKE_SYSTEMCTL_START_FAIL_AFTER_CHANGE
  pass "indexing recovery: partial Ollama enable/start transitions are durably reconciled"
}

test_serena_download_refusal_and_exact_model_identity() {
  local dir out rc
  dir=$(new_fixture dependency-and-model-policy)
  : > "$dir/fake.log"

  FM_FAKE_LOG="$dir/fake.log" out=$(run_kit "$dir" --action apply --pull-model no --start-ollama no --persist-ollama no --install-tools no \
    --init serena --allow-language-downloads no --rollback-manifest "$dir/rollback.log" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "Serena execution passed with language downloads forbidden"
  assert_contains "$out" "cannot prove Serena dependency resolution is network-free" "Serena no-download refusal"
  ! grep -E 'args=(project|start-mcp-server)' "$dir/fake.log" >/dev/null || fail "Serena dependency execution started after no-download refusal"
  [ ! -e "$dir/rollback.log" ] || fail "Serena no-download refusal occurred after mutation"

  FM_FAKE_MODEL_DIGEST=sha256:wrong out=$(run_kit "$dir" --action health --pull-model no --start-ollama no --persist-ollama no --install-tools no --init none 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "unexpected nomic model digest passed"
  assert_contains "$out" "model digest" "exact model digest refusal"

  FM_FAKE_MODEL_DIGEST='' FM_FAKE_MODEL_QUANTIZATION=Q4_K_M out=$(run_kit "$dir" --action health --pull-model no --start-ollama no --persist-ollama no --install-tools no --init none 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "non-F16 nomic model passed"
  assert_contains "$out" "quantization" "F16 model refusal"
  unset FM_FAKE_MODEL_DIGEST FM_FAKE_MODEL_QUANTIZATION
  pass "indexing recovery: Serena downloads and nomic model identity fail closed"
}

test_grepai_config_rejects_commented_local_values_and_missing_endpoint() {
  local dir out rc
  dir=$(new_fixture malicious-grepai-config)
  mkdir -p "$dir/project/.grepai"
  cat > "$dir/project/.grepai/config.yaml" <<'YAML'
# provider: ollama
provider: remote
# model: nomic-embed-text:latest
model: cloud-embedding
# backend: gob
backend: cloud
endpoint: http://127.0.0.1:11434
YAML
  : > "$dir/fake.log"

  FM_FAKE_LOG="$dir/fake.log" out=$(run_kit "$dir" --action health --pull-model no --start-ollama no --persist-ollama no --install-tools no --init none 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "commented local grepai values bypassed active config validation"
  assert_contains "$out" "provider is 'remote'" "grepai commented-value refusal"
  ! grep -F 'args=status --no-ui' "$dir/fake.log" >/dev/null || fail "grepai health started before active config refusal"

  cat > "$dir/project/.grepai/config.yaml" <<'YAML'
provider: ollama
model: nomic-embed-text:latest
backend: gob
YAML
  out=$(run_kit "$dir" --action health --pull-model no --start-ollama no --persist-ollama no --install-tools no --init none 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "missing grepai endpoint passed as local"
  assert_contains "$out" "exactly one active non-empty endpoint" "grepai missing-endpoint refusal"

  cat > "$dir/project/.grepai/config.yaml" <<'YAML'
provider: ollama
provider: remote
model: nomic-embed-text:latest
backend: gob
endpoint: http://127.0.0.1:11434
YAML
  out=$(run_kit "$dir" --action health --pull-model no --start-ollama no --persist-ollama no --install-tools no --init none 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "duplicate grepai provider values passed as unambiguous"
  assert_contains "$out" "exactly one active" "grepai duplicate-value refusal"
  pass "indexing recovery: grepai config rejects comments, missing fields, and duplicates before health"
}

test_grepai_config_rejects_deceptive_remote_endpoint() {
  local dir out rc
  dir=$(new_fixture deceptive-grepai-endpoint)
  mkdir -p "$dir/project/.grepai"
  cat > "$dir/project/.grepai/config.yaml" <<'YAML'
provider: ollama
model: nomic-embed-text:latest
backend: gob
endpoint: http://localhost:1@api.example.com
YAML

  out=$(run_kit "$dir" --action health --pull-model no --start-ollama no --persist-ollama no --install-tools no --init none 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "userinfo-style remote grepai endpoint passed as loopback"
  assert_contains "$out" "not an explicit loopback Ollama URL" "deceptive grepai endpoint refusal"
  pass "indexing recovery: grepai config rejects deceptive remote endpoints"
}

test_dirty_apply_refuses_before_mutation() {
  local dir out rc before_exclude after_exclude
  dir=$(new_fixture dirty-apply)
  printf 'uncommitted\n' > "$dir/project/dirty.txt"
  before_exclude=$(sha256sum "$dir/project/.git/info/exclude")
  out=$(run_kit "$dir" --action apply --pull-model no --start-ollama no --persist-ollama no --install-tools no --init grepai --benchmark yes \
    --benchmark-query 'one=src/main.rs' --benchmark-query 'two=src/main.rs' --benchmark-query 'three=src/main.rs' --benchmark-query 'four=src/main.rs' --benchmark-query 'five=src/main.rs' \
    --rollback-manifest "$dir/rollback.log" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "dirty apply passed"
  assert_contains "$out" "project has 1 dirty entries" "dirty worktree refusal"
  after_exclude=$(sha256sum "$dir/project/.git/info/exclude")
  [ "$before_exclude" = "$after_exclude" ] || fail "dirty refusal changed local excludes"
  [ ! -e "$dir/rollback.log" ] || fail "dirty refusal created a rollback manifest"
  [ ! -e "$dir/project/.grepai" ] || fail "dirty refusal created grepai state"
  pass "indexing recovery: dirty apply refuses before any mutation"
}

test_linked_worktree_state_uses_git_canonical_exclude() {
  local dir linked out canonical_exclude
  dir=$(new_fixture linked-worktree-ignore)
  linked="$dir/linked-project"
  git -C "$dir/project" worktree add -q -b linked-fixture "$linked" HEAD

  FM_TEST_PROJECT="$linked" out=$(run_kit "$dir" --action apply --pull-model no --start-ollama no --persist-ollama no --install-tools no \
    --init serena --allow-language-downloads yes --rollback-manifest "$dir/rollback.log")
  assert_contains "$out" "complete action=apply project=$linked" "linked-worktree apply completion"
  canonical_exclude=$(git -C "$linked" rev-parse --git-path info/exclude)
  grep -Fxq '.serena/' "$canonical_exclude" || fail "canonical linked-worktree exclude omitted .serena/"
  git -C "$linked" check-ignore -q .serena/project.yml || fail "linked-worktree Serena state is not ignored"
  [ -z "$(git -C "$linked" status --porcelain=v1)" ] || fail "linked-worktree local state appears in Git status"
  unset FM_TEST_PROJECT
  pass "indexing recovery: linked worktrees use Git's canonical local exclude"
}

test_incompatible_existing_indexes_refuse_before_mutation() {
  local component dir before_exclude after_exclude out rc
  for component in grepai codegraph serena; do
    dir=$(new_fixture "preflight-$component")
    mkdir -p "$dir/project/.$component" "$dir/project/.git/info"
    case "$component" in
      grepai) printf 'provider: ollama\nmodel: nomic-embed-text:latest\nbackend: gob\nendpoint: http://127.0.0.1:11434\n' > "$dir/project/.grepai/config.yaml" ;;
      codegraph) printf 'sqlite fixture\n' > "$dir/project/.codegraph/codegraph.db" ;;
      serena)
        printf 'languages:\n- rust\n- typescript\n- python\n' > "$dir/project/.serena/project.yml"
        mkdir -p "$dir/install-parent/tools/serena/home" \
          "$dir/install-parent/tools/serena/runtime-home/.cache" \
          "$dir/install-parent/tools/serena/runtime-home/.local/state"
        ;;
    esac
    : > "$dir/project/.git/info/exclude"
    git -C "$dir/project" add -f ".$component"
    git -C "$dir/project" -c user.name=Test -c user.email=test@example.invalid commit -qm "seed $component state"
    before_exclude=$(sha256sum "$dir/project/.git/info/exclude")
    FM_FAKE_GREPAI_HEALTH=$([ "$component" = grepai ] && printf bad || printf healthy) \
    FM_FAKE_CODEGRAPH_HEALTH=$([ "$component" = codegraph ] && printf bad || printf healthy) \
    FM_FAKE_SERENA_HEALTH=$([ "$component" = serena ] && printf bad || printf healthy) \
      out=$(run_kit "$dir" --action apply --pull-model no --start-ollama no --persist-ollama no --install-tools no \
        --init "$component" --allow-language-downloads yes --rollback-manifest "$dir/rollback.log" 2>&1); rc=$?
    [ "$rc" -ne 0 ] || fail "incompatible existing $component index passed"
    assert_contains "$out" "existing $component" "$component substantive preflight refusal"
    after_exclude=$(sha256sum "$dir/project/.git/info/exclude")
    [ "$before_exclude" = "$after_exclude" ] || fail "$component incompatibility was detected after local-exclude mutation"
    [ ! -e "$dir/rollback.log" ] || fail "$component incompatibility was detected after rollback-manifest mutation"
    unset FM_FAKE_GREPAI_HEALTH FM_FAKE_CODEGRAPH_HEALTH FM_FAKE_SERENA_HEALTH
  done
  pass "indexing recovery: incompatible existing indexes refuse before mutation"
}

test_benchmark_timeout_reaps_process_group_and_stops_watcher() {
  local dir out rc child_pid child_started index elapsed
  dir=$(new_fixture benchmark-timeout)
  for index in $(seq 1 100); do
    printf 'pub fn timeout_%03d() -> usize { %d }\n' "$index" "$index" > "$dir/project/src/timeout-$index.rs"
  done
  git -C "$dir/project" add src
  git -C "$dir/project" -c user.name=Test -c user.email=test@example.invalid commit -qm 'benchmark timeout corpus'
  : > "$dir/fake.log"
  FM_FAKE_LOG="$dir/fake.log" FM_FAKE_WATCH_HANG=yes FM_FAKE_WATCH_TERM_RESISTANT=yes FM_FAKE_CHILD_PID_FILE="$dir/child.pid" \
    out=$(run_kit "$dir" --action apply --pull-model no --start-ollama no --persist-ollama no --install-tools no --init none --benchmark yes --max-index-seconds 1 \
      --benchmark-query 'one=src/main.rs' --benchmark-query 'two=src/main.rs' --benchmark-query 'three=src/main.rs' --benchmark-query 'four=src/main.rs' --benchmark-query 'five=src/main.rs' \
      --rollback-manifest "$dir/rollback.log" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "hanging benchmark passed"
  assert_contains "$out" "scratch grepai index exceeded the 1s hard bound" "benchmark timeout refusal"
  grep -F 'args=watch --stop' "$dir/fake.log" >/dev/null || fail "benchmark timeout did not invoke grepai watch --stop"
  [ -s "$dir/child.pid" ] || fail "benchmark fixture did not record its child"
  child_pid=$(sed -n '1p' "$dir/child.pid")
  child_started=$(sed -n '2p' "$dir/child.pid")
  elapsed=$(($(date +%s) - child_started))
  [ ! -e "/proc/$child_pid" ] || fail "benchmark child process $child_pid survived process-group cleanup"
  [ "$elapsed" -le 5 ] || fail "TERM-resistant benchmark cleanup exceeded its hard shutdown bound (${elapsed}s)"
  unset FM_FAKE_WATCH_HANG FM_FAKE_WATCH_TERM_RESISTANT FM_FAKE_CHILD_PID_FILE FM_FAKE_LOG
  pass "indexing recovery: benchmark timeout KILL-reaps a TERM-resistant process group within a hard bound"
}

test_codegraph_mcp_entry_is_project_bound() {
  local dir out snippet
  dir=$(new_fixture codegraph-project-binding)
  out=$(run_kit "$dir" --action health --pull-model no --start-ollama no --persist-ollama no --install-tools no --init none)
  snippet=$(printf '%s\n' "$out" | awk 'found || /^\{$/ { found=1; print; if (/^}$/) exit }')
  printf '%s\n' "$snippet" | jq -e --arg project "$dir/project" \
    '.codegraph.args == ["serve", "--mcp", "--path", $project]' >/dev/null \
    || fail "CodeGraph MCP entry is not bound to the supplied project"
  pass "indexing recovery: CodeGraph MCP entry is project-bound"
}

test_mcp_probe_kill_reaps_term_resistant_server_within_hard_bound() {
  local dir out rc pid started elapsed
  dir=$(new_fixture mcp-term-resistant)
  mkdir -p "$dir/project/.grepai"
  printf 'provider: ollama\nmodel: nomic-embed-text:latest\nbackend: gob\nendpoint: http://127.0.0.1:11434\n' \
    > "$dir/project/.grepai/config.yaml"
  started=$SECONDS
  FM_FAKE_MCP_TERM_RESISTANT=yes FM_FAKE_MCP_PID_FILE="$dir/mcp.pid" \
    out=$(run_kit "$dir" --action health --pull-model no --start-ollama no --persist-ollama no --install-tools no \
      --init none --mcp-timeout-seconds 3 2>&1); rc=$?
  elapsed=$((SECONDS - started))
  [ "$rc" -eq 0 ] || fail "TERM-resistant MCP health failed: $out"
  [ -s "$dir/mcp.pid" ] || fail "TERM-resistant MCP fixture did not record its PID"
  pid=$(cat "$dir/mcp.pid")
  [ ! -e "/proc/$pid" ] || fail "TERM-resistant MCP server $pid survived health cleanup"
  [ "$elapsed" -le 7 ] || fail "TERM-resistant MCP cleanup exceeded its hard shutdown bound (${elapsed}s)"
  unset FM_FAKE_MCP_TERM_RESISTANT FM_FAKE_MCP_PID_FILE
  pass "indexing recovery: MCP probe KILL-reaps a TERM-resistant server within a hard bound"
}

test_complete_benchmark_reports_every_gate() {
  local dir out index
  dir=$(new_fixture complete-benchmark)
  for index in $(seq 1 100); do
    printf 'pub fn benchmark_%03d() -> usize { %d }\n' "$index" "$index" > "$dir/project/src/benchmark-$index.rs"
  done
  git -C "$dir/project" add src
  git -C "$dir/project" -c user.name=Test -c user.email=test@example.invalid commit -qm 'benchmark corpus'
  : > "$dir/fake.log"

  FM_FAKE_LOG="$dir/fake.log" FM_FAKE_REQUIRE_COLD_MICRO=yes FM_FAKE_COLD_PROOF="$dir/cold.proof" FM_FAKE_WATCH_CPU_BURST=yes \
    out=$(run_kit "$dir" --action apply --pull-model no --start-ollama no --persist-ollama no --install-tools no --init grepai --benchmark yes \
    --benchmark-query 'one=src/main.rs' --benchmark-query 'two=src/main.rs' --benchmark-query 'three=src/main.rs' --benchmark-query 'four=src/main.rs' --benchmark-query 'five=src/main.rs' \
    --max-index-seconds 5 --max-micro-batch-seconds 60 --max-search-ms 2000 --max-incremental-seconds 10 \
    --max-swap-growth-mib 0 --max-temperature-celsius 90 --max-load-per-cpu-percent 100 --max-watcher-idle-cpu-percent 5 \
    --rollback-manifest "$dir/rollback.log")
  assert_contains "$out" "micro_batch chunks=100 passes=4" "cold/warm micro-batch evidence"
  assert_contains "$out" "swap_growth_mib=0" "swap gate evidence"
  assert_contains "$out" "temperature_peak_celsius=45" "thermal gate evidence"
  assert_contains "$out" "load_peak=" "load gate evidence"
  assert_contains "$out" "search_median_ms=" "search latency evidence"
  assert_contains "$out" "incremental_seconds=" "incremental convergence evidence"
  assert_contains "$out" "watcher_idle_cpu_percent=" "watcher idle evidence"
  assert_contains "$out" "watcher_idle_window_seconds=" "watcher idle delta window"
  assert_contains "$out" "cold_model_boundary=verified_unloaded" "cold model boundary evidence"
  [ -e "$dir/cold.proof" ] || fail "first micro-batch request did not start from an unloaded model"
  grep -Fxq 'endpoint: http://127.0.0.1:11434' "$dir/project/.grepai/config.yaml" || fail "canonical grepai config lacks an explicit loopback endpoint"
  [ "$(grep -Fc 'args=watch --background' "$dir/fake.log")" -eq 2 ] || fail "scratch and canonical watchers were not both loopback-bound"
  unset FM_FAKE_LOG FM_FAKE_REQUIRE_COLD_MICRO FM_FAKE_COLD_PROOF FM_FAKE_WATCH_CPU_BURST
  pass "indexing recovery: benchmark reports every bounded acceptance gate"
}

test_read_only_health_observes_local_model() {
  local dir out before after before_exclude after_exclude
  dir=$(new_fixture health)
  before=$(git -C "$dir/project" status --porcelain=v1)
  before_exclude=$(sha256sum "$dir/project/.git/info/exclude")
  out=$(run_kit "$dir" --action health --pull-model no --start-ollama no --persist-ollama no --install-tools no --init none)
  after=$(git -C "$dir/project" status --porcelain=v1)
  after_exclude=$(sha256sum "$dir/project/.git/info/exclude")
  assert_contains "$out" "ollama_health digest=0a109f422b47e3a30ba2b10eca18548e944e8a23073ee3f3e947efcf3c45e59f size=274302450 quantization=F16 dimensions=768" "local model health"
  assert_contains "$out" "placement='nomic-embed-text:latest abc 274 MB 100% CPU'" "CPU placement health"
  assert_contains "$out" "complete action=health" "health completion"
  [ "$before" = "$after" ] || fail "health changed project state"
  [ "$before_exclude" = "$after_exclude" ] || fail "health changed local excludes"
  pass "indexing recovery: health validates the loopback model without mutation"
}

seed_healthy_indexes() {
  local dir=$1 managed_root="$1/install-parent/tools/serena"
  mkdir -p "$dir/project/.grepai" "$dir/project/.codegraph" "$dir/project/.serena" "$dir/project/.git/info"
  mkdir -p "$managed_root/home" "$managed_root/runtime-home/.cache" "$managed_root/runtime-home/.local/state" \
    "$managed_root/runtime-home/.solidlsp"
  printf ready > "$managed_root/runtime-home/.solidlsp/cache.ready"
  printf 'provider: ollama\nmodel: nomic-embed-text:latest\nbackend: gob\nendpoint: http://127.0.0.1:11434\n' > "$dir/project/.grepai/config.yaml"
  printf 'sqlite fixture\n' > "$dir/project/.codegraph/codegraph.db"
  printf 'languages:\n- rust\n- typescript\n- python\n' > "$dir/project/.serena/project.yml"
  printf '.grepai/\n.codegraph/\n.serena/\n' > "$dir/project/.git/info/exclude"
}

test_healthy_apply_is_idempotent_and_mcp_is_bounded() {
  local dir out first_tree second_tree
  dir=$(new_fixture healthy-apply)
  seed_healthy_indexes "$dir"
  first_tree=$(find "$dir/project" -path "$dir/project/.git" -prune -o -type f -print0 | sort -z | xargs -0 sha256sum)
  out=$(run_kit "$dir" --action apply --pull-model no --start-ollama no --persist-ollama no --install-tools no --init grepai,codegraph,serena --allow-language-downloads yes --rollback-manifest "$dir/rollback.log")
  second_tree=$(find "$dir/project" -path "$dir/project/.git" -prune -o -type f -print0 | sort -z | xargs -0 sha256sum)
  [ "$first_tree" = "$second_tree" ] || fail "healthy apply changed existing project state"
  assert_contains "$out" "grepai init no-op: existing compatible config preserved" "grepai apply no-op"
  assert_contains "$out" "CodeGraph init no-op: existing healthy state preserved" "CodeGraph apply no-op"
  assert_contains "$out" "Serena create no-op: existing healthy project state preserved" "Serena apply no-op"
  assert_contains "$out" "grepai_mcp_health transport=stdio tools_list=healthy" "grepai MCP health"
  assert_contains "$out" "codegraph_mcp_health transport=stdio tools_list=healthy" "CodeGraph MCP health"
  assert_contains "$out" "serena_mcp_health transport=stdio tools_list=healthy" "Serena MCP health"
  pass "indexing recovery: healthy apply preserves indexes and stops bounded MCP probes"
}

test_lazy_mcp_conflict_preserves_bytes() {
  local dir lazy before_runtime before_generator out rc
  dir=$(new_fixture lazy-conflict)
  seed_healthy_indexes "$dir"
  lazy="$dir/lazy-mcp"
  mkdir -p "$lazy/hierarchy"
  printf '{"mcpProxy":{"type":"stdio","addr":":9090"},"mcpServers":{"grepai":{"transportType":"stdio","command":"different","args":[]}}}\n' > "$lazy/config.json"
  printf '{"mcpServers":{"grepai":{"transportType":"stdio","command":"different","args":[]}},"outputDir":"hierarchy"}\n' > "$lazy/gen_config.json"
  printf '{"overview":"Root: 0 servers, 0 tools","unrelatedRoot":"keep"}\n' > "$lazy/hierarchy/root.json"
  printf '#!/usr/bin/env bash\nexit 100\n' > "$lazy/structure_generator"
  chmod +x "$lazy/structure_generator"
  before_runtime=$(sha256sum "$lazy/config.json")
  before_generator=$(sha256sum "$lazy/gen_config.json")
  out=$(FM_INDEX_OS_RELEASE="$dir/os-release" FM_INDEX_MEMINFO="$dir/meminfo" FM_INDEX_LOADAVG="$dir/loadavg" FM_INDEX_UNAME_M=x86_64 HOME="$dir/home" XDG_RUNTIME_DIR="$dir/runtime" PATH="$dir/fakebin:$PATH" "$SCRIPT" \
    --action apply --project "$dir/project" --ollama-owner arch --ollama-accel cpu --pull-model no --start-ollama no --persist-ollama no --install-tools no \
    --init grepai,codegraph,serena --ignore-policy defaults --state-policy local-ignored --serena-language rust --serena-language typescript --serena-language python \
    --allow-language-downloads yes --telemetry off --benchmark no --health-query main --mcp-client lazy-mcp --mcp-scope user --lazy-mcp-dir "$lazy" \
    --persistent-grepai-watch no --destructive-rollback no --rollback-manifest "$dir/rollback.log" --install-root "$dir/install-parent/tools" --bin-dir "$dir/fakebin" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "conflicting lazy-mcp entry passed"
  assert_contains "$out" "lazy-mcp entry 'grepai' conflicts" "lazy-mcp conflict refusal"
  [ "$before_runtime" = "$(sha256sum "$lazy/config.json")" ] || fail "lazy-mcp runtime config changed on conflict"
  [ "$before_generator" = "$(sha256sum "$lazy/gen_config.json")" ] || fail "lazy-mcp generator config changed on conflict"
  [ -z "$(find "$lazy" -name '*.fm-indexing-backup-*' -print -quit)" ] || fail "lazy-mcp conflict created a backup despite no mutation"
  pass "indexing recovery: lazy-mcp duplicate conflict preserves source bytes"
}

test_lazy_mcp_registration_is_additive_reversible_and_idempotent() {
  local dir lazy out first_calls second_calls backup_count
  dir=$(new_fixture lazy-additive)
  seed_healthy_indexes "$dir"
  lazy="$dir/lazy-mcp"
  mkdir -p "$lazy/hierarchy"
  printf '{"mcpProxy":{"type":"stdio","addr":":9090"},"mcpServers":{"unrelated":{"transportType":"stdio","command":"unrelated","args":[]}}}\n' > "$lazy/config.json"
  printf '{"mcpServers":{"unrelated":{"transportType":"stdio","command":"unrelated","args":[]}},"outputDir":"hierarchy"}\n' > "$lazy/gen_config.json"
  printf '{"overview":"Root: 0 servers, 0 tools","unrelatedRoot":"keep"}\n' > "$lazy/hierarchy/root.json"
  cat > "$lazy/structure_generator" <<'SH'
#!/usr/bin/env bash
output=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -output) output=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$output" ] || exit 2
[ -n "${FM_FAKE_GENERATOR_LOG:-}" ] && printf 'generator\n' >> "$FM_FAKE_GENERATOR_LOG"
mkdir -p "$output"
for name in grepai codegraph serena; do
  mkdir -p "$output/$name"
  printf '{"overview":"%s: 1 tool; fixture tool"}\n' "$name" > "$output/$name/$name.json"
  printf '{"name":"fixture"}\n' > "$output/$name/fixture.json"
done
printf '{"overview":"Root: 3 servers, 3 tools"}\n' > "$output/root.json"
SH
  chmod +x "$lazy/structure_generator"
  : > "$dir/generator.log"
  FM_FAKE_GENERATOR_LOG="$dir/generator.log" out=$(run_kit "$dir" --action apply --pull-model no --start-ollama no --persist-ollama no --install-tools no \
    --init grepai,codegraph,serena --allow-language-downloads yes --mcp-client lazy-mcp --mcp-scope user --lazy-mcp-dir "$lazy" --rollback-manifest "$dir/rollback.log")
  assert_contains "$out" "lazy_mcp registration=healthy" "lazy-mcp additive registration"
  for file in "$lazy/config.json" "$lazy/gen_config.json"; do
    jq -e '.mcpServers | has("unrelated") and has("grepai") and has("codegraph") and has("serena")' "$file" >/dev/null \
      || fail "lazy-mcp registration lost or omitted entries in $file"
  done
  for name in grepai codegraph serena; do
    [ -d "$lazy/hierarchy/$name" ] || fail "lazy-mcp hierarchy omitted $name"
  done
  jq -e '.overview | contains("grepai") and contains("codegraph") and contains("serena")' "$lazy/hierarchy/root.json" >/dev/null \
    || fail "lazy-mcp root overview omitted a category"
  jq -e '.unrelatedRoot == "keep"' "$lazy/hierarchy/root.json" >/dev/null || fail "lazy-mcp root update lost unrelated state"
  backup_count=$(find "$lazy" -name '*.fm-indexing-backup-*' -type f | wc -l | tr -d ' ')
  [ "$backup_count" -eq 3 ] || fail "lazy-mcp registration made $backup_count backups, expected 3"
  first_calls=$(wc -l < "$dir/generator.log" | tr -d ' ')
  FM_FAKE_GENERATOR_LOG="$dir/generator.log" out=$(run_kit "$dir" --action apply --pull-model no --start-ollama no --persist-ollama no --install-tools no \
    --init grepai,codegraph,serena --allow-language-downloads yes --mcp-client lazy-mcp --mcp-scope user --lazy-mcp-dir "$lazy" --rollback-manifest "$dir/rollback.log")
  second_calls=$(wc -l < "$dir/generator.log" | tr -d ' ')
  assert_contains "$out" "lazy_mcp registration=no-op existing entries and hierarchy are healthy" "lazy-mcp rerun no-op"
  [ "$first_calls" -eq 1 ] && [ "$second_calls" -eq 1 ] || fail "lazy-mcp no-op reran the hierarchy generator"
  pass "indexing recovery: lazy-mcp registration is additive, backed up, and idempotent"
}

test_required_service_inventory_and_listener_refuse_before_mutation() {
  local dir tool start_choice out rc before_exclude
  for tool in ss systemctl; do
    dir=$(new_fixture "missing-$tool")
    printf '#!/usr/bin/env bash\nexit 127\n' > "$dir/fakebin/$tool"
    chmod +x "$dir/fakebin/$tool"
    start_choice=no
    [ "$tool" != systemctl ] || start_choice=yes
    out=$(run_kit "$dir" --action plan --pull-model no --start-ollama "$start_choice" \
      --persist-ollama no --install-tools no --init none 2>&1); rc=$?
    [ "$rc" -ne 0 ] || fail "missing $tool prerequisite passed"
    case "$tool" in
      ss) assert_contains "$out" "ss could not inventory TCP listeners" "$tool prerequisite refusal" ;;
      systemctl) assert_contains "$out" "cannot resolve the existing Ollama service unit" "$tool prerequisite refusal" ;;
    esac
  done

  dir=$(new_fixture exposed-ollama)
  before_exclude=$(sha256sum "$dir/project/.git/info/exclude")
  FM_FAKE_SS_LISTENER=0.0.0.0:11434 out=$(run_kit "$dir" --action apply --pull-model no --start-ollama no --persist-ollama no --install-tools no \
    --init serena --allow-language-downloads yes --rollback-manifest "$dir/rollback.log" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "non-loopback Ollama listener passed"
  assert_contains "$out" "exposed beyond loopback" "non-loopback listener refusal"
  [ "$before_exclude" = "$(sha256sum "$dir/project/.git/info/exclude")" ] || fail "listener refusal happened after exclude mutation"
  [ ! -e "$dir/rollback.log" ] || fail "listener refusal happened after rollback-manifest mutation"
  unset FM_FAKE_SS_LISTENER
  pass "indexing recovery: service inventory and loopback listener checks precede mutation"
}

test_bounded_indexer_commands_and_micro_requests() {
  local dir out rc index
  for command in grepai-status grepai-search codegraph-status codegraph-query; do
    dir=$(new_fixture "timeout-$command")
    case "$command" in
      grepai-*) mkdir -p "$dir/project/.grepai"; printf 'provider: ollama\nmodel: nomic-embed-text:latest\nbackend: gob\nendpoint: http://127.0.0.1:11434\n' > "$dir/project/.grepai/config.yaml" ;;
      codegraph-status|codegraph-query) mkdir -p "$dir/project/.codegraph"; printf db > "$dir/project/.codegraph/codegraph.db" ;;
    esac
    FM_FAKE_HANG_COMMAND=$command out=$(run_kit "$dir" --action health --pull-model no --start-ollama no --persist-ollama no --install-tools no \
      --init none --command-timeout-seconds 1 2>&1); rc=$?
    [ "$rc" -ne 0 ] || fail "$command exceeded its bound without failing"
    assert_contains "$out" "1s hard timeout" "$command hard-timeout refusal"
  done

  dir=$(new_fixture codegraph-init-index-budget)
  FM_FAKE_HANG_COMMAND=codegraph-init out=$(run_kit "$dir" --action apply --pull-model no --start-ollama no --persist-ollama no --install-tools no \
    --init codegraph --allow-language-downloads yes --command-timeout-seconds 1 --max-index-seconds 5 \
    --rollback-manifest "$dir/rollback.log" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "CodeGraph init incorrectly used the 1s command timeout: $out"

  dir=$(new_fixture codegraph-init-index-timeout)
  FM_FAKE_HANG_COMMAND=codegraph-init out=$(run_kit "$dir" --action apply --pull-model no --start-ollama no --persist-ollama no --install-tools no \
    --init codegraph --allow-language-downloads yes --command-timeout-seconds 10 --max-index-seconds 1 \
    --rollback-manifest "$dir/rollback.log" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "CodeGraph init exceeded max-index without failing"
  assert_contains "$out" "CodeGraph init exceeded its 1s hard timeout" "CodeGraph max-index timeout"

  dir=$(new_fixture timeout-grepai-stop)
  for index in $(seq 1 100); do
    printf 'pub fn stop_%03d() -> usize { %d }\n' "$index" "$index" > "$dir/project/src/stop-$index.rs"
  done
  git -C "$dir/project" add src
  git -C "$dir/project" -c user.name=Test -c user.email=test@example.invalid commit -qm 'stop timeout corpus'
  FM_FAKE_HANG_COMMAND=grepai-stop out=$(run_kit "$dir" --action apply --pull-model no --start-ollama no --persist-ollama no --install-tools no --init none \
    --benchmark yes --command-timeout-seconds 1 --max-index-seconds 5 \
    --benchmark-query 'one=src/main.rs' --benchmark-query 'two=src/main.rs' --benchmark-query 'three=src/main.rs' \
    --benchmark-query 'four=src/main.rs' --benchmark-query 'five=src/main.rs' --rollback-manifest "$dir/rollback.log" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "grepai watcher stop exceeded its bound without failing"
  assert_contains "$out" "scratch grepai watcher stop exceeded its 1s hard timeout" "grepai stop hard-timeout refusal"

  dir=$(new_fixture timeout-micro-request)
  for index in $(seq 1 100); do
    printf 'pub fn request_%03d() -> usize { %d }\n' "$index" "$index" > "$dir/project/src/request-$index.rs"
  done
  git -C "$dir/project" add src
  git -C "$dir/project" -c user.name=Test -c user.email=test@example.invalid commit -qm 'request timeout corpus'
  FM_FAKE_HANG_MICRO=yes out=$(run_kit "$dir" --action apply --pull-model no --start-ollama no --persist-ollama no --install-tools no --init none \
    --benchmark yes --max-micro-batch-seconds 30 --max-embed-request-seconds 1 \
    --benchmark-query 'one=src/main.rs' --benchmark-query 'two=src/main.rs' --benchmark-query 'three=src/main.rs' \
    --benchmark-query 'four=src/main.rs' --benchmark-query 'five=src/main.rs' --rollback-manifest "$dir/rollback.log" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "slow micro-batch request passed"
  assert_contains "$out" "micro-batch embed request exceeded its 1s hard timeout" "micro request hard-timeout refusal"
  unset FM_FAKE_HANG_COMMAND FM_FAKE_HANG_MICRO
  pass "indexing recovery: indexer commands and micro requests have real hard timeouts"
}

test_serena_healthy_rerun_reuses_managed_cache_offline_without_state_changes() {
  local dir out count before after managed_root
  dir=$(new_fixture serena-offline-rerun)
  seed_healthy_indexes "$dir"
  managed_root="$dir/install-parent/tools/serena"
  : > "$dir/fake.log"
  before=$(find "$dir/project/.serena" "$managed_root" -type f -print0 | sort -z | xargs -0 sha256sum)
  FM_FAKE_LOG="$dir/fake.log" FM_FAKE_SERENA_OFFLINE_RERUN=yes FM_FAKE_SERENA_MANAGED_ROOT="$managed_root" \
    FM_FAKE_NETWORK_ATTEMPT="$dir/network.attempt" \
    out=$(run_kit "$dir" --action apply --pull-model no --start-ollama no --persist-ollama no --install-tools no \
      --init grepai,codegraph,serena --allow-language-downloads no --rollback-manifest "$dir/rollback.log")
  after=$(find "$dir/project/.serena" "$managed_root" -type f -print0 | sort -z | xargs -0 sha256sum)
  count=$(grep -Fc 'args=project health-check' "$dir/fake.log")
  [ "$count" -eq 1 ] || fail "Serena health-check ran $count times instead of once"
  [ "$before" = "$after" ] || fail "healthy offline Serena rerun changed managed or project state"
  [ ! -e "$dir/network.attempt" ] || fail "healthy offline Serena rerun attempted dependency network access"
  grep -Fq 'serena_health_artifacts=project_log_removed managed_cache_reused=yes offline=yes' "$dir/rollback.log" \
    || fail "Serena managed-cache health boundary was not recorded"
  assert_contains "$out" "serena_health" "Serena health result"
  unset FM_FAKE_LOG FM_FAKE_SERENA_OFFLINE_RERUN FM_FAKE_SERENA_MANAGED_ROOT FM_FAKE_NETWORK_ATTEMPT
  pass "indexing recovery: healthy Serena rerun reuses managed caches and is a true offline no-op"
}

test_partial_initializer_state_is_planned_and_reconciled() {
  local dir out rc
  dir=$(new_fixture partial-codegraph)
  FM_FAKE_PARTIAL_INITIALIZER=codegraph out=$(run_kit "$dir" --action apply --pull-model no --start-ollama no --persist-ollama no --install-tools no \
    --init codegraph --allow-language-downloads yes --rollback-manifest "$dir/rollback.log" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "partial CodeGraph initializer unexpectedly passed"
  [ -d "$dir/project/.codegraph" ] || fail "partial initializer fixture did not create state"
  grep -Fq "planned_project_state=$dir/project/.codegraph initializer=codegraph" "$dir/rollback.log" || fail "initializer plan was not recorded before mutation"
  grep -Fq "partial_project_state=$dir/project/.codegraph initializer=codegraph operator_review_required=yes" "$dir/rollback.log" || fail "partial initializer state was not reconciled on exit"
  unset FM_FAKE_PARTIAL_INITIALIZER
  pass "indexing recovery: partial initializer state is durable and recoverable"
}

test_existing_model_is_validated_before_apply_mutation() {
  local dir before_exclude out rc
  dir=$(new_fixture model-before-mutation)
  before_exclude=$(sha256sum "$dir/project/.git/info/exclude")
  FM_FAKE_MODEL_DIGEST=wrong out=$(run_kit "$dir" --action apply --pull-model no --start-ollama no --persist-ollama no --install-tools no \
    --init serena --allow-language-downloads yes --rollback-manifest "$dir/rollback.log" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "incompatible existing model passed apply preflight"
  assert_contains "$out" "model digest" "existing model compatibility refusal"
  [ "$before_exclude" = "$(sha256sum "$dir/project/.git/info/exclude")" ] || fail "model incompatibility was found after exclude mutation"
  [ ! -e "$dir/rollback.log" ] || fail "model incompatibility was found after rollback-manifest mutation"
  unset FM_FAKE_MODEL_DIGEST
  pass "indexing recovery: existing Ollama model compatibility precedes apply mutation"
}

test_unmanaged_grepai_destination_is_never_overwritten() {
  local dir destination target before out rc
  for kind in file symlink; do
    dir=$(new_fixture "grepai-destination-$kind")
    destination="$dir/install-parent/tools/grepai/v0.35.0/grepai"
    mkdir -p "$(dirname "$destination")"
    if [ "$kind" = file ]; then
      printf 'do-not-overwrite\n' > "$destination"
      target=$destination
    else
      target="$dir/destination-target"
      printf 'do-not-overwrite\n' > "$target"
      ln -s "$target" "$destination"
    fi
    before=$(sha256sum "$target")
    out=$(run_kit "$dir" --action plan --pull-model no --start-ollama no --persist-ollama no --install-tools yes --init none 2>&1); rc=$?
    [ "$rc" -ne 0 ] || fail "unmanaged grepai $kind destination passed"
    assert_contains "$out" "grepai managed destination is not a proven owner-managed regular executable" "grepai destination refusal"
    [ "$before" = "$(sha256sum "$target")" ] || fail "grepai $kind destination target changed"
  done
  pass "indexing recovery: unmanaged grepai destinations are never overwritten or followed"
}

test_lazy_mcp_symlink_topology_is_refused_without_target_changes() {
  local dir lazy real target before out rc
  for target in config root; do
    dir=$(new_fixture "lazy-symlink-$target")
    seed_healthy_indexes "$dir"
    lazy="$dir/lazy-mcp"
    mkdir -p "$lazy/hierarchy"
    printf '{"mcpProxy":{"type":"stdio","addr":":9090"},"mcpServers":{}}\n' > "$lazy/config.real.json"
    printf '{"mcpServers":{},"outputDir":"hierarchy"}\n' > "$lazy/gen_config.json"
    printf '{"overview":"Root: 0 servers, 0 tools"}\n' > "$lazy/hierarchy/root.real.json"
    printf '#!/usr/bin/env bash\nexit 100\n' > "$lazy/structure_generator"
    chmod +x "$lazy/structure_generator"
    if [ "$target" = config ]; then
      ln -s config.real.json "$lazy/config.json"
      cp "$lazy/hierarchy/root.real.json" "$lazy/hierarchy/root.json"
      real="$lazy/config.real.json"
    else
      cp "$lazy/config.real.json" "$lazy/config.json"
      ln -s root.real.json "$lazy/hierarchy/root.json"
      real="$lazy/hierarchy/root.real.json"
    fi
    before=$(sha256sum "$real")
    out=$(run_kit "$dir" --action apply --pull-model no --start-ollama no --persist-ollama no --install-tools no --init grepai,codegraph,serena \
      --allow-language-downloads yes --mcp-client lazy-mcp --mcp-scope user --lazy-mcp-dir "$lazy" --rollback-manifest "$dir/rollback.log" 2>&1); rc=$?
    [ "$rc" -ne 0 ] || fail "symlink-managed lazy-mcp $target file passed"
    assert_contains "$out" "lazy-mcp refuses symlink-managed config or hierarchy files" "lazy-mcp symlink refusal"
    [ "$before" = "$(sha256sum "$real")" ] || fail "lazy-mcp symlink target changed"
    [ ! -e "$dir/rollback.log" ] || fail "lazy-mcp symlink refusal occurred after manifest mutation"
  done
  pass "indexing recovery: lazy-mcp symlink topology is refused transactionally"
}

test_state_ancestors_and_serena_languages_are_semantically_exact() {
  local dir target before out rc
  dir=$(new_fixture state-child-symlink)
  mkdir -p "$dir/project/.codegraph"
  target="$dir/codegraph-target.db"
  printf 'sqlite fixture\n' > "$target"
  ln -s "$target" "$dir/project/.codegraph/codegraph.db"
  before=$(sha256sum "$target")
  out=$(run_kit "$dir" --action plan --pull-model no --start-ollama no --persist-ollama no --install-tools no \
    --init none 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "symlink CodeGraph database passed canonical state topology"
  assert_contains "$out" "project state topology contains a symlink" "state child symlink refusal"
  [ "$before" = "$(sha256sum "$target")" ] || fail "state child symlink target changed"

  dir=$(new_fixture serena-language-semantics)
  seed_healthy_indexes "$dir"
  printf 'languages:\n- rust\n- typescript\n# - python\n- go\n' > "$dir/project/.serena/project.yml"
  out=$(run_kit "$dir" --action health --pull-model no --start-ollama no --persist-ollama no --install-tools no \
    --init none 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "commented/mismatched Serena languages passed"
  assert_contains "$out" "Serena languages do not exactly match" "semantic Serena language refusal"

  dir=$(new_fixture lazy-symlink-ancestor)
  seed_healthy_indexes "$dir"
  mkdir -p "$dir/lazy-real/hierarchy"
  printf '{"mcpProxy":{"type":"stdio","addr":":9090"},"mcpServers":{}}\n' > "$dir/lazy-real/config.json"
  printf '{"mcpServers":{},"outputDir":"hierarchy"}\n' > "$dir/lazy-real/gen_config.json"
  printf '{"overview":"Root: 0 servers, 0 tools"}\n' > "$dir/lazy-real/hierarchy/root.json"
  printf '#!/usr/bin/env bash\nexit 100\n' > "$dir/lazy-real/structure_generator"
  chmod +x "$dir/lazy-real/structure_generator"
  ln -s "$dir/lazy-real" "$dir/lazy-link"
  out=$(run_kit "$dir" --action apply --pull-model no --start-ollama no --persist-ollama no --install-tools no \
    --init grepai,codegraph,serena --allow-language-downloads yes --mcp-client lazy-mcp --mcp-scope user \
    --lazy-mcp-dir "$dir/lazy-link" --rollback-manifest "$dir/rollback.log" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "symlink lazy-mcp ancestor passed"
  assert_contains "$out" "lazy-mcp topology contains a symlink" "lazy-mcp ancestor symlink refusal"
  [ ! -e "$dir/rollback.log" ] || fail "lazy-mcp ancestor refusal occurred after manifest mutation"
  pass "indexing recovery: project/lazy state topology and Serena languages are exact"
}

test_source_inventory_rejects_symlink_and_fifo_without_following() {
  local dir outside before out rc pid waited
  dir=$(new_fixture tracked-source-symlink)
  outside="$dir/outside.rs"
  printf 'outside sentinel\n' > "$outside"
  rm "$dir/project/src/main.rs"
  ln -s "$outside" "$dir/project/src/main.rs"
  git -C "$dir/project" add src/main.rs
  git -C "$dir/project" -c user.name=Test -c user.email=test@example.invalid commit -qm 'tracked source symlink'
  before=$(sha256sum "$outside")
  out=$(run_kit "$dir" --action plan --pull-model no --start-ollama no --persist-ollama no --install-tools no --init none 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "tracked source symlink passed inventory"
  assert_contains "$out" "tracked source is not a regular in-worktree file" "tracked symlink refusal"
  [ "$before" = "$(sha256sum "$outside")" ] || fail "tracked symlink target was changed"

  dir=$(new_fixture tracked-source-fifo)
  rm "$dir/project/src/main.rs"
  mkfifo "$dir/project/src/main.rs"
  run_kit "$dir" --action plan --pull-model no --start-ollama no --persist-ollama no --install-tools no --init none >"$dir/out" 2>&1 &
  pid=$!
  waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 30 ]; do sleep 0.1; waited=$((waited + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "source inventory hung while reading a FIFO"
  fi
  wait "$pid"; rc=$?
  out=$(cat "$dir/out")
  [ "$rc" -ne 0 ] || fail "tracked source FIFO passed inventory"
  assert_contains "$out" "tracked source is not a regular in-worktree file" "tracked FIFO refusal"
  pass "indexing recovery: source inventory rejects symlinks and FIFOs without reading them"
}

test_git_exclude_refuses_symlink_without_following() {
  local dir exclude target before out rc
  dir=$(new_fixture unsafe-git-exclude)
  exclude=$(git -C "$dir/project" rev-parse --path-format=absolute --git-path info/exclude)
  target="$dir/exclude-target"
  printf 'do-not-touch\n' > "$target"
  rm "$exclude"
  ln -s "$target" "$exclude"
  before=$(sha256sum "$target")
  out=$(run_kit "$dir" --action apply --pull-model no --start-ollama no --persist-ollama no --install-tools no --init serena \
    --allow-language-downloads yes --rollback-manifest "$dir/rollback.log" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "symlink Git exclude passed"
  assert_contains "$out" "Git info/exclude must be an owner-owned regular file" "Git exclude topology refusal"
  [ "$before" = "$(sha256sum "$target")" ] || fail "Git exclude symlink target changed"
  [ ! -e "$dir/project/.serena" ] || fail "Serena initialized after unsafe Git exclude"
  pass "indexing recovery: Git info/exclude symlinks are refused without following"
}

test_watcher_fast_exit_cleanup_does_not_reuse_stale_identity() {
  local dir out rc decoy_pid index
  dir=$(new_fixture watcher-fast-exit-boundary)
  for index in $(seq 1 100); do
    printf 'pub fn fast_exit_%03d() -> usize { %d }\n' "$index" "$index" > "$dir/project/src/fast-exit-$index.rs"
  done
  git -C "$dir/project" add src
  git -C "$dir/project" -c user.name=Test -c user.email=test@example.invalid commit -qm 'fast-exit watcher corpus'
  : > "$dir/fake.log"
  setsid sleep 30 &
  decoy_pid=$!
  FM_FAKE_LOG="$dir/fake.log" FM_FAKE_WATCH_STATUS_FAIL=yes \
    out=$(run_kit "$dir" --action apply --pull-model no --start-ollama no --persist-ollama no --install-tools no \
      --init none --benchmark yes --max-index-seconds 5 \
      --benchmark-query 'one=src/main.rs' --benchmark-query 'two=src/main.rs' --benchmark-query 'three=src/main.rs' \
      --benchmark-query 'four=src/main.rs' --benchmark-query 'five=src/main.rs' \
      --rollback-manifest "$dir/rollback.log" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "fast-exit watcher status failure unexpectedly passed"
  assert_contains "$out" "scratch grepai watcher did not report running" "post-fast-exit watcher failure"
  kill -0 "$decoy_pid" 2>/dev/null || fail "cleanup reused stale watcher identity and terminated an unrelated process"
  grep -Fq 'args=watch --background' "$dir/fake.log" || fail "fast-exit watcher command was not exercised"
  grep -Fq 'args=watch --stop' "$dir/fake.log" || fail "owned scratch watcher was not stopped after the boundary failure"
  kill "$decoy_pid" 2>/dev/null || true
  wait "$decoy_pid" 2>/dev/null || true
  unset FM_FAKE_LOG FM_FAKE_WATCH_STATUS_FAIL
  pass "indexing recovery: fast-exit watcher cleanup stops only owned work and does not reuse stale identity"
}

test_help_and_plan_are_read_only
test_inventory_is_hard_bounded_and_inotify_capacity_fails_closed
test_fail_closed_preflight_matrix
test_unset_runtime_uses_private_home_lock_without_following_public_symlink
test_temporary_ollama_stop_failure_is_terminal_without_masking_primary_failure
test_preexisting_active_ollama_is_never_adopted_or_stopped
test_canonical_grepai_watcher_is_reconciled_without_adoption
test_partial_ollama_service_transitions_are_reconciled
test_serena_download_refusal_and_exact_model_identity
test_grepai_config_rejects_commented_local_values_and_missing_endpoint
test_grepai_config_rejects_deceptive_remote_endpoint
test_dirty_apply_refuses_before_mutation
test_linked_worktree_state_uses_git_canonical_exclude
test_incompatible_existing_indexes_refuse_before_mutation
test_codegraph_mcp_entry_is_project_bound
test_mcp_probe_kill_reaps_term_resistant_server_within_hard_bound
test_benchmark_timeout_reaps_process_group_and_stops_watcher
test_complete_benchmark_reports_every_gate
test_read_only_health_observes_local_model
test_healthy_apply_is_idempotent_and_mcp_is_bounded
test_lazy_mcp_conflict_preserves_bytes
test_lazy_mcp_registration_is_additive_reversible_and_idempotent
test_required_service_inventory_and_listener_refuse_before_mutation
test_bounded_indexer_commands_and_micro_requests
test_serena_healthy_rerun_reuses_managed_cache_offline_without_state_changes
test_partial_initializer_state_is_planned_and_reconciled
test_existing_model_is_validated_before_apply_mutation
test_unmanaged_grepai_destination_is_never_overwritten
test_lazy_mcp_symlink_topology_is_refused_without_target_changes
test_state_ancestors_and_serena_languages_are_semantically_exact
test_source_inventory_rejects_symlink_and_fifo_without_following
test_git_exclude_refuses_symlink_without_following
test_watcher_fast_exit_cleanup_does_not_reuse_stale_identity

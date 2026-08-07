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
  mkdir -p "$dir/home" "$dir/install-parent" "$dir/bin" "$dir/project/src" "$dir/project/scripts" "$dir/project/web"
  printf 'ID=cachyos\nID_LIKE=arch\n' > "$dir/os-release"
  printf 'MemTotal:       16777216 kB\nMemAvailable:   12582912 kB\n' > "$dir/meminfo"
  printf '0.10 0.20 0.30 1/100 123\n' > "$dir/loadavg"
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
case "${1:-}" in
  is-active|is-enabled) exit 1 ;;
  show) printf '/usr/lib/systemd/system/ollama.service\n' ;;
  *) printf 'unexpected systemctl mutation: %s\n' "$*" >&2; exit 92 ;;
esac
SH
  cat > "$fakebin/ss" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/ollama" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf 'ollama version 0.32.6\n' ;;
  ps) printf 'NAME ID SIZE PROCESSOR\nnomic-embed-text:latest abc 274 MB 100%% CPU\n' ;;
  stop) printf 'unexpected model stop\n' >&2; exit 93 ;;
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
  init) mkdir -p .grepai; printf 'fixture\n' > .grepai/config.yaml ;;
  status) printf 'healthy grepai index\n' ;;
  search) printf '[{"path":"src/main.rs"}]\n' ;;
  watch)
    case "${2:-}" in
      --background)
        if [ "${FM_FAKE_WATCH_HANG:-no}" = yes ]; then
          sleep 30 &
          child=$!
          [ -n "${FM_FAKE_CHILD_PID_FILE:-}" ] && printf '%s\n' "$child" > "$FM_FAKE_CHILD_PID_FILE"
          wait "$child"
        fi
        ;;
      --stop) ;;
      *) printf 'unexpected grepai watch call: %s\n' "$*" >&2; exit 95 ;;
    esac
    ;;
  mcp-serve)
    while IFS= read -r line; do
      case "$line" in
        *'"id":1'*) printf '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"grepai","version":"test"}}}\n' ;;
        *'"id":2'*) printf '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"grepai_search"}]}}\n' ;;
      esac
    done
    ;;
  *) printf 'unexpected grepai mutation: %s\n' "$*" >&2; exit 95 ;;
esac
SH
  cat > "$fakebin/codegraph" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '1.5.0\n' ;;
  status) printf '{"initialized":true,"journalMode":"wal","worktreeMismatch":null,"pendingChanges":{"added":0,"modified":0,"removed":0},"index":{"state":"complete","pendingRefs":0,"reindexRecommended":false}}\n' ;;
  query) printf '[{"node":{"filePath":"src/main.rs"}}]\n' ;;
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
case "${1:-}" in
  --version) printf 'Serena 1.6.1\n' ;;
  project)
    [ "${2:-}" = health-check ] || { printf 'unexpected Serena project mutation: %s\n' "$*" >&2; exit 97; }
    ;;
  start-mcp-server)
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
  *'/api/version'*) printf '{"version":"0.32.6"}\n' ;;
  *'/api/tags'*) printf '{"models":[{"name":"nomic-embed-text:latest","model":"nomic-embed-text:latest","digest":"sha256:test-local-model","size":274000000}]}\n' ;;
  *'/api/embed'*)
    vector=$(jq -nc '[range(0;768) | 0]')
    jq -nc --argjson vector "$vector" '{embeddings:[$vector],total_duration:100,prompt_eval_count:9}'
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
    FM_FAKE_LOG="${FM_FAKE_LOG:-}" \
    FM_FAKE_WATCH_HANG="${FM_FAKE_WATCH_HANG:-no}" \
    FM_FAKE_CHILD_PID_FILE="${FM_FAKE_CHILD_PID_FILE:-}" \
    FM_FAKE_GENERATOR_LOG="${FM_FAKE_GENERATOR_LOG:-}" \
    HOME="$dir/home" \
    PATH="$dir/fakebin:$PATH" \
    "$SCRIPT" \
      --project "$dir/project" \
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
  assert_contains "$out" "plan complete; no package, service, model, index, MCP, or rollback-manifest state was changed" "plan no-mutation result"
  [ "$before" = "$after" ] || fail "plan changed project state"
  [ "$before_exclude" = "$after_exclude" ] || fail "plan changed the local exclude file"
  [ ! -e "$dir/install-parent/tools" ] || fail "plan created the install root"
  pass "indexing recovery: help is explicit and plan inventories without mutation"
}

test_fail_closed_preflight_matrix() {
  local dir out rc
  dir=$(new_fixture refusals)
  printf 'ID=ubuntu\nID_LIKE=debian\n' > "$dir/os-release"
  out=$(run_kit "$dir" --action plan --pull-model no --start-ollama no --persist-ollama no --install-tools no --init none 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "unsupported OS passed"
  assert_contains "$out" "unsupported OS 'ubuntu'" "unsupported OS refusal"

  printf 'ID=cachyos\nID_LIKE=arch\n' > "$dir/os-release"
  out=$(FM_INDEX_OS_RELEASE="$dir/os-release" FM_INDEX_MEMINFO="$dir/meminfo" FM_INDEX_LOADAVG="$dir/loadavg" FM_INDEX_UNAME_M=x86_64 HOME="$dir/home" PATH="$dir/fakebin:$PATH" "$SCRIPT" \
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
  pass "indexing recovery: OS, polyglot, resource, and daemon hazards fail closed"
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

test_benchmark_timeout_reaps_process_group_and_stops_watcher() {
  local dir out rc child_pid
  dir=$(new_fixture benchmark-timeout)
  : > "$dir/fake.log"
  FM_FAKE_LOG="$dir/fake.log" FM_FAKE_WATCH_HANG=yes FM_FAKE_CHILD_PID_FILE="$dir/child.pid" \
    out=$(run_kit "$dir" --action apply --pull-model no --start-ollama no --persist-ollama no --install-tools no --init none --benchmark yes --max-index-seconds 1 \
      --benchmark-query 'one=src/main.rs' --benchmark-query 'two=src/main.rs' --benchmark-query 'three=src/main.rs' --benchmark-query 'four=src/main.rs' --benchmark-query 'five=src/main.rs' \
      --rollback-manifest "$dir/rollback.log" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "hanging benchmark passed"
  assert_contains "$out" "scratch grepai index exceeded the 1s hard bound" "benchmark timeout refusal"
  grep -F 'args=watch --stop' "$dir/fake.log" >/dev/null || fail "benchmark timeout did not invoke grepai watch --stop"
  [ -s "$dir/child.pid" ] || fail "benchmark fixture did not record its child"
  child_pid=$(cat "$dir/child.pid")
  [ ! -e "/proc/$child_pid" ] || fail "benchmark child process $child_pid survived process-group cleanup"
  pass "indexing recovery: benchmark timeout reaps its process group and stops the watcher"
}

test_read_only_health_observes_local_model() {
  local dir out before after before_exclude after_exclude
  dir=$(new_fixture health)
  before=$(git -C "$dir/project" status --porcelain=v1)
  before_exclude=$(sha256sum "$dir/project/.git/info/exclude")
  out=$(run_kit "$dir" --action health --pull-model no --start-ollama no --persist-ollama no --install-tools no --init none)
  after=$(git -C "$dir/project" status --porcelain=v1)
  after_exclude=$(sha256sum "$dir/project/.git/info/exclude")
  assert_contains "$out" "ollama_health digest=sha256:test-local-model size=274000000 dimensions=768" "local model health"
  assert_contains "$out" "placement='nomic-embed-text:latest abc 274 MB 100% CPU'" "CPU placement health"
  assert_contains "$out" "complete action=health" "health completion"
  [ "$before" = "$after" ] || fail "health changed project state"
  [ "$before_exclude" = "$after_exclude" ] || fail "health changed local excludes"
  pass "indexing recovery: health validates the loopback model without mutation"
}

seed_healthy_indexes() {
  local dir=$1
  mkdir -p "$dir/project/.grepai" "$dir/project/.codegraph" "$dir/project/.serena" "$dir/project/.git/info"
  printf 'provider: ollama\nmodel: nomic-embed-text:latest\nbackend: gob\n' > "$dir/project/.grepai/config.yaml"
  printf 'sqlite fixture\n' > "$dir/project/.codegraph/codegraph.db"
  printf 'languages:\n- rust\n- typescript\n- python\n' > "$dir/project/.serena/project.yml"
  printf '.grepai/\n.codegraph/\n.serena/\n' > "$dir/project/.git/info/exclude"
}

test_healthy_apply_is_idempotent_and_mcp_is_bounded() {
  local dir out first_tree second_tree
  dir=$(new_fixture healthy-apply)
  seed_healthy_indexes "$dir"
  first_tree=$(find "$dir/project" -path "$dir/project/.git" -prune -o -type f -print0 | sort -z | xargs -0 sha256sum)
  out=$(run_kit "$dir" --action apply --pull-model no --start-ollama no --persist-ollama no --install-tools no --init grepai,codegraph,serena --rollback-manifest "$dir/rollback.log")
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
  printf '{"overview":"Root: 0 servers, 0 tools"}\n' > "$lazy/hierarchy/root.json"
  printf '#!/usr/bin/env bash\nexit 100\n' > "$lazy/structure_generator"
  chmod +x "$lazy/structure_generator"
  before_runtime=$(sha256sum "$lazy/config.json")
  before_generator=$(sha256sum "$lazy/gen_config.json")
  out=$(FM_INDEX_OS_RELEASE="$dir/os-release" FM_INDEX_MEMINFO="$dir/meminfo" FM_INDEX_LOADAVG="$dir/loadavg" FM_INDEX_UNAME_M=x86_64 HOME="$dir/home" PATH="$dir/fakebin:$PATH" "$SCRIPT" \
    --action apply --project "$dir/project" --ollama-owner arch --ollama-accel cpu --pull-model no --start-ollama no --persist-ollama no --install-tools no \
    --init grepai,codegraph,serena --ignore-policy defaults --state-policy local-ignored --serena-language rust --serena-language typescript --serena-language python \
    --allow-language-downloads no --telemetry off --benchmark no --health-query main --mcp-client lazy-mcp --mcp-scope user --lazy-mcp-dir "$lazy" \
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
  printf '{"overview":"Root: 0 servers, 0 tools"}\n' > "$lazy/hierarchy/root.json"
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
    --init grepai,codegraph,serena --mcp-client lazy-mcp --mcp-scope user --lazy-mcp-dir "$lazy" --rollback-manifest "$dir/rollback.log")
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
  backup_count=$(find "$lazy" -name '*.fm-indexing-backup-*' -type f | wc -l | tr -d ' ')
  [ "$backup_count" -eq 3 ] || fail "lazy-mcp registration made $backup_count backups, expected 3"
  first_calls=$(wc -l < "$dir/generator.log" | tr -d ' ')
  FM_FAKE_GENERATOR_LOG="$dir/generator.log" out=$(run_kit "$dir" --action apply --pull-model no --start-ollama no --persist-ollama no --install-tools no \
    --init grepai,codegraph,serena --mcp-client lazy-mcp --mcp-scope user --lazy-mcp-dir "$lazy" --rollback-manifest "$dir/rollback.log")
  second_calls=$(wc -l < "$dir/generator.log" | tr -d ' ')
  assert_contains "$out" "lazy_mcp registration=no-op existing entries and hierarchy are healthy" "lazy-mcp rerun no-op"
  [ "$first_calls" -eq 1 ] && [ "$second_calls" -eq 1 ] || fail "lazy-mcp no-op reran the hierarchy generator"
  pass "indexing recovery: lazy-mcp registration is additive, backed up, and idempotent"
}

test_help_and_plan_are_read_only
test_fail_closed_preflight_matrix
test_dirty_apply_refuses_before_mutation
test_benchmark_timeout_reaps_process_group_and_stops_watcher
test_read_only_health_observes_local_model
test_healthy_apply_is_idempotent_and_mcp_is_bounded
test_lazy_mcp_conflict_preserves_bytes
test_lazy_mcp_registration_is_additive_reversible_and_idempotent

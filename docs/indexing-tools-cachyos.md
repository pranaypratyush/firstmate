# CachyOS local indexing recovery

Use [`fm-indexing-tools-cachyos.sh`](../bin/fm-indexing-tools-cachyos.sh) to recover grepai with local Ollama and `nomic-embed-text`, `colbymchenry/codegraph`, Serena, and optional lazy-mcp registration for one explicit Git worktree.
The script owns all flags and mechanics; run `bin/fm-indexing-tools-cachyos.sh --help` instead of copying installation commands from this page.

The recovery boundary is local-first.
Project source, indexes, embeddings, and credentials stay on the machine, while the only outbound requests made by apply mode are approved package, release-asset, Python-package, and model downloads.
Ollama is accepted only through `127.0.0.1:11434`, direct MCP checks use stdio, CodeGraph telemetry is disabled, Serena usage reporting is disabled, and generated lazy-mcp entries contain no secrets.

## Recovery pass

Start with the plan action and supply every decision even when the answer is no.
The plan validates CachyOS/Arch, x86-64 or arm64, the exact no-symlink Git/state topology, local-filesystem suitability, binary/package ownership, PATH precedence, Ollama service provenance, loopback binding, accelerator evidence, existing config/index layout, exact Serena languages, RAM, disk, physical/logical CPU, load/temperature, inotify headroom, extension distribution, and the grepai v0.35.0 scanner census before mutation.
The complete source inventory has its own hard timeout.
It refuses tracked source symlinks and special files before reading candidate content, requires working `ss` and systemd service inventory, and uses either a validated `XDG_RUNTIME_DIR` or an owner-private mode-0700 lock directory directly under `HOME`.
It exits without creating a rollback manifest or changing packages, services, models, indexes, Git excludes, MCP configuration, or lazy-mcp hierarchy.
Apply mode requires a clean worktree whenever it benchmarks or initializes project state so the `HEAD` scratch copy and canonical index cannot silently diverge.

The script's `--help` output is the single owner of the complete invocation, exact flags, defaults, thresholds, and mutation mechanics.
Prepare exactly five project-specific benchmark queries and include exactly the selected Serena language set before changing the selected action from plan to apply.

Choosing the default ignore policy explicitly accepts grepai's pinned scanner and ignore defaults.
Choose the existing ignore policy only when the project already has a reviewed `.grepaiignore`.
The local-ignored state policy adds only missing index-directory entries to the worktree's local Git exclude file, while the existing policy requires pre-existing state and performs no initialization.

Apply mode requires a private rollback-manifest path and is safe to rerun against the same healthy pins.
Existing compatible state receives substantive health checks before setup mutation, while version, owner, model, language, state-path, symlink, service, and lazy-mcp conflicts stop with the exact choice that must be reconciled.
Fresh grepai state is revalidated with an explicit `http://127.0.0.1:11434` endpoint before any watcher starts, and planned initializer paths plus partial failures are retained in the rollback manifest for operator recovery.
An existing canonical grepai watcher is inventoried and refused instead of adopted because persistent watching is outside the accepted policy.
The script never removes or overwrites an existing index, model, service, tool owner, MCP entry, lazy-mcp category, or Serena configuration.
Fresh Serena initialization requires explicit permission for managed dependency resolution because a network-free first run cannot be proven across every supported language backend.
Healthy reruns may deny language downloads: they reuse only owner-validated managed Serena state and caches, force supported package managers into offline mode, and stop before health when that managed state is absent.

## Resource and benchmark gate

The pinned release downloads are approximately 8 MB for grepai and 62 MB for CodeGraph, and the accepted `nomic-embed-text` manifest is 274,302,450 bytes with digest `0a109f422b47e3a30ba2b10eca18548e944e8a23073ee3f3e947efcf3c45e59f`, F16 quantization, and 768-dimensional output.
Serena language servers and Arch GPU runtime packages add tool-specific downloads, with current CUDA and ROCm packages potentially consuming roughly 1 GB and 3 GB respectively.
Project indexes remain workload-dependent, so the default preflight requires at least 1 GiB of available RAM and 2 GiB free on both project and install filesystems and prints the actual observations.
Raise those floors for large repositories rather than treating them as capacity promises.

New canonical grepai state is refused until the script-owned cold/warm, resource, scratch-index, search-latency, incremental-convergence, and watcher-idle gates all pass.
The cold pass requires the model to have been unloaded at entry, explicitly verifies the task-loaded model is stopped before its first request, uses exactly five search cases, and measures watcher CPU over a post-convergence idle window rather than lifetime CPU.
The script's help owns their exact thresholds and cleanup mechanics.
Persistent grepai watching is intentionally outside this kit and its required decision accepts only no.

Health mode forbids install, pull, start, and persistence mutations while running the bounded probes owned by the script.
Indexer status, search, stop, init, query, MCP, and individual embed requests all have process-enforced timeouts.
Serena health runs once against its owner-validated managed cache, removes only the exact task-created project health log, and records that boundary for apply runs.

## Ollama and tool ownership

The Arch owner discovers the current signed repository version and installs only the selected official CPU or accelerator package without a partial repository upgrade.
The script never chooses a GPU package from vendor name alone or mixes a package-owned binary with an upstream-owned service.
The upstream owner is supported for a separately installed pinned Ollama v0.32.6 in CPU mode because the upstream bundle owns privileged system paths that this compact recovery script will not replace automatically.
Pre-existing active Ollama service state is never adopted or stopped; task-planned enable/start transitions are observed separately and partial failures are reconciled to their prior state.

grepai v0.35.0 and CodeGraph v1.5.0 use immutable GitHub release URLs and the exact SHA-256 digests published with those releases for both supported architectures.
Serena is installed as exact `serena-agent==1.6.1` through Arch-owned `uv` into the selected user-local install root.
Version changes are deliberate source changes: inspect the new upstream release, update the pin and published per-architecture digest, run the offline tests and a real recovery plan, then ship the script through normal review.

## Lazy-mcp and rollback

Optional lazy-mcp registration is available only through the explicit user-scoped choice documented by the script's help after all three direct health checks pass.
It remains additive, loopback-only, secret-free, backed up, reversible, project-bound for all three servers, and a no-op on an identical rerun.
Symlink-managed lazy-mcp configs, hierarchy roots, categories, or ancestors are refused without changing their targets.

The rollback manifest records created payloads, symlinks, project state, model digest, prior Ollama active/enabled state, and every lazy-mcp backup without embedding credentials.
For rollback, restore only the recorded config backups and prior service state first, then reinstall a recorded prior pin if required.
Indexes and models are retained by default as recoverable local data.
Removing `.grepai`, `.codegraph`, `.serena`, an Ollama model, a package, a tool environment, or a service is a separate destructive decision and is never performed by this script.

Upstream behavior references: [grepai installation and commands](https://yoanbernabeu.github.io/grepai/), [CodeGraph README](https://github.com/colbymchenry/codegraph), [Serena usage guide](https://oraios.github.io/serena/02-usage/010_installation.html), [Ollama Linux setup](https://docs.ollama.com/linux), and [Arch package search](https://archlinux.org/packages/).

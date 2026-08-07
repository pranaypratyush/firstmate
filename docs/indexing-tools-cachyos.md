# CachyOS local indexing recovery

Use [`fm-indexing-tools-cachyos.sh`](../bin/fm-indexing-tools-cachyos.sh) to recover grepai with local Ollama and `nomic-embed-text`, `colbymchenry/codegraph`, Serena, and optional lazy-mcp registration for one explicit Git worktree.
The script owns all flags and mechanics; run `bin/fm-indexing-tools-cachyos.sh --help` instead of copying installation commands from this page.

The recovery boundary is local-first.
Project source, indexes, embeddings, and credentials stay on the machine, while the only outbound requests made by apply mode are approved package, release-asset, Python-package, and model downloads.
Ollama is accepted only through `127.0.0.1:11434`, direct MCP checks use stdio, CodeGraph telemetry is disabled, Serena usage reporting is disabled, and generated lazy-mcp entries contain no secrets.

## Recovery pass

Start with `--action plan` and supply every decision even when the answer is `no`.
The plan validates CachyOS/Arch, x86-64 or arm64, the exact Git root, local-filesystem suitability, binary/package ownership, PATH precedence, Ollama service provenance, loopback binding, accelerator prerequisites, existing configs and indexes, detected languages, RAM, disk, CPU/load, and the grepai v0.35.0 scanner census before mutation.
It exits without creating a rollback manifest or changing packages, services, models, indexes, Git excludes, MCP configuration, or lazy-mcp hierarchy.
Apply mode requires a clean worktree whenever it benchmarks or initializes project state so the `HEAD` scratch copy and canonical index cannot silently diverge.

This is the smallest planning shape; add every detected Serena language and five project-specific benchmark cases before changing `plan` to `apply`:

```sh
bin/fm-indexing-tools-cachyos.sh \
  --action plan \
  --project /absolute/path/to/project \
  --ollama-owner arch \
  --ollama-accel cpu \
  --pull-model yes \
  --start-ollama yes \
  --persist-ollama no \
  --install-tools yes \
  --init grepai,codegraph,serena \
  --ignore-policy defaults \
  --state-policy local-ignored \
  --serena-language rust \
  --serena-language typescript \
  --serena-language python \
  --allow-language-downloads yes \
  --telemetry off \
  --benchmark yes \
  --benchmark-query 'authentication flow=src/auth' \
  --benchmark-query 'database migrations=db/migrations' \
  --benchmark-query 'command entrypoint=src/main' \
  --benchmark-query 'error handling=src/error' \
  --benchmark-query 'configuration parsing=src/config' \
  --health-query 'configuration parsing' \
  --mcp-client none \
  --mcp-scope print \
  --persistent-grepai-watch no \
  --destructive-rollback no
```

`--ignore-policy defaults` is an explicit acceptance of grepai's pinned scanner and ignore defaults.
Use `--ignore-policy existing` only when the project already has a reviewed `.grepaiignore`.
`--state-policy local-ignored` adds only missing `.grepai/`, `.codegraph/`, and `.serena/` entries to the worktree's local Git exclude file, while `existing` requires pre-existing state and performs no initialization.

Apply mode requires a private `--rollback-manifest PATH` and is safe to rerun against the same healthy pins.
Existing compatible state is reused or incrementally checked, while version, owner, model, language, state-path, symlink, service, and lazy-mcp conflicts stop with the exact choice that must be reconciled.
The script never removes or overwrites an existing index, model, service, tool owner, MCP entry, lazy-mcp category, or Serena configuration.

## Resource and benchmark gate

The pinned release downloads are approximately 8 MB for grepai and 62 MB for CodeGraph, and the observed `nomic-embed-text` model is approximately 274 MB with 768-dimensional output.
Serena language servers and Arch GPU runtime packages add tool-specific downloads, with current CUDA and ROCm packages potentially consuming roughly 1 GB and 3 GB respectively.
Project indexes remain workload-dependent, so the default preflight requires at least 1 GiB of available RAM and 2 GiB free on both project and install filesystems and prints the actual observations.
Raise those floors for large repositories rather than treating them as capacity promises.

New canonical grepai state requires `--benchmark yes`.
The script creates a temporary `git archive HEAD`, performs an Ollama embed probe, enforces the selected CPU/GPU placement, bounds scratch indexing to 15 minutes by default, samples the observed RAM delta against the selected percentage, requires at least four of five expected areas in the top ten results, stops the scratch watcher, and removes the scratch tree.
Canonical grepai indexing also uses the hard timeout and always stops the watcher before exit.
Persistent grepai watching is intentionally outside this kit, so `--persistent-grepai-watch` accepts only `no`.

Health mode is read-only and requires install, pull, start, and persistence flags all set to `no`.
It checks the local model digest, size, 768-vector embed result, and processor placement; grepai status, query, and MCP initialize/tools-list; CodeGraph JSON status, query, and MCP initialize/tools-list; and Serena selected languages, project health-check, symbol services, and MCP initialize/tools-list.
Every direct MCP process has a hard timeout and is stopped as a process group.

## Ollama and tool ownership

The Arch owner discovers the current signed repository version with `pacman -Si` and installs only the selected `ollama`, `ollama-cuda`, `ollama-rocm`, or `ollama-vulkan` package with `pacman -S --needed`.
The script never runs `pacman -Sy`, chooses a GPU package from vendor name alone, or mixes a package-owned binary with an upstream-owned service.
The upstream owner is supported for a separately installed pinned Ollama v0.32.6 in CPU mode because the upstream bundle owns privileged system paths that this compact recovery script will not replace automatically.

grepai v0.35.0 and CodeGraph v1.5.0 use immutable GitHub release URLs and the exact SHA-256 digests published with those releases for both supported architectures.
Serena is installed as exact `serena-agent==1.6.1` through Arch-owned `uv` into the selected user-local install root.
Version changes are deliberate source changes: inspect the new upstream release, update the pin and published per-architecture digest, run the offline tests and a real recovery plan, then ship the script through normal review.

## Lazy-mcp and rollback

`--mcp-client none --mcp-scope print` prints the three secret-free stdio entries without touching a client.
For this workstation's hierarchy, use `--mcp-client lazy-mcp --mcp-scope user --lazy-mcp-dir /absolute/path/to/lazy-mcp` only after all three direct health checks pass.
The directory must already contain `config.json`, `gen_config.json`, `hierarchy/`, and `structure_generator`.
Registration generates only the three local servers in a temporary hierarchy, refuses duplicate differences, copies only absent categories, atomically adds the entries to both configs, keeps byte-for-byte private backups of both source files, retains unrelated entries semantically, and refuses a non-loopback HTTP proxy bind.
An identical rerun is a no-op.

The rollback manifest records created payloads, symlinks, project state, model digest, prior Ollama active/enabled state, and every lazy-mcp backup without embedding credentials.
For rollback, restore only the recorded config backups and prior service state first, then reinstall a recorded prior pin if required.
Indexes and models are retained by default as recoverable local data.
Removing `.grepai`, `.codegraph`, `.serena`, an Ollama model, a package, a tool environment, or a service is a separate destructive decision and is never performed by this script.

Upstream behavior references: [grepai installation and commands](https://yoanbernabeu.github.io/grepai/), [CodeGraph README](https://github.com/colbymchenry/codegraph), [Serena usage guide](https://oraios.github.io/serena/02-usage/010_installation.html), [Ollama Linux setup](https://docs.ollama.com/linux), and [Arch package search](https://archlinux.org/packages/).

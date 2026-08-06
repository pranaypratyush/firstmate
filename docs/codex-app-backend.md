# Codex App backend boundary

Codex App is not a selectable Firstmate runtime backend.
Codex Desktop host tools can create and supervise visible threads and those threads can write Firstmate status files when given an authorized path, but Firstmate has no supported shell-callable bridge to those host tools.
A manual thread ledger is not a backend.

## No-mistakes live companion

An eligible Herdr `kind=ship`, `mode=no-mistakes` task opens an unfocused companion tab for the exact active Codex App Server thread by default.
This is a view-oriented companion to the no-mistakes-owned structured turn, not a Firstmate runtime backend and not a second delivery path.
The current Codex TUI remains interactive, so typing into the companion can interfere with the no-mistakes-owned turn even though Firstmate never routes messages, approvals, or lifecycle input there.

The trigger recognizes only the harness adapter's exact canonical no-mistakes invocation after `fm-send` has resolved a recorded task selector.
Claude, Grok, and Kimi use `/no-mistakes`, Codex uses `$no-mistakes`, and the OpenCode, Pi, Pi Signed, and Muse natural-language surfaces are not inferred.
Preflight validates the exact task and parent workspace and may ensure the shared managed App Server, but it creates no tab and never submits or rewrites the skill invocation.
Only a successful backend delivery verdict activates the journal and reconciliation.
A later companion failure is reported as already-delivered and never invites resending the skill.

The no-mistakes interface is pinned to commit `0d39eadf3f36ed8087794947425d122ca9323f8f`.
The global no-mistakes config must select the singular `agent: codex`, `codex.transport: app-server`, and a local `codex.app_server_endpoint` matching the managed endpoint or the `unix://` default alias.
Eligible active steps expose their exact thread identity as `active_steps[].session_id`.
Firstmate accepts exactly one canonical UUID from a causally matching active run whose branch and head pass the shared attribution rule in `bin/fm-nm-run-lib.sh`.
Detached, another-branch, stale, locally advanced, diverged, terminal, malformed, multiple, or already-claimed identities never create a companion.

`bin/fm-codex-app-server.sh` is the sole owner of managed App Server lifecycle JSON and socket validation.
It invokes only the idempotent managed daemon start or read-only inspection, accepts only a positive managed pid with matching nonempty CLI, App Server, and managed Codex versions, and validates the exact absolute non-symlink Unix socket as current-user-owned mode 0600 before returning a normalized `unix:///absolute/path` endpoint.
It never scans processes or sockets and never stops or restarts the shared server.
A missing managed standalone installation fails with a bootstrap and current-session consent diagnostic; Firstmate does not install it implicitly.

`bin/fm-nm-live.sh` owns the mode-0600 `state/<task-id>.nm-live` journal, run and thread attribution, exact Herdr creation, restart reconciliation, duplicate prevention, rotation, quarantine, and focus-safe cleanup.
The tab is created in the journal's exact named session and exact parent workspace with `--no-focus`, a `VIEW ONLY` no-mistakes label, and `$FM_HOME/state` as its local cwd.
Only the exact returned root pane receives one safely quoted `codex --remote <endpoint> resume <session-id>` launch.
Labels and global focus are never identity or adoption sources.
Lost or malformed mutation responses quarantine the attempt instead of searching by label.
Normal watcher cycles and locked startup reconcile the journal idempotently.
Terminal or rotated threads close only the exact nonfocused pane; a focused companion records `cleanup-deferred` and remains open until a later safe cycle.
Teardown asks for this exact cleanup before removing task state, and a deferred journal deliberately survives missing task metadata so locked startup can finish it later.
No companion path closes a Herdr workspace, stops the shared Codex or no-mistakes daemon, archives the server thread, or changes focus as cleanup policy.

A home opts out by writing `off` to its private gitignored `config/nm-live-view`.
Absence, an empty file, and `on` mean enabled, while an unrecognized value warns and keeps the default-on behavior.
The setting follows the primary-authoritative secondmate inheritance contract in `.agents/skills/secondmate-provisioning/SKILL.md`.
`tests/fm-nm-live.test.sh` is the deterministic fake-surface regression entry point.

## Acceptance contract

A future Codex App backend must satisfy the same lifecycle contract as terminal-backed adapters:

1. Create a task endpoint and return a durable thread id.
2. Send the initial instructions and later operator messages to that endpoint.
3. Read enough live state or bounded transcript to supervise the task.
4. Archive, kill, or otherwise stop the exact endpoint.
5. Let the thread append Firstmate's normal lifecycle lines to `state/<id>.status`.

The status return channel is mandatory.
A visible thread that cannot report into Firstmate's normal lifecycle is not a complete backend.

## Selectable-backend blocker

Firstmate backend scripts are shell entry points and can call tmux, Herdr, Zellij, Orca, and cmux directly.
Codex Desktop host tools are available to a Desktop conversation, not to arbitrary Firstmate subprocesses.
The missing component is a Codex Desktop-supported shell-callable transport, not another local ledger.

`codex app-server --stdio` exposes useful JSON-RPC pieces such as thread start, turn start, thread read, and thread archive.
A one-process probe could create and archive a thread record, but no supported bridge was found that lets Firstmate create, continue, read, and archive the same visible Desktop-owned endpoint over its full lifetime.
A raw Desktop control-socket proxy is not a supported transport.
These partial pieces do not authorize adding `codex-app` to the known or spawn-capable backend registries.

## Required bridge for a selectable backend

Implementation can begin after Codex Desktop exposes one supported interface:

- a CLI wrapper for create, send, read, and archive host-tool operations;
- a documented JSON-RPC or MCP transport with stable framing; or
- a maintained helper that speaks the supported transport and returns plain JSON to a shell adapter.

The bridge must provide these semantics:

```text
create: task id, worktree request, initial instructions -> thread id, cwd, state
send: thread id, text -> accepted or rejected
read: thread id, bounded cursor -> transcript and live state
archive: thread id -> archived or stopped
return: thread appends state/<id>.status lifecycle lines
```

Once available, Firstmate should add a real `bin/backends/codex-app.sh`, persist `backend=codex-app` and `codex_app_thread_id=`, and route spawn, send, peek, watch, and cleanup through the shared dispatcher.

## Rollout

Ship and scout tasks come first.
Secondmate support remains out of scope until create, send, read, status return, and archive are proven through the normal backend dispatcher.
Until then, Codex App remains a blocked backend boundary with a verified host-tool capability record, not a selectable backend.

[`verification/runtime-backends.md`](verification/runtime-backends.md#codex-app-host-tools) owns the active Desktop host-tool smoke without exposing task-specific thread ids or local paths.

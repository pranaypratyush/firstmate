# Codex App backend boundary

Codex App is not a selectable Firstmate runtime backend.
Codex Desktop host tools can create and supervise visible threads and those threads can write Firstmate status files when given an authorized path, but Firstmate has no supported shell-callable bridge to those host tools.
A manual thread ledger is not a backend.

## No-mistakes live companion

An eligible Herdr `kind=ship`, `mode=no-mistakes` task opens an unfocused companion tab for the exact active Codex App Server thread by default.
This is a view-oriented companion to the no-mistakes-owned structured turn, not a Firstmate runtime backend and not a second delivery path.
The current Codex TUI remains interactive, so typing into the companion can interfere with the no-mistakes-owned turn even though Firstmate never routes messages, approvals, or lifecycle input there.

The companion activates only after `fm-send` successfully delivers the eligible task's canonical no-mistakes invocation.
Preflight may prepare the exact parent and shared server state, but it never delivers the invocation, and a later companion failure cannot turn an already-delivered command into an unsent result.

The headers of `bin/fm-codex-app-server.sh`, `bin/fm-nm-run-lib.sh`, and `bin/fm-nm-live.sh` own the lifecycle, attribution, journal, Herdr mutation, recovery, and cleanup mechanics.
Their public safety boundary is that Firstmate never discovers identity globally, never uses a label as authority, never routes input or approvals to the companion, and never stops a shared Codex or no-mistakes daemon or closes a Herdr workspace.
Malformed or ambiguous identity and mutation results fail closed, while focused cleanup is deferred for a later safe cycle.

[`configuration.md`](configuration.md) owns the private `config/nm-live-view` schema and inheritance behavior.
`tests/fm-nm-live.test.sh` is the deterministic fake-surface regression entry point, and `tests/fm-nm-live-herdr-process-live-e2e.test.sh` is the opt-in installed-interface drift guard.

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

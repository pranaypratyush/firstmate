---
name: stuck-crewmate-recovery
description: >-
  Agent-only playbook for stuck or missing ordinary Firstmate direct reports.
  Use when the session-start digest reports an ordinary direct report's endpoint dead or its metadata has no window, or after a stale wake, looping pane, repeated confusion, an answered-by-brief question, an unresponsive crewmate, a failed inbox enqueue or typed steer, or a delivered-no-turn or delivered-no-turn-persistence-failed verdict.
  Reconciles recorded work before escalating from targeted inspection through safe relaunch or failure.
user-invocable: false
metadata:
  internal: true
---

# stuck-crewmate-recovery

Use this playbook when the session-start digest reports an ordinary direct report's endpoint dead or its metadata has no window, or when a direct report is stale, looping, repeatedly confused, asking a question its brief already answers, unresponsive, when an inbox enqueue or typed steer fails, or when `fm-send.sh` reports `delivered-no-turn` or `delivered-no-turn-persistence-failed`.

Load `harness-adapters` before sending an interrupt, exit command, resume command, or harness-specific skill invocation.
The target window's harness is recorded as `harness=` in `state/<id>.meta`.

## Session-start reconciliation for a dead ordinary direct report

This procedure covers ordinary `kind=ship` and `kind=scout` direct reports.
Load `secondmate-provisioning` instead for `kind=secondmate` recovery.

Treat the digest's endpoint result as a presence signal, not proof that the task's work or validation run is gone.
Read the targeted current state with `bin/fm-crew-state.sh <id>` before deciding how to preserve the work.
A no-mistakes run matched to the crew's branch and current code remains authoritative when the endpoint is dead: handle a terminal or parked run through the normal lifecycle, and keep supervising an active run instead of creating a duplicate worker.

When no authoritative run accounts for the task, inspect only its recorded backend and worktree inventory.
Use `treehouse status` for treehouse-backed tmux, herdr, zellij, or cmux tasks, and use the recorded `orca_worktree_id=` and `terminal=` for Orca tasks.
Do not sweep another home's endpoints or infer ownership from a matching window label.

Ordinary-worker recovery is never automatic.
Do not resume an old session, restart an old worker, close an endpoint, or reuse its isolated copy.
When the recorded endpoint is authoritatively `missing`, the operator may explicitly run `bin/fm-clean-commit-relaunch.sh <source-task-id> <destination-task-id>` only after preparing the destination's complete ship brief.
That command accepts only a readable, completely clean source isolated copy at an exact committed branch tip in the recorded physical repository, then makes a separate destination worker and preserves the source as evidence.
Uncommitted, dirty, unreadable, dead-but-present, ambiguous, malformed, cross-home, or manual-salvage cases stay blocked with every source record intact.
An active or parked No-Mistakes run is never changed by the relaunch and refuses before destination creation.
If the worktree or ownership cannot be reconciled safely, leave all state intact and report the task failed or blocked with the conflicting evidence.

## Live-endpoint escalation

Both delivered-no-turn verdicts mean a typed command was submitted but OMP or Hermes did not begin a turn, so never resend the same command as if delivery failed.
Treat the synchronous verdict itself as the supervised-recovery trigger; use any persisted `failed:` status event and watcher wake as corroboration, then inspect the recorded worktree and current validation state and preserve every uncommitted change and commit before any endpoint lifecycle action.
Do not automatically terminate an ordinary crewmate or scout on this verdict because its work may be unlanded.

Escalate in order:

1. Peek the pane and inspect `state/<id>.inbox/*.msg` for any durable instruction that survived without acknowledgement before re-steering or relaunching.
2. If the crewmate is waiting on a question its brief already answers, send a concise answer via `FM_HOME=<this-firstmate-home> bin/fm-send.sh` from an active firstmate session unless `FM_HOME` is already set to the active firstmate home; when that question is an open keyed decision or blocker, pass its key through `--resolve-key` as required by `bin/fm-send.sh`'s header contract.
3. If the crewmate is confused or looping, interrupt with the adapter's interrupt key, then send a concise corrective steer.
   For example, for a single-Escape adapter: `FM_HOME=<this-firstmate-home> bin/fm-send.sh <window> --key Escape`.
4. For a live OMP agent whose PROVIDER STREAM is wedged but whose composer still submits input, send `/fresh` via `fm-send` first and confirm it takes a fresh turn.
   `/fresh` rotates provider-stream state while retaining the local transcript, session file, and identity, and is rejected during active streaming, so abort the current turn first when needed.
   This does not fix a herdr composer-submit freeze where input is swallowed and `/fresh` cannot be submitted; that distinct case still requires the existing kill-plus-respawn recovery.
   If `/fresh` cannot be submitted or does not clear the wedge, continue with the recovery below.
5. If the crewmate is genuinely wedged after redirection, preserve its endpoint and worktree and report the failure for an explicit operator decision.
6. If the work cannot be continued safely, write `failed` to the backlog and tell the captain the plain failure, preserved work, and consequence using `AGENTS.md` section 9; do not mention metadata, harness, window, or worktree unless the path itself is needed for action.

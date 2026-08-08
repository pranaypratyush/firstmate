---
name: helm
description: Leave away-mode supervision only when the captain explicitly invokes the helm skill, using Firstmate's guarded shutdown and durable catch-up path before ordinary work resumes.
user-invocable: true
metadata:
  internal: true
---

# helm

Leave away mode only through this explicit invocation.

1. Run `bin/fm-afk-return.sh begin` before handling any ordinary captain work.
2. If the command reports a firstmate-actionable blocker or lifecycle failure, preserve the gate, resolve or durably reclassify every listed blocker through the normal lifecycle, and run `bin/fm-afk-return.sh check`.
3. Resume ordinary work only after the command succeeds and reports that catch-up is clear.

If the daemon has stopped while the catch-up gate remains, resume full per-wake responsiveness through the emitted primary-harness supervision protocol while resolving the gate.
The return script owns daemon shutdown, durable wake draining, retained escalation and wedge evidence, retry-safe failure state, and the catch-up gate.

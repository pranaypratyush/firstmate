# Cross-system supervisor handoff — 2026-08-08

This document is the portable authority for resuming the current Firstmate/NSM
fleet without access to this machine's Treehouse worktrees or Firstmate-private
`data/` and `state/` directories.

## Non-negotiable operating constraints

- Do not invoke, resume, poll, synchronize, attach to, or otherwise use
  no-mistakes unless the captain gives a new explicit instruction.
- Ask the captain to review delivery-ready work. Do not merge any PR without the
  captain's explicit word.
- Do not force-push, reset, stash, clean, discard, or rewrite preserved refs.
- Use visible Codex crewmates through Firstmate/Herdr for project work. The
  captain's preferred model is GPT-5.6-sol with effort chosen to fit the task.
- For UI work, ground against the current TalkToFigma channel and real feedback:
  the last recorded current channel is `q5qcznb4`; use Widgetbook for isolated
  components and Maestro against a real emulator/app when integration behavior
  matters. Historical Figma channels in old evidence are not current authority.

## Repository authority

| Repository | Writable fork | Canonical/upstream | Verified main |
|---|---|---|---|
| NSM | `git@github.com:pranaypratyush/nsm.git` | same repository for this fleet | `467ead9081957e499b2d9f66c04cd1be4223ce1e` |
| Firstmate | `git@github.com:pranaypratyush/firstmate.git` | `https://github.com/kunchenguid/firstmate.git` | canonical `833a9a25bcf2ae522d6f93dbbd9911a6d8e7c409`; fork main `70aeba855527f7693082f6dd1bc731e334d0269f` |

All branch tips below were independently read from the remotes on 2026-08-08.
No PR or merge was created during this checkpoint.

## NSM resumable checkpoints

| Work | Remote ref | Exact SHA | State and next action |
|---|---|---|---|
| Feature 019 responsive UI | `019-unify-responsive-ui` | `44eacfeacf90a56f072e5163d416aba3066c923e` | Committed and pushed. It is 15 behind / 2 ahead of the recorded main. Review the open API/Figma decisions below before reconciliation. |
| Feature 020 GraphQL state | `020-unify-graphql-state` | `3e8924fdd5e95657f9f645734c72a03b0a530975` | Recovered, includes current main, committed and pushed. Captain review is the next delivery step. |
| Feature 021 Rust/Surreal GraphQL | `021-rust-surreal-backend` | `93c689bd457a9fa647d58ac6a306da27e92a0aec` | Product feature history, validated and pushed. Review/delivery must use this ref only. |
| Feature 021 excluded custody | `archive/021-excluded-custody-20260808` | `7aa41f5b32ce785a7a9ae22c663038991dbeb27e` | Exact archive of 398 inherited paths. **Custody only: never merge or cherry-pick as product work.** Parent is `93c689b`; tree is `ae54e1e9717522cd511a88a825f1c61e8c92caab`. |
| Feature 022 local-first CI | `022-local-first-ci` | `68f3df9f6881f691e7b6919c0d411253106c4323` | Spec Kit planning only: 73 TDD-first tasks, 39/39 traceability, zero analyze findings, 36/36 readiness. No implementation yet. Captain review and five gates below precede promotion. |
| Stable Rust Clippy cleanup | `fix/backend-clippy-stable` | `236f6686765e06bf0b5b23b4fc8824353375c191` | Strict Clippy reduced 141 diagnostics to zero; focused tests 42/42; captain review required. |
| Superseded build-fix dirt | `fm/nsm-build-fix-audit` | `a3558a836fab58249798471250e67e587fe4dd5d` | Exact two-file archival commit. Audit found no current product value; do not merge without a new product decision. |

### Feature 019 decisions and evidence gap

Open product/API decisions are F036/F038 Like controls versus viewer-context API,
F040 target-profile history, F041 pagination/count/photo semantics, F042
relationship-ID client correction, F043 secondary navigation, and F044 bulk
notification placement. Existing Widgetbook, Figma, and real-app evidence exists,
but no feature-019 Maestro YAML or executed flow was recorded. Final validation
must use representative real backend data and keep Widgetbook evidence distinct
from real-app/Maestro evidence.

### Feature 020 known unchanged baselines

- Landing typecheck passed; landing unit tests passed 26/26; focused Svelte lint
  passed.
- Full landing lint retains the pre-existing `svelte/no-at-html-tags` finding at
  `apps/landing/src/components/Auth/AuthBox.svelte:30`.
- `bun run graphql:check-state` retains the pre-existing provider-owned snapshot
  finding in `apps/nsm/lib/providers/post_provider.dart`.

### Feature 021 archive proof

The archive commit has exactly 398 changed paths over feature HEAD: 396 tracked
`backend/` paths and two `.specify/**/__pycache__/*.pyc` files, with no other
delta. Sorted path manifest SHA-256:
`d7e45e4268d3c9cb578268f1e1e71c836699ddc45de374d384948e02d8c196b4`.
The product branch passed 4/4 central privacy-policy unit tests, 1/1 pinned
SurrealDB 3.2.3 friend-list privacy E2E, and package-scoped Clippy with warnings
denied. A new supervisor should clone the feature normally and materialize the
archive only in a separate detached worktree if custody inspection is necessary.

### Feature 022 captain gates

1. Reconcile the declared Rust 1.86 floor, stable host, and backend nightly
   override before Rust evidence is promoted as reproducible.
2. Decide whether `packages/testing` is repaired, replaced, or quarantined.
3. Approve the mandatory Android AVD/physical-device matrix and evidence owner.
4. Approve host/forge topology, canonical repository, backups, recovery,
   operator access, and credential custody before Stage 3 procurement/Stage 4.
5. Approve the shadow-observation window and recovery-drill threshold before
   Stage 3 acceptance.

Stages 0–2 may be implemented after captain review, but gated promotion remains
non-green until the relevant decisions are recorded.

### Clippy review boundary

The correction branch is clean and review-ready. Known pre-existing repository
limitations are recursion-limit code generation in
`backend/tests/content_length_test.rs` and missing
`backend/benches/common/mod.rs` for repository-wide formatting. Do not treat
those as regressions from the cleanup without fresh evidence.

## Older NSM delivery whose live slot was recycled

Quicksand typography is preserved remotely even though its former Treehouse slot
now points at detached main:

- Branch `fix/android-quicksand-typography` at
  `5963acb44d384bf79808976fb851a24ed4a92dcf`.
- PR `https://github.com/pranaypratyush/nsm/pull/20` is open and unmerged.
- On 2026-08-08 GitHub reported 21 passed and 3 failed checks.
- The typography root cause and fix were proven with bundled Quicksand weights,
  APK manifest inspection, Figma grounding, and Android Maestro login/signup
  captures. Historical evidence used channel `ha8m8ovz`; re-ground future work
  using the current channel.
- The old reboot note tells an agent to poll a no-mistakes run. That instruction
  is superseded: do not touch no-mistakes. Inspect the three failed hosted checks
  directly and ask the captain to review the branch/PR before corrections.

## Remotely preserved parity branches with incomplete local task metadata

These refs exist, while the local Firstmate backlog entries have no child
metadata. Treat them as preserved evidence, not automatically active work:

| Ref | SHA |
|---|---|
| `fm/nsm-build-fix` | `69853f9ff7fb065effbcf15d1a366be8d383378b` |
| `fm/nsm-login-parity-d07a` | `5d6dc5f90d8dd9e718937ebd28cc9feb6e828ed2` |
| `fm/nsm-settings-parity-ef2a` | `4af395571dc60deb253545ec29ceb74ed1951d56` |
| `fm/nsm-friend-menu-parity-d66e` | `afea5f7392462a789d64d486be91ef071f2e2326` |
| `fm/nsm-chat-parity-76cf` | `22b96b00cfb3694dbb28071c466c1917b673ce19` |

Before resuming one, audit its diff and current product intent against main;
do not infer unfinished work merely from the stale backlog checkbox.

## Firstmate fork checkpoints

| Work | Fork ref | Exact SHA | State and next action |
|---|---|---|---|
| Fork/upstream updater topology | `fm/firstmate-fork-upstream-topology` | `d4c08563d83f15fa9e85143d37530c10eec722f5` | Tested and pushed only to the captain's fork. Needs `fork-main-sync` authorization before a scoped PR. |
| Original updater evidence | `captain/updatefirstmate-fork-sync` | `bb75014e202ddd4b03d278f259498e12246bdedb` | Preserve unchanged as evidence. |
| Human-facing no-mistakes/Herdr readiness | `fm/firstmate-no-mistakes-readiness` | `ed4edb66880785cc7ff87bbfc56eb8f212f368e1` | Tested and pushed to the captain's fork; ready for human review. Historical no-mistakes run/PR custody is frozen and must not be revived. |

The one open updater decision is whether to fast-forward
`pranaypratyush/firstmate:main` from `70aeba8555...` to canonical
`833a9a25bc...`. An ancestry-safe operator command was identified as
`gh-axi repo sync pranaypratyush/firstmate --branch main`, but it must not run
without explicit captain authorization. After sync, re-read both main tips,
require exact equality, then open a scoped PR from the feature branch. Never
push to canonical `kunchenguid/firstmate` and never merge without captain word.

## Fresh-machine bootstrap

Fetch the NSM checkpoints without relying on old worktrees:

```bash
git clone git@github.com:pranaypratyush/nsm.git nsm
cd nsm
git fetch --no-tags origin \
  019-unify-responsive-ui \
  020-unify-graphql-state \
  021-rust-surreal-backend \
  archive/021-excluded-custody-20260808 \
  022-local-first-ci \
  fix/backend-clippy-stable \
  fix/android-quicksand-typography \
  fm/nsm-build-fix-audit
git ls-remote --heads origin
```

Clone Firstmate from the captain's fork, but keep canonical upstream separate
and push-disabled:

```bash
git clone git@github.com:pranaypratyush/firstmate.git firstmate
cd firstmate
git remote add upstream https://github.com/kunchenguid/firstmate.git
git remote set-url --push upstream DISABLED
git fetch --no-tags origin \
  fm/firstmate-fork-upstream-topology \
  fm/firstmate-no-mistakes-readiness \
  captain/updatefirstmate-fork-sync
git fetch --no-tags upstream main
git remote -v
```

Do not assume the fork's `main` is current Firstmate code until the explicit
fork-main synchronization decision is resolved. Recreate Firstmate-private
task records from this document and the remote refs; old pane IDs and local
Treehouse paths are not portable authority.

## Local checkout disposition at checkpoint

- All normal NSM and Firstmate branch worktrees are clean and their relevant
  commits are pushed.
- Feature 021 intentionally retains 398 dirty custody paths in its old local
  checkout; the exact bytes are now independently preserved by the archive ref.
- Detached Treehouse pool slots are clean at NSM main and contain no unpushed
  work.
- A stale prunable registration for `/tmp/nsm-020-baseline` points to no existing
  directory; it contains no files to save. Pruning it is optional housekeeping,
  not recovery work.
- No merge, force-push, reset, stash, discard, or no-mistakes action was used for
  this checkpoint.

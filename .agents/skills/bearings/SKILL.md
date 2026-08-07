---
name: bearings
description: >-
  Generate a "pick up where I left off" fleet digest from firstmate's live fleet state.
  Use when the captain invokes /bearings or asks for a bearings report, morning brief, status report, catch-up, "where did I leave off", or "what's in the works".
  Plain /bearings is chat-only by default, while /bearings file explicitly writes the dated data/status-report-<YYYY-MM-DD>.md artifact; live PR enrichment remains opt-in and composes with file mode.
user-invocable: true
metadata:
  internal: true
---

# bearings

Generate a complete current snapshot from the fleet's current state, so the captain can resume in one read after a break, a night, or a context reset.
Plain `/bearings` returns only the concise four-section chat digest.
Only `/bearings file` writes the dated markdown report artifact and then returns the concise four-section chat digest linked to that report.
This skill is operationally read-only in both modes.
It never tears down a task, merges a PR, dispatches new work, steers a worker, answers a decision, cleans up work, mutates backlog or task state, or writes any file except the single dated report in explicit file mode.

## Invocation modes

- Plain `/bearings` gathers a fresh bounded snapshot and renders the four-section chat digest without creating, deleting, reading, or replacing `data/status-report-<YYYY-MM-DD>.md`.
- `/bearings file` gathers a fresh bounded snapshot, replaces today's `data/status-report-<YYYY-MM-DD>.md` from scratch, and renders the four-section chat digest with a link or path to that report.
- Treat `file` only as an explicit invocation option in the slash command.
- Do not treat natural-language requests such as "write a report", "save this", "persist it", or "make a file" as file mode unless the invocation explicitly includes the standalone `file` option.
- When the captain asks to include PRs, pass the snapshot command's live-PR opt-in.
- `/bearings include PRs` remains chat-only and makes the live-PR opt-in.
- `/bearings file include PRs` writes the dated report and makes the live-PR opt-in.

## What it does

1. **Gather live fleet state with one deterministic command.**
   Run `bin/fm-bearings-snapshot.sh` at invocation time and read its compact output.
   It is the single bounded, deterministic fleet-state source for Bearings and renders TOON by default.
   Do not create or consult a second fleet-state reader, parser contract, status-event-tail interpretation, visible-session recap, ad-hoc project probe, or ad-hoc `gh-axi`/`gh` query.
   The command's header and `--help` output own its exact fields, bounds, opt-ins, and output contract.
   Keep the default local-only read unless the captain asks to include PRs.
   For registered secondmates, use the snapshot's structured-home classification and provenance.
   A parent event or bounded terminal contradiction is fallback evidence, never authority over readable structured home state.
   Structured captain-held decisions come from `decision-hold-lifecycle` and appear under `decisions_open`.
   Do not scrape reports, visual-review artifacts, raw status-event tails, or visible conversation history to supplement current state.
   A queued item under `gates` only becomes "next work" when its blocker is gone and its time/date gate has arrived.
   Until then it stays queued with the reason.
   The `(main-inventory)` gate is an action-free integrity warning rather than queued work.
   Render it under Charted Next with the related `omitted` disclosure, never invent an Underway row from backlog-only state, and never move it into Captain's Call.

2. **Compose the four-section chat digest from the fresh snapshot.**
   The gather step is deterministic; your judgment is scoped to ranking the command's facts by what matters right now and writing scannable captain-facing prose.
   Build every nonempty item as one concise causal capsule: name the concrete object, state what happened or remains uncertain, say why that fact matters now, and name the next action and its owner.
   Use only the snapshot's explicit objective, milestone, caveat, evidence, outcome, context, blocker, `next_action`, and owner fields for that capsule.
   Every nonempty Underway and Recently Landed item must use its nonempty `context`, `next_action`, and `next_owner` values rather than reconstructing them from a title.
   Captain's Call must use the canonical `action_types` values and their projected `review_changes_required`, `merge_decision_required`, and `missing_choice_required` booleans, and may render more than one explicit action when more than one value is present.
   Incidental evidence prose never creates an action type.
   Render `action_type_evidence_gap` when action metadata is missing or invalid instead of guessing from the request or evidence prose.
   Surface every machine-visible backlog-body, report-byte, report-character, report-count, evidence-projection, context-projection, hold-reason, next-action, or gate-condition limit through the item's structured caveat.
   Treat a missing causal field as a disclosed evidence gap, never as permission to compress the item to its title or invent the missing link.
   The chat response uses the four complete sections in the chat-response contract below, in the same order, each always present.
   Plain mode stops here and writes no report artifact.

3. **In explicit file mode only, compose and replace the detailed report file.**
   The report uses the same four complete sections as the chat, in the same order, and adds the detail the chat omits.
   Never read an earlier `data/status-report-*.md` to decide what to omit, include, describe as changed, or call current.
   Write the full report to `data/status-report-<YYYY-MM-DD>.md` using today's date.
   If today's file already exists, delete it first, then create a new file from scratch.
   This is the only write allowed by the skill.
   The detailed report includes:
   - **Title** - `# Bearings - <day> <YYYY-MM-DD>` (use "Morning status" only when the captain specifically asks for a morning brief), followed by two or three sentences framing where things stand.
   - **Captain's Call** - every open decision with the concrete implementation or choice, the bounded evidence or findings that produced the request, and one explicit action classified as review the changes, decide whether to merge, or provide a missing choice, plus each PR ready to merge and each needed credential or login, every PR with the full `https://...` URL, never a bare `#number`.
   - **Recently Landed** - the bounded current recent-completions baseline from structured state across the main fleet and every registered secondmate home, with each useful outcome, material caveat or evidence gap, and any named downstream consumer or follow-up owner.
   - **Underway** - each live direct report making progress, with its objective, last trustworthy structured milestone, current caveat, and immediate next action, plus the plans or main pickup pointers worth reopening (`data/<id>/report.md` files, `.lavish/*.html` boards).
   - **Charted Next** - queued or gated work, including any main-inventory integrity warning, with the reason it is queued and the blocker, date, or integrity condition that moves it forward.
   After writing the file, return the concise four-section chat digest and include the report path or link without adding a fifth section.
   For a richer review surface, optionally offer a Lavish board with `lavish-axi` when the report has enough structure to deserve one, but only after the required digest is ready.

## Chat-response contract

This skill is the one owner of the `/bearings` chat-response format; the snapshot and classifier own the data that feeds it, and no other file restates this contract.
Every `/bearings` chat response renders EXACTLY these four sections, in THIS order, and nothing else structural (there is no At Anchor section):

1. **Captain's Call** - ONLY items that need the captain's own action now: a decision to make, a PR to approve or merge, a credential or login to provide, or a blocker only the captain can clear.
   Empty-state: "Nothing needs your action right now."
2. **Recently Landed** - the bounded current recent-completions baseline: merged PRs, completed scouts, and finished local-only merges across the main fleet and every registered secondmate home.
   Empty-state: "No recent completions are in the current baseline."
3. **Underway** - live work progressing on its own, one line of current state per direct report.
   Empty-state: "Nothing is underway."
4. **Charted Next** - queued or gated work waiting on the fleet or a date, plus action-free fleet-integrity warnings, never on the captain.
   Empty-state: "Nothing is queued."

Rules that keep the contract unambiguous:

- Every section ALWAYS renders, even when empty, with its short empty-state sentence; never omit a section.
- Every chat digest and file-mode report is a complete current snapshot, never a delta against a prior report.
- Recently Landed always renders the bounded current baseline, even when the same completions appeared in an earlier report.
- The four buckets are mutually exclusive, so every item is forced into exactly one: needs-your-action is Captain's Call, done is Recently Landed, self-progressing is Underway, and not-yet-started work or an action-free fleet-integrity warning is Charted Next.
- The strict boundary keeps action-free items OUT of Captain's Call: a working or validating task, a queued item blocked on another task or a date, landed work, a completed scout's report pointer, a declared `paused:` external wait, and a bare recorded PR with no merge-ready signal each belong to one of the other three sections, never Captain's Call.
- A secondmate's own row appears Underway only for `active_child_work`; `externally_held` belongs in Charted Next, and `unknown` belongs there as an unavailable-state gate unless its reason requires the captain's action, using that row's structured `context`, `next_action`, and `advance_when` without reconstruction.
- An unavailable live harness state is a caveat attached to the snapshot's last trustworthy structured milestone, context, immediate `next_action`, and `next_owner`, never the whole item.
- Captain's Call names the concrete action from the structured action flags: review the changes, decide whether to merge, or provide the missing choice; never collapse those actions into generic approval wording.
- Recently Landed states the useful evidence-backed `outcome`, material `caveat`, immediate `next_action`, and `next_owner`, and discloses every active source or projection limit.
- When `outcome_evidence_available` is false, render `outcome_evidence_gap` as the result instead of substituting the task title for an outcome.
- Charted Next states the queue reason and uses `advance_when` as the exact condition that moves the item forward.
- Do not suppress separately projected decisions, landed records, or gates from a `partial-structured` home merely because that secondmate's own row is `unknown`.
- Include the required direct address to the captain inside one item or empty-state sentence.
- Every PR appears as the full `https://...` URL; a shorthand `#number` is fine only as a back-reference after the full URL has already appeared in the same digest.
- The chat follows `AGENTS.md` section 9 and carries one scannable line per item.
- Keep the evidence needed to make each action or disposition understandable in the chat capsule; reserve supporting detail, longer plans, and full gate reasons for explicit file mode.
- In file mode, include the report path or link inside the four-section digest without adding another heading.

## Tone and content rules

- The optional file-mode report is a private, captain-facing internal artifact that lives in gitignored `data/`, so unlike normal captain chat it MAY reference task ids, PR URLs, and repo names.
- The captain works with those directly and needs them to resume; keep the report organized and scannable, not a raw dump.
- Every PR reference is a full `https://...` URL, never a bare `#number`.
- Never include PHI or secret values; the report is an operational artifact, but it is still subject to the same security and compliance rules that govern everything else in this fleet.

## Supervision discipline

This skill changes no fleet state.
Do not tear down a task, merge a PR, dispatch queued work, steer a worker, answer a queued decision, clean up work, or mutate any `state/` or `data/` file other than the single report file in explicit file mode.
If the state you read suggests an action - a PR ready to merge, a queued item whose gate has arrived, or a needs-decision finding - name it in its section and leave the action to the normal lifecycle and configured authority rather than taking it from inside this skill.

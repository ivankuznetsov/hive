---
title: Encapsulate idea-draft state decisions in IdeaDraftStore
date: 2026-09-22
tags: [bot, idea-draft, encapsulation, patrol]
---

## Encapsulate idea-draft state decisions in IdeaDraftStore

Patrol finding `encapsulate-idea-draft-state-decisions` (architecture patrol,
scheduled run `scheduled-dad16bf…`): `IdeaDraftStore` declared that the
phase/origin contract belongs to the store, but it still handed callers a live
mutable `Draft` Struct, and three consumers re-derived compound state
interpretations from raw fields:

- `Router` read `phase == :awaiting_transcript_confirm && origin == :voice`
  for transcript-confirm routing and `origin != :voice` for the
  voice-during-draft short-circuit, plus `phase == :awaiting_text` for idea
  text capture.
- `CallbackHandlers#collect_files_for_draft` owned a second compound
  interpretation (`origin == :voice && attachments.empty?`) to choose
  immediate commit versus file collection.
- `Supervisor` independently validated project/text, consumed attachment
  tuples, and branched on origin (`non_voice_draft?`, `ensure_voice_draft`,
  `clear_voice_draft`, `execute_idea_commit`), making execution depend on the
  store's mutable representation.

### Change

`lib/hive/bot/idea_draft_store.rb` now exposes a state-decision API that is
the single authority for these interpretations:

- Routing/callback predicates: `awaiting_transcript_confirmation?`,
  `non_voice_draft?`, `voice_draft?`, `awaiting_text_draft?`,
  `transcript_only_voice_draft?(token:)`.
- Voice reuse/reject/clear transitions moved into the store:
  `ensure_voice_draft(chat_id:, token:)` (reuse voice-origin only, start
  fresh when empty, return nil for an open text/media draft) and
  `clear_voice_draft(chat_id:)`.
- Commit boundary: `commit_blocker(chat_id:)` returns
  `:draft_expired` / `:project_missing` / `:text_missing` / nil, and
  `commit_snapshot(chat_id:)` returns a frozen `CommitSnapshot`
  (project, text, frozen attachment tuples) so `Supervisor#execute_idea_commit`
  and `idea_body_override` never depend on the live mutable Draft.

Router, CallbackHandlers, and Supervisor now delegate all of these decisions;
`Supervisor#ensure_voice_draft` / `#clear_voice_draft` remain as thin
delegators (they are test seams). No behavior change intended; regression
tests cover each predicate, the reuse/reject semantics, commit blockers, and
the frozen snapshot's independence from later live-draft mutations.

Validation: `bin/test --changed` (unit bot suites + integration bot scenarios
including s6 voice idea) all passing.
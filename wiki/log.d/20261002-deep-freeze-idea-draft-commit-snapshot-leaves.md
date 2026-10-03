---
title: Deep-freeze IdeaDraftStore commit_snapshot String leaves
date: 2026-10-02
tags: [bot, idea-draft, encapsulation, patrol, fix]
---

## Deep-freeze IdeaDraftStore commit_snapshot String leaves

Patrol-fix review feedback (generation 1, task
`make-one-internal-idea-draft-aggregate-authorita-b22bf56d54f7`) identified a P2
defect in the commit boundary added by the encapsulation refactor:
`commit_snapshot` froze the `CommitSnapshot` struct, the attachments array, and
each attachment hash, but the String leaves inside them (`project`, `text`,
`staging_path`, `dest_name`, `ext`) were assigned by reference and left
unfrozen. Freeze does not deep-freeze, so the "independent execution view"
still aliased the live mutable Draft: an in-place edit on the live draft
(`draft.text << ...`, `draft.project.replace(...)`, or mutating an attachment
value) rewrote what had already been handed to `Supervisor#execute_idea_commit`.

### Change

`IdeaDraftStore#commit_snapshot` now duplicates and freezes every String leaf
via a private `frozen_string` helper (nil passes through for absent text /
project), so the snapshot is an independently frozen view, not a shallow one.
Regression tests cover in-place live-draft mutation after snapshotting and nil
text/project passthrough.

Validation: `bin/test --changed` (unit bot suites + integration bot scenarios
including s6 voice idea) all passing.

---
title: Validate command contract cells and index prose
date: 2026-09-09
---

The PR sweep found that shared table headings could satisfy missing behavior,
error, serialization, and exit details, and index-section prose escaped the
navigation guard. The guard now checks each command row’s named field and
exempts only navigation table rows. Negative tests cover both cases.

The new-command owner now distinguishes legacy text output from idempotent
`--json` capture and records the shared error-envelope serialization policy.

Current-main integration preserves removal of the circuits command and adds
a sole owner for the newer publication-reconcile command. Its schema-less
observation and local-record-only recovery semantics are documented from the
current command and publication controller.

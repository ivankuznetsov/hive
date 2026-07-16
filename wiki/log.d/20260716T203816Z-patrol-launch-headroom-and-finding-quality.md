---
title: Patrol launch headroom and finding quality
date: 2026-07-16T20:38:16Z
---

- Added conservative initial-context admission to ordinary and architecture
  patrol review/fix launches. Claude reserves 20,000 provider-context tokens
  plus the rendered prompt bytes before a launch can consume the shared
  subscription-backed daily allowance.
- Restricted Claude patrol context to verified role-specific tool sets,
  disabled slash commands, capped reviews at three completed turns, and stopped them
  once an expected structured artifact is written. Completed artifacts still
  pass through the existing schema/evidence validators.
- Preserved the final usage delta and an already-generated `Write` regardless
  of which provider event arrives first. A three-second protocol grace closes
  the race without allowing a fourth reasoning turn.
- Narrowed ordinary mapping to four owned plus four context files. Architecture
  retains six plus six for full-component leverage measurement while its agent
  sees at most four owned files selected with a 32 KiB source budget, retaining
  the first entrypoint when it alone is larger. Both prompts allow one
  bounded evidence follow-up and prefer empty output to speculative findings.
- Live local Hive sampling produced one concrete ordinary-patrol defect:
  `Fingerprint.snippet_at` called `join` on a nil out-of-range slice. The
  reproducer is now a regression test and the helper safely normalizes that
  slice to an empty array. The architecture sample correctly returned no
  thesis when it could not establish a current material consequence.
- Architecture keeps its 2x cycle/per-agent/launch allowance, while ordinary
  and architecture patrols retain one shared per-project daily token ceiling.

---
title: Render Web idea-capture I/O failures as typed errors
type: change
created: 2026-07-31
tags: [web, ideas, errors, storage]
---

- Normalized `SystemCallError` and `IOError` from the in-process
  `Hive::Commands::New#call!` adapter at `Project#add_idea!`, so Web renders a
  readable 422 instead of an opaque 500 when project or attachment I/O fails.
- Redacted filesystem paths from the browser response while preserving the
  original exception class and cause for diagnostics.
- Added a real permission-denied integration regression that proves the
  response is typed, no partial task is created, the absolute project path is
  absent, and the test restores the original directory mode.

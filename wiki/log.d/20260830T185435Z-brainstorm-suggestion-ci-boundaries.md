---
date: 2026-08-30
title: Restore brainstorm suggestion CI boundaries
tags: [brainstorm, suggestions, daemon, wiki, e2e]
---

- Normalize external main-wiki bytes to valid UTF-8 and keep capture-cache
  return values independently mutable before repository selection.
- Keep scheduler inventory and row failures inside the daemon's closed logging
  boundary, with source-scanning tests covering direct logger calls.
- Make the Web golden-path fake author a skip-eligible local plan so the
  hermetic workflow never launches a real plan reviewer.

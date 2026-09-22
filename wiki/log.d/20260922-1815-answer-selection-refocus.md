---
title: Preserve answer selection when a refresh restores focus
date: 2026-09-22
tags: [web, answers, morph, browser-tests]
---

- Restore a draft's selection range before focusing its textarea, so the
  synchronous `focusin` handler cannot replace the saved range with the
  browser's default end-of-text caret.
- Make the existing Q&A browser scenario exercise focus loss during a pushed
  morph even when Turbo preserves the textarea node.
- Keep opaque draft bindings and new-question-round replacement unchanged.

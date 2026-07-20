---
title: Clear submitted web composer before permanent-node rendering
type: fix
date: 2026-07-19
tags: [web, composer, turbo, stimulus, testing]
---

- A successful idea response now clears the permanent composer on
  `turbo:before-fetch-response`, while its Stimulus controller is guaranteed to
  remain connected; `turbo:submit-end` stays as a compatibility fallback.
- This closes a CI-observed race where the idea was captured successfully but
  Turbo moved the permanent form during rendering and the completed text could
  remain duplicate-ready in the browser.
- Playwright coverage dispatches the pre-render success event and pins text,
  chip, upload transport, and retained-project behavior.

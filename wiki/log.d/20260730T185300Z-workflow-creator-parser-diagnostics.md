---
title: Close workflow-creator parser diagnostic and hard-link review gaps
type: fix
created: 2026-07-30
tags: [agent-skills, evidence, security, testing]
---

- Replaced producer-controlled JSON parser diagnostics with fixed,
  entry-specific proof errors so malformed evidence cannot echo secret bytes.
- Added Attestor and Verifier regressions proving malformed primary and
  supporting evidence never exposes the submitted bytes.
- Pinned the retained-bundle hard-link admission guard alongside existing
  symlink and per-file size rejection tests.
- Kept execution custody and authenticated provider orchestration open in
  [[gaps]]; these review fixes only close U1 admission behavior.

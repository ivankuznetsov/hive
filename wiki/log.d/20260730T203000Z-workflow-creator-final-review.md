---
title: Close workflow-creator final-review encoding and aggregate-bound gaps
type: fix
created: 2026-07-30
tags: [agent-skills, evidence, security, testing]
---

- Normalized invalid-UTF-8 JSON canonicalization failures into the
  workflow-creator proof error surface for primary and supporting evidence.
- Added Attestor and Verifier regressions for malformed producer bytes.
- Exercised the aggregate retained-bundle byte cap with four individually
  admitted files whose combined canonical bytes exceed the contract limit.
- Kept execution custody and authenticated provider orchestration open in
  [[gaps]]; these final-review fixes only close U1 admission and coverage.

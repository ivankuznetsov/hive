---
title: Stabilize the web golden-path PR gate
type: fix
module: web
created: 2026-08-05
tags: [web, e2e, daemon, ci, open-pr]
---

The browser golden-path E2E now proves that the task reached the durable
`5-open-pr` stage instead of waiting for the transient "Ready to open PR"
action label. An enrolled daemon may replace that label immediately when it
dispatches the open-PR stage, while the stage identity and the test's real
implementation commit remain durable evidence that execute completed.

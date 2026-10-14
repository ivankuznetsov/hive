---
title: Close project workflow review gaps
type: change
source: lib/hive/commands/status.rb, lib/hive/task_workspace/builder.rb, lib/hive/workflows/project.rb, script/measure_project_workflow_view.rb, web/test/system/kanban_board_test.rb
created: 2026-10-14
---

- Cold descriptor and managed-package preparation now completes before the
  process-wide Project Monitor is acquired. A deterministic contention test
  proves another project remains usable while managed selection waits.
- Unavailable managed-workflow tasks remain reachable in Hive Web. Their
  semantic artifact view keeps the existing document/change wire vocabulary,
  renders a descriptor-unavailable warning, and exposes no workflow mutation,
  daemon-blocker, closure, or stage-send-back controls. The Playwright system
  regression retains board and expanded task-detail screenshots.
- Active-only Status projections scan orphan stages only for genuinely
  unresolved workflow selectors or an unavailable fieldless default, so
  accepted workflows' terminal rows remain outside the active Web projection.
- A revision-selectable measurement harness compares production Status,
  StatusFeed, activation I/O, and unrelated-project Monitor wait under the same
  generated workload. The five-by-ten Ruby 3.4.10 comparison against
  `fa96ebf16b8f` found no back-out-triggering regression; Status and StatusFeed
  p50 improved, and an unrelated project completed during all 50 candidate
  activation stalls versus none of 50 at baseline.

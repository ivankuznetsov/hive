---
title: Multiple-dependency outcome rework
date: 2026-10-14
---

- Added a real remote/default-branch lifecycle fixture proving that list task
  worktrees contain both prerequisite commits after they land while a stale
  local default branch stays untouched.
- Added a real browser task-detail regression for scheduling-only fan-in with
  one clear edge and one blocking edge.
- Clarified that one-shot dependency wake conditions carry a compact array of
  dependency-name strings, while structured stage and required-gate records
  remain on operational status.
- Strengthened private-reader coverage so otherwise-current payloads in retired
  v1 operational snapshot or status-cache records are rejected and rebuilt.
- Added real `bin/hive` creation/replay/rejection coverage and an integration
  fixture that refreshes ordered JSON, text, and TUI blockers as individual
  prerequisites reach `9-done`.

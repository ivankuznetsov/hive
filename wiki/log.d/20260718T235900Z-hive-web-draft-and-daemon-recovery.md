---
title: Prevent duplicate ideas and unblock stopped-daemon tasks in Hive Web
created: 2026-07-18T23:59:00Z
tags: [web, composer, daemon, tasks, browser]
---

- Kept the idea composer permanent for unsent work, but now clear completed
  text, attachment chips, preview URLs, and the upload transport after a
  successful Turbo submission. The project selection remains as intentional
  working context, and controller reconnects rebuild staged attachment state.
- Added stopped-daemon recovery guidance to daemon-enabled task pages without
  bypassing Hive's single-dispatcher queue boundary or presenting a Run button
  that cannot be consumed.
- Made the status daemon strip distinguish a healthy stopped installation
  (`hive daemon start --detach`) from missing/drifted service repair
  (`hive daemon install --force`).
- Covered the behavior with Rails integration tests and a real Playwright
  composer submission that verifies text, chips, and the file transport reset
  while the selected project survives.

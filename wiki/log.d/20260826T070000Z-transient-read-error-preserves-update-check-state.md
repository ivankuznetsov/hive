---
date: 2026-08-26
title: Transient read errors no longer reset update_check shared state
tags: [update, state, patrol, durability]
---

- `Hive::UpdateCheck::State#load!` previously funneled both `File.read`
  I/O errors and JSON parse errors into `handle_corrupt!`, which resets
  `@data` to empty. A transient read failure (e.g. `Errno::EIO`) during a
  locked read-modify-write therefore persisted emptied state over an intact
  file, permanently erasing `last_notified_version` and `nudge` and causing
  duplicate release notifications.
- Read errors are now handled separately (`handle_read_error!`, event
  `:update_check_state_read_error`): the last-known in-memory state is kept
  and writes are suspended until the next successful load clears the flag,
  so that tick's mutation is dropped instead of clobbering shared state.
  Genuinely corrupt JSON still degrades to empty as before.

# Archive visibility web rebase hardening

- Restacked archive visibility retention on the current resilient web status
  feed and retained its fresh, degraded, and unavailable publication contract.
- The bounded `StateSource` adapter now raises an ordinary refresh failure to
  `StatusFeed` even when a TUI-style latest-good payload exists, preventing
  stale rows from being republished as fresh.
- Active task folders now participate in the bounded mtime fingerprint, so
  artifact creation/removal changes the web semantic token immediately and a
  reconnect can catch up without waiting for the liveness fallback.
- The daemon recovery-receipt overlay is now copy-on-write, preserving frozen
  archived cache rows while still exposing current recovery state.
- Archive task route coverage now uses a real expired terminal task, the
  non-scanning current-page snapshot seam, and the typed unavailable-diff
  response used by current main.
- Archive-linked task routes now use current main's exact project/stage resolver
  with retention filtering disabled instead of invoking the lossless fleet
  archive producer for the shell and every child request. Archived terminal
  logs also no longer run the live three-second poll.
- Refreshed the existing task-media Brakeman false-positive fingerprint after
  the controller dataflow moved to targeted archive resolution; the realpath,
  basename, extension, and symlink guards are unchanged.
- Closed the exact coverage-gate gaps with failure-path tests for cursor I/O,
  history deadlines, terminal rollback, invalid hidden counts, workflow
  generation faults, and both complete and visible archive caches. The
  resulting merged gate covers 61,074 of 61,074 executable lines.

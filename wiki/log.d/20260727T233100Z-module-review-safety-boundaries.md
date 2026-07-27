# Close module execution and migration evidence safety gaps

- Native module workflow targets again fail closed after validation and
  snapshotting until task metadata, admission, recovery, and permission
  intersection can remain pinned to the installed module generation.
- Patrol schedule adapters no longer manufacture legacy captures from their
  own decisions. Only an independent occurrence capture can contribute to the
  migration cutover window; the existing merged-PR reconciler supplies that
  evidence for Architecture Patrol.
- Module command output is drained concurrently into bounded memory, including
  stdout and stderr, and secret prefixes at the truncation boundary are
  redacted. Filesystem grants now reject symlinks that resolve outside the
  project.

**Pages:** [[modules/workflows]], [[modules/patrol]]

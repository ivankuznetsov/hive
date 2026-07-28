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
  redacted. Filesystem grants reject symlinks that resolve outside the project,
  and bubblewrap is never resolved through a project-relative `PATH` entry.
- The four module acceptance scenarios are registered as required semantic E2E
  coverage so current release-profile preflight can select and run them.
- Attempt v3 is the sole runtime record shape. The one-off recovery migration
  rewrites retained v1/v2 task attempts with explicit subjects, replaces the
  prior migration receipt, and removes the v2 schema and in-memory bridges.
- Catalog materialization rejects symlink destinations, validates safe,
  collision-free paths and a complete manifest inventory, then creates the
  destination tree.
- Module dry-run receives its read-only Attempts store from the command
  composition root, and both dry-run and inspection sites are pinned in the
  component boundary catalog rather than becoming alternate admission paths.
- If attempt admission wins before decision persistence, replay keeps terminal
  or lost runs eligible for the daemon's normal finalization/retry pass instead
  of misclassifying successful work as failed.
- Capacity- or handoff-deferred module retries wait one hour before another
  admission attempt instead of spinning on every daemon tick; status retains
  the bounded pending reason and intended retry charge.
- Module manifests and the daemon share one bounded UTC cron parser, so every
  comma branch, range, step, and field domain is rejected before installation
  instead of failing later in scheduling or status.

**Pages:** [[modules/workflows]], [[modules/patrol]], [[modules/attempts]], [[commands/migrate]], [[e2e]]

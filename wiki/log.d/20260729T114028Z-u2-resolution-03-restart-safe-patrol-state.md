---
title: Restart-safe Patrol selection and occurrence state
type: change
created: 2026-07-29
tags: [patrol, architecture-patrol, migration, recovery, storage]
---

- Separated immutable selection from terminal outcome. Ordinary and
  Architecture Patrol keep distinct strict input projectors and produce one
  shared `PatrolDecisionProjection`; coercion revalidates even an existing
  in-memory value, provisional captures cannot contain outcome/effect evidence,
  and final captures must retain the exact selection.
- Added one bounded coordination cell to each existing occurrence journal.
  Scheduled, module-event, and architecture-job identities compact through
  canonical window/generation high-water and closed-through fences.
  Non-sequenced manual/direct captures use a bounded exact fence and retain
  terminal proof rather than replaying when it is full.
- Persisted normalized recovery failure generations and 60/300/900-second
  backoff in that cell. It owns no effects, outbox, or product work, and the
  occurrence journal remains the sole recovery inventory.
- Streamed the initial bounded occurrence snapshot under the fixed lock order
  identity → journal state → inventory → occurrence record.
- Moved managed storage to descriptor-relative no-follow operations for reads,
  traversal, locks, and atomic replacement. Declared Fiddle as a direct runtime
  dependency because Ruby 4 no longer guarantees it as a default gem.
- Strengthened one-off shadow-v1 conversion so its checkpoint binds source,
  archive, and live-v2 replacement digests, restart adoption verifies all
  three, and completion re-inventories the live tree. Native v2 remains strict;
  migrated v1 evidence is archived and non-comparable.
- Replaced obsolete global `File.open`/`File.lstat` monkeypatch tests with
  public oversized, malformed, symlink, missing-directory, descriptor-race,
  and migration-restart proofs. U3 compressed qualification remains open.
- Reconstructed the discovery transition coordinator in daemon-launched
  `--job-manifest` children before incremental feature checkpoints. The child
  does not mint a second claim: it uses only the exact scheduler-attached
  PID/start-time and generation token.
- Removed unused ActionRunner registry helpers and the comparator's impossible
  array-difference arm. Platform flag selection is now a small explicit
  Linux/macOS mapping so both supported contracts can be proven on one host.

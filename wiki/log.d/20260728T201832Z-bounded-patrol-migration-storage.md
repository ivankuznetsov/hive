---
title: Bounded patrol migration storage
type: change
date: 2026-07-28
---

**Changed:** Replaced filesystem-cookie receipt repair and eager shadow-history
materialization with a shared bounded lexicographic inventory. Cursors bind the
store, count, filename fingerprint, high-water name, and last processed name,
so restart order is portable and in-snapshot mutations fail closed.

**Safety:** Added `Hive::ManagedDirectory` for component-wise symlink refusal,
no-follow inode-verified locks and reads, and verified-parent atomic writes.
EvidenceStore, shadow comparison/reporting, and the one-off v1 migration now
use it. Existing archive collisions are read with the same no-follow byte cap;
links, special files, and oversized archives are rejected.

**Proof:** Focused unit coverage includes cursor restart/store binding,
high-water append behavior, early excess rejection before record reads,
streaming report consumption, linked directory/file/lock refusal, and
symlinked v1 archive rejection. The module migration integration path consumes
the new streaming API.

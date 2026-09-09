---
date: 2026-08-30
tags: [conditions, projection, attempts, recovery, bounded-storage]
pages: [commands/status, commands/repair-projection, modules/conditions, testing]
---

# Keep terminal checkpoint history outside the mutable attempt budget

Routine projection reads now charge the 100-attempt cap only to mutable
checkpoint bindings and attempt IDs introduced by the bounded journal suffix.
Terminal bindings are immutable, already covered by the 512 KiB checkpoint cap,
and require no attempt-store read, so long recovered task histories no longer
make the next ordinary stage launch demand impossible projection compaction.

Focused tests retain the fail-closed cap for 101 mutable bindings and prove
that 101 terminal bindings remain current without any attempt-store reads.

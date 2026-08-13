---
date: 2026-08-13
slug: unused-runtime-readiness-reader
pages: [modules/daemon]
---

Removed the orphaned `OperationalSnapshot::Reader#runtime_readiness` API and
its reader-only tests. The writer still publishes the generation-bound runtime
readiness flag used by daemon startup; the former maintenance consumer was
retired. Updated [[modules/daemon]] to distinguish that live publisher
invariant from the remaining ordinary reader contract.

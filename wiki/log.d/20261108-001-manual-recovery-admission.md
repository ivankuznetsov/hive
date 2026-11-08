---
title: Guarded existing-request recovery admission
date: 2026-11-08
---

Added project/task-scoped bounded recovery evidence and a manual recovery seam.
Existing-request observations bind the durable revision and post-clear task
identity. The coordinator expedites cleared operator retries and rejects stale
observations before repair. Focused coordinator/API tests cover replay without
a second retry charge, changed progress and scoped reads.

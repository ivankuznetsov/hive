---
date: 2026-06-23
slug: init-workflow-authoring-hints
pages: [commands/init]
---

Added the `hive init` discovery surface for project-authored workflows.
Fresh coding-default projects with no descriptors now show a single human
summary tip for `hive workflow new <id>`, while `hive init --json` emits a
required `hints` array containing the same pointer. Non-coding defaults or
projects that already have descriptors suppress the tip and emit `hints: []`.

Updated [[commands/init]] with the new `hive-init.v1` payload key and the
focused integration/schema coverage that keeps the producer and schema in
lockstep.

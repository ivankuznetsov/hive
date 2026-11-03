---
date: 2026-11-03
title: Preserve immutable task execution plans and accepted evidence
---

Added strict optional task capability adoption metadata, immutable canonical
execution-plan versions, content-addressed accepted result/approval storage and
fixed controller-owned pointer/acceptance-chain anchors. Enabled lower-level
coding capture writes initial Automatic selections atomically; the adoption
default stays disabled. Reads never adopt old tasks and fail closed on corrupt,
missing, altered or unaccepted references. Managed updates reject incompatible
active capability bindings before repinning and retain historical package assets.

Focused storage, capture, metadata, migration and custody checks cover crash
recovery, identity races, same-path replacement, forged blobs, approval digest
references and legacy behavior. See [[modules/task_capabilities]],
[[modules/workflow_package]] and [[modules/protected_files]].

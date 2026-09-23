---
date: 2026-09-23
title: Skip unused task audit work and unrelated project policy reads
---

Task HTML builds bounded page evidence and the semantic result without
capturing hidden repository/wiki provenance or assembling a hidden timeline.
Artifacts are materialized only for the semantic result. Existing normalization,
question bindings, action readiness, and explicit audit reads are preserved.

Targeted dependency contexts retain the complete enrollment index while loading
admission policy once per selected or reachable project within that context.
Relevant config failures and cross-project identity checks still fail closed.

An automatic admission rejected as `StaleTaskSource` defers its task until a
fresh observation, continues other rows, and discards any cached automatic
approval without advancing the dispatch baseline or consuming capacity.

The existing daemon status cache remains unsuitable as a prompt Web display
feed; measured publication age and missing incremental observations are
recorded in [[gaps]]. See [[modules/task_workspace]],
[[modules/task_dependencies]], and [[modules/daemon]].

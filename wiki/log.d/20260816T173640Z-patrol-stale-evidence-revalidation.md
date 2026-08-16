---
title: Patrol revalidates evidence roles across moving default branches
module: patrol
---

Patrol fix attempts no longer discard a finding merely because surrounding source text changed or one redundant evidence anchor was replaced while the default branch advanced. Hive now rebinds exact snippets on the fresh base and proceeds only when every original evidence role still has an unambiguous current anchor; otherwise it retains the fail-closed `stale_evidence` outcome.

---
title: Hive prepares the PRDigest v0.2 dependency
type: log
tags: [digest, prdigest, dependency, release]
---

# Hive prepares the PRDigest v0.2 dependency

Hive's runtime dependency, installed-gem executable fallback, root lockfile,
managed-web lockfile, tests, and operator wiki now target `prdigest ~> 0.2.0`.

PRDigest v0.2.0 adds facts and optional prose modes without changing Hive's
deterministic `prdigest run` invocation, `prdigest-result` v1 pass-through, or
exit-code contract. Hive does not invoke the new presentation modes.

This change is prepared against the local exact v0.2.0 package. It must remain
local until that gem is published because a remote Hive bundle cannot resolve
an unpublished dependency. No Hive release metadata, tag, publication, merge,
or deployment is part of this preparation.

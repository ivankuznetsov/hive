---
date: 2026-08-02
title: Artifact capture selects compatible or project-owned recorders
tags: [web, capture, artifacts, config, security]
---

- Capture selects the built-in Hivebox recorder only for a complete compatible
  source layout; conventional projects can declare a validated
  `artifacts.capture.provider` executable.
- Project providers receive an exact JSON request in a deny-default subprocess.
  Linux child-subreaper custody covers detached descendants, output drains, and
  abnormal supervisor death from a parent-owned PID/start-time and exit-status
  boundary. Hive revalidates the complete working-tree snapshot, including
  ignored paths, after every attempted execution and preserves combined
  provider/custody failures. Snapshot hashing has explicit 1 GiB cumulative and
  30-second monotonic bounds.
- Fiddle is now an explicit runtime dependency for the Linux `prctl` custody
  call instead of relying on its pre-Ruby-3.5 default-gem status.
- Hive accepts artifacts only from private staging, then bounds evidence and
  argv, decodes the declared image/video content, independently hashes it, and
  publishes a sub-240-KiB manifest last. Content-addressed provider names make
  changed- and identical-byte recapture deterministic and recoverable.
- The tracked executable remains ordinary local project tooling, not an OS
  filesystem sandbox.
- Added provider-neutral `hive-artifact-capture` v2 manifests while retaining
  explicit policy and Hive Web read compatibility for v1 evidence. Non-object
  receipts and recorder envelopes fail closed and can be replaced on recapture.
- Unsupported projects now receive an actionable provider declaration message
  instead of a misleading missing Hivebox dependency error.

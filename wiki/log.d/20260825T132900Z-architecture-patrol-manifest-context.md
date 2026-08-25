# Architecture Patrol manifest source context

- Centralized the authoritative PR source projection in
  `Hive::RefactorPatrol::PrManifest.source_context`.
- Scheduled schema-v3 Architecture Patrol jobs now preserve `lane`,
  `classification`, and `provenance` when validating a published manifest
  against its durable job. Previously the command dropped those fields and
  rejected every scheduled v3 discovery with exit 78.
- Public `source_pr` envelopes retain the compact source reference; frozen v3
  provenance is used only for the authoritative manifest/job comparison so
  successful partial discovery reports continue to satisfy schema v4.
- Added regression coverage for the daemon's scheduled job-manifest path.

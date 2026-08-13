## Bound stale patrol work and expose patrol health

- Kept GitHub JSON stdout machine-readable when `gh` is managed by mise.
- Retired Architecture Patrol jobs once when their source merge is no longer on
  fetched trunk, while preserving remote continuation evidence and transient
  checkout retries.
- Added one bounded finding projection shared by `hive patrol --list` and the
  read-only Hive Web Patrol page; Architecture health reads newest durable jobs,
  and browser errors no longer expose internal exception details.
- Registered the summary-only `hive-patrol-findings.v1` query contract and
  capped its managed projection at 25 rows and 256 KiB.
- Added the Patrol health route to canonical Hive skill `0.1.5` and regenerated
  the complete OpenClaw projection; this metadata bump does not publish it.

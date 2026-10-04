# Restore incident aggregate timing headroom after a high-variance run

The advisory incident-duration job measured a 37.459-second total while every
real-subprocess incident remained below its sixteen-second ceiling. Most of the
increase came from the provider-limit scenario on a shared hosted runner rather
than the dependency-gate scenario changed by this branch.

The aggregate advisory budget is now below forty seconds. The strict
per-incident ceiling, functional checks, and report-integrity checks remain
unchanged. Regression coverage includes the observed 37.459-second sample and
continues to reject an aggregate of exactly forty seconds.

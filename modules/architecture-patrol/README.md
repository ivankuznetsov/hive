# Architecture Patrol module

The reviewed first-party Architecture Patrol module consumes immutable merged
pull-request manifests from Hive's existing merge reconciler. It does not add
another GitHub poller. Scheduled discovery, merged-PR discovery, and action
continuations execute through the existing generation-fenced job lifecycle.

Authoritative runtime state remains under `.hive-state/refactor_patrol/`, with
terminal action proofs under the configured Hive home. Installations begin in
shadow mode and may become mutators only through the durable migration cutover.
The `hive refactor-patrol` command and `refactor_patrol.*` settings remain
compatible throughout Hive 0.x.

The merged-PR manifest remains immutable enqueue provenance. A distinct
finalized scheduler capture is emitted only after the authoritative JobStore
checkpoint or release, and branch, issue, pull-request, and review-handoff
mutations pass through the Architecture Patrol gateway while its live claim
and migration ownership are valid. Evidence never replaces JobStore recovery.

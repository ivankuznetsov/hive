# Architecture Patrol module

The reviewed first-party Architecture Patrol module has two independent
discovery sources. Scheduled discovery re-pins current `main`, maps the current
architecture feature IDs, and claims exactly one stable feature slice per
provider launch. Merged-PR discovery still consumes immutable manifests from
Hive's merge reconciler and does not add another GitHub poller.

Scheduled launches use Architecture Patrol's own mode-derived daily allowance;
merged-PR discovery and action continuations are not charged to that allowance.
The scheduled producer retains a durable feature cursor and result inventory so
accepted dispositions can enter the unified fix-admission outbox before the
cursor advances. Its coverage-pass generation keeps later same-SHA sweeps
distinct without changing the stable identity used by crash replay.

Authoritative runtime state remains under `.hive-state/refactor_patrol/`, with
terminal action proofs under the configured Hive home. Installations begin in
shadow mode and may become mutators only through the durable migration cutover.
The `hive refactor-patrol` command and `refactor_patrol.*` settings remain
compatible throughout Hive 0.x.

The merged-PR manifest remains immutable enqueue provenance. A distinct
finalized scheduler capture is emitted only after the authoritative JobStore
checkpoint or release. New findings enter the common Patrol-fix workflow,
which may publish pull requests after validation and review. Architecture
Patrol no longer creates GitHub issues; historical issue links remain readable
as provenance during migration. Scheduled current-main results and merged-PR
JobStore recovery remain separate durable authorities.

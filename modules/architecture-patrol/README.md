# Architecture Patrol module

The reviewed first-party Architecture Patrol module has two independent
discovery sources. Scheduled discovery re-pins current `main`, maps the current
architecture feature IDs, and claims exactly one stable feature slice per
provider launch. Merged-PR discovery still consumes immutable manifests from
Hive's merge reconciler and does not add another GitHub poller.

Scheduled launches use Architecture Patrol's own mode-derived daily allowance;
merged-PR discovery is not charged to that allowance.
The scheduled producer retains a durable feature cursor and result inventory so
accepted dispositions can enter the unified fix-admission outbox before the
cursor advances. Its coverage-pass generation keeps later same-SHA sweeps
distinct without changing the stable identity used by crash replay.

Authoritative discovery state remains under `.hive-state/refactor_patrol/`.
Installations begin in shadow mode and may become mutators through the module
ownership switch.

The merged-PR manifest remains immutable enqueue provenance. A distinct
finalized scheduler capture is emitted only after the authoritative JobStore
checkpoint or release. New findings enter the common Patrol-fix workflow,
which publishes pull requests after validation and review. Architecture Patrol
does not fix code, create issues, push branches, or open pull requests itself.
Scheduled current-main results and merged-PR discovery remain separate durable
authorities.

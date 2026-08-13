---
title: Migrate retained tasks instead of dispatching historical workflows
date: 2026-08-13
---

Hive updates now use the newly installed binary to migrate global state and
every registered project, including retained Honeycomb tasks whose package or
configuration pin differs from the selected workflow. Semantic stage names
map those tasks into the selected descriptor, pending recovery requests are
invalidated, and unreferenced generations are cleaned after migration.

Workflow activation and retained-task mutation now share one state commit.
Candidate destinations and task locks are reserved before the pointer changes;
any apply or commit failure restores both the old pins/folders and the prior
selection. State-file renames preserve the existing stage artifact, and bound
dispatch requests that race the cutover are rejected at consume time. Fleet
migration restarts the daemon only after every registered project succeeds.
A producer that resolves during the task-folder move still writes a durable,
stage-bound request without claiming a task id; the daemon rejects that
incomplete binding instead of silently dropping the requested action.

Managed runtime dispatch now accepts only the selected generation. A stale pin
fails with an explicit `hive migrate` instruction, workflow removal is blocked
while retained tasks exist, and direct `install.sh` upgrades run fleet
migration before daemon setup. This deliberately replaces historical workflow
dispatch with one idempotent forward migration boundary.
When the current installer is deliberately used to install a release that
predates fleet migration, it detects the missing `migrate --all` capability
and skips this new phase; releases containing the capability fail closed if
any registered project cannot migrate.

Focused coverage exercises semantic stage and artifact moves, same-position
repins, removed-stage and live-lock refusal, mid-batch rollback, queue cleanup
and request identity fencing, current-only task loading, workflow lifecycle
migration, direct-installer ordering, and fleet restart gating.

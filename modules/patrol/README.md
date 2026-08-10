# Patrol module

The reviewed first-party Patrol module routes scheduled and `task.completed`
occurrences into Hive's existing ordinary Patrol engine. The authoritative
runtime state remains under `.hive-state/patrol/`; executable generation
rollback never rewinds findings, fingerprints, dismissals, budgets, patches,
or review handoffs.

Installations begin in shadow mode for migration proof. Disable shadow mode
only through the durable migration ownership cutover. The legacy `hive patrol`
command and `patrol.*` project settings remain compatible throughout Hive 0.x.

Every legacy scheduler occurrence now carries an immutable capture into the
module comparison path. State, finding, fix-attempt, branch, pull-request, and
review-handoff mutations pass through the ordinary Patrol effect gateway,
which rechecks the current ownership epoch and installed capability at the
sink. Shadow execution records attempted effects but cannot mutate.

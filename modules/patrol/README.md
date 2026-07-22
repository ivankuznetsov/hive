# Patrol module

The reviewed first-party Patrol module routes scheduled and `task.completed`
occurrences into Hive's existing ordinary Patrol engine. The authoritative
runtime state remains under `.hive-state/patrol/`; executable generation
rollback never rewinds findings, fingerprints, dismissals, budgets, patches,
or review handoffs.

Installations begin in shadow mode for migration proof. Disable shadow mode
only through the durable migration ownership cutover. The legacy `hive patrol`
command and `patrol.*` project settings remain compatible throughout Hive 0.x.


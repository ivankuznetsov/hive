# Patrol module

The reviewed first-party Patrol module routes scheduled and `task.completed`
occurrences into Hive's existing ordinary Patrol engine. The authoritative
runtime state remains under `.hive-state/patrol/`.

Installations begin in shadow mode. Disable shadow mode through the module
ownership switch.

Every accepted finding is persisted once and published directly to the shared
Patrol Fix admission outbox. Ordinary Patrol does not edit code, select fixes,
push branches, open pull requests, or create review tasks. Shadow execution
records the discovery decision but cannot mutate.

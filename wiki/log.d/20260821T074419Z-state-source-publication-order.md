# TUI snapshots publish after change fingerprints

`Hive::Tui::StateSource` now installs the mtime and policy fingerprints for a
refresh before exposing its lock-free `current` snapshot pointer. This closes a
race where a reader could observe the snapshot, mutate a watched file, and have
the still-running publication path absorb that mutation into the new baseline.

Focused tests pin both the publication barrier and the 1.5-second state-file
change latency contract.

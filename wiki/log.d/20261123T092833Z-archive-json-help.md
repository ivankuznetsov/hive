# `hive archive` help: a target without `--reason` acts at once

- `hive help archive` said "--json alone is a read-only preview and archives
  nothing", but that holds only for `--reason` closures.
- For a completed finalize task, `hive archive TARGET --json` moves the task
  into done and runs its done stage at once. An operator who read the help as
  "preview first" archived two finished tasks, and cut off the CLI while the
  done stage ran. The durable attempts finished the stage anyway.
- The help and [[cli]] now say that a target without `--reason` acts at once,
  with no preview or prompt, and that the read-only `--json` preview applies
  to `--reason` closures. Behavior is unchanged.

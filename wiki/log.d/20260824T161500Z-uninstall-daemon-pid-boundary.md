## Uninstall reads the daemon PID through the lifecycle boundary

- `hive uninstall` no longer parses `.daemon.pid` with a local bare-integer
  read (`File.read.strip.to_i`). That parser predates the daemon lifecycle
  owner's YAML process-identity payload (`{pid:, process_start_time:,
  started_at:}`) and silently evaluated the whole document as PID 0, skipping
  the foreground-daemon TERM during purge.
- Added `Hive::PidFile.read_pid(path)` as the stateless positive-Integer
  reader over any hive-owned PID file: it accepts both the owner payload and
  legacy bare-integer docs, and returns nil for missing, unreadable, corrupt,
  or non-positive payloads. `Uninstall#stop_foreground_daemon` now goes
  through it instead of re-implementing the on-disk format.
- Regression tests model the payload the owner actually writes in
  `test/unit/commands/uninstall_test.rb`, plus corrupt/non-positive coverage
  in `test/unit/pid_file_test.rb`.

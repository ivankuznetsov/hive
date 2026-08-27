## Uninstall shutdown honours daemon pid identity (rework of the lifecycle-boundary fix)

- Review rework: the first fix exposed `Hive::PidFile.read_pid` (numeric
  positive-Integer reader), but `Uninstall#stop_foreground_daemon` signalled
  that PID directly, discarding the `process_start_time` identity the daemon
  owner writes and verifies. A stale `.daemon.pid` whose numeric PID had been
  reused could make uninstall TERM an unrelated process.
- Replaced the identity-blind reader with an ownership-aware shutdown
  boundary, `Hive::PidFile.stop(path)`: it parses via the new shared
  `Hive::PidFile.parse_payload`, gates on liveness (`PidFile.alive?`), then
  applies the same tri-state ownership policy as `hive daemon stop`
  (`:verified`/`:legacy` signal; `:reused`/`:unverified` refused). It returns
  `{ status:, pid: }` so callers can warn instead of signalling blindly.
- The instance-level `pid_ownership` policy now delegates to a module-level
  `Hive::PidFile.ownership`, and `read_pid_file_payload` delegates to
  `parse_payload`, keeping the on-disk format and the reuse defense in single
  places. `Uninstall` never signals a locally parsed number; it warns on
  refused identities and no-ops otherwise.
- Regression tests cover reused (start-time mismatch) and unverified
  (no provable identity) payloads at both the PidFile boundary
  (`test/unit/pid_file_test.rb`) and the uninstall command level
  (`test/unit/commands/uninstall_test.rb`), alongside verified-payload,
  legacy bare-integer, stale, and malformed coverage.

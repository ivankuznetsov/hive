## [2026-07-13T02:10:26Z] testing - hive-eval surfaces report cleanup failures

**Action:** Fixed Hive patrol finding `command-bin-hive-6`. `bin/hive-eval` now removes a selected report with `File.unlink`, tolerating only `Errno::ENOENT`; permission and other unlink failures abort before a usage result or Rake launch can leave stale JSON looking current. Added wrapper coverage with a stale report in a non-writable directory and a fake Bundle marker that proves Rake is not launched.

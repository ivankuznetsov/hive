## [2026-07-09T16:27:05Z] e2e - preserve rotated TUI marker artifacts

**Action:** `ArtifactCapture` now copies the run-scoped `hive-tui-subprocess.log.1` rotation alongside the current shared TUI marker log when a TUI scenario fails, so marker history is not lost before the live log directory is removed.

**Coverage:** Extended `test/e2e/lib/artifact_capture_test.rb` to seed both `hive-tui-subprocess.log` and `hive-tui-subprocess.log.1` and assert both are copied into `tui-subprocess/` and listed in `manifest.json`. Updated [[e2e]]; did not edit compiled [[log]].

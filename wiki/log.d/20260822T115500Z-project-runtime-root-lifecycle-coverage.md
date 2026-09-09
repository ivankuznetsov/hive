# Managed project runtime root proves its teardown guards

**Problem:** `CaptureToolkit#prepare_project_runtime_root` and
`#remove_project_runtime_root` were reachable only from a full Pi producer run,
so the create/chmod pair, the ownership re-check, and the already-removed
rescue were uncovered against the exact-100% line gate.

**Change:** `capture_toolkit_coverage_gaps_test.rb` drives both private
lifecycle seams directly: a round trip that asserts the 0700 mode and the
cleared ivar, a substituted symlink root that must raise rather than delete
through the link, and a vanished root that teardown tolerates.

**Verification:** Ruby's `Coverage` reports lines 522-536 of
`lib/hive/artifacts/capture_toolkit.rb` covered from that test file alone.

See [[artifacts]].

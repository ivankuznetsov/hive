---
date: 2026-06-16
slug: clipboard-capture-coverage-fixture
pages: [testing]
---

Stabilized `Hive::Tui::Clipboard::DefaultShim.capture3` coverage after the
hosted Ruby 3.4.9 CI job showed
`HiveTuiClipboardTest#test_default_shim_capture3_success_and_timeout_paths`
timing out before the success-path child wrote stdout. The production shim did
not change. The test now uses temporary executable shell fixtures for the
generic stdout/stderr and timeout paths instead of spawning `RbConfig.ruby`,
because coverage prepends `RUBYOPT=-Itest -rhive_coverage_boot` and nested Ruby
startup latency can leak into unrelated timeout assertions.

Updated [[testing]] with the fixture guideline. No page-list update was needed.

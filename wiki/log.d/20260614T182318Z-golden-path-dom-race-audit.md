---
date: 2026-06-14
slug: golden-path-dom-race-audit
pages: [commands/status, modules/daemon, testing, gaps]
---

Audited commit `798beb74` (`test(web): avoid stale golden-path grid element`)
after it touched `web/test/e2e/golden_path_e2e.rb`, [[testing]], and a wiki log
fragment, then refreshed the audit after the next CI run exposed an adjacent
mtime-baseline race in the same golden-path E2E. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent
compiled [[log]] entries first. `qmd search "golden path DOM race stale grid
element web e2e"` surfaced prior golden-path/Turbo context but no conflicting
page.

Verified the committed diff plus current `web/test/e2e/golden_path_e2e.rb`,
the status-grid row markup in `web/app/views/status/_projects.html.erb`,
`Hive::Daemon::Policy`, `Hive::Daemon::Dispatcher`, [[commands/status]],
[[commands/web]], [[modules/daemon]], [[state-model]], and [[e2e]]. Updated the
duplicate Hivebox golden-path section in [[testing]] so it records both the
current-DOM slug lookup convention and the mtime guard before writing the
brainstorm answer. The second pass found the production precision bug behind
the repeated `needs_input` stall: `hive status --json` truncated subsecond
`File.mtime` values while daemon dispatch baselines kept microseconds. Updated
[[commands/status]], [[modules/daemon]], [[testing]], and [[gaps]] accordingly.
Page coverage did not change, so [[index]] did not need a catalog update. Did
not run `qmd update` or `qmd embed`.

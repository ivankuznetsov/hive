---
title: Make Doctor's supplied QMD environment authoritative
type: change
created: 2026-11-02
tags: [doctor, qmd, environment, testing]
---

- QMD discovery reads `HIVE_QMD_BIN`, `PATH`, `HOME`, and `XDG_DATA_HOME`
  from Doctor's supplied environment. Missing or empty roots omit managed
  candidates instead of consulting the host or creating relative paths.
- Preserved override/PATH/data-home/HOME/sidecar precedence, executable-only
  override eligibility, regular-file managed candidates, and stripped
  first-line-only install-prefix parsing.
- The version subprocess receives the supplied environment with inherited
  variables disabled. The 15-second deadline, diagnostic selection, optional
  warnings, human output, v2 JSON, and default `environment: ENV` remain intact.
- Converted QMD and auth boundary tests to injected hashes and scratch-home
  Ruby children. Child launches inherit Ruby/Bundler and coverage settings,
  disable MCP discovery, inject an empty inspector, and assert unchanged ENV
  across successful, missing, failed, unlaunchable, and timed-out probes.
- Documented the narrow contract in [[commands/doctor]], including required
  executable dependencies and the remaining host-driven default MCP discovery
  and runtime-state checks. The production CLI still uses default ENV.
- Verification: Doctor tests passed (47 tests, 516 assertions); adjacent managed
  skills, web aliases, and config validation passed (8 tests, 48 assertions).
  `bin/test --changed` passed (290 tests, 2,139 assertions), as did
  `bundle exec rake coverage:changed` with exact line coverage for Doctor.
  RuboCop passed for both changed Ruby files. Discovery and probe regressions
  were observed failing before their respective fixes.
- Broad checkpoint: `bin/test --all` completed with 15,924 tests and 305,476
  assertions, but was not green (3 failures, 23 errors, 14 skips). Available
  diagnostics show `Errno::ESRCH` reading vanished `/proc/<pid>/environ` entries
  in unchanged process-custody code, affecting OpenCode lifecycle/integration
  and custody tests. A representative OpenCode case reproduced that error
  while a broad worker remained active; after the workers exited, four
  representative cases passed together (4 tests, 47 assertions). The runner
  reused `worker-2.log` for its component job, so its full earlier diagnostic
  list was not retained. This run does not establish a green broad suite.

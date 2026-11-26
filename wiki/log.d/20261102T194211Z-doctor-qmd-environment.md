---
title: Make Doctor's supplied QMD environment authoritative
type: change
created: 2026-11-02
tags: [doctor, qmd, environment, testing]
---

- QMD discovery reads `HIVE_QMD_BIN`, `PATH`, `HOME`, and `XDG_DATA_HOME`
  from Doctor's supplied environment. Executable `HIVE_QMD_BIN` values are
  normalized with `File.absolute_path` so bare names execute directly rather
  than searching the parent process's `PATH` and `~` is never expanded.
  Missing or empty roots omit managed candidates instead of consulting the host
  or creating relative paths.
- Preserved override/PATH/data-home/HOME/sidecar precedence, executable-only
  override eligibility, regular-file managed candidates, deduplicated candidate
  lookup, and stripped first-line-only parsing of regular readable
  `install-prefix` files (ignoring directory entries instead of raising
  `Errno::EISDIR`).
- The version subprocess receives the supplied environment with inherited
  variables disabled. The 15-second deadline, diagnostic selection, optional
  warnings, human output, v2 JSON, and default `environment: ENV` remain intact.
- Converted QMD and auth boundary tests to injected hashes and scratch-home
  Ruby children, and added regression coverage for bare-name `HIVE_QMD_BIN`
  isolation (file and directory), literal `~/qmd` non-expansion, and directory
  `install-prefix` sidecars. Child launches inherit Ruby/Bundler and coverage
  settings, disable MCP discovery, inject an empty inspector, and assert
  unchanged ENV across successful, missing, failed, unlaunchable, and timed-out
  probes.
- Documented the narrow contract in [[commands/doctor]], including required
  executable dependencies and the remaining host-driven default MCP discovery
  and runtime-state checks. The production CLI still uses default ENV.
- Verification: `test/unit/commands/doctor_test.rb` passed (51 runs, 560
  assertions); adjacent doctor unit and integration tests passed (22 runs, 125
  assertions); `bundle exec rake coverage:changed` passed (315 runs, 2,427
  assertions) with exact line coverage for `lib/hive/commands/doctor.rb`;
  RuboCop passed with 0 offenses on both changed Ruby files.

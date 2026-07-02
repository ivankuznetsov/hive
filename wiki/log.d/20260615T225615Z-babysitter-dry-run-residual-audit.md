## [2026-06-15T22:56:15Z] wiki - audit residual babysitter dry-run docs

**Action:** Refreshed wiki planning/documentation coverage after commit `2d15e9ee`, a residual wiki commit that updated [[commands/babysit]], [[modules/babysitter]], [[gaps]], and added the `20260615T222502Z-babysitter-gh-config-home-residual-audit` fragment. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and both top/tail recent compiled [[log]] entries first. `qmd search "babysitter gh config home dry-run residual audit trusted GH_CONFIG_DIR"` returned no indexed hits in this checkout, so verification fell back to `rg`, the committed diff, the configured master wiki path, and direct source/wiki reads.

**Refresh:** Inspected residual commit `2d15e9ee`, prior residual commit `6a6cf990`, and source commit `f12c46c7` against current `bin/hive-babysitter-stub-gh`, `bin/hive-babysitter-stub-git`, `lib/hive/babysitter/dry_run_env.rb`, and `test/unit/babysitter/dry_run_env_test.rb`. Confirmed the existing command/module coverage matches the code: the dry-run `gh` wrapper captures the parent GitHub config directory before command-local env can redirect it, the `gh` stub restores only that trusted path while setting `HOME` to `File::NULL`, and the `git` stub fail-closes on `GIT_EXEC_PATH`, `GIT_ASKPASS`, and `SSH_ASKPASS`. Refreshed [[testing]] so the dry-run test map names those same regression seams and the private trusted-config handoff, and carried the unchanged live-smoke uncertainty forward in [[gaps]]. Page coverage stayed within existing pages, so [[index]] did not need a catalog update. Did not edit compiled [[log]], and did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[testing]]
- [[gaps]]

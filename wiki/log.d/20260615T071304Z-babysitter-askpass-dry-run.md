# babysitter askpass dry-run executable coverage

Refreshed command/API and executable-entrypoint wiki coverage after commit
`2b86e674` changed `bin/hive-babysitter-stub-git` and
`test/unit/babysitter/dry_run_env_test.rb`. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]],
and recent [[log]] entries first. `qmd search "babysitter dry-run git askpass
SSH_ASKPASS GIT_ASKPASS passthrough"` returned no indexed hits; the configured
master wiki path had only generic route/coverage guidance.

Inspected the committed diff plus current `bin/hive-babysitter-stub-git`,
`bin/hive-babysitter-stub-gh`, `lib/hive/babysitter/dry_run_env.rb`,
`test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]],
[[modules/babysitter]], [[testing]], and [[gaps]]. Updated the dry-run git
stub contract so the known exec-capable environment seam list includes
`GIT_ASKPASS` and `SSH_ASKPASS`, allowed read passthrough scrubs both variables,
and the real-git argv now injects `-c core.askPass=` alongside
`-c core.fsmonitor=false`. Recorded that focused unit coverage exists, but no
checked-in artifact proves a full live-agent
`hive babysit --once PROJECT --dry-run` run after the askpass hardening. No new
page was needed, so [[index]] page coverage stayed at 78. Did not edit compiled
[[log]], and did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
- [[gaps]]

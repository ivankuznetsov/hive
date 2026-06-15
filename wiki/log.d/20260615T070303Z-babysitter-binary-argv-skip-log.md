# babysitter binary argv skip-log refresh

Refreshed babysitter dry-run wiki coverage after commit `36631816` changed
`bin/hive-babysitter-stub-git` and `bin/hive-babysitter-stub-gh` so
`escape_control_chars` binary-encodes argv before escaping control bytes. Read
`AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and
recent compiled [[log]] entries first; [[log]] is stale relative to newer
`wiki/log.d/` fragments, so the latest babysitter fragment was also checked
without editing [[log]].

`qmd search "babysitter skip log hardening dry-run stub"` and `qmd search
"hive babysitter dry-run git gh stub skip log"` found existing local babysitter
coverage; `qmd search "babysitter dry-run git gh stub skip log" -c master` and
the configured master wiki path had no relevant cross-project context.
Inspected the HEAD diff, both current stub files, `test/unit/babysitter/dry_run_env_test.rb`,
[[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]].

Updated babysitter command/module docs to record that skip-log argv rendering is
byte-scanned: ASCII control bytes are escaped as `\xHH`, invalid/non-UTF-8 bytes
do not raise inside `log_skip`, and high bytes pass through unchanged. Updated
testing/gap coverage to avoid overstating the test state: current tests cover
symlink refusal and ASCII control-character escaping, but this refresh found no
focused invalid/non-UTF-8 argv regression and no live `hive babysit --once
PROJECT --dry-run` artifact. No new wiki page was needed, so [[index]] did not
need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
- [[gaps]]

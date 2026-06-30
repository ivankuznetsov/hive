## [2026-06-30T11:21:02Z] babysitter - extract shared skip-log/escaping helper for the dry-run stubs

**Action:** Fixed Hive patrol finding `command-bin-hive-babysitter-stub-git-2`
(maintainability/medium): the security-critical skip-log and control-char
escaping helpers (`log_skip`, `append_skip_log`, `escaped_argv`,
`escape_control_chars`) were copy-pasted byte-for-byte across
`bin/hive-babysitter-stub-git` and `bin/hive-babysitter-stub-gh`, so a future
hardening pass on the audit-log open path or the binary-safe escaping could land
in one stub and silently diverge from the other.

Extracted the four helpers into a single `bin/hive-babysitter-skip-log.rb` that
both stubs `require_relative`. require_relative resolves from each stub's real
`bin/` dir, which survives the PATH-overlay shim handoff because
`Hive::Babysitter::DryRunEnv#prepare_overlay` execs the stub by its absolute
`bin/` path through the pinned interpreter. `log_skip` now takes the
`"git"`/`"gh"` label as its first argument so the audit line still names the
entrypoint; the only per-stub difference is removed from the duplicated body.
Added the shared file to `hive.gemspec` `spec.files` so it ships with the gem
(verified `Gem::Specification.load`).

Verified behaviorally: both stubs still skip a mutating command, write the
correct command-prefixed line to the skip log, exit 0, and the escaping path
stays binary-safe (control bytes -> `\xHH`, high bytes pass through, non-UTF-8
argv does not raise). Full minitest suite (`test/babysitter/acceptance/dry_run_test.rb`,
`test/unit/gemspec_test.rb`) runs under Hive validation; minitest is not
installed in this worktree's gem home for a local run.

**Refreshed pages:**
- [[modules/babysitter]]

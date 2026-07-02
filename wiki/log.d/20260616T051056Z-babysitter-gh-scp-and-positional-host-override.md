## [2026-06-16T05:10:56Z] fix - reject scp-form and positional host overrides in dry-run gh stub

**Action:** 6-review pass 03 fix for `bin/hive-babysitter-stub-gh`. Closed two host-override bypasses the argv flag gate missed:

1. **scp-style `--repo`/`-R` value** — `repo_value_selects_host?` keyed on `://` or a non-`1` slash count, so `git@host:owner/repo` (one slash, no scheme) was waved through as a bare slug and reached real gh against an agent-chosen host. Now any colon disqualifies the value (covers both `scheme://` URLs and scp `host:owner/repo`).
2. **Positional host-qualified targets** — `host_override?` only inspects `-R`/`--repo`/`--hostname` flags, so `gh repo view HOST/owner/repo` and `gh pr {view,checks,diff} https://host/owner/repo/pull/N` carried the host as a positional operand. Added `positional_host_override?(rest)` (wired into the gate): it rejects `repo view` operands with a colon or a second slash, and `pr view/checks/diff` operands containing `://`. The multi-slash slug rule is scoped to `repo view` because `gh api repos/owner/repo` endpoints and `gh pr view feature/branch` refs legitimately carry slashes. A `target_operands` helper skips gh's value-taking read flags (`--repo`/`-R`, `--branch`/`-b`, `--json`, `--jq`/`-q`, `--template`/`-t`) so a `--branch feature/x/y` or `--json a,b` value is not mistaken for a host.

**Tests:** Extended `test/unit/babysitter/dry_run_env_test.rb` — skips for `gh -R git@host:owner/repo …`, `gh repo view <HOST/slug|url|scp>`, and `gh pr {view,diff,checks} <url>`; passes for `gh repo view owner/repo`, `gh pr view 42`, and `gh pr view feature/topic/branch` (and the pre-existing `gh api repos/owner/repo` guard confirms the slug rule stays off api).

**Verified:** `ruby -Itest test/unit/babysitter/dry_run_env_test.rb` (17 runs, 1203 assertions, 0 failures) and `ruby -Itest test/babysitter/acceptance/dry_run_test.rb` (1 run, 11 assertions). Rubocop clean on both edited files; `ruby -c` clean on the stub.

**Refreshed pages:**
- [[modules/babysitter]]

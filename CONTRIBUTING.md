# Contributing to Hive

Thanks for your interest. Hive is a folder-as-agent pipeline driving a six-stage filesystem state machine; bug reports, patches, and design feedback are all welcome.

## Reporting bugs

Open an issue with:
- Hive version (`hive --version` once published, or git SHA)
- `claude --version`, `gh --version`, `git --version`, `ruby -v`
- A minimal reproduction — the `mv` sequence, the marker each stage produced, the relevant slice of `<project>/.hive-state/logs/<slug>/<stage>-*.log`
- The expected behavior

For security issues, see [SECURITY.md](SECURITY.md) — please do not open a public issue.

## Proposing changes

1. Fork and create a branch from `main`. Use a meaningful name (`feat/...`, `fix/...`, `docs/...`).
2. Match the existing style — the codebase is small and consistent. Run the quality gate locally before pushing:
   ```bash
   bundle install
   bundle exec rake test
   bundle exec rubocop
   bundle exec brakeman --no-pager
   bundle exec bundler-audit check --update
   ```
3. Add or update tests for any behavioral change. Unit tests live in `test/unit/`, integration tests in `test/integration/`.
4. Keep commits focused. Conventional commit prefixes are appreciated (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`).
5. Open a pull request. CI runs the quality gate above; please make sure it's green before requesting review.

## Coding conventions

- Ruby 3.4. Frozen-string-literal is **disabled** project-wide.
- Double-quoted strings.
- Module-level functions (`module_function`) for stateless helpers; classes for stateful entities.
- Subprocess invocations always use `Open3.capture3` array form — never shell-interpolate user-controlled values.
- All git/gh/claude calls go through the dedicated wrappers in `lib/hive/git_ops.rb`, `lib/hive/worktree.rb`, and `lib/hive/agent.rb`. Don't call `system` or backticks directly.
- See [`wiki/architecture.md`](wiki/architecture.md) for the layer cake and [`wiki/decisions.md`](wiki/decisions.md) for the active ADRs before proposing structural changes.

## Tests

- `test/fixtures/fake-claude` and `test/fixtures/fake-gh` are bash scripts that stand in for real binaries during tests. Pointed at via `HIVE_CLAUDE_BIN` / `PATH`.
- `HIVE_HOME` env var redirects the global config to a tmp dir so tests never touch the real registry.
- New stages or commands should ship with both unit (`test/unit/`) and integration (`test/integration/`) coverage.

## Scope discipline

Hive's scope is deliberately narrow (see [Phase 1 deferred work](wiki/active-areas.md)). New features are most welcome when they hew to the project's identity:

- Filesystem is the queue, markdown is the source of truth, `mv` is the API.
- No daemon. No web UI. No tracker.
- Single-developer trust model — `--dangerously-skip-permissions` is intentional.

If a proposal would change one of these, open an issue first to discuss before sending a PR.

## Code of Conduct

By participating in this project, you agree to abide by the [Contributor Covenant](CODE_OF_CONDUCT.md).

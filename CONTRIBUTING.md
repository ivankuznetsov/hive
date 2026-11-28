# Contributing to Hive

Thanks for your interest. Hive is a durable, local-first folder-as-agent workflow engine driving a filesystem state machine; bug reports, patches, and design feedback are all welcome.

## Reporting bugs

Open an issue with:
- Hive version (`hive --version` once published, or git SHA)
- `claude --version`, `gh --version`, `git --version`, `ruby -v`
- A minimal reproduction — the `mv` sequence, the marker each stage produced, the relevant slice of `<project>/.hive-state/logs/<slug>/<stage>-*.log`
- The expected behavior

For security issues, see [SECURITY.md](SECURITY.md) — please do not open a public issue.

## Proposing changes

1. Fork and create a branch from `main`. Use a meaningful name (`feat/...`, `fix/...`, `docs/...`).
2. Match the existing style — the codebase is small and consistent. While
   editing, run the focused test files for the behavior you changed. Run the
   broad local checkpoint before pushing when the change warrants it:
   ```bash
   bundle install
   bundle exec rake test
   bundle exec rubocop
   bundle exec brakeman --no-pager
   bundle exec bundler-audit check --update
   ```
   CI additionally owns the exhaustive coverage run, packaged Hive web
   bootstrap, TUI reactivity scale, multi-agent setup integration, operational
   status on read-only mounts, babysitter dry-run security, platform, browser,
   and release-adjacent gates; these
   should not slow every local commit.
3. Add or update tests for any behavioral change. Unit tests live in `test/unit/`, integration tests in `test/integration/`.
4. Keep commits focused. Conventional commit prefixes are appreciated (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`).
5. Open a pull request. CI runs the local checkpoint plus its exhaustive merge
   gates; please make sure they're green before requesting review.

## Coding conventions

- Ruby 3.4. Frozen-string-literal is **disabled** project-wide.
- Double-quoted strings.
- Module-level functions (`module_function`) for stateless helpers; classes for stateful entities.
- Subprocess invocations always use `Open3.capture3` array form — never shell-interpolate user-controlled values.
- All git/gh/claude calls go through the dedicated wrappers in `lib/hive/git_ops.rb`, `lib/hive/worktree.rb`, and `lib/hive/agent.rb`. Don't call `system` or backticks directly.
- See [`wiki/architecture.md`](wiki/architecture.md) for the layer cake and [`wiki/decisions.md`](wiki/decisions.md) for the active ADRs before proposing structural changes.

## CLI contract for agent callers

[`docs/cli.md`](docs/cli.md) is the single authoritative public CLI reference for every visible `bin/hive` command, subcommand, alias, option, JSON/JSON-Lines/text framing contract, remote-context rule, side effect, and exit code. Machine-validation JSON schemas live under [`schemas/`](schemas/), and internal exit-code constants live in `Hive::ExitCodes` (`lib/hive/errors.rb`).

When changing any visible command, subcommand, alias, option, behavioral mode, schema, or exit code:

1. Update the owning leaf record in [`docs/cli.md`](docs/cli.md) (and its JSON schema under `schemas/` if wire output changes).
2. Run `bin/test test/unit/docs_cli_authority_test.rb` to verify bidirectional parity against live `bin/hive` metadata and semantic invariants.
3. Keep `schema_version` compatibility intact: bump `schema_version` only when an existing key changes shape or is removed; adding new keys is non-breaking.

## Tests

- `test/fixtures/fake-claude` and `test/fixtures/fake-gh` are bash scripts that stand in for real binaries during tests. Pointed at via `HIVE_CLAUDE_BIN` / `PATH`.
- `HIVE_HOME` env var redirects the global config to a tmp dir so tests never touch the real registry.
- New stages or commands should ship with both unit (`test/unit/`) and integration (`test/integration/`) coverage.

## Scope discipline

Hive's scope is deliberately focused (see [active areas](wiki/active-areas.md) and [`docs/architecture.md`](docs/architecture.md)). New features are most welcome when they preserve the project's identity:

- Filesystem is the queue, markdown and git state are the source of truth, and every surface (CLI, TUI, native web UI, daemon, and bot) builds on the same durable local-first state machine documented in [`docs/cli.md`](docs/cli.md).
- Single-developer trust model — non-interactive agent execution and explicit consent gates are deliberate.

If a proposal would change one of these, open an issue first to discuss before sending a PR.

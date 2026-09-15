# Hive web

Hive's shared Rails 8 + Turbo interface, served natively by `hive web` and by
the managed service installed through `hive setup` (see
`wiki/commands/web.md`). The same app is packaged in the Hivebox container;
container operations live in `packaging/docker/README.md`. Architecture
decisions live in `wiki/decisions.md` (ADR-036/ADR-037).

## UI fixtures and screenshots

Run the visual scenario test from `web/`:

```sh
bundle exec rails test test/visual/status_scenarios_capture.rb
```

It creates a private test `HIVE_HOME`, uses native project/task creation, and
captures **empty** and **populated** Board/Grid pages at desktop and phone sizes
in light and dark themes. The populated scenario has two projects and nine tasks
covering inbox, unanswered brainstorm questions, planning, an execution error,
review, and completion, including a long title. Task links open real task folders.
Expanded mobile-menu captures include the account avatar. The avatar response
is a local SVG fixture, so the browser tests do not require GitHub network access.
These are synthetic examples, not evidence about a running daemon or live work.

Each successful run prints a unique `web/tmp/ui-captures/<run>/` directory with
20 full-page PNGs and `screenote-manifest.json`. Publication is a separate step:

```sh
screenote snapshot --project 16 --manifest /absolute/path/to/screenote-manifest.json
```

The manifest names the base Git commit and labels the screenshots as local
working-tree fixtures. A failed run keeps diagnostic images but does not write
a publishable manifest. Test projects are removed by the standard test teardown;
captures remain available for review.

Reuse `test/support/ui_fixtures.rb` in browser tests with `include UiFixtures`
and `seed_ui_fixture!(:populated)` before sign-in. `:empty` requires a clean
workspace and creates no projects. Seed only once per example. The helper refuses
non-test environments and refuses to overwrite existing registered projects.
The status capture test asserts task counts, titles, navigation, and page overflow
so the screenshots cannot silently become empty again.

# Single retry mechanism, and a manual-retry escape hatch past lost attempts

## What changed

**One mechanism.** The `daemon.auto_retry.enabled` kill switch is gone as a control.
Automatic `ERROR` / `REVIEW_ERROR` retry is now unconditional and governed by a single
backoff ladder in `RecoveryCoordinator`:

```ruby
RETRY_BACKOFF_SEC = [ 5, 10, 60, 300, 900, 3600 ].freeze
```

There is no retry cap, no exempt error class, and no second subsystem. The only thing that
pauses retry for a project is `daemon.enabled: false`. The config key is still
shape-validated so an existing typo fails loudly, but it no longer switches anything —
`wiki/commands/daemon.md` and `wiki/modules/config.md` now say so.

Removed with it: `StaleAgentHealer#auto_retry_enabled?` and its kwarg/ivar/gate,
`Dispatcher#auto_retry_enabled?` and the semantic-terminal-error gate, and the
`auto_retry_enabled` field in `operational_project_context`. `automatic_error_retry?`
reduces to `daemon_enabled? && %w[error review_error].include?(marker)`.

**Naming.** The surviving per-project gate wore an `auto_retry` prefix that made it read
like a separate subsystem. Renamed to say what it checks:
`project_auto_retry_enabled` → `project_daemon_enabled`, `auto_retry_projects` →
`daemon_enabled_projects`, `auto_retry_allowed?` → `daemon_enabled_for_row?`,
`auto_retry_error_row?` → `retryable_error_row?`. `Daemon::AutoRetrySafety` keeps its name:
it is a work-area precondition inside the one mechanism, not a competing one.

## The defect this exposed

A lost attempt blocks ordinary admission until an explicit successor exists
(`Attempts::Dispatcher#unresolved_lost_attempts`). The daemon reaches that successor via
`dispatch_request`, which routes to `dispatch_successor` when
`successor_predecessor?(predecessor)` is true — and it is true for `state == "lost"`.

The CLI had no such route. `Attempts::Entrypoint#dispatch` passes no predecessor, so every
operator `hive run` against a task with a lost attempt raised:

```
durable attempt deferred for <slug>: attempt_lost
```

**Manual retry was therefore impossible while the daemon was paused** — exactly when an
operator most needs it. Observed live on `webmail.sh`, whose project daemon had been
`enabled: false`: every task in the project was unrunnable by hand, each stuck behind a
lost attempt from its last failed run, with nothing able to mint the successor.

## The fix

`Entrypoint#dispatch` now converts an `attempt_lost` deferral into a supersede **when the
dispatch is interactive** (an operator at a terminal), by calling the same
`dispatch_successor` the daemon uses. It is the sanctioned route, not a bypass: the
successor still inherits the predecessor's generation, frozen routing policy, and outputs.

Non-interactive dispatch still defers — the daemon owns its own recovery route, and
self-superseding there would race two successors against one lost attempt. Deferrals for
any other reason (`capacity`, `successor_exists`, `invalid_predecessor`) are untouched.

Verified against the live wedge: the previously-unrunnable
`plan-the-webmail-sh-architecture-260817-fd6f` admitted successor `0654ef28` to lost
`7ee66c4e`, entered its stage, and started its agent.

## Tests

`test/unit/attempts/entrypoint_test.rb` gains three cases: operator dispatch supersedes a
lost attempt, non-interactive dispatch still defers, and a non-loss deferral reason still
defers. Suites touched and green: attempts (281), daemon + operational status + config
(703).

`test/unit/daemon/dispatcher_test.rb` had two tests whose only subject was the removed kill
switch. Rather than delete them, each kept the behaviour still worth pinning —
rebuild-on-reload, and reload atomicity under a late loader failure — with the config
dimension swapped to `edit_debounce_sec`.

## Gotcha found along the way

`test/unit/operational_status_test.rb`'s `disabled` fixture was built with
`daemon_enabled => true`, identical to `automated`, so its `needs_repair` assertion could
never hold once the auto-retry dimension went away. Corrected to `false`, which is now the
only thing that makes an error row operator-owned.

See [[modules/attempts]], [[modules/daemon]], [[commands/daemon]], [[modules/config]].

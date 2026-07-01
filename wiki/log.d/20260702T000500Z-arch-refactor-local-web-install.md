# 2026-07-02 — architecture pass over the local web install feature (#622)

Post-merge architecture review of PR #622 drove five behavior-preserving
refactors:

- `Hive::Daemon::StatusReport` now produces the `hive-daemon-status`
  envelope; `Commands::Daemon` delegates and the web `StatusController`
  uses `StatusReport#safe_payload` directly (no more CLI-command-object
  construction or `public :status_payload` escape hatch).
  `BINARY_DRIFT_STATES` / `BINARY_DRIFT_ACTIONABLE` moved with it.
- ServiceInstaller family: `target_path` derives in `Base` from
  `service_name` (one rule, nil on unsupported hosts — the web installer
  previously raised where daemon/bot returned nil); the bot installer now
  uses the shared `render_systemd_from` / `render_launchd_from` helpers.
- `Commands::Web#call` dispatches subcommands with one case expression;
  the foreground boot path is `#run_foreground` (no `@subcommand`
  mutation + re-entry).
- `ApplicationController#local_loopback_request?` delegates to
  `Hive::Web::Loopback.address?` — the module's "single source of truth"
  claim is now true.
- `hive setup`: phases run through one `#phase` runner (uniform
  rescue → failed-phase recording); the dead `--yes` flag is removed
  from CLI/docs (nothing ever read it; #622 unreleased).

Pages touched: [[commands/daemon]], [[commands/setup]].

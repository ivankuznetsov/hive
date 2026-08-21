# Merged main into the unified Patrol Fix branch (2026-08-21)

Resolved the `main` merge for the unified Patrol Fix workflow branch.

- `Patrol::Validator` keeps both sides: the idle-output deadline
  (`idle_timeout_sec`, `timeout_reason`, `await_completion` returning
  `wall_clock`/`idle_output`) from `main`, and the branch's per-command
  `started_at`/`finished_at`/`duration_ms`/`provenance` timing fields.
- `Commands::Patrol` keeps the branch's discovery-only shape (no inline fix
  loop, no PR opener) and re-adopts `Patrol::Shutdown.install_trap!` so a
  daemon SIGTERM still stops the sweep between units of work.
- `Patrol::Fixer`, `RefactorPatrol::Fixer`, and `patrol/fixer_test.rb` stay
  deleted. `main`'s interrupted-attempt recovery went with them; that
  regression is recorded in [[gaps]] rather than silently dropped.
- Kept `main`'s manual-capture and capture-validation integration tests
  (they cover `Commands::Patrol` methods that survive) and dropped its
  `perform_fix_attempt` / `recover_pending_fix_attempts!` tests, whose
  subjects no longer exist.
- `schemas/hive-patrol.v3.json` keeps `maxItems: 0` for inline fix results:
  the Patrol Fix workflow, not the discovery sweep, publishes them.

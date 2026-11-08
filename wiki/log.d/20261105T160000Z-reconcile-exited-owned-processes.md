# 2026-11-05 — Reconcile exited owned processes under unverified custody

- `owned_processes` rows stayed active forever when their process exited
  without its cleanup committing. One install had about 14,200 such rows, all
  `custody_mode = unverified`, with only nine processes alive: 6,641 attempt
  wrappers left `descendant_absence_unverified` by
  `mark_stopped_by_reservation!(require_descendant_absence: true)`, and about
  7,200 direct CLI rows whose `at_exit` `finish!` lost to
  `SQLite3::BusyException` (swallowed in `bin/hive`). Quiescence capability
  stayed ineligible with `agent_attempt_root`.
- `ProcessRegistry#reconcile_exited_processes!` closes an `unverified` row
  whose root identity is proven missing or mismatched. Attempt-linked rows also
  need a `terminal`/`lost` attempt and an empty recorded session and process
  group in a host-wide `/proc` snapshot (`Hive::Attempts::ProcessTable`). Other
  rows need only the session or group they led to be empty. Closed rows get
  `owner_gone_custody_unverified` and their registered reservation is released.
- The daemon runs it after the reservation release (500 rows per pass, event
  `owned_processes_reconciled`); `hive daemon quiesce` runs it before the entry
  gate and under the controller writer. A failure leaves the rows active.

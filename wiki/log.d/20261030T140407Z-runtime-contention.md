## [2026-10-30T14:04:07Z] runtime — bound SQLite contention

Default human/JSON status now shares one second of busy waiting through
startup, lease observation, and cleanup. Persistent contention yields truthful
partial v2 status with independent daemon/runtime identity, false count
exactness, no fabricated truncation, and exit 0. Human output names the busy
source once. Ordinary startup keeps the existing 15-second per-operation busy
timeout, then exits 75 before command work with one retry message and the
existing JSON maintenance envelope when requested. Failed cleanup retains
ownership evidence for existing resume reconciliation.

The installed sqlite3 2.10.1 / Sequel 5.109.0 adapter supports a Ruby busy
handler. It is installed for new and cached runtime connections, reinstated
after transaction/checkpoint timeout pragma restoration, and removed at scope
exit. A separate SQLite writer reproduced the prior raw busy exception. The
historical holder and duration remain unknown; see `wiki/gaps.md`.

Verification mapping for implementation units:

- U1: `test/unit/runtime_control_plane/contention_budget_test.rb` proves typed
  classification, monotonic shared accounting, free computation, and scope
  cleanup. `database_test.rb` covers real adapter installation, cached readers,
  timeout restoration, typed diagnostics/identity/lifecycle errors and preserved
  non-busy classifications. The named gate exercises real conflicting SQLite
  locks, including transaction/checkpoint restoration followed by another
  statement using only the remainder.
- U2: `activation_gate_test.rb` covers the default-status route and excluded
  modes/boolean spellings, and defers invalid argument bytes to the existing
  CLI usage validator. `command_registration_test.rb` covers individual
  15-second operation settings, durable reservation retention, fence release,
  and disconnect after cleanup failure. Existing process-registry and
  operational-inspection tests preserve handoff/admission/storage behavior;
  `status_error_envelope_test.rb` keeps non-busy bootstrap contracts.
- U3: `running_status_test.rb` drives the real lease-reader/database boundary
  with controlled busy errors and an injected clock, including shared remaining
  allowance, independent identity, zero projects, repeated calls and exactness.
  Status/concise tests cover renderer metadata, one human reason, JSON selection,
  schema validity, and successful behavior.
- U4: `test/integration/runtime_database_contention_test.rb` is registered as
  `test:runtime_database_contention` beside the read-only mount gate, excluded
  from default tests and coverage shards. It tests real CLI persistent writer
  locks, transient release within one second and after five seconds, ordinary
  success, read-conflicting exclusive WAL locks after committed registration,
  bounded exit cleanup, retained process rows and existing resume reconciliation.
  It reports callback waiting separately from process duration, with a 10-second
  startup/scheduler tolerance and a 35-second watchdog. CI partition tests pin
  the new gate and its exclusion from routine suites. Receipt contract,
  maintenance, and operation tests keep existing prune/capacity/unresolved-result
  handling when the new typed busy error crosses their database boundaries;
  only their narrow busy catches changed. The injected-clock tests also cover
  sub-resolution waits terminating without a floating-point spin.

Acceptance rerun on this checkout: all 8 real-lock tests passed (186
assertions). Persistent status contention consumed 1.000 seconds of callback
waiting, with process durations of 1.75–1.94 seconds. Persistent ordinary
registration waited 15.03 seconds; a synchronized release after 5.20 seconds
succeeded and created the task once (6.35 seconds for the process). The 14
focused test files passed 465 tests and 2,554 assertions. Loading the pinned
revision's database implementation against an isolated database and a separate
SQLite writer reproduced a raw `Sequel::DatabaseError` caused by
`SQLite3::BusyException`, using a shortened fixture timeout. This establishes
the prior error escape, not attribution of the historical incident. Exhaustive
coverage is left to the existing CI gate.

The broad `bin/test --all` checkpoint completed 15,929 tests and 305,424
assertions, with 13 skips and one failure: invalid UTF-8 status arguments hit
the new early classifier before the established usage validator. A focused
unit test reproduced the exception before the fix. The classifier now declines
invalid UTF-8 bytes, including binary strings, leaving the usage validator to
produce its existing exit-64 JSON envelope. The follow-up activation-gate,
argv-policy, and complete CLI JSON usage-error suites passed all 44 tests and
1,605 assertions. The broad suite was not rerun after this narrow correction.

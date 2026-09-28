# Command receipt capacity qualification

This is the Tier A local qualification for receipt settlement, maximum-result
finalization, bounded prune, and SQLite physical exhaustion. It is a repeatable
lab measurement, not a storage reservation or operator service guarantee.

Run from the repository root:

```sh
bundle exec ruby script/measure_command_receipts.rb
bin/test test/integration/command_receipt_capacity_qualification_test.rb
```

The 2026-09-28 run used Ruby 3.4.10, SQLite 3.53.2, x86_64 Linux, the real base
and additive command schema, WAL, FULL synchronous behavior, and 4 KiB pages.
The measurement command returned:

```json
{
  "settlement": {
    "samples": 100,
    "workflow": "read exact provider observation, build evidence, preview, confirm",
    "p50_ms": 4.148,
    "p95_ms": 5.425,
    "p95_minutes": 0.00009041,
    "conditional_receipts_per_day": {
      "T_absent": null,
      "T_0_minutes": 0,
      "T_30_minutes_at_lab_p95": 331814
    }
  },
  "maximum_finalization": {
    "payload_bytes": 225280,
    "elapsed_ms": 26.944,
    "main_allocated_delta_bytes": 225280,
    "wal_growth_bytes": 263712,
    "total_physical_delta_bytes": 488992
  },
  "prune_batch": {
    "candidate_limit": 100,
    "deleted": 100,
    "elapsed_ms": 112.446,
    "main_allocated_delta_bytes": 4096,
    "wal_growth_bytes": 457352,
    "reusable_page_delta": 79
  }
}
```

The settlement timer starts before the authoritative effect row is read. It
includes exact provider-correlation selection, effect identity hashing,
evidence construction, all preview safety checks, confirm-time authorization
and generation checks, terminalization, and audit persistence. It does not
pretend that an ambiguous human investigation takes 5.425 ms. For planning,
measure that installation's end-to-end `t_actual` and apply
`floor(T/t_actual)`. T absent yields no positive numeric claim; T=0 yields zero.
An operator count never multiplies a shared T allocation automatically.

The largest measured finalization F was 488,992 physical bytes when main-file
and WAL growth are counted together. `NEXT_OPERATION_ALLOWANCE` is therefore
rounded up to 512 KiB. The 100-row prune transaction P grew WAL by 457,352
bytes and made 79 pages reusable; the main file did not shrink. Neither number
guarantees a write if another process consumes disk after admission.

The integration fault test uses SQLite's real `max_page_count` limit at the
current physical page count, then attempts to persist the 220 KiB result. SQLite
returns `database or disk is full`; the receipt remains executing with no saved
result and no success is reported. Raising the physical limit and retrying the
same finalization commits one succeeded receipt with the original result. This
qualifies recovery at a real SQLite allocation boundary. The separate pruner
tests retain typed `command_prune_storage_unavailable` behavior for ENOSPC and
quota failures, preserve non-terminal rows, and rerun after availability is
restored. Prune has no reserved lane and may still fail before it can free
reusable pages.

## Maintenance and capacity evidence map

This table names the concrete proof behind each maintenance claim. “SQLite”
means the test uses the real database and transactions. “Injected fault” means
the failure is deterministically raised at the database boundary; it is not a
claim that the host filesystem was physically filled during the test.

| Contract | Evidence | Proof kind |
| --- | --- | --- |
| Owner custody, loopback provenance, GitHub-owner reload and own-receipt limits | `test/unit/command_maintenance_authority_test.rb` | Filesystem custody plus predicate tests |
| Old, unpinned terminal-only prune and exact 30-day boundary | `CommandReceiptMaintenanceTest#test_preview_and_confirm_prune_only_old_unpinned_terminals` | SQLite |
| Preview changes neither database nor WAL/SHM bytes; cold preview creates no sidecars | `#test_read_only_preview_does_not_change_database_or_sidecar_bytes`, `#test_cold_preview_refuses_without_creating_wal_or_shm_sidecars` | SQLite plus byte snapshots |
| Required absolute pin horizon, immutable acquisition identity and explicit force-release consequences | `#test_pin_requires_absolute_future_horizon_and_identity_is_immutable`, `#test_force_released_pin_cannot_be_reacquired_after_its_persisted_horizon`, `#test_force_released_pin_cannot_be_reacquired_before_horizon_either` | SQLite |
| Authorization before disclosure and confirm-time owner revocation | `#test_maintenance_authorization_precedes_disclosure_and_mutation`, `#test_revoked_github_owner_is_denied_at_confirm_time_without_audit` | SQLite plus injected principals |
| Busy, resumed, completed and abandoned prune batches retain and fence committed progress | `#test_prune_contention_and_unfinished_batches_return_recoverable_failures`, `#test_real_sqlite_writer_contention_reports_command_prune_busy`, `#test_prune_resume_and_receipt_accounting_cover_persisted_maintenance_state`, `#test_completed_keyed_prune_batch_reconstructs_committed_outcomes`, and the three abandonment tests | SQLite; real writer contention where named |
| Live N changes, A reclamation only for proven-dead owners, stale completion fencing and four-probe cursor progress | named tests in `test/unit/command_receipt_store_test.rb` | SQLite plus controlled liveness evidence |
| Namespace and installation N, A and byte backstops and staffing arithmetic | `CommandReceiptContractTest#test_capacity_configuration_and_installation_scoped_limits`, `#test_settlement_budget_distinguishes_unspecified_zero_and_allocated_time` | SQLite and configuration |
| Finalization at a physical SQLite page ceiling reports no success and recovers | `CommandReceiptCapacityQualificationTest#test_real_sqlite_page_exhaustion_never_reports_success_and_finalization_recovers` | Real `PRAGMA max_page_count` boundary |
| Prune ENOSPC preserves terminal and non-terminal rows, then resumes | `#test_prune_storage_failure_preserves_rows_and_reruns_after_availability_returns` | Injected `Errno::ENOSPC`, real SQLite state |
| Measurement entrypoint remains executable and emits the declared schema | `#test_measurement_script_emits_reproducible_qualification_json` | Real script subprocess with reduced samples |

The settlement measurement is a deterministic local lower bound for the
mechanical read/evidence/preview/confirm path. It excludes provider restoration,
operator judgment, queue cancellation and ambiguous-effect investigation. It
therefore cannot be used as operational investigation throughput. Operators
must measure their own end-to-end `t_actual`; the documented one-operator,
one-business-day default is response latency, not an allocation of T minutes.

The 2026-09-28 combined receipt/dispatch/maintenance focused run, including
the capacity qualification and every evidence-map suite above, completed 928
runs and 4,581 assertions with no failures, errors, or skips.

# Command receipt capacity qualification

This is the Tier A local qualification for receipt settlement, maximum-result
finalization, bounded prune, and SQLite physical exhaustion. It is a repeatable
lab measurement, not a storage reservation or operator service guarantee.

Run from the repository root:

```sh
bundle exec ruby script/measure_command_receipts.rb
bin/test test/integration/command_receipt_capacity_qualification_test.rb
```

The 2026-09-27 run used Ruby 3.4.10, SQLite 3.53.2, x86_64 Linux, the real base
and additive command schema, WAL, FULL synchronous behavior, and 4 KiB pages.
The measurement command returned:

```json
{
  "settlement": {
    "samples": 100,
    "workflow": "read exact provider observation, build evidence, preview, confirm",
    "p50_ms": 3.761,
    "p95_ms": 4.802,
    "p95_minutes": 0.00008004,
    "conditional_receipts_per_day": {
      "T_absent": null,
      "T_0_minutes": 0,
      "T_30_minutes_at_lab_p95": 374815
    }
  },
  "maximum_finalization": {
    "payload_bytes": 225280,
    "elapsed_ms": 25.285,
    "main_allocated_delta_bytes": 225280,
    "wal_growth_bytes": 255472,
    "total_physical_delta_bytes": 480752
  },
  "prune_batch": {
    "candidate_limit": 100,
    "deleted": 100,
    "elapsed_ms": 108.053,
    "main_allocated_delta_bytes": 4096,
    "wal_growth_bytes": 424392,
    "reusable_page_delta": 189
  }
}
```

The settlement timer starts before the authoritative effect row is read. It
includes exact provider-correlation selection, effect identity hashing,
evidence construction, all preview safety checks, confirm-time authorization
and generation checks, terminalization, and audit persistence. It does not
pretend that an ambiguous human investigation takes 4.802 ms. For planning,
measure that installation's end-to-end `t_actual` and apply
`floor(T/t_actual)`. T absent yields no positive numeric claim; T=0 yields zero.
An operator count never multiplies a shared T allocation automatically.

The largest measured finalization F was 480,752 physical bytes when main-file
and WAL growth are counted together. `NEXT_OPERATION_ALLOWANCE` is therefore
rounded up to 512 KiB. The 100-row prune transaction P grew WAL by 424,392
bytes and made 189 pages reusable; the main file did not shrink. Neither number
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

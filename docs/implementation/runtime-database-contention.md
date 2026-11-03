# Runtime database contention evidence

Base checkout: `966211001e76d53da50879a582668b5b2e381607` (the plan's
`acbb0c51d6a818cdaa268c96886bff6ebae0ba56` is an ancestor).

## Instrumented writer comparison

The reproducible fixture is
`test/support/runtime_database_contention_workload.rb`. The manifest was fixed
before the first comparison: 251 snapshot rows, 1024 padding bytes per row,
269531 encoded snapshot bytes, five writer processes (one publisher, four
manual-style bookkeeping writers), publisher target 5 Hz, each manual writer
10 Hz, two seconds of paced iterations, three repetitions, seed 261103.
Each run executes ten publications and eighty manual mutations plus reads.
A blocked iteration can extend the elapsed run beyond the nominal duration.
These are bookkeeping mutations, not yet four end-to-end stage supervisors.

`runtime-database-contention/baseline.jsonl` records the instrumented original
encoding placement; `runtime-database-contention/encoding-prepared.jsonl`
records preparation before SQL, with identical workload parameters. Values are
seconds; each repetition includes counts and p50/p95/max acquisition wait and
hold, measured separately. The observer runs after transaction and fence
release. The hold includes commit or rollback, but excludes encoding after the
change. No receipt/admission CAS was split. Payload sealing still prepares
bytes before its reference transaction.

Baseline publisher hold medians were 24.4, 26.8 and 25.4 ms; the prepared
medians were 60.4, 6.48 and 6.58 ms. Baseline manual medians were 3.73, 3.73
and 3.62 ms; prepared medians were 122, 4.58 and 3.81 ms. The first prepared
run had a 5.71-second manual hold and 10.44-second acquisition wait. All
other repetitions had zero holds over one second. The baseline had **zero**
such holds. This is negative reproduction evidence for the historical
long-writer incident, and the prepared run has a residual warning. No
long-hold reduction or historical incident resolution has been established.
The actual removed work is canonical encoding of the paired snapshot and
projection under the lock. Further reductions require attribution rather than
a larger synthetic snapshot.

## Checkpoint policy and pinned-reader qualification

Checkpoint-policy changes were exercised on the implementation tree after
`8105e313a0`. Standalone/manual connections now use `wal_autocheckpoint=4096`;
explicit daemon-owned connections use zero. Tests observe the pragmas on the
cached connection, wrapper reconnect, physical pool replacement and fork.
Daemon commits crossed the former 1000-page threshold without growing the
main database; a subsequent PASSIVE pass copied the frames. Manual-only writes
made automatic progress at the raised threshold without a daemon or lifecycle
hook. Manual commits can therefore still perform checkpoint work. Durability
remains `synchronous=FULL` and busy timeout remains 15000 ms.

Reproduce the storage-policy capture with
`bundle exec ruby -Ilib test/support/runtime_checkpoint_workload.rb`.
`runtime-database-contention/checkpoints.json` records 72 publications of the
same fixed 251-row, 1024-byte-padding, 269531-byte snapshot used by the writer
comparison. Padding content changes while its size remains fixed. This
single-writer storage test deliberately uses more publications than the
ten-publication comparison, with a pinned reader and an injected maintenance
clock advancing at five publications per second. It establishes checkpoint
policy and lifecycle feasibility; it supplies no writer timing comparison or
long-hold reduction claim.

The reader held checkpoint progress at zero while the WAL grew to **20175672
bytes / 4897 frames**, exceeding the 16 MiB escalation threshold (4073 frames
at 4096-byte page size including WAL headers). Maintenance reported deferred
progress and selected the one-second cadence above high water. After reader
release, one PASSIVE pass copied all 4897 frames in 0.365 ms. Whole quiescence,
including its pre-pause PASSIVE drain and checked FULL, completed in 20.46 ms
within its unchanged 600-second budget. The pre-pause pass copied 2/2 current
frames in 0.083 ms; FULL copied 1/1 in 0.112 ms. The existing upgrade-source
TRUNCATE completed in 2.78 ms and reduced WAL bytes to zero, within its unchanged
15-second SQLite timeout. These operations ran with the retained 20.18 MB WAL
allocation after reader release; repeated overwrites meant the live database
was much smaller than cumulative WAL frames.

The pinned-reader peak demonstrates that high water is an escalation threshold,
not a hard storage bound. A long-running daemon/four-supervisor steady-state
maximum and lifecycle behavior at that maximum remain qualification work for
the combined implementation. Deterministic tests separately cover cadence,
process and overlap guards, deferred errors, lifecycle operation/writer fences,
closed admission, transaction rejection and pre-pause error/deadline exhaustion.
The broad local checkpoint has not been run for this unit.

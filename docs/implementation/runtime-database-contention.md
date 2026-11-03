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

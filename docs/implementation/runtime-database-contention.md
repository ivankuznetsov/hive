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
At the original checkpoint-policy capture, the broad local checkpoint had
not been run; the combined qualification below records the later checks.

## Combined recovery qualification, November 8

Review-pass implementation based on `3335aef8d0` adds the default
`test/unit/runtime_database_contention_invariants_test.rb` and the named
`bundle exec rake test:runtime_database_contention` gate. CI runs the gate
separately and retains `tmp/runtime-database-contention-evidence.json`.
The November 8 capture reported three tests, 113 assertions. That fixture did
not establish detached supervisor sessions, so its restart-replay claim depended
on the caller's session layout; the November 9 qualification below supersedes
that claim. Its ten held-lock cases
run one daemon publisher/reconciler and four actual supervisors through claim,
first heartbeat, worker registration, heartbeat and terminal publication.
A barrier places the SQLite writer hold at the selected operation. Each
success case releases after 0.25 seconds with a five-second test envelope;
each exhaustion case holds for 0.6 seconds against a 0.2-second test envelope.
These shortened real-lock cases establish operation behavior and invocation
counts, not wall-clock proof of production envelopes. Default injected-clock
invariants separately exercise 30-second startup and 600-second live-operation
budgets, success after more than 30 seconds, and nested calls sharing one try.

All four supervisors returned zero on lock release. Exhaustion returned
TEMPFAIL with `runtime_bookkeeping_busy`; prestart cases invoked no workers,
while live/terminal cases invoked each worker once. Restarting reconciliation
replayed the prepared terminal successes without another invocation. The
per-role pragmas were zero for the daemon and 4096 for every manual supervisor.
The publisher retains the pinned 5 Hz cadence; the largest sampled WAL
allocation across the short combined matrix was 1,355,512 bytes. Transaction
observations retain acquisition wait and hold independently.
The gate also executes both original fixtures, including all three fixed-size
writer-comparison repetitions. This capture had zero holds over one second;
the earlier negative baseline reproduction and its residual warning remain
unchanged. No historical incident resolution or performance ratio is claimed.

The pinned-reader fixture again reached 20,175,672 WAL bytes / 4897 frames.
After reader release, PASSIVE drained all frames in 0.375 ms; quiescence took
22.87 ms, including a 0.128 ms passive pre-drain and 0.164 ms FULL checkpoint.
Upgrade TRUNCATE took 3.52 ms and reduced WAL bytes to zero. The unchanged
budgets were 600 seconds for quiescence and 15 seconds for upgrade SQLite.
This fixed-size pinned workload is storage feasibility evidence, not a
long-running steady-state WAL bound for the combined workload.

Additional unit regressions cover the fixed claimed-owner ceiling immediately
before and at expiry, restart stability, EPERM and empty fingerprints, matching
owner protection, proven live worker custody, deferred SQL disposition, pending
completion precedence and a delayed first heartbeat winning the lease CAS.
They also verify cancellation before worker registration, quiescence's separate
custody/finalization allowances, typed reasons through stage/recovery consumers,
symlinked store ancestors and the production deadline-exhausted JSON schema.

The changed-source coverage run (`HIVE_COVERAGE_BASE=HEAD bundle exec rake
coverage:changed`) selected 14 sources and 93 focused files. Its 2205 tests had
no assertion failures but two OpenCode integration errors: unchanged
`InvocationProcessCustody` raises `Errno::ESRCH` reading the environment of a
defunct 1Password process on this host. Both errors reproduce in the isolated
OpenCode file. The coverage task stops before enforcing its per-file gate, so
this run does not establish exact changed-source coverage.

The explicit regression selection passed 563 tests / 2998 assertions.
Pending-bookkeeping and supervisor suites also passed with TMPDIR traversing a
symlink: 69 tests / 429 assertions. Changed Ruby files pass RuboCop.

The broad `bin/test --all` checkpoint completed in 1286 seconds: 16,015
tests / 306,010 assertions, with three failures, 23 errors and 14 skips.
OpenCode procfs cleanup errors reproduce in the isolated lifecycle file
(29 tests: two failures / 20 errors) as well as the integration file. The
public-help repository snapshot assertion also observed concurrent checkout
activity during the broad run, which included the local fix commit. These
wider failures are not treated as a passing broad checkpoint.

A final reconciler regression also covers legacy/malformed persisted claim
timestamps without guessing a ceiling: 39 tests / 199 assertions passed.

With the broad workers stopped and the checkout quiet, the unmodified public-
help snapshot test passes in isolation: two tests / 52 assertions. This
confirms the snapshot failure depends on concurrent checkout activity; it does
not erase the failed broad checkpoint or the OpenCode procfs errors.


## Review-pass recovery qualification, November 9

The forked qualification supervisors now call `Process.setsid`, matching
`DetachedLauncher`. Before replay, the exhaustion fixture verifies that each
wrapper is its session leader, its worker shares that session, and the recorded
worker group is absent. The named gate now passes from an ordinary shell:
11 tests / 349 assertions, including all held-lock operations, four successful
terminal replays and one invocation per started worker.

With the wrapper gone or mismatched, worker identity mismatch permits pending
completion replay or loss instead of reserving capacity forever. The same rule
applies to lost-outcome cleanup. Permission-denied termination and custody that
becomes unverifiable during cleanup report `still_alive`, retaining the live
or unresolved worker fence. Bookkeeping losses publish `AgentHealthy` as
`unsatisfied` with reason `attempt_lost`, so they route to `recover_execute`;
the typed reason travels as `bookkeeping_reason` on the `attempt_lease`
evidence. Markerless recovery preserves its original
failure-origin lookup key through terminalization and rearms at retry count two
without a duplicate request-id conflict.

Nine focused test files pass: 255 tests / 1514 assertions, covering reconciliation,
process identity, loss cleanup, pending bookkeeping, finalization, condition
observation, recovery coordination, stale healing and contention invariants.
All eleven changed Ruby files pass RuboCop. The earlier broad-suite failures and
historical incident qualification limits above remain open; this fix pass did
not rerun the full suite or coverage.

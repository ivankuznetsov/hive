# 2026-11-06 — Daemon status publish no longer encodes JSON under the write lock

**Action:** Investigated chronic `SQLite3::BusyException` on the runtime
control-plane DB (daemon `fatal` busy events on 2026-11-04/05/06, a supervisor
`heartbeat deferred` line, and hivedev attempt `372e9d2a` marked lost).

**Findings:** Live `/proc/locks` sampling of the WAL write lock (shm byte 120)
showed the daemon as the longest holder (≈1.3 s spans), from
`OperationalRepository#publish`: the `daemon_runtime.observation_json` row is
5.7 MB (5.5 MB `hive-status` projection) and `Codec.dump_json` ran inside
`BEGIN IMMEDIATE` (~0.8 s CPU at rest; far longer when the daemon's heap is
swapped). The host ran with 17 GiB swap in use and memory/IO PSI `full`
avg10 ≈ 35–45 %. Attempt `372e9d2a` was not lost to SQLite: systemd-oomd
killed its whole `hive-attempt-*` scope (supervisor included) at 05:13:26, so
the reconciler saw `owner_gone`. Steady-state heartbeats already defer busy
for 600 s, and a live owner is never marked lost for a stale heartbeat.

**Change:** `publish` encodes before opening the transaction (write-lock
hold on the real document: ~820 ms → ~60 ms). The supervisor's launch claim
and first heartbeat now also retry SQLite busy, bounded by their own launch
deadlines, instead of failing the launch on one busy timeout.

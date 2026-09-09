## Recover interrupted state commits without a dispatch loop

Hive's state commit lock now conservatively quarantines abandoned empty Git
index locks after process and open-holder checks; uncertain/live locks remain.
Aborted activity operations reuse their stable identity after reconciliation
proves no committed effect, removing numbered retries and the 100-slot ceiling.
Existing historical numbered receipts remain on disk; durable attempts retain
failure history. Pending and completed operations still enforce intent matching.

Failed automatic advances now use the same backoff ladder as marker recovery,
derived from terminal attempts and capped at hourly retries. This also covers
a failed move whose source marker remains complete. The daily safety cap stays.
Regression tests cover more than 100 aborted operations, repeated failed
transitions through the hourly ceiling, and preserved live/uncertain index locks.

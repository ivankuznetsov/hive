# Preserve reused-PID candidates and unavailable identity reads

**Problem:** Drop deduplicated recorded cleanup candidates by numeric PID, so
a stale task-folder record could suppress a later live identity and its
`kill_failed` result. The process start-time wrapper also allowed identity-source
I/O failures to escape after TERM instead of taking the unavailable-identity
fail-closed path.

**Action:** Keyed Drop candidates by PID plus recorded start time while keeping
group cleanup dominant for exact duplicates. Process start-time system and I/O
errors now return an unavailable lookup. Added focused regressions proving that
every reused-PID identity contributes a cleanup result and that post-TERM
`Errno::EIO` returns `kill_failed` without sending KILL.

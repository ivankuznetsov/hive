# 2026-07-15 — Serialize babysitter dry-run skip-log records

Concurrent dry-run stubs could interleave records larger than Ruby's IO buffer
because each process appended through its own buffered `File` without
serializing the full logical line. The shared skip-log helper now takes a
nonblocking advisory lock with a one-second monotonic deadline, writes and
flushes the complete encoded record while holding the lock, then releases it
when the descriptor closes. A synchronized multi-process regression writes
16 KiB records and verifies that every invocation remains one intact line.

Pages: [[modules/babysitter]], [[commands/babysit]], [[testing]].

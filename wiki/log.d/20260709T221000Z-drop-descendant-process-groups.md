# Drop terminates descendant processes

`hive drop` now snapshots the recorded agent's descendant processes before
termination, confirms each PID's parent, process group, and start time in a
second full snapshot, and signals only the verified PIDs present in both reads
through TERM/KILL escalation. This prevents a PID reused between the ancestry
and identity reads from inheriting an old process's trusted ancestry. Both
headless and tmux launchers now record
`.lock` `claude_pid_start_time` alongside `claude_pid`, and drop compares that
identity before signalling the child. A process-tree discovery failure falls
back to root-PID-only cleanup and is reported as incomplete with
`process_tree_unavailable` rather than as a complete tree kill.

A real-process regression test covers an agent process with a nested tool process,
and focused unit coverage pins snapshot failure, PID-reuse, fallback cleanup, and
permission-denied paths at 100% line coverage for `Hive::ProcessKill`.
The confirmed snapshot still has a concurrent-fork race: a descendant created
after confirmation can escape, and fully closing that gap requires durable
OS-level containment.

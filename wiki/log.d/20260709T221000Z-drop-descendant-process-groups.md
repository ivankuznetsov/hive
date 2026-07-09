# Drop terminates descendant processes

`hive drop` now snapshots the recorded agent's descendant processes before
termination and signals the verified PIDs present in a successful snapshot
through TERM/KILL escalation. Both headless and tmux launchers now record
`.lock` `claude_pid_start_time` alongside `claude_pid`, and drop compares that
identity before signalling the child. A process-tree discovery failure falls
back to root-PID-only cleanup and is reported as incomplete with
`process_tree_unavailable` rather than as a complete tree kill.

A real-process regression test covers an agent process with a nested tool process.
The one-shot snapshot still has a concurrent-fork race: a descendant created
after discovery can escape, and fully closing that gap requires durable
OS-level containment.

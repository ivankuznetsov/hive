# OpenCode owns detached invocation processes

OpenCode tool commands can call `setsid` and leave a development server
reparented to the user service manager. A process-group-only teardown therefore
reported the agent complete while the server kept its port and runtime state.

Hive now injects a random custody ID into each prepared OpenCode invocation and
performs bounded TERM/KILL cleanup of only processes that still carry that
exact ID, checked again against PID start identity before each signal. The scan
continues across rounds so children forked during teardown are also found.
Linux reads exact NUL-delimited procfs environments; the portable fallback uses
the current user's `ps xeww` inventory. A surviving process turns the run into
`process_cleanup_failed`, even if OpenCode's transcript otherwise completed.
An empty procfs environment is a non-match: Ruby may return `nil` for a
length-bounded read at EOF, so the inventory normalizes that kernel-visible
case to an empty byte string instead of crashing cleanup.

Regression coverage launches a real child that calls `setsid`, lets its parent
exit so ancestry and process-group custody are both lost, and proves the child
is terminated while a second invocation's child remains alive. The OpenCode
lifecycle fixture independently proves the custody ID crosses the prepared
environment and cleanup happens before a successful agent result returns.
The failure paths also pin survivor reporting, procfs races and bounds, the
portable inventory, PID identity failures, signal races and permission errors,
and cleanup errors before and after spawn.

## [2026-07-21T18:07:51Z] tmux — keep exited-target cleanup idempotent

- Classified tmux's `no current target` response as the same typed
  session-unavailable state as `can't find session` and `no server running`.
- This keeps `kill_session` idempotent when a short-lived detached command
  exits between observation and cleanup, while other tmux command failures
  continue to raise `CommandFailed`.
- Added a deterministic fake-tmux regression for the exact hosted-CI error.

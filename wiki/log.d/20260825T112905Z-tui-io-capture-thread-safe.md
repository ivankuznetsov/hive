# TUI stdout suppression is now race-free across threads

`StateSource#capture_status_io` (archive refresher thread) and
`BubbleModel#capture_command_io` (TUI update thread) both used to swap the
process-global `$stdout`/`$stderr` with a per-caller
`orig = $stdout; ... $stdout = orig` restore. Patrol traced a real corruption:
when a user command's capture overlapped the archive refresher's long
`json_payload` scan, one block's `ensure` restored the other's throwaway
StringIO as the "original" binding, permanently black-holing all later TUI
output including teardown.

Both helpers now delegate to a shared, mutex-coordinated registry in
`lib/hive/tui/io_capture.rb`. Only the first capture under an empty registry
records the base bindings and installs its buffers; only the last one out
restores them, and an exiting capture whose buffer is still bound hands the
binding to a still-live buffer instead of restoring. Output inside any active
capture is discarded either way — the only contract these suppression buffers
ever had.

`test/unit/tui/io_capture_test.rb` pins both exit orderings of the reported
interleaving plus a concurrent stress pass. `Hive::Bot::Supervisor` still has
its own single-threaded copy of the old pattern (no cross-thread capture
partner today); left untouched as out of scope for this fix.

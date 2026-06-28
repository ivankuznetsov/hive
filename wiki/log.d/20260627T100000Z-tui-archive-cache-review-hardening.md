## [2026-06-27T10:00:00Z] tui/status — archive-cache review hardening (pass 3)

**Last-row drop (plan Risk #6):** `archived_cache_from_payload`'s
retain-prior-on-empty guard now fires ONLY when the project's on-disk `9-done`
dir still holds task folders (`archive_dir_has_tasks?`). An empty archive
payload is structurally identical whether it's a transient per-project
degradation (`tasks=[]`, no `"error"`) or a legitimate "final folder dropped",
so the on-disk check supplies the missing discriminator: populated dir → retain,
empty/absent dir → publish `[]`. Without it, dropping a project's last archived
task left a permanent ghost in the archive pane. A stat fault on the dir is
treated as "uncertain → retain" (mirrors `safe_mtime`'s re-check bias).

**Stat-error trigger no longer hot-loops:** `refresh_archive_signals` compares
on a STABLE signature (`archive_mtime_signature`) that collapses every
never-equal `StatError` marker to one sentinel. The marker correctly biases the
cheap active-reparse *gate* toward a re-check, but fed into the archive *trigger*
it read as "changed" every tick for a persistently-stuck `9-done` dir (stale
NFS: `exist?` true, `mtime` raises), hot-looping the heavy
`json_payload(stages:[9-done])` rescan. Collapsing it makes a stuck dir trigger
once on entry and once on recovery; the 30s backstop still covers changes hidden
behind an unreadable mtime.

**Off-thread refresher isolation:** the refresher wraps `Status#json_payload` in
`capture_status_io` (mirrors `BubbleModel#capture_command_io`) so Status's
degrade-path `warn`s can't tear the alt-screen frame from a second concurrent
emitter. A hung refresher (uninterruptible I/O) now leaves a once-fired
breadcrumb after `ARCHIVE_REFRESHER_HANG_TICKS` consecutive alive poll ticks
(`note_archive_refresher_liveness`), since both spawn guards otherwise freeze the
cache silently while `stalled?` stays false.

**Perf gate flakiness:** the absolute wall-clock budgets in
`tui_reactivity_perf_test` (idle 5ms / active 100ms) are now opt-in
(`HIVE_TUI_PERF_ABSOLUTE`) — a reviewer's host measured the active parse at 118ms
> 100ms, proving the flakiness plan Risk #2 anticipated. The machine-independent
SCALING assertions stay the always-on default + coverage gate.

# 2026-08-28 — Keep routine status projections active-only

## Summary

Removed archived task history from the daemon, bot, watch, TUI, Web, and
operational-status hot paths. Their shared `hive-status.v7` compatibility
envelope now declares `projection: active`; exact daemon refreshes declare
`partial`, explicit archive reads declare `archive`, and the remaining
in-process compatibility producer declares `ordinary`.

## Details

- Active scans enumerate every nonterminal workflow stage plus any non-inert
  terminal stage that can still require work. Inert terminal stages
  are skipped before task folders are read.
- Dependency admission starts from active metadata and exact-loads only the
  terminal prerequisites reachable from those tasks, so completion history
  still satisfies dependencies without a fleet-wide archive scan.
- Explicit Watch targets use an exact initial row projection, including hidden
  archive rows, and retain authoritative dependency admission on later bounded
  polls.
- The TUI performs one synchronous active refresh at boot. Opening Archive
  starts one coalesced background lossless scan; active and archive publication
  are synchronized so neither result overwrites the other.
- Web polls the active source and reads lossless archive state only for the
  permanent `/archive` entry point. Routine hidden-archive counts and UI copy
  were removed.
- The daemon publishes the completed operational snapshot immediately after
  task reconciliation, before running project-level Patrol discovery. Its PR
  watcher resolves only persisted candidates absent from an active frame to
  observe terminal transitions.
- Bot and daemon row adapters retain only fields they consume. Obsolete TUI
  archive retention, merge, generation, and backoff machinery was deleted.
- A degraded archive project retains its last-known rows with a visible warning,
  and a StateSource restarted while an old scan is still blocked now hands off
  to a current-generation poller when that scan exits.

## Remaining work

This prevents routine cost from growing with completed Patrol history, but a
live sample still contained 249 active rows (including 152 Patrol Fix rows) and
the rich v7 producer took 9.56 seconds to emit 1.58 MiB. Patrol discovery also
remains inside the coordinator tick, so a scan longer than the scheduler
snapshot validity window can still make status expire while work is running.
Installed dogfood, true Patrol/scheduler cadence decoupling, and proof of bot
`auto_residue` delivery across an archive transition remain open in [[gaps]].

## Refreshed pages

- [[commands/status]]
- [[commands/watch]]
- [[commands/tui]]
- [[commands/web]]
- [[commands/daemon]]
- [[modules/daemon]]
- [[modules/bot]]
- [[modules/task_dependencies]]
- [[architecture]]
- [[state-model]]
- [[testing]]
- [[gaps]]

---
title: Hive::Lock
type: module
source: lib/hive/lock.rb, lib/hive/runtime_control_plane/task_lease_repository.rb, lib/hive/runtime_control_plane/process_guard.rb
created: 2026-04-25
updated: 2026-08-30
tags: [lock, concurrency, sqlite, sequel, lease, fencing, flock, commit-lock, fork]
---

**TLDR**: Ordinary task coordination is a typed SQLite lease keyed by stable
task id. The only repository-level task workflow mutex that remains a file is
the short-lived per-project `.commit-lock` around hive-state Git mutations.

## Task leases

`Hive::Lock.with_task_lock(task_folder, payload = {}, create: true)` resolves
`meta.yml#id` through `task_subjects`, claims `task_leases` in an immediate
Sequel transaction, runs the block, then clears only the row whose random
`holder_id` still matches. There is no task-folder `.lock`, tempfile guard,
filesystem compatibility reader, or runtime backfill.

The row contains typed holder identity, monotonic `lease_version`, and a bounded JSON
payload. The payload projects operation detail plus runner and optional agent
PID/start-time identities. JSON is canonicalized and bounded to 16 KiB before
both claim and update; an oversized write cannot make its own row unreadable.

Reclamation checks PID/start-time liveness, not elapsed lease time. Task source
generation and fingerprints belong to task admission, not the lock row.

Acquisition uses compare-and-swap against the observed lease version and
holder. A live exact PID/start-time holder raises `Hive::ConcurrentRunError`.
A dead holder or reused PID can be replaced only by a higher lease version.
Release and update require the current fenced holder nonce, so an old or
unrelated caller cannot mutate a replacement generation. `Lock.update_task_lock`
also requires same-thread ownership.

Reentrancy is process- and thread-local, keyed by stable task id. A nested call
for the same task reuses the outer lease; forked children reject inherited
ownership. Folder moves remain safe because metadata id is authoritative and
the subject's observed path is updated under that id. A missing moved source
can still release by its unguessable holder nonce without recreating a folder.
A recreated path with a different id never binds to the historical subject,
and an id cannot move across registered projects. Custom state roots resolve
against `projects.state_root_path`, not a hard-coded `.hive-state` basename.

Supported task mutators take this shared lease. Multi-task destructive work
uses deterministic path order. When both project and task coordination are
needed, lock order is commit lock, task lease(s), then narrower marker/file
mutexes. `hive new` and other true identity creators use the commit lock
because no task subject exists yet. Explicit fleet cutover/bootstrap is the
other identity-creation exception.

The runner adds `slug:` and `stage:` to the payload. After launch, both the
headless `Hive::Agent` writer and the tmux-backed `Hive::ClaudeLauncher` writer
inject `claude_pid` plus `claude_pid_start_time` through `update_task_lock`.
Those fields describe only the currently owned child: after a confirmed child
exit or shared-session teardown, `clear_task_lock_child` removes both fields
in a fenced SQL update only when PID and start time still match. That
compare-and-clear prevents an older completion from erasing a replacement
child's liveness evidence. `hive status` uses the child PID for liveness, while
cleanup commands compare the recorded start time with the live process before
signalling it so a reused PID cannot target an unrelated process. If the
platform cannot read a start time, the field is nil and that child-specific
PID-reuse guard degrades to its existing PID-only behavior.

## Liveness

The runner identity is `holder_pid + holder_process_identity`; agent launchers
add `claude_pid + claude_pid_start_time`. Linux reads `/proc/<pid>/stat` field
22 and other systems fall back to bounded `ps -o lstart=`. Status and cleanup
compare both PID and start identity so PID reuse does not target or report an
unrelated process. An unavailable identity probe fails conservatively.

`hive status --json` does one bounded join from active `task_leases` through
`task_subjects` and `projects`, then validates only those observed folders and
process identities. It does not scan every task directory or issue one SQL
query per task. Stale rows ahead of a live row do not consume the 32-row output
budget; the source scan is independently capped at 10,000 rows.

## Process guard

`Hive::RuntimeControlPlane::ProcessGuard` is the single process-wide barrier
between Sequel checkouts and process creation. Every registered Database
wrapper enters it for reads, transactions, open/migration, and temporary
diagnostics connections. Before fork/daemon/self-exec it:

1. rejects a request from a thread that owns any checkout;
2. rejects while another thread owns a write transaction;
3. blocks new checkouts and waits only for other-thread reads;
4. disconnects every registered Database wrapper; and
5. resets synchronization state in the child, while the owning parent/daemon
   reconnects lazily.

Sequel pool disconnect alone drains idle connections but does not coordinate
an application-wide fork request with active checkouts. The barrier supplies
that missing ordering. Spawned agent processes rely on close-on-exec/
`close_others` and inherit no SQLite descriptor; they do not receive a writable
Database wrapper. The guarded boundaries include durable double-fork launch,
daemonization, bot/web/babysitter self-exec, project-capture forks, and every
Puma worker fork (`before_worker_fork`, parent release, child reset).

Filesystem, provider, network, subprocess, and Git work stays outside SQLite
transactions. Long work may hold a logical task lease, but never a database
transaction.

## Per-project commit lock

`with_commit_lock(project_hive_state_path, timeout: 30)` opens the persistent
`<state>/.commit-lock`, polls `flock(LOCK_EX | LOCK_NB)` to a bounded deadline,
and holds the descriptor while yielding. It is same-thread reentrant but
process-scoped; forked children must contend normally. The kernel releases it
on close or process death.

The commit lock serializes the shared hive-state Git index and brief commit
window. It does not serialize long agents on different tasks. `.markers-lock`
and other domain-specific filesystem mutexes remain narrower machine-local
coordination, not task ownership authority.

## Tests

- `test/unit/lock_test.rb` — stable identity, contention, CAS fencing,
  reentrancy, dead/PID-reuse reclaim, moved/recreated/custom-root behavior,
  oversized payload refusal, child-identity compare-and-clear, and commit-lock
  process contention.
- `test/unit/runtime_control_plane/process_guard_test.rb` — own-checkout and
  transaction rejection, blocked new checkouts, all-wrapper disconnect,
  diagnostics/fork race, mixed-database real fork, spawn, self-exec, and
  daemon/double-fork descriptor proofs.
- `test/unit/task_counter_test.rb` and
  `test/unit/patrol/launch_budget_test.rb` — real multiprocess atomic mutation.
- `test/integration/new_test.rb` — `hive new` wraps the captured-task hive-state commit in the project commit lock.

## Backlinks

- [[modules/task]] · [[modules/agent]] · [[modules/git_ops]]
- [[commands/run]] · [[commands/new]] · [[commands/drop]] · [[commands/markers]]
- [[commands/status]] · [[state-model]]

# 2026-07-26 — Promote the UserService internal boundary

**Why:** Per-user service mechanics were shared through a Hive command base,
which made the useful platform-neutral seam depend on command policy and
presentation.

**Change:** Added `Hive::UserService` with public Definition, Plan, Status, and
Result values. Inspect and plan are non-mutating. Apply and remove bind to and
revalidate the exact file and manager observation, refuse stale or unsafe
paths, replace drift atomically with timestamped backups when forced, and
report partial systemd-user/launchd outcomes with final observed state.

**Adapters:** Daemon, bot, web, setup, init, status, and uninstall retain Hive
templates, binary/install-channel resolution, web environment, command
messages and JSON, the daemon restart warning, prompts, foreground shutdown,
and global purge sequencing. Uninstall now delegates service teardown to the
same boundary without rendering install-only web configuration.

**Enforcement:** The component catalog marks UserService `boundary-ready`,
forbids external construction of its Manager collaborator, permits only the
downward AtomicFile dependency, and verifies a clean process load without Hive
commands, stages, or web code. No gem, version, release, publication,
deployment, or repository split was introduced.

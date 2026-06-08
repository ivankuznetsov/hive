## [2026-06-08T10:15:00Z] config — document daemon.max_concurrent_patrol_scans

**Action:** `wiki/modules/config.md` did not mention `daemon.max_concurrent_patrol_scans` even though the setting is live on `main` (`Config::DEFAULTS` daemon block = 1, validated `>= 1`, enforced by `Hive::Daemon::ConcurrencyController` as a `:patrol_scan_cap` separate from task-dispatch slots). Added a grounded sentence to the notable-defaults prose: daemon-scheduled `hive patrol PROJECT` scans run on their own in-flight budget so a long codex-backed scan never consumes a `daemon.max_concurrent_runs` task slot (scans tagged `kind: :patrol_scan`, excluded from the per-project/global caps).

**Refreshed pages:**
- [[modules/config]]

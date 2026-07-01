## [2026-06-30T14:54:19Z] setup/web/daemon — residual local install coverage refresh

**Action:** Refreshed command/API wiki coverage for branch `add-local-hive-web-install-260629-f4ca` after its residual 6-review commit touched `Hive::Commands::Setup`, `Hive::Commands::Web`, daemon/web service installers, `Hive::Web::AppBundle`, `Hive::Web::Loopback`, and `Hive::Daemon::DispatchRequestQueue`. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], recent [[log]] entries, ran `qmd search "local hive web install service installer daemon web loopback app bundle"` (no hits), and inspected the committed diff plus current source/tests.

**Coverage:** Added missing [[commands/setup]] for the local non-Docker provisioning surface, added it to [[index]]/[[cli]]/[[commands]], and refreshed [[commands/daemon]], [[commands/web]], [[modules/daemon]], [[testing]], and [[gaps]]. Documented `--no-bootstrap` as diagnose-only, setup phase/exit semantics, QMD/web-bundle bootstrap failure reporting, managed web-bundle stale refresh and safe extraction, same-binary daemon/web service install, shared launchd rendering and daemon plist `$0` parsing, web loopback/no-auth gating, `hive web start --detach` systemd reload behavior, and the narrowed daemon queue global-maintenance allowlist. Recorded remaining uncertainty that source can emit `binary_drift: unreadable` while the inspected `hive-daemon-status.v1` schema enum still lacks that value, plus missing live smoke for `hive setup --service` against a real local release install. Did not edit compiled [[log]], and did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/setup]]
- [[index]]
- [[cli]]
- [[commands]]
- [[commands/daemon]]
- [[commands/web]]
- [[modules/daemon]]
- [[testing]]
- [[gaps]]

## [2026-06-09T08:31:25Z] patrol/config/daemon — make patrol opt-in and per-project scan cap

**Action:** Fixed two patrol-system bugs.

1. **Patrol opt-in (`Hive::Config.resolve_patrol_mode!`).** An unset `patrol.mode` previously fell back to `DEFAULT_PATROL_MODE` (`"medium"`), which injected medium's `enabled: true` knob over `DEFAULTS["patrol"]["enabled"] = false` — so every project with no patrol section (or no `mode:`) was silently enabled. `resolve_patrol_mode!` now `return`s without injecting knobs unless `mode:` is explicitly present in the raw config (`return unless nested_key?(data, "patrol", "mode")`), so patrol falls through to `DEFAULTS` (`enabled: false`). `medium` remains the `hive init` *prompt* default (writes an explicit `mode:` into `templates/project_config.yml.erb`); the `DEFAULT_PATROL_MODE` constant is kept only for that prompt. Net: no patrol section → disabled; explicit `mode: medium` → enabled + timer/14400 (unchanged); `mode: off` → disabled; no-mode + explicit `enabled: true` → stays enabled.

2. **Per-project patrol-scan cap (`Hive::Daemon::ConcurrencyController#can_dispatch_patrol_scan?`).** The scan count summed ALL running patrol scans across every project, so `daemon.max_concurrent_patrol_scans = 1` serialized patrol across projects and starved them. Now counts only the given project's scans (`entry[:kind] == :patrol_scan && entry[:project] == project`), making the cap per-project: different projects patrol in parallel, while a second scan for the same project still returns `:patrol_scan_cap`.

**Refreshed pages:**
- [[modules/config]] — opt-in resolution prose; `daemon.max_concurrent_patrol_scans` documented as per-project.
- [[modules/patrol]] — daemon-triggers and safety-invariants sections now state patrol is opt-in (no section / no `mode:` → disabled).

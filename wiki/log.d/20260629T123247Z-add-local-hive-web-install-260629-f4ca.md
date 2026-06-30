## [2026-06-29T12:32:47Z] setup/daemon/web — local setup and daemon binary-drift status

**Action:** Refreshed command/API wiki coverage after branch `add-local-hive-web-install-260629-f4ca` touched the local setup command, daemon status payload/schema, daemon service-installer parsing, setup diagnostics, and hivebox status rendering. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "daemon status binary drift installed_binary hive-daemon-status"` returned no indexed hits, and the configured main wiki path had no matching context. Inspected the committed diff plus committed versions of `lib/hive/commands/setup.rb`, `lib/hive/setup/diagnostics.rb`, `lib/hive/commands/daemon.rb`, `lib/hive/commands/daemon/service_installer.rb`, `schemas/hive-daemon-status.v1.json`, `web/app/controllers/status_controller.rb`, `web/app/views/status/_daemon.html.erb`, and focused tests.

**Coverage:** Added [[commands/setup]] for the local non-Docker web/daemon provisioning path and updated [[cli]], [[commands]], [[commands/daemon]], [[commands/web]], [[modules/agent_profile]], [[testing]], [[gaps]], and [[index]]. Documented the `hive-setup` phase report, setup diagnostic status/auth semantics, daemon-status binary-drift fields and enum, bounded installed-binary version probe, macOS launchd `$0` binary parsing, and hivebox's in-process daemon status payload plus actionable repair states. Recorded missing live evidence for real `hive setup` service repair and concurrent web dashboard daemon-status rendering. Did not edit compiled [[log]], and did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/setup]]
- [[cli]]
- [[commands]]
- [[commands/daemon]]
- [[commands/web]]
- [[modules/agent_profile]]
- [[testing]]
- [[gaps]]
- [[index]]

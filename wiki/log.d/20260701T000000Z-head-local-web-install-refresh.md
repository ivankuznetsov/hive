## [2026-07-01T00:00:00Z] web/setup — refresh local web install command/API coverage

**Action:** Refreshed command/API and executable-service coverage for HEAD after it added local managed web mode. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "hive web setup local bundle service installer app bundle"` had no exact indexed hits, and the configured main wiki path had no matching local-web context. Inspected the committed diff and current source for `lib/hive/cli.rb`, `lib/hive/commands/web.rb`, `lib/hive/commands/web/service_installer.rb`, `lib/hive/web/app_bundle.rb`, `lib/hive/config.rb`, `lib/hive/paths.rb`, `web/app/controllers/application_controller.rb`, and the launchd/systemd example units, plus focused web command, app-bundle, bind-policy, service-installer, and Rails loopback-auth tests.

**Notes:** Existing [[commands/web]], [[commands/setup]], [[commands]], [[architecture]], and [[gaps]] already covered the managed bundle, `hive web install|start|stop|status`, loopback no-auth gate, and separate `hive-web` service. Updated [[modules/config]] so the defaults and validation summary now include `web.local_loopback`, and carried forward the missing live Homebrew/AUR/install.sh release-install smoke evidence in [[gaps]]. Page coverage count did not change, so [[index]] did not need a page-list update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[modules/config]]
- [[gaps]]

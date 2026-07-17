## [2026-07-09T16:04:26Z] hive web - normalize relative app overrides

Fixed `hive web` boot when `HIVEBOX_WEB_APP_DIR` is set to a relative Rails app
path. The override is now returned as an absolute path after the Rails marker is
verified, so the exported `BUNDLE_GEMFILE` still points at the real Gemfile
after `Dir.chdir(app_dir)`. Added focused coverage in
`test/unit/web/web_command_test.rb` for the relative override exec env.

Pages: [[commands/web]], [[testing]].

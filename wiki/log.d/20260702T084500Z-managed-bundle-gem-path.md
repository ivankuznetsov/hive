# 2026-07-02 — managed web bundle could never bundle-install (release blocker)

Pre-release testing of the 0.3.3 managed-bundle path (with
`HIVE_WEB_BUNDLE_URL` pointed at a local web/ tree, simulating the release
asset) exposed that `web/Gemfile`'s `gem "hive-cli", path: ".."` can only
resolve in a source checkout: the extracted `hive-web-<version>.tar.gz` has
no gem at `..` and hive-cli is not on rubygems, so `AppBundle.bundle_install!`
failed on every gem install. The GitHub-release 404 (no asset published yet)
had masked this — nobody had ever completed the fetch → bundle-install path.

Fix: the Gemfile resolves the path gem via `ENV.fetch("HIVE_CLI_ROOT", "..")`;
`AppBundle.bundle_install!` and the `hive web` foreground env both export
`HIVE_CLI_ROOT` = the running gem's root (`AppBundle.hive_cli_root`). Source
checkouts are unaffected (default `..`; web CI's frozen install unchanged).
Verified live: full ensure! → real bundle install → db:prepare → Rails 200
from the managed dir. Pages: [[commands/web]].

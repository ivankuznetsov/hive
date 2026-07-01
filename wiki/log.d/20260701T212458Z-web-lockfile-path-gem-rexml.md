---
date: 2026-07-01
slug: web-lockfile-path-gem-rexml
pages: [testing]
---

Fixed the PR #638 web CI setup failure where `ruby/setup-ruby` stopped before
Rails tests with Bundler's "gemspecs for path gems changed" error. The root
`hive.gemspec` already declared `rexml (~> 3.2)`, but the Rails app's
`web/Gemfile.lock` path-gem stanza for `hive-cli` had not been refreshed, so
frozen web Bundler refused to install.

Updated `web/Gemfile.lock` to record `hive-cli`'s `rexml` dependency and the
resolved `rexml 3.4.4` gem. Refreshed [[testing]] to note that root gemspec
runtime dependency changes must be mirrored into the web lockfile because
`web/Gemfile` depends on the root gem via `path: ".."`.

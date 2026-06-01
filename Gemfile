source "https://rubygems.org"

ruby "~> 3.4"

# Runtime deps live in hive.gemspec. `gemspec` pulls them into the Gemfile
# automatically and keeps the two manifests in sync.
#
# bubbletea is pinned exactly to 0.1.4: `Hive::Tui::PasteAwareRunner`
# overrides `run_loop` / `process_input` and reads private superclass
# instance variables (`@program`, `@running`, `@options`, `@model`). Any
# minor bump may rename or remove those, silently breaking paste handling.
# `PasteAwareRunner` ships a boot-time assertion that re-checks
# `Bubbletea::VERSION` on load, but the lock-down at the dependency layer
# is the first line of defence. See
# `docs/plans/2026-04-27-003-refactor-hive-tui-charm-bubbletea-plan.md`.
gemspec

group :development, :test do
  gem "minitest", "~> 6.0"
  gem "rake", "~> 13.0"
  gem "json_schemer", "~> 2.5", require: false
  gem "rubocop", "~> 1.87", require: false
  gem "rubocop-rails-omakase", "~> 1.1", require: false
  gem "brakeman", "~> 8.0", require: false
  gem "bundler-audit", "~> 0.9", require: false
end

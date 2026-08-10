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
# is the first line of defence. See `lib/hive/tui/paste_aware_runner.rb` and
# the dependency rationale in `wiki/architecture.md`.
gemspec

group :development, :test do
  gem "minitest", "~> 6.0"
  gem "rake", "~> 13.0"
  gem "rubocop", "~> 1.88", require: false
  gem "rubocop-rails-omakase", "~> 1.1", require: false
  gem "brakeman", "~> 8.0", require: false
  gem "bundler-audit", "~> 0.9", require: false
end

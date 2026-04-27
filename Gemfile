source "https://rubygems.org"

ruby "~> 3.4"

gem "thor", "~> 1.3"
gem "curses", "~> 1.6"
# Charm Ruby bindings — feature-flagged via HIVE_TUI_BACKEND=charm. Curses is the
# default through the migration; the env var flip lands in U10. See plan
# docs/plans/2026-04-27-003-refactor-hive-tui-charm-bubbletea-plan.md and the
# U2 verification at docs/solutions/2026-04-27-charm-bubbletea-api-gaps.md.
gem "bubbletea", "~> 0.1.4"
gem "lipgloss", "~> 0.2.2"

group :development, :test do
  gem "minitest", "~> 6.0"
  gem "rake", "~> 13.0"
  gem "rubocop", "~> 1.60", require: false
  gem "rubocop-rails-omakase", "~> 1.1", require: false
  gem "brakeman", "~> 8.0", require: false
  gem "bundler-audit", "~> 0.9", require: false
end

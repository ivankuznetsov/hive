source "https://rubygems.org"

ruby "~> 3.4"

gem "thor", "~> 1.3"
# Charm Ruby bindings — the only TUI backend after U11 of plan #003
# (`docs/plans/2026-04-27-003-refactor-hive-tui-charm-bubbletea-plan.md`).
# Bubble Tea drives the MVU loop in `Hive::Tui::App.run_charm`; lipgloss
# styles every rendered frame. U2 verification:
# `docs/solutions/2026-04-27-charm-bubbletea-api-gaps.md`.
gem "bubbletea", "~> 0.1.4"
gem "lipgloss", "~> 0.2.2"

group :development, :test do
  gem "minitest", "~> 6.0"
  gem "rake", "~> 13.0"
  gem "json_schemer", "~> 2.5", require: false
  gem "rubocop", "~> 1.60", require: false
  gem "rubocop-rails-omakase", "~> 1.1", require: false
  gem "brakeman", "~> 8.0", require: false
  gem "bundler-audit", "~> 0.9", require: false
end

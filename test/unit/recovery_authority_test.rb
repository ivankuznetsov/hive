require "test_helper"

# Recovery adapters may request a transition, but they must never manufacture
# one by clearing ERROR / REVIEW_ERROR themselves. This source-level guard is
# deliberately broad: it covers production code that is awkward to exercise
# together in one process (Telegram, Bubble Tea, Rails, and the recorder).
class HiveRecoveryAuthorityTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  ADAPTER_GLOBS = [
    "lib/hive/bot/**/*.rb",
    "lib/hive/tui/**/*.rb",
    "lib/hive/commands/act.rb",
    "lib/hive/operational_action.rb",
    "web/app/**/*.rb",
    "web/script/record_box_demo_real_resume.rb"
  ].freeze

  DESTRUCTIVE_RECOVERY_PATTERNS = {
    "direct marker clear" => /Hive::Markers\.clear_current/,
    "coordinator destructive edge" => /RecoveryCoordinator\.clear_recoverable_marker/,
    "markers-clear subprocess" =>
      /["']hive["']\s*,\s*["']markers["']\s*,\s*["']clear["']/
  }.freeze

  def test_production_adapters_cannot_clear_recoverable_markers
    violations = adapter_paths.flat_map do |path|
      source = File.read(path)
      DESTRUCTIVE_RECOVERY_PATTERNS.filter_map do |label, pattern|
        "#{relative(path)}: #{label}" if source.match?(pattern)
      end
    end

    assert_empty violations,
                 "recovery adapters must submit to Recovery::API/RecoveryCoordinator:\n" \
                 "#{violations.join("\n")}"
  end

  def test_only_recovery_coordinator_contains_the_recoverable_clear_primitive
    direct_clear_files = Dir.glob(File.join(ROOT, "lib/**/*.rb")).filter_map do |path|
      source = File.read(path)
      next unless source.match?(/Hive::Markers\.clear_current/)

      recoverable_call = source.scan(
        /Hive::Markers\.clear_current\((?:(?!\n\s*\)).)*\n\s*\)/m
      ).any? do |call|
        call.match?(
          /expected_name:\s*(?:marker_name|:(?:error|review_error|review_stale|review_ci_stale))/
        )
      end
      relative(path) if recoverable_call
    end

    assert_equal [ "lib/hive/daemon/recovery_coordinator.rb" ], direct_clear_files.sort
  end

  def test_each_user_facing_adapter_routes_recovery_to_the_neutral_api
    expected = {
      "bot" => "lib/hive/bot/supervisor.rb",
      "tui" => "lib/hive/tui/bubble_model.rb",
      "rails" => "web/app/models/concerns/task_mutations.rb",
      "recorder" => "web/script/record_box_demo_real_resume.rb"
    }

    expected.each do |surface, relative_path|
      source = File.read(File.join(ROOT, relative_path))
      assert_match(/\.recover!\(/, source,
                   "#{surface} recovery must use the canonical API")
      next if surface == "bot" # bot keeps the combined queue-writer compatibility adapter

      assert_includes source, "Hive::Recovery::API",
                      "#{surface} must not depend on the Telegram queue writer"
    end
  end

  private

  def adapter_paths
    ADAPTER_GLOBS.flat_map { |glob| Dir.glob(File.join(ROOT, glob)) }.uniq.sort
  end

  def relative(path)
    path.delete_prefix("#{ROOT}/")
  end
end

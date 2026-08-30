require "test_helper"
require "hive/config"

class HiveBrainstormSuggestionsConfigTest < Minitest::Test
  def with_project(config = "")
    Dir.mktmpdir do |root|
      state = File.join(root, ".hive-state")
      FileUtils.mkdir_p(state)
      File.write(File.join(state, "config.yml"), config)
      yield root, state
    end
  end

  def test_defaults_enable_bounded_claude_route
    with_project do |root, _state|
      cfg = Hive::Config.load(root)

      assert_equal true, cfg.dig("brainstorm", "suggestions", "enabled")
      assert_equal "claude", cfg.dig("brainstorm", "suggestions", "agent")
      assert_equal 3, cfg.dig("brainstorm", "suggestions", "max_automatic_attempts")
      assert Hive::ModelRouting.known?("brainstorm_suggestion")
    end
  end

  def test_invalid_suggestion_configuration_fails_at_load
    with_project("brainstorm:\n  suggestions:\n    timeout_sec: 0\n") do |root, _state|
      error = assert_raises(Hive::ConfigError) { Hive::Config.load(root) }
      assert_includes error.message, "brainstorm.suggestions.timeout_sec"
    end

    with_project("brainstorm:\n  suggestions:\n    agent: missing-provider\n") do |root, _state|
      error = assert_raises(Hive::ConfigError) { Hive::Config.load(root) }
      assert_includes error.message, "brainstorm.suggestions.agent"
    end
  end

  def test_feature_cannot_be_disabled_until_cleanup_is_safe
    config = "brainstorm:\n  suggestions:\n    enabled: false\n"
    with_project(config) do |root, state|
      task = File.join(state, "stages", "2-brainstorm", "task-1")
      FileUtils.mkdir_p(task)
      sidecar = File.join(task, "brainstorm-suggestions.json")
      File.write(sidecar, "{}")

      error = assert_raises(Hive::ConfigError) { Hive::Config.load(root) }
      assert_includes error.message, "hive brainstorm-suggestion cleanup"

      File.delete(sidecar)
      assert_equal false, Hive::Config.load(root).dig("brainstorm", "suggestions", "enabled")
    end
  end
end

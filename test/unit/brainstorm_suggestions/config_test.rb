require "test_helper"
require "hive/config"

class HiveBrainstormSuggestionsConfigTest < Minitest::Test
  include HiveTestHelper

  def with_project(config = "")
    Dir.mktmpdir do |root|
      state = File.join(root, ".hive-state")
      FileUtils.mkdir_p(state)
      File.write(File.join(state, "config.yml"), config)
      yield root, state
    end
  end

  def test_defaults_keep_bounded_claude_route_opted_out
    with_project do |root, _state|
      cfg = Hive::Config.load(root)

      assert_equal false, cfg.dig("brainstorm", "suggestions", "enabled")
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

  def test_closed_suggestion_schema_rejects_wrong_shape_unknown_keys_and_non_boolean_flag
    base = Marshal.load(Marshal.dump(Hive::Config::DEFAULTS))
    invalid = [
      [ [], "must be a Hash" ],
      [ base.dig("brainstorm", "suggestions").merge("surprise" => true), "unknown keys" ],
      [ base.dig("brainstorm", "suggestions").merge("enabled" => "yes"), "must be a boolean" ]
    ]

    invalid.each do |suggestions, message|
      cfg = Marshal.load(Marshal.dump(base))
      cfg["brainstorm"]["suggestions"] = suggestions
      error = assert_raises(Hive::ConfigError) do
        Hive::Config.send(:validate_brainstorm_suggestions!, cfg, "fixture.yml")
      end
      assert_includes error.message, message
    end
  end

  def test_disable_check_treats_symlink_and_read_failure_as_unsafe
    with_project do |root, state|
      task = File.join(state, "stages", "2-brainstorm", "task-1")
      FileUtils.mkdir_p(task)
      brainstorm = File.join(task, "brainstorm.md")
      cfg = Marshal.load(Marshal.dump(Hive::Config::DEFAULTS))
      cfg["project_root"] = root
      cfg["hive_state_path"] = state
      cfg["brainstorm"]["suggestions"]["enabled"] = false

      File.symlink("missing", brainstorm)
      assert_raises(Hive::ConfigError) do
        Hive::Config.send(:validate_brainstorm_suggestion_disable!, cfg, "fixture.yml")
      end

      File.unlink(brainstorm)
      File.write(brainstorm, "ordinary brainstorm\n")
      original_binread = File.method(:binread)
      replacement = lambda do |path, *args|
        raise Errno::EIO, "read failed" if path == brainstorm

        original_binread.call(path, *args)
      end
      with_replaced_singleton_method(File, :binread, replacement) do
        assert_raises(Hive::ConfigError) do
          Hive::Config.send(:validate_brainstorm_suggestion_disable!, cfg, "fixture.yml")
        end
      end
    end
  end

  def test_disable_check_rejects_oversized_and_reserved_brainstorm_content
    with_project do |root, state|
      task = File.join(state, "stages", "2-brainstorm", "task-1")
      FileUtils.mkdir_p(task)
      brainstorm = File.join(task, "brainstorm.md")
      cfg = Marshal.load(Marshal.dump(Hive::Config::DEFAULTS))
      cfg["project_root"] = root
      cfg["hive_state_path"] = state
      cfg["brainstorm"]["suggestions"]["enabled"] = false

      File.write(
        brainstorm,
        "x" * (Hive::BrainstormSuggestions::Envelope::MAX_SCAN_BYTES + 1)
      )
      assert_raises(Hive::ConfigError) do
        Hive::Config.send(:validate_brainstorm_suggestion_disable!, cfg, "fixture.yml")
      end

      File.write(brainstorm, "<!-- hive-suggestion:v1 binding=#{'a' * 64} -->\n")
      assert_raises(Hive::ConfigError) do
        Hive::Config.send(:validate_brainstorm_suggestion_disable!, cfg, "fixture.yml")
      end
    end
  end
end

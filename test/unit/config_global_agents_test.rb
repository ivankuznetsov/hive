require "test_helper"
require "hive/config"

class ConfigGlobalAgentsTest < Minitest::Test
  include HiveTestHelper

  def test_load_global_agents_defaults_when_key_absent
    with_tmp_global_config do
      assert_equal %w[claude codex], Hive::Config.load_global_agents
    end
  end

  def test_write_and_load_global_agents_round_trips_in_backend_order
    with_tmp_global_config do |home|
      written = Hive::Config.write_global_agents!(%w[pi claude pi])

      assert_equal %w[claude pi], written
      assert_equal %w[claude pi], Hive::Config.load_global_agents

      data = YAML.safe_load(File.read(File.join(home, "config.yml")))
      assert_equal %w[claude pi], data.dig("agents", "selected")
      assert_equal [], data.fetch("registered_projects")
    end
  end

  def test_write_global_agents_preserves_other_agent_settings
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), {
        "registered_projects" => [],
        "agents" => { "notes" => "operator-owned" }
      }.to_yaml)

      Hive::Config.write_global_agents!(%w[codex])

      data = YAML.safe_load(File.read(File.join(home, "config.yml")))
      assert_equal "operator-owned", data.dig("agents", "notes")
      assert_equal %w[codex], data.dig("agents", "selected")
    end
  end

  def test_load_global_agents_rejects_malformed_agents_block
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), {
        "registered_projects" => [],
        "agents" => "claude"
      }.to_yaml)

      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_agents }
      assert_match(/agents .* must be a Hash/, err.message)
    end
  end

  def test_load_global_agents_rejects_malformed_selected_block
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), {
        "registered_projects" => [],
        "agents" => { "selected" => "claude" }
      }.to_yaml)

      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_agents }
      assert_match(/agents\.selected .* must be an Array/, err.message)
    end
  end

  def test_load_global_agents_rejects_unknown_backend
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), {
        "registered_projects" => [],
        "agents" => { "selected" => [ "claude", "unknown" ] }
      }.to_yaml)

      err = assert_raises(Hive::ConfigError) { Hive::Config.load_global_agents }
      assert_match(/unknown backend "unknown"/, err.message)
    end
  end
end

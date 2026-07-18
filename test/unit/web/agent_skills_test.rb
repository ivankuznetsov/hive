require "test_helper"
require "hive/web/agent_skills"

class WebAgentSkillsTest < Minitest::Test
  include HiveTestHelper

  def test_inspect_returns_the_shared_inspector_payload_for_the_project
    with_tmp_dir do |dir|
      write_project_config(dir)
      captured = {}
      row = Struct.new(:payload) { def to_h = payload }.new({ "health" => "healthy" })
      inspector_class = factory_for do |kwargs|
        captured.merge!(kwargs)
        Struct.new(:row) { def inspect = [ row ] }.new(row)
      end

      result = Hive::Web::AgentSkills.new(inspector_class: inspector_class).inspect("path" => dir)

      assert_equal [ { "health" => "healthy" } ], result
      assert_equal File.expand_path(dir), captured.fetch(:project_root)
      assert_equal "agent-skills-test", captured.fetch(:config).fetch("project_name")
    end
  end

  def test_repair_uses_the_cli_command_with_non_tty_explicit_web_consent
    with_tmp_dir do |dir|
      write_project_config(dir)
      captured = {}
      setup_command_class = factory_for do |kwargs|
        captured.merge!(kwargs)
        Object.new.tap do |command|
          command.define_singleton_method(:call) do
            kwargs.fetch(:output).puts JSON.generate(
              "classification" => "success",
              "exit_code" => 0,
              "final_health" => []
            )
            0
          end
        end
      end

      result = Hive::Web::AgentSkills.new(setup_command_class: setup_command_class).repair("path" => dir)

      assert_equal "success", result.fetch("classification")
      assert_equal 0, result.fetch("exit_code")
      assert_equal true, captured.fetch(:yes)
      assert_equal true, captured.fetch(:json)
      assert_equal "web_confirmed", captured.fetch(:consent_provenance)
      assert_equal false, captured.fetch(:input).tty?
      assert_equal File.expand_path(dir), captured.fetch(:project_root)
    end
  end

  def test_repair_maps_malformed_command_output_to_a_typed_error
    with_tmp_dir do |dir|
      write_project_config(dir)
      setup_command_class = factory_for do |kwargs|
        Object.new.tap do |command|
          command.define_singleton_method(:call) do
            kwargs.fetch(:output).write("not-json")
            1
          end
        end
      end

      error = assert_raises(Hive::Error) do
        Hive::Web::AgentSkills.new(setup_command_class: setup_command_class).repair("path" => dir)
      end
      assert_match(/could not read agent skill setup result/, error.message)
    end
  end

  private

  def write_project_config(dir)
    state = File.join(dir, ".hive-state")
    FileUtils.mkdir_p(state)
    File.write(File.join(state, "config.yml"), { "project_name" => "agent-skills-test" }.to_yaml)
  end

  def factory_for(&builder)
    Object.new.tap do |factory|
      factory.define_singleton_method(:new) { |**kwargs| builder.call(kwargs) }
    end
  end
end

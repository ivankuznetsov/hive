require "test_helper"
require "hive/refactor_patrol/review_agent_runner"
require "hive/refactor_patrol/state_store"

class RefactorPatrolReviewAgentRunnerTest < Minitest::Test
  include HiveTestHelper

  def test_call_records_usage_and_profile_fallback
    with_tmp_dir do |dir|
      state = Hive::RefactorPatrol::StateStore.new(dir)
      runner = Hive::RefactorPatrol::ReviewAgentRunner.new(project_root: dir, cfg: cfg, state: state)
      fake_profile = Object.new
      fake_agent = Class.new do
        def initialize(**); end

        def run!
          { usage: { model: "m", input: 1, output: 2, cached: 3 } }
        end
      end
      records = []

      original_lookup = Hive::AgentProfiles.method(:lookup)
      original_record = Hive::UsageDb.method(:record!)
      original_agent = Hive.const_get(:Agent)
      begin
        Hive::AgentProfiles.define_singleton_method(:lookup) { |*| fake_profile }
        Hive::UsageDb.define_singleton_method(:record!) { |**kwargs| records << kwargs }
        Hive.send(:remove_const, :Agent)
        Hive.const_set(:Agent, fake_agent)
        runner.call(prompt: "p", output_path: File.join(dir, "out.json"), run_dir: state.run_dir("review"))
      ensure
        Hive.send(:remove_const, :Agent)
        Hive.const_set(:Agent, original_agent)
        Hive::AgentProfiles.define_singleton_method(:lookup, original_lookup)
        Hive::UsageDb.define_singleton_method(:record!, original_record)
      end

      assert_equal 1, records.size
      assert_equal "claude", records.first.fetch(:agent)
      assert_equal "refactor-patrol-review", records.first.fetch(:stage)
    end
  end

  def test_record_usage_warning_is_non_fatal
    with_tmp_dir do |dir|
      runner = Hive::RefactorPatrol::ReviewAgentRunner.new(
        project_root: dir, cfg: cfg, state: Hive::RefactorPatrol::StateStore.new(dir)
      )
      original_record = Hive::UsageDb.method(:record!)
      begin
        Hive::UsageDb.define_singleton_method(:record!) { |**_kwargs| raise "db down" }

        _out, err = capture_io do
          runner.send(:record_usage, { usage: { input: 1 } }, Struct.new(:name).new("claude"), Time.now.utc)
        end

        assert_includes err, "usage record failed"
      ensure
        Hive::UsageDb.define_singleton_method(:record!, original_record)
      end
    end
  end

  def test_read_only_call_uses_claude_tool_confinement
    with_tmp_dir do |dir|
      state = Hive::RefactorPatrol::StateStore.new(dir)
      runner = Hive::RefactorPatrol::ReviewAgentRunner.new(
        project_root: dir, cfg: cfg, state: state, read_only: true
      )
      profile = Struct.new(:name).new(:claude)
      captured = nil
      output_path = File.join(dir, "out.json")
      fake_agent = Class.new do
        define_method(:initialize) { |**kwargs| captured = kwargs }
        define_method(:run!) { { status: :ok, final_message: '{"theses":[]}' } }
      end

      with_replaced_singleton_method(Hive::AgentProfiles, :lookup, ->(*) { profile }) do
        original_agent = Hive.const_get(:Agent)
        begin
          Hive.send(:remove_const, :Agent)
          Hive.const_set(:Agent, fake_agent)
          runner.call(prompt: "p", output_path: output_path, run_dir: state.run_dir("review"))
        ensure
          Hive.send(:remove_const, :Agent)
          Hive.const_set(:Agent, original_agent)
        end
      end

      assert_equal "default", captured.fetch(:permission_mode)
      assert_equal Hive::PermissionScope::READ_ONLY_ALLOWED, captured.fetch(:allowed_tools)
      assert_equal Hive::PermissionScope::READ_ONLY_DISALLOWED, captured.fetch(:disallowed_tools)
      assert_equal :exit_code_only, captured.fetch(:status_mode)
      assert_nil captured.fetch(:expected_output)
      assert_equal({ "theses" => [] }, JSON.parse(File.read(output_path)))
    end
  end

  def test_read_only_call_fails_closed_for_provider_without_enforcement
    with_tmp_dir do |dir|
      runner = Hive::RefactorPatrol::ReviewAgentRunner.new(
        project_root: dir,
        cfg: cfg.merge("refactor_patrol" => { "agent" => "codex" }),
        state: Hive::RefactorPatrol::StateStore.new(dir),
        read_only: true
      )
      profile = Struct.new(:name).new(:codex)

      with_replaced_singleton_method(Hive::AgentProfiles, :lookup, ->(*) { profile }) do
        error = assert_raises(Hive::ConfigError) do
          runner.call(prompt: "p", output_path: File.join(dir, "out.json"), run_dir: dir)
        end
        assert_includes error.message, "cannot enforce read-only"
      end
    end
  end

  private

  def cfg
    {
      "budget_usd" => { "patrol" => 100 },
      "timeout_sec" => { "patrol" => 3600 },
      "refactor_patrol" => { "agent" => "claude" }
    }
  end
end

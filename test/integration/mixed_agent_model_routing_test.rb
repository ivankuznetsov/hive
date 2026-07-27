require "test_helper"
require "hive/agent_profiles"
require "hive/model_routing"
require "hive/stages/base"

class MixedAgentModelRoutingTest < Minitest::Test
  include HiveTestHelper

  Task = Struct.new(:folder, :state_file, :log_dir, :stage_name, keyword_init: true)

  def setup
    @previous = {
      "HIVE_CODEX_BIN" => ENV["HIVE_CODEX_BIN"],
      "HIVE_CLAUDE_BIN" => ENV["HIVE_CLAUDE_BIN"],
      "HIVE_FAKE_CODEX_ARGV_LOG" => ENV["HIVE_FAKE_CODEX_ARGV_LOG"],
      "HIVE_FAKE_CLAUDE_LOG_DIR" => ENV["HIVE_FAKE_CLAUDE_LOG_DIR"]
    }
    ENV["HIVE_CODEX_BIN"] = File.expand_path("../fixtures/fake-codex", __dir__)
    ENV["HIVE_CLAUDE_BIN"] = File.expand_path("../fixtures/fake-claude", __dir__)
    Hive::AgentProfile.reset_version_cache!
  end

  def teardown
    @previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    Hive::AgentProfile.reset_version_cache!
  end

  def test_mixed_provider_workflow_uses_native_ordering_without_flag_leakage
    with_tmp_dir do |dir|
      codex_log = File.join(dir, "codex-argv.log")
      ENV["HIVE_FAKE_CODEX_ARGV_LOG"] = codex_log
      ENV["HIVE_FAKE_CLAUDE_LOG_DIR"] = dir
      models = {
        "plan" => { "model" => "gpt-5.6-sol", "effort" => "xhigh" },
        "execute_implementation" => { "model" => "gpt-5.6-sol", "effort" => "xhigh" },
        "review" => { "effort" => "high" }
      }

      %w[plan execute_implementation].each do |stage|
        spawn_fake(
          dir, stage,
          Hive::AgentProfiles.lookup(:codex),
          Hive::ModelRouting.resolve(
            models: models, stage: stage, provider: :codex
          )
        )
      end
      spawn_fake(
        dir, "review_reviewers",
        Hive::AgentProfiles.lookup(:claude),
        Hive::ModelRouting.resolve(
          models: models, stage: "review_reviewers",
          current: { model: "opus" }, provider: :claude
        )
      )
      spawn_fake(
        dir, "review_reviewers_codex",
        Hive::AgentProfiles.lookup(:codex),
        Hive::ModelRouting.resolve(
          models: models, stage: "review_reviewers",
          current: { model: "gpt-5.6-sol" }, provider: :codex
        )
      )

      codex_invocations = argv_invocations(File.read(codex_log))
      assert_equal 3, codex_invocations.length
      codex_invocations.first(2).each do |argv|
        assert_equal [
          "--model", "gpt-5.6-sol",
          "-c", "model_reasoning_effort=xhigh",
          "exec"
        ], argv.first(5)
        refute_includes argv, "--effort"
        refute_includes argv, "opus"
      end
      assert_equal [
        "--model", "gpt-5.6-sol",
        "-c", "model_reasoning_effort=high",
        "exec"
      ], codex_invocations.fetch(2).first(5)
      refute_includes codex_invocations.fetch(2), "--effort"
      refute_includes codex_invocations.fetch(2), "opus"

      claude_argv = argv_invocations(
        File.read(File.join(dir, "fake-claude-argv.log"))
      ).fetch(0)
      model_index = claude_argv.index("--model")
      effort_index = claude_argv.index("--effort")
      assert_equal "opus", claude_argv.fetch(model_index + 1)
      assert_equal "high", claude_argv.fetch(effort_index + 1)
      refute_includes claude_argv, "-c"
      refute claude_argv.any? { |arg| arg.start_with?("model_reasoning_effort=") }
    end
  end

  private

  def spawn_fake(dir, stage, profile, resolution)
    folder = File.join(dir, stage)
    FileUtils.mkdir_p(folder)
    task = Task.new(
      folder: folder,
      state_file: File.join(folder, "state.md"),
      log_dir: File.join(folder, "logs"),
      stage_name: stage
    )
    result = Hive::Stages::Base.spawn_agent(
      task,
      prompt: "offline routing acceptance",
      max_budget_usd: nil,
      timeout_sec: 5,
      cwd: dir,
      profile: profile,
      status_mode: :exit_code_only,
      routing_resolution: resolution
    )
    assert_equal :ok, result.fetch(:status)
  end

  def argv_invocations(log)
    log.split(/^---\n/).filter_map do |block|
      next if block.strip.empty?

      block.lines.grep(/^arg=/).map { |line| line.sub(/^arg=/, "").chomp }
    end
  end
end

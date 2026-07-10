require "test_helper"
require "hive/config"
require "hive/reviewers/agent"
require "hive/reviewers/synthetic_task"
require "hive/stages/base"

class MixedAgentModelRoutingTest < Minitest::Test
  include HiveTestHelper

  FAKE_CODEX = File.expand_path("../fixtures/fake-codex", __dir__)

  def setup
    Hive::AgentProfile.reset_version_cache!
  end

  def teardown
    Hive::AgentProfile.reset_version_cache!
  end

  def test_loaded_config_routes_mixed_stage_and_reviewer_subprocesses
    with_tmp_dir do |project|
      logs = File.join(project, "argv")
      FileUtils.mkdir_p(logs)
      with_env(
        "HIVE_CLAUDE_BIN" => FAKE_CLAUDE_FIXTURE,
        "HIVE_CODEX_BIN" => FAKE_CODEX,
        "HIVE_FAKE_CLAUDE_LOG_DIR" => logs,
        "HIVE_FAKE_CODEX_ARGV_LOG" => File.join(logs, "codex.log"),
        "HIVE_FAKE_CLAUDE_WRITE_FILE" => nil,
        "HIVE_FAKE_CLAUDE_WRITE_CONTENT" => nil,
        "HIVE_FAKE_CODEX_WRITE_FILE" => nil,
        "HIVE_FAKE_CODEX_WRITE_CONTENT" => nil
      ) do
        write_config(project, valid_config)
        cfg = Hive::Config.load(project)
        task = synthetic_task(project)

        spawn_stage(task, cfg, config_stage: "plan", identity: :plan)
        spawn_stage(task, cfg, config_stage: "execute", identity: :execute_implementation)
        run_reviewers(project, cfg)
        spawn_stage(task, cfg, config_stage: "artifacts", identity: :artifacts)
        spawn_stage(task, cfg, config_stage: "open_pr", identity: nil)

        codex_sections = argv_sections(File.join(logs, "codex.log"))
        assert_equal 3, codex_sections.length
        codex_sections.each do |args|
          assert_includes args, "--model"
          assert_includes args, "gpt-5.6-sol"
          assert_includes args, "-c"
          assert_includes args, 'model_reasoning_effort="xhigh"'
          refute_includes args, "--effort"
          refute_includes args, "opus"
          refute_includes args, "--dangerously-skip-permissions"
        end

        claude_sections = argv_sections(File.join(logs, "fake-claude-argv.log"))
        assert_equal 3, claude_sections.length
        reviewer_args, artifacts_args, no_stage_args = claude_sections
        assert_equal "opus", value_after(reviewer_args, "--model")
        assert_equal "high", value_after(reviewer_args, "--effort")
        assert_equal "default", value_after(artifacts_args, "--model")
        refute_includes artifacts_args, "--effort"
        assert_equal "default", value_after(no_stage_args, "--model")
        refute_includes no_stage_args, "opus",
                        "a no-stage spawn must ignore models.open_pr"
        claude_sections.each do |args|
          refute args.any? { |arg| arg.start_with?("model_reasoning_effort=") }
          refute_includes args, "-c"
        end

        before = [ File.size(File.join(logs, "codex.log")), File.size(File.join(logs, "fake-claude-argv.log")) ]
        invalid = File.join(project, "invalid")
        write_config(invalid, valid_config.merge(
          "plan" => { "agent" => "pi" },
          "models" => { "plan" => { "model" => "unsupported" } }
        ))
        assert_raises(Hive::ConfigError) { Hive::Config.load(invalid) }
        after = [ File.size(File.join(logs, "codex.log")), File.size(File.join(logs, "fake-claude-argv.log")) ]
        assert_equal before, after, "invalid config must fail before either binary runs"
      end
    end
  end

  private

  def valid_config
    {
      "claude" => { "mode" => "headless", "model" => "default", "effort" => "default" },
      "plan" => { "agent" => "codex" },
      "execute" => { "agent" => "codex" },
      "models" => {
        "plan" => { "model" => "gpt-5.6-sol", "effort" => "xhigh" },
        "execute" => { "model" => "gpt-5.6-sol", "effort" => "xhigh" },
        "open_pr" => { "model" => "opus" }
      },
      "review" => {
        "reviewers" => [
          reviewer_spec("claude-review", "claude", "opus", "high"),
          reviewer_spec("codex-review", "codex", "gpt-5.6-sol", "xhigh")
        ]
      }
    }
  end

  def reviewer_spec(name, agent, model, effort)
    {
      "name" => name,
      "kind" => "agent",
      "agent" => agent,
      "model" => model,
      "effort" => effort,
      "skill" => "ce-code-review",
      "output_basename" => name,
      "prompt_template" => "reviewer_claude_ce_code_review.md.erb",
      "timeout_sec" => 5
    }
  end

  def write_config(project, data)
    state = File.join(project, ".hive-state")
    FileUtils.mkdir_p(state)
    File.write(File.join(state, "config.yml"), data.to_yaml)
  end

  def synthetic_task(project)
    folder = File.join(project, ".hive-state", "routing-task")
    FileUtils.mkdir_p(folder)
    state_file = File.join(folder, "task.md")
    File.write(state_file, "# routing\n")
    Hive::Reviewers::SyntheticTask.new(
      folder: folder,
      state_file: state_file,
      log_dir: File.join(folder, "logs"),
      stage_name: "routing",
      project_root: project
    )
  end

  def spawn_stage(task, cfg, config_stage:, identity:)
    profile = Hive::Stages::Base.stage_profile(cfg, config_stage)
    result = Hive::Stages::Base.spawn_agent(
      task,
      prompt: "route #{config_stage}",
      max_budget_usd: 1,
      timeout_sec: 5,
      profile: profile,
      status_mode: :exit_code_only,
      cfg: cfg,
      stage: identity
    )
    assert_equal :ok, result[:status]
  end

  def run_reviewers(project, cfg)
    task_folder = File.join(project, ".hive-state", "review-task")
    FileUtils.mkdir_p(task_folder)
    File.write(File.join(task_folder, "plan.md"), "## Plan\n")
    context = Hive::Reviewers::Context.new(
      worktree_path: project,
      task_folder: task_folder,
      default_branch: "main",
      pass: 1
    )

    cfg.dig("review", "reviewers").each do |spec|
      output = File.join(task_folder, "reviews", "#{spec.fetch('output_basename')}-01.md")
      FileUtils.mkdir_p(File.dirname(output))
      if spec.fetch("agent") == "claude"
        ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = output
        ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## High\nNo findings.\n"
      else
        ENV["HIVE_FAKE_CODEX_WRITE_FILE"] = output
        ENV["HIVE_FAKE_CODEX_WRITE_CONTENT"] = "## High\nNo findings.\n"
      end
      result = Hive::Reviewers::Agent.new(spec, context, cfg: cfg).run!
      assert result.ok?, result.error_message
    end
  ensure
    %w[
      HIVE_FAKE_CLAUDE_WRITE_FILE HIVE_FAKE_CLAUDE_WRITE_CONTENT
      HIVE_FAKE_CODEX_WRITE_FILE HIVE_FAKE_CODEX_WRITE_CONTENT
    ].each { |key| ENV.delete(key) }
  end

  def argv_sections(path)
    File.read(path).split(/^---\n/).drop(1).map do |section|
      section.lines.grep(/^arg=/).map { |line| line.delete_prefix("arg=").chomp }
    end
  end

  def value_after(args, flag)
    index = args.index(flag)
    index && args[index + 1]
  end
end

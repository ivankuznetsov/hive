require "test_helper"
require "json"
require "hive/stages/base"
require "hive/task"
require "hive/usage_db"

class StagesBaseUsageTest < Minitest::Test
  include HiveTestHelper

  FAKE_BIN = File.expand_path("../fixtures/fake-claude", __dir__)

  def setup
    @old_bin = ENV["HIVE_CLAUDE_BIN"]
    @old_usage_path = Hive::UsageDb.path
    ENV["HIVE_CLAUDE_BIN"] = FAKE_BIN
    Hive::AgentProfile.reset_version_cache!
  end

  def teardown
    ENV["HIVE_CLAUDE_BIN"] = @old_bin
    Hive::UsageDb.path = @old_usage_path
    %w[
      HIVE_FAKE_CLAUDE_OUTPUT HIVE_FAKE_CLAUDE_EXIT
      HIVE_FAKE_CLAUDE_WRITE_FILE HIVE_FAKE_CLAUDE_WRITE_CONTENT
    ].each { |key| ENV.delete(key) }
    Hive::AgentProfile.reset_version_cache!
  end

  def make_task(root, stage = "2-brainstorm", slug = "usage-task-260524-abcd")
    folder = File.join(root, ".hive-state", "stages", stage, slug)
    FileUtils.mkdir_p(folder)
    Hive::Task.new(folder)
  end

  def with_usage_db(root)
    Hive::UsageDb.path = File.join(root, "usage.db")
    yield
  end

  def configure_fake_agent(task, usage: true, exit_code: 0)
    ENV["HIVE_FAKE_CLAUDE_OUTPUT"] = usage ? usage_result_json : JSON.generate("type" => "result", "result" => "done")
    ENV["HIVE_FAKE_CLAUDE_EXIT"] = exit_code.to_s
    ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = task.state_file
    ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## Round 1\n<!-- WAITING -->\n"
  end

  def usage_result_json
    JSON.generate(
      "type" => "result",
      "result" => "done",
      "usage" => {
        "input_tokens" => 321,
        "output_tokens" => 123,
        "cache_read_input_tokens" => 20,
        "cache_creation_input_tokens" => 10
      },
      "modelUsage" => {
        "claude-opus-4-7" => { "inputTokens" => 321 }
      }
    )
  end

  def token_usage_rows
    require "sqlite3"

    db = SQLite3::Database.new(Hive::UsageDb.path)
    db.results_as_hash = true
    db.execute("SELECT * FROM token_usage ORDER BY started_at")
  ensure
    db&.close
  end

  def spawn(task, profile: nil)
    Hive::Stages::Base.spawn_agent(
      task,
      prompt: "collect usage",
      max_budget_usd: 1,
      timeout_sec: 5,
      profile: profile
    )
  end

  def test_spawn_agent_records_one_usage_row
    with_tmp_dir do |root|
      task = make_task(root, "2-brainstorm", "usage-task-260524-abcd")
      with_usage_db(root) do
        configure_fake_agent(task)

        result = spawn(task)
        rows = token_usage_rows

        assert_equal :waiting, result[:status]
        assert_equal 1, rows.size
        row = rows.first
        assert_equal "claude", row.fetch("agent")
        assert_equal "claude-opus-4-7", row.fetch("model")
        assert_equal File.basename(root), row.fetch("project_slug")
        assert_equal "usage-task-260524-abcd", row.fetch("task_slug")
        assert_equal "2-brainstorm", row.fetch("stage")
        assert_equal 321, row.fetch("input")
        assert_equal 123, row.fetch("output")
        assert_equal 30, row.fetch("cached")
      end
    end
  end

  def test_spawn_without_usage_extractor_inserts_no_row
    with_tmp_dir do |root|
      task = make_task(root)
      with_usage_db(root) do
        configure_fake_agent(task, usage: false)
        profile = Hive::AgentProfile.new(
          name: :no_usage,
          bin_default: FAKE_BIN,
          env_bin_override_key: "HIVE_CLAUDE_BIN",
          headless_flag: "-p",
          version_flag: "--version",
          skill_syntax_format: "/%{skill}",
          status_detection_mode: :state_file_marker
        )

        result = spawn(task, profile: profile)

        assert_equal :waiting, result[:status]
        refute File.exist?(Hive::UsageDb.path)
      end
    end
  end

  def test_profile_without_model_capability_fails_instead_of_dropping_controls
    with_tmp_dir do |root|
      task = make_task(root)
      with_usage_db(root) do
        configure_fake_agent(task, usage: false)
        profile = Hive::AgentProfile.new(
          name: :codex,
          bin_default: FAKE_BIN,
          env_bin_override_key: "HIVE_CLAUDE_BIN",
          headless_flag: "-p",
          version_flag: "--version",
          skill_syntax_format: "/%{skill}",
          status_detection_mode: :state_file_marker
        )

        error = assert_raises(Hive::ConfigError) do
          Hive::Stages::Base.spawn_agent(
            task,
            prompt: "collect usage",
            max_budget_usd: 1,
            timeout_sec: 5,
            profile: profile,
            model: "opus",
            effort: "high"
          )
        end

        assert_includes error.message, "agent profile :codex does not support model selection"
        refute File.exist?(File.join(task.log_dir, "config-warnings.log"))
      end
    end
  end

  def test_custom_profile_with_native_renderers_runs_requested_controls
    with_tmp_dir do |root|
      task = make_task(root)
      configure_fake_agent(task, usage: false)
      with_env("HIVE_FAKE_CLAUDE_LOG_DIR" => root) do
        profile = Hive::AgentProfile.new(
          name: :codex,
          bin_default: FAKE_BIN,
          env_bin_override_key: "HIVE_CLAUDE_BIN",
          headless_flag: "-p",
          version_flag: "--version",
          skill_syntax_format: "/%{skill}",
          status_detection_mode: :state_file_marker,
          model_renderer: ->(value) { [ "--model", value ] },
          effort_renderer: ->(value) { [ "-c", %(model_reasoning_effort="#{value}") ] },
          effort_values: %w[high]
        )

        result = Hive::Stages::Base.spawn_agent(
          task,
          prompt: "collect usage",
          max_budget_usd: 1,
          timeout_sec: 5,
          profile: profile,
          model: "custom-model",
          effort: "high"
        )

        assert_equal :waiting, result[:status]
        argv = File.read(File.join(root, "fake-claude-argv.log"))
        assert_includes argv, "arg=--model"
        assert_includes argv, "arg=custom-model"
        assert_includes argv, 'arg=model_reasoning_effort="high"'
      end
    end
  end

  def test_non_zero_exit_still_records_captured_usage
    with_tmp_dir do |root|
      task = make_task(root)
      with_usage_db(root) do
        configure_fake_agent(task, exit_code: 1)

        result = spawn(task)
        rows = token_usage_rows

        assert_equal :error, result[:status]
        assert_equal 1, rows.size
        assert_equal 321, rows.first.fetch("input")
      end
    end
  end

  def test_usage_db_failure_does_not_fail_spawn
    with_tmp_dir do |root|
      task = make_task(root)
      configure_fake_agent(task)
      Hive::UsageDb.path = root

      _out, err = capture_io do
        result = spawn(task)
        assert_equal :waiting, result[:status]
      end

      assert_match(/usage record failed/, err)
    end
  end
  def test_base_usage_helpers_handle_synthetic_task_shapes
    project_task = Struct.new(:project_root, :folder).new("/tmp/project-alpha", "/tmp/project-alpha/.hive-state/stages/6-review/slug")
    folder_task = Struct.new(:folder).new("/tmp/project/.hive-state/stages/6-review/slug")
    stage_task = Struct.new(:stage_name, :folder).new("6-review", "/tmp/project/.hive-state/stages/6-review/slug")

    assert_equal "project-alpha", Hive::Stages::Base.usage_project_slug(project_task)
    assert_nil Hive::Stages::Base.usage_project_slug(folder_task)
    assert_equal "slug", Hive::Stages::Base.usage_task_slug(folder_task)
    assert_equal "6-review", Hive::Stages::Base.usage_stage_label(stage_task)
    assert_equal "6-review", Hive::Stages::Base.usage_stage_label(folder_task)
  end

  def test_record_usage_warns_and_continues_when_usage_db_fails
    task = Struct.new(:project_name, :slug, :stage_index, :stage_name, :folder).new(
      "alpha", "slug", 6, "review", "/tmp/slug"
    )
    profile = Struct.new(:name).new(:claude)

    _out, err = capture_io do
      with_replaced_singleton_method(Hive::UsageDb, :record!, ->(**_kwargs) { raise "db locked" }) do
        assert_nil Hive::Stages::Base.record_usage(
          task,
          profile,
          { usage: { input: 1, output: 2, cached: 3 }, model: "m" },
          Time.utc(2026, 5, 25)
        )
      end
    end

    assert_match(/usage record failed: db locked/, err)
  end
end

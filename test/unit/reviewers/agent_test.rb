require "test_helper"
require "hive/reviewers"
require "hive/agent_profiles"

class ReviewersAgentTest < Minitest::Test
  include HiveTestHelper

  FAKE_BIN = File.expand_path("../../fixtures/fake-claude", __dir__)

  def setup
    @prev_bin = ENV["HIVE_CLAUDE_BIN"]
    ENV["HIVE_CLAUDE_BIN"] = FAKE_BIN
    Hive::AgentProfile.reset_version_cache!
  end

  def teardown
    ENV["HIVE_CLAUDE_BIN"] = @prev_bin
    %w[HIVE_FAKE_CLAUDE_OUTPUT HIVE_FAKE_CLAUDE_EXIT
       HIVE_FAKE_CLAUDE_WRITE_FILE HIVE_FAKE_CLAUDE_WRITE_CONTENT
       HIVE_FAKE_CLAUDE_LOG_DIR].each { |k| ENV.delete(k) }
    Hive::AgentProfile.reset_version_cache!
  end

  def make_ctx(dir)
    Hive::Reviewers::Context.new(
      worktree_path: dir,
      task_folder: File.join(dir, ".hive-state", "stages", "5-review", "test"),
      default_branch: "main",
      pass: 1
    )
  end

  def make_spec(overrides = {})
    {
      "name" => "claude-ce-code-review",
      "kind" => "agent",
      "agent" => "claude",
      "skill" => "ce-code-review",
      "output_basename" => "claude-ce-code-review",
      "prompt_template" => "reviewer_claude_ce_code_review.md.erb",
      "budget_usd" => 50,
      "timeout_sec" => 5
    }.merge(overrides)
  end

  def test_run_returns_ok_when_agent_writes_expected_output_file
    with_tmp_dir do |dir|
      ctx = make_ctx(dir)
      FileUtils.mkdir_p(ctx.task_folder)
      reviewer = Hive::Reviewers::Agent.new(make_spec, ctx)

      ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = reviewer.output_path
      ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## High\n- [ ] finding: justification\n"

      result = reviewer.run!

      assert result.ok?, "expected :ok status, got #{result.status} (#{result.error_message})"
      assert_equal reviewer.output_path, result.output_path
      assert File.exist?(reviewer.output_path)
      assert_includes File.read(reviewer.output_path), "## High"
    end
  end

  def test_run_returns_error_when_agent_does_not_write_output_file
    with_tmp_dir do |dir|
      ctx = make_ctx(dir)
      FileUtils.mkdir_p(ctx.task_folder)
      reviewer = Hive::Reviewers::Agent.new(make_spec, ctx)
      # Fake claude exits 0 but doesn't write the expected file.

      result = reviewer.run!

      assert result.error?
      assert_match(/missing or empty/, result.error_message)
    end
  end

  def test_run_returns_error_when_agent_exits_nonzero
    with_tmp_dir do |dir|
      ctx = make_ctx(dir)
      FileUtils.mkdir_p(ctx.task_folder)
      reviewer = Hive::Reviewers::Agent.new(make_spec, ctx)
      ENV["HIVE_FAKE_CLAUDE_EXIT"] = "2"

      result = reviewer.run!

      assert result.error?
      assert_match(/exit_code=2/, result.error_message)
    end
  end

  def test_orchestrator_marker_is_not_clobbered_by_reviewer_spawn
    # Crucial regression: the 5-review runner sets REVIEW_WORKING phase=reviewers
    # before spawning each reviewer. The reviewer's spawn must not overwrite
    # that marker with :agent_working — that contract is gated by the
    # claude profile's :output_file_exists status_detection_mode (per U4).
    with_tmp_dir do |dir|
      ctx = make_ctx(dir)
      FileUtils.mkdir_p(ctx.task_folder)
      task_md = File.join(ctx.task_folder, "task.md")
      File.write(task_md, "## Implementation\n\n<!-- REVIEW_WORKING phase=reviewers pass=1 -->\n")

      reviewer = Hive::Reviewers::Agent.new(make_spec, ctx)
      ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = reviewer.output_path
      ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## High\n- [ ] f: j\n"

      reviewer.run!

      content = File.read(task_md)
      assert_includes content, "<!-- REVIEW_WORKING phase=reviewers pass=1 -->",
                      "orchestrator-set REVIEW_WORKING must survive the reviewer spawn"
      refute_includes content, "AGENT_WORKING",
                      ":output_file_exists mode must not write task.state_file"
    end
  end

  def test_argv_invokes_claude_with_expected_skill_in_prompt
    with_tmp_dir do |dir|
      ctx = make_ctx(dir)
      FileUtils.mkdir_p(ctx.task_folder)
      reviewer = Hive::Reviewers::Agent.new(make_spec, ctx)

      log_dir = Dir.mktmpdir("fake-claude-argv")
      ENV["HIVE_FAKE_CLAUDE_LOG_DIR"] = log_dir
      ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = reviewer.output_path
      ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## High\n- [ ] f: j\n"

      reviewer.run!

      argv = File.read(File.join(log_dir, "fake-claude-argv.log"))
      # The rendered prompt is the last positional argv arg.
      assert_includes argv, "/ce-code-review", "prompt must invoke /ce-code-review skill"
      assert_includes argv, ctx.task_folder, "prompt must mention the task folder"
      assert_includes argv, "git diff main..HEAD", "prompt must invoke the diff against the default branch"
    ensure
      FileUtils.rm_rf(log_dir) if log_dir
    end
  end
end

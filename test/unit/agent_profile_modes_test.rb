require "test_helper"
require "hive/markers"
require "hive/lock"
require "hive/config"
require "hive/task"
require "hive/agent"
require "hive/agent_profile"
require "hive/agent_profiles"

# Coverage for the three Hive::Agent#handle_exit modes that the per-CLI
# AgentProfile selects between. The default :state_file_marker mode (today's
# claude behavior) is exercised by test/unit/agent_test.rb; this file adds
# coverage for :exit_code_only and :output_file_exists, plus per-profile
# build_cmd shape checks.
class AgentProfileModesTest < Minitest::Test
  include HiveTestHelper

  FAKE_BIN = File.expand_path("../fixtures/fake-claude", __dir__)

  def setup
    @prev_bin = ENV["HIVE_CLAUDE_BIN"]
    ENV["HIVE_CLAUDE_BIN"] = FAKE_BIN
    Hive::AgentProfile.reset_version_cache!
  end

  def teardown
    ENV["HIVE_CLAUDE_BIN"] = @prev_bin
    %w[HIVE_FAKE_CLAUDE_OUTPUT HIVE_FAKE_CLAUDE_EXIT
       HIVE_FAKE_CLAUDE_WRITE_FILE HIVE_FAKE_CLAUDE_WRITE_CONTENT
       HIVE_FAKE_CLAUDE_HANG HIVE_FAKE_CLAUDE_LOG_DIR
       HIVE_FAKE_CLAUDE_VERSION].each { |k| ENV.delete(k) }
    Hive::AgentProfile.reset_version_cache!
  end

  def make_task(dir, stage = "2-brainstorm", slug = "agent-modes-260425-aaaa")
    folder = File.join(dir, ".hive-state", "stages", stage, slug)
    FileUtils.mkdir_p(folder)
    Hive::Task.new(folder)
  end

  def make_profile(mode, overrides = {})
    Hive::AgentProfile.new(
      name: :test,
      bin_default: "claude",
      env_bin_override_key: "HIVE_CLAUDE_BIN",
      headless_flag: "-p",
      permission_skip_flag: "--dangerously-skip-permissions",
      add_dir_flag: "--add-dir",
      output_format_flags: [ "--verbose" ],
      version_flag: "--version",
      skill_syntax_format: "/%{skill}",
      status_detection_mode: mode,
      **overrides
    )
  end

  # --- :exit_code_only mode -------------------------------------------------

  def test_exit_code_only_returns_ok_on_zero_exit
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "")
      result = Hive::Agent.new(
        task: task, prompt: "test",
        max_budget_usd: 1, timeout_sec: 5,
        profile: make_profile(:exit_code_only)
      ).run!
      assert_equal :ok, result[:status]
    end
  end

  def test_exit_code_only_returns_error_on_nonzero_exit
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "")
      ENV["HIVE_FAKE_CLAUDE_EXIT"] = "2"
      result = Hive::Agent.new(
        task: task, prompt: "test",
        max_budget_usd: 1, timeout_sec: 5,
        profile: make_profile(:exit_code_only)
      ).run!
      assert_equal :error, result[:status]
      assert_equal :error, Hive::Markers.current(task.state_file).name
    end
  end

  # --- :output_file_exists mode --------------------------------------------

  def test_output_file_exists_ok_when_file_present_and_nonempty
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "")
      output_path = File.join(task.folder, "reviews", "expected-out.md")
      ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = output_path
      ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## High\n- [ ] finding\n"
      FileUtils.mkdir_p(File.dirname(output_path))

      result = Hive::Agent.new(
        task: task, prompt: "test",
        max_budget_usd: 1, timeout_sec: 5,
        profile: make_profile(:output_file_exists),
        expected_output: output_path
      ).run!

      assert_equal :ok, result[:status]
    end
  end

  def test_output_file_exists_error_when_file_missing
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "")
      output_path = File.join(task.folder, "reviews", "missing.md")

      result = Hive::Agent.new(
        task: task, prompt: "test",
        max_budget_usd: 1, timeout_sec: 5,
        profile: make_profile(:output_file_exists),
        expected_output: output_path
      ).run!

      assert_equal :error, result[:status]
      assert_match(/missing or empty/, result[:error_message])
    end
  end

  def test_output_file_exists_error_when_file_empty
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "")
      output_path = File.join(task.folder, "reviews", "empty.md")
      FileUtils.mkdir_p(File.dirname(output_path))
      File.write(output_path, "")

      result = Hive::Agent.new(
        task: task, prompt: "test",
        max_budget_usd: 1, timeout_sec: 5,
        profile: make_profile(:output_file_exists),
        expected_output: output_path
      ).run!

      assert_equal :error, result[:status]
      assert_match(/missing or empty/, result[:error_message])
    end
  end

  def test_output_file_exists_error_when_no_path_given
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "")
      result = Hive::Agent.new(
        task: task, prompt: "test",
        max_budget_usd: 1, timeout_sec: 5,
        profile: make_profile(:output_file_exists)
        # no expected_output passed
      ).run!
      assert_equal :error, result[:status]
      assert_match(/no expected_output was provided/, result[:error_message])
    end
  end

  def test_output_file_exists_error_when_exit_nonzero
    with_tmp_dir do |dir|
      task = make_task(dir)
      File.write(task.state_file, "")
      output_path = File.join(task.folder, "reviews", "out.md")
      FileUtils.mkdir_p(File.dirname(output_path))
      File.write(output_path, "non-empty content")
      ENV["HIVE_FAKE_CLAUDE_EXIT"] = "3"

      result = Hive::Agent.new(
        task: task, prompt: "test",
        max_budget_usd: 1, timeout_sec: 5,
        profile: make_profile(:output_file_exists),
        expected_output: output_path
      ).run!

      # Even though the file exists, exit_code != 0 means agent failed.
      assert_equal :error, result[:status]
    end
  end

  # --- per-profile build_cmd shape (claude / codex / pi) -------------------

  def test_claude_profile_build_cmd_matches_legacy_shape
    with_tmp_dir do |dir|
      task = make_task(dir)
      log_dir = Dir.mktmpdir("fake-claude-argv")
      ENV["HIVE_FAKE_CLAUDE_LOG_DIR"] = log_dir
      File.write(task.state_file, "<!-- WAITING -->\n")
      Hive::Agent.new(
        task: task, prompt: "do work",
        max_budget_usd: 5, timeout_sec: 5,
        add_dirs: [ dir ],
        profile: Hive::AgentProfiles.lookup(:claude)
      ).run!
      argv = File.read(File.join(log_dir, "fake-claude-argv.log"))
      # Same flags the pre-refactor test asserts against — claude profile
      # must reproduce today's argv exactly.
      assert_includes argv, "arg=-p"
      assert_includes argv, "arg=--dangerously-skip-permissions"
      assert_includes argv, "arg=--add-dir"
      assert_includes argv, "arg=#{dir}"
      assert_includes argv, "arg=--max-budget-usd"
      assert_includes argv, "arg=5"
      assert_includes argv, "arg=--output-format"
      assert_includes argv, "arg=stream-json"
      assert_includes argv, "arg=--include-partial-messages"
      assert_includes argv, "arg=--verbose"
      assert_includes argv, "arg=--no-session-persistence"
      assert_includes argv, "arg=do work"
    ensure
      FileUtils.rm_rf(log_dir) if log_dir
    end
  end

  def test_codex_profile_build_cmd_uses_correct_flags
    profile = Hive::AgentProfiles.lookup(:codex)
    with_tmp_dir do |dir|
      task = make_task(dir)
      agent = Hive::Agent.new(
        task: task, prompt: "do work",
        max_budget_usd: 5, timeout_sec: 5,
        add_dirs: [ dir, "/tmp/extra" ],
        profile: profile
      )
      cmd = agent.build_cmd
      # bin first
      assert_equal profile.bin, cmd[0]
      # exec subcommand instead of -p
      assert_equal "exec", cmd[1]
      # codex's bypass flag (different name from claude's)
      assert_includes cmd, "--dangerously-bypass-approvals-and-sandbox"
      # --add-dir is single-arg, repeated for each dir
      add_dir_indices = cmd.each_index.select { |i| cmd[i] == "--add-dir" }
      assert_equal 2, add_dir_indices.size, "expected --add-dir repeated once per dir"
      assert_equal dir, cmd[add_dir_indices[0] + 1]
      assert_equal "/tmp/extra", cmd[add_dir_indices[1] + 1]
      # codex has no budget flag — --max-budget-usd must NOT appear
      refute_includes cmd, "--max-budget-usd"
      # codex output format is --json
      assert_includes cmd, "--json"
      # claude-only flags must not appear
      refute_includes cmd, "--dangerously-skip-permissions"
      refute_includes cmd, "--include-partial-messages"
      refute_includes cmd, "--no-session-persistence"
      # prompt last
      assert_equal "do work", cmd.last
    end
  end

  def test_pi_profile_build_cmd_skips_missing_flags
    profile = Hive::AgentProfiles.lookup(:pi)
    with_tmp_dir do |dir|
      task = make_task(dir)
      agent = Hive::Agent.new(
        task: task, prompt: "do work",
        max_budget_usd: 5, timeout_sec: 5,
        add_dirs: [ dir ], # passed but pi has no add_dir_flag → ignored
        profile: profile
      )
      cmd = agent.build_cmd
      assert_equal profile.bin, cmd[0]
      assert_includes cmd, "-p"
      # No add_dir_flag → no --add-dir appears even though add_dirs was passed
      refute_includes cmd, "--add-dir"
      refute_includes cmd, dir
      # No permission_skip_flag → none of those flags appear
      refute_includes cmd, "--dangerously-skip-permissions"
      refute_includes cmd, "--dangerously-bypass-approvals-and-sandbox"
      # No budget_flag → --max-budget-usd not present
      refute_includes cmd, "--max-budget-usd"
      # pi output format
      assert_includes cmd, "--mode"
      assert_includes cmd, "json"
      assert_includes cmd, "--no-session"
      # prompt last
      assert_equal "do work", cmd.last
    end
  end

  # --- backward compat: default profile is claude ---------------------------

  def test_agent_without_profile_kwarg_defaults_to_claude
    with_tmp_dir do |dir|
      task = make_task(dir)
      log_dir = Dir.mktmpdir("fake-claude-argv")
      ENV["HIVE_FAKE_CLAUDE_LOG_DIR"] = log_dir
      File.write(task.state_file, "<!-- WAITING -->\n")
      # Construct with NO profile: kwarg — must default to claude.
      agent = Hive::Agent.new(
        task: task, prompt: "x",
        max_budget_usd: 1, timeout_sec: 5
      )
      assert_equal :claude, agent.profile.name
      agent.run!
      argv = File.read(File.join(log_dir, "fake-claude-argv.log"))
      assert_includes argv, "arg=--dangerously-skip-permissions"
    ensure
      FileUtils.rm_rf(log_dir) if log_dir
    end
  end

  # --- backward compat: legacy class methods still work ---------------------

  def test_agent_bin_class_method_returns_claude_profile_bin
    assert_equal FAKE_BIN, Hive::Agent.bin
  end

  def test_agent_check_version_class_method_delegates_to_claude_profile
    # Should not raise; fake-claude returns "2.1.118 (Claude Code)" by default.
    assert Hive::Agent.check_version!
  end
end

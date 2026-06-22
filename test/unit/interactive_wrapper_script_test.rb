require "test_helper"
require "open3"

class InteractiveWrapperScriptTest < Minitest::Test
  include HiveTestHelper

  SCRIPT = File.expand_path("../../lib/hive/scripts/interactive_claude_wrapper.sh", __dir__)
  FAKE_BIN = File.expand_path("../fixtures/fake-claude", __dir__)

  def teardown
    %w[HIVE_FAKE_CLAUDE_LOG_DIR ANTHROPIC_API_KEY CLAUDE_API_KEY
       HIVE_SCREENOTE_API_TOKEN HIVE_SCREENOTE_BASE_URL].each { |key| ENV.delete(key) }
  end

  def test_script_syntax
    assert system("sh", "-n", SCRIPT)
  end

  def test_execs_claude_interactively_with_cwd_add_dirs_and_api_keys_unset
    with_tmp_dir do |dir|
      log_dir = File.join(dir, "logs")
      add_one = File.join(dir, "add one")
      add_two = File.join(dir, "add-two")
      FileUtils.mkdir_p([ log_dir, add_one, add_two ])

      env = {
        "HIVE_FAKE_CLAUDE_LOG_DIR" => log_dir,
        "ANTHROPIC_API_KEY" => "parent-anthropic-key",
        "CLAUDE_API_KEY" => "parent-claude-key",
        "HIVE_SCREENOTE_API_TOKEN" => "parent-screenote-token",
        "HIVE_SCREENOTE_BASE_URL" => "https://screenote.parent"
      }
      _out, err, status = Open3.capture3(
        env,
        SCRIPT,
        "--cwd", dir,
        "--add-dir", add_one,
        "--add-dir", add_two,
        "--bin", FAKE_BIN
      )

      assert status.success?, err
      argv_log = File.read(File.join(log_dir, "fake-claude-argv.log"))
      assert_includes argv_log, "cwd=#{dir}"
      assert_includes argv_log, "env_ANTHROPIC_API_KEY=__unset__"
      assert_includes argv_log, "env_CLAUDE_API_KEY=__unset__"
      # The artifacts agent spawns through this wrapper; its screenote
      # credentials belong to the parent upload, never the agent's Bash.
      assert_includes argv_log, "env_HIVE_SCREENOTE_API_TOKEN=__unset__"
      assert_includes argv_log, "env_HIVE_SCREENOTE_BASE_URL=__unset__"
      refute_includes argv_log, "arg=-p"
      refute_includes argv_log, "arg=--dangerously-skip-permissions"
      assert_equal [ "--add-dir", add_one, "--add-dir", add_two ], argv_args(argv_log)
    end
  end

  # The case-arm passthrough is the layer the Ruby-side argv tests cannot
  # see: a typo'd pattern makes the script reject its OWN argv (usage, exit
  # 64) and every tmux claude launch fails while the suite stays green.
  def test_model_and_effort_flags_pass_through_to_claude
    Dir.mktmpdir("hive-wrapper") do |dir|
      log_dir = File.join(dir, "logs")
      FileUtils.mkdir_p(log_dir)

      _out, err, status = Open3.capture3(
        { "HIVE_FAKE_CLAUDE_LOG_DIR" => log_dir },
        SCRIPT,
        "--cwd", dir,
        "--model", "sonnet",
        "--effort", "low",
        "--bin", FAKE_BIN
      )

      assert status.success?, err
      argv_log = File.read(File.join(log_dir, "fake-claude-argv.log"))
      assert_equal [ "--model", "sonnet", "--effort", "low" ], argv_args(argv_log),
                   "the wrapper must forward the model/effort pins to claude in order"
    end
  end

  def test_missing_required_cwd_exits_nonzero
    _out, err, status = Open3.capture3(SCRIPT, "--bin", FAKE_BIN)

    refute status.success?
    assert_match(/--cwd is required/, err)
  end

  def test_multiple_add_dir_flags_survive_in_order
    with_tmp_dir do |dir|
      log_dir = File.join(dir, "logs")
      FileUtils.mkdir_p(log_dir)
      env = { "HIVE_FAKE_CLAUDE_LOG_DIR" => log_dir }

      _out, err, status = Open3.capture3(
        env,
        SCRIPT,
        "--cwd", dir,
        "--add-dir", "/one",
        "--add-dir", "/two",
        "--add-dir", "/three",
        "--bin", FAKE_BIN
      )

      assert status.success?, err
      argv_log = File.read(File.join(log_dir, "fake-claude-argv.log"))
      assert_equal [ "--add-dir", "/one", "--add-dir", "/two", "--add-dir", "/three" ], argv_args(argv_log)
    end
  end

  def test_permission_mode_and_tool_scope_flags_are_forwarded_to_claude
    with_tmp_dir do |dir|
      log_dir = File.join(dir, "logs")
      FileUtils.mkdir_p(log_dir)
      env = { "HIVE_FAKE_CLAUDE_LOG_DIR" => log_dir }

      _out, err, status = Open3.capture3(
        env,
        SCRIPT,
        "--cwd", dir,
        "--permission-mode", "bypassPermissions",
        "--allowedTools", "Read,Write,Edit,LS",
        "--disallowedTools", "Bash,Write",
        "--bin", FAKE_BIN
      )

      assert status.success?, err
      argv_log = File.read(File.join(log_dir, "fake-claude-argv.log"))
      assert_equal [
        "--permission-mode", "bypassPermissions",
        "--allowedTools", "Read,Write,Edit,LS",
        "--disallowedTools", "Bash,Write"
      ], argv_args(argv_log)
    end
  end

  def test_dangerously_skip_permissions_flag_is_forwarded_to_claude
    with_tmp_dir do |dir|
      log_dir = File.join(dir, "logs")
      FileUtils.mkdir_p(log_dir)
      env = { "HIVE_FAKE_CLAUDE_LOG_DIR" => log_dir }

      _out, err, status = Open3.capture3(
        env,
        SCRIPT,
        "--cwd", dir,
        "--dangerously-skip-permissions",
        "--allowedTools", "Read,Write,Edit,LS",
        "--bin", FAKE_BIN
      )

      assert status.success?, err
      argv_log = File.read(File.join(log_dir, "fake-claude-argv.log"))
      assert_equal [ "--dangerously-skip-permissions", "--allowedTools", "Read,Write,Edit,LS" ], argv_args(argv_log)
    end
  end

  private

  def argv_args(log)
    log.lines.filter_map do |line|
      line.delete_prefix("arg=").strip if line.start_with?("arg=")
    end
  end
end

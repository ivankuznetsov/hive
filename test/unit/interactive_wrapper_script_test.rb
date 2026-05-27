require "test_helper"
require "open3"

class InteractiveWrapperScriptTest < Minitest::Test
  include HiveTestHelper

  SCRIPT = File.expand_path("../../lib/hive/scripts/interactive_claude_wrapper.sh", __dir__)
  FAKE_BIN = File.expand_path("../fixtures/fake-claude", __dir__)

  def teardown
    %w[HIVE_FAKE_CLAUDE_LOG_DIR ANTHROPIC_API_KEY CLAUDE_API_KEY].each { |key| ENV.delete(key) }
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
        "CLAUDE_API_KEY" => "parent-claude-key"
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
      refute_includes argv_log, "arg=-p"
      refute_includes argv_log, "arg=--dangerously-skip-permissions"
      assert_equal [ "--add-dir", add_one, "--add-dir", add_two ], argv_args(argv_log)
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

  def test_permission_mode_and_allowed_tools_are_forwarded_to_claude
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
        "--bin", FAKE_BIN
      )

      assert status.success?, err
      argv_log = File.read(File.join(log_dir, "fake-claude-argv.log"))
      assert_equal [ "--permission-mode", "bypassPermissions", "--allowedTools", "Read,Write,Edit,LS" ], argv_args(argv_log)
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
